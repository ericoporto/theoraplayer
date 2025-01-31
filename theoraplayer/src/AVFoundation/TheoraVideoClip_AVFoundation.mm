/************************************************************************************
This source file is part of the Theora Video Playback Library
For latest info, see http://libtheoraplayer.googlecode.com
*************************************************************************************
Copyright (c) 2008-2014 Kresimir Spes (kspes@cateia.com)
This program is free software; you can redistribute it and/or modify it under
the terms of the BSD license: http://opensource.org/licenses/BSD-3-Clause
*************************************************************************************/
#ifdef __AVFOUNDATION
#define AVFOUNDATION_CLASSES_DEFINED
#import <AVFoundation/AVFoundation.h>
#include "TheoraAudioInterface.h"
#include "TheoraDataSource.h"
#include "TheoraException.h"
#include "TheoraTimer.h"
#include "TheoraUtil.h"
#include "TheoraFrameQueue.h"
#include "TheoraVideoFrame.h"
#include "TheoraVideoManager.h"
#include "TheoraVideoClip_AVFoundation.h"
#include "TheoraPixelTransform.h"

#ifdef _AVFOUNDATION_BGRX
// a fast function developed to use kernel byte swapping calls to optimize alpha decoding.
// In AVFoundation, BGRX mode conversion is prefered to YUV conversion because apple's YUV
// conversion on iOS seems to run faster than libtheoraplayer's implementation
// This may change in the future with more optimizations to libtheoraplayers's YUV conversion
// code, making this function obsolete.
static void bgrx2rgba(unsigned char* dest, int w, int h, struct TheoraPixelTransform* t)
{
	unsigned register int a;
	unsigned int *dst = (unsigned int*) dest, *dstEnd;
	unsigned char* src = t->raw;
	int y, x, ax;
	
	for (y = 0; y < h; ++y, src += t->rawStride)
	{
		for (x = 0, ax = w * 4, dstEnd = dst + w; dst != dstEnd; x += 4, ax += 4, ++dst)
		{
			// use the full alpha range here because the Y channel has already been converted
			// to RGB and that's in [0, 255] range.
			a = src[ax];
			*dst = (OSReadSwapInt32(src, x) >> 8) | (a << 24);
		}
	}
}
#endif

static CVPlanarPixelBufferInfo_YCbCrPlanar getYUVStruct(void* src)
{
	CVPlanarPixelBufferInfo_YCbCrPlanar* bigEndianYuv = (CVPlanarPixelBufferInfo_YCbCrPlanar*) src;
	CVPlanarPixelBufferInfo_YCbCrPlanar yuv;
	yuv.componentInfoY.offset = OSSwapInt32(bigEndianYuv->componentInfoY.offset);
	yuv.componentInfoY.rowBytes = OSSwapInt32(bigEndianYuv->componentInfoY.rowBytes);
	yuv.componentInfoCb.offset = OSSwapInt32(bigEndianYuv->componentInfoCb.offset);
	yuv.componentInfoCb.rowBytes = OSSwapInt32(bigEndianYuv->componentInfoCb.rowBytes);
	yuv.componentInfoCr.offset = OSSwapInt32(bigEndianYuv->componentInfoCr.offset);
	yuv.componentInfoCr.rowBytes = OSSwapInt32(bigEndianYuv->componentInfoCr.rowBytes);
	return yuv;
}

TheoraVideoClip_AVFoundation::TheoraVideoClip_AVFoundation(TheoraDataSource* data_source,
											   TheoraOutputMode output_mode,
											   int nPrecachedFrames,
											   bool usePower2Stride):
	TheoraVideoClip(data_source, output_mode, nPrecachedFrames, usePower2Stride),
	TheoraAudioPacketQueue()
{
	this->loaded = 0;
	this->reader = NULL;
	this->output = this->audioOutput = NULL;
	this->readAudioSamples = this->audioFrequency = this->numAudioChannels = 0;
}

TheoraVideoClip_AVFoundation::~TheoraVideoClip_AVFoundation()
{
	unload();
}

void TheoraVideoClip_AVFoundation::unload()
{
	if (this->output != NULL || this->audioOutput != NULL || this->reader != NULL)
	{
		NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

		if (this->output != NULL)
		{
			[this->output release];
			this->output = NULL;
		}
		
		if (this->audioOutput)
		{
			[this->audioOutput release];
			this->audioOutput = NULL;
		}
		
		if (this->reader != NULL)
		{
			[this->reader release];
			this->reader = NULL;
		}
		
		[pool release];
	}
}

bool TheoraVideoClip_AVFoundation::_readData()
{
	return 1;
}

bool TheoraVideoClip_AVFoundation::decodeNextFrame()
{
	if (this->reader == NULL || this->endOfFile) return 0;
	AVAssetReaderStatus status = [this->reader status];
	if (status == AVAssetReaderStatusFailed)
	{
		// This can happen on iOS when you suspend the app... Only happens on the device, iOS simulator seems to work fine.
		th_writelog("AVAssetReader reading failed, restarting...");

		this->seekFrame = this->timer->getTime() * this->fps;
		// just in case
		if (this->seekFrame < 0) this->seekFrame = 0;
		if (this->seekFrame > this->duration * this->fps - 1) this->seekFrame = this->duration * this->fps - 1;
		_restart();
		status = [this->reader status];
		if (status == AVAssetReaderStatusFailed)
		{
			th_writelog("AVAssetReader restart failed!");
			return 0;
		}
		th_writelog("AVAssetReader restart succeeded!");
	}

	TheoraVideoFrame* frame = this->frameQueue->requestEmptyFrame();
	if (!frame) return 0;

	CMSampleBufferRef sampleBuffer = NULL;
	NSAutoreleasePool* pool = NULL;
	CMTime presentationTime;
	
	if (this->audioInterface) decodeAudio();
	
	if (status == AVAssetReaderStatusReading)
	{
		pool = [[NSAutoreleasePool alloc] init];
		
		while ((sampleBuffer = [this->output copyNextSampleBuffer]))
		{
			presentationTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);
			frame->timeToDisplay = (float) CMTimeGetSeconds(presentationTime);
			frame->iteration = iteration;
			frame->_setFrameNumber(this->frameNumber);
			++this->frameNumber;
			if (frame->timeToDisplay < this->timer->getTime() && !this->restarted && this->frameNumber % 16 != 0)
			{
				// %16 operation is here to prevent a playback halt during video playback if the decoder can't keep up with demand.
#ifdef _DEBUG_FRAMEDROP
				th_writelog(this->name + ": pre-dropped frame " + str(this->frameNumber - 1));
#endif
				++this->numDisplayedFrames;
				++this->numDroppedFrames;
				CMSampleBufferInvalidate(sampleBuffer);
				CFRelease(sampleBuffer);
				sampleBuffer = NULL;
				continue; // drop frame
			}

			CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
			CVPixelBufferLockBaseAddress(imageBuffer, 0);
			void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
			
			this->stride = (int) CVPixelBufferGetBytesPerRow(imageBuffer);
			size_t width = CVPixelBufferGetWidth(imageBuffer);
			size_t height = CVPixelBufferGetHeight(imageBuffer);

			TheoraPixelTransform t;
			memset(&t, 0, sizeof(TheoraPixelTransform));
#ifdef _AVFOUNDATION_BGRX
			if (this->outputMode == TH_BGRX || this->outputMode == TH_RGBA)
			{
				t.raw = (unsigned char*) baseAddress;
				t.rawStride = this->stride;
			}
			else
#endif
			{
				CVPlanarPixelBufferInfo_YCbCrPlanar yuv = getYUVStruct(baseAddress);
				
				t.y = (unsigned char*) baseAddress + yuv.componentInfoY.offset;  t.yStride = yuv.componentInfoY.rowBytes;
				t.u = (unsigned char*) baseAddress + yuv.componentInfoCb.offset; t.uStride = yuv.componentInfoCb.rowBytes;
				t.v = (unsigned char*) baseAddress + yuv.componentInfoCr.offset; t.vStride = yuv.componentInfoCr.rowBytes;
			}
#ifdef _AVFOUNDATION_BGRX
			if (this->outputMode == TH_RGBA)
			{
				unsigned char* buffer = frame->getBuffer();
				for (int i = 0; i < 1000; ++i)
				{
					bgrx2rgba(buffer, this->width / 2, this->height, &t);
				}
				frame->ready = true;
			}
			else
#endif
			frame->decode(&t);

			CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
			CMSampleBufferInvalidate(sampleBuffer);
			CFRelease(sampleBuffer);

			break; // TODO - should this really be a while loop instead of an if block?
		}
	}
	if (pool) [pool release];

	if (!frame->ready) // in case the frame wasn't used
	{
		frame->inUse = 0;
	}

	if (sampleBuffer == NULL && this->reader.status == AVAssetReaderStatusCompleted) // other cases could be app suspended
	{
		if (this->autoRestart)
		{
			++iteration;
			_restart();
		}
		else
		{
			unload();
			this->endOfFile = true;
			th_writelog(this->name + " finished playing");
		}
		return 0;
	}
	
	
	return 1;
}

void TheoraVideoClip_AVFoundation::_restart()
{
	this->endOfFile = false;
	unload();
	load(this->stream);
	this->restarted = true;
}

void TheoraVideoClip_AVFoundation::load(TheoraDataSource* source)
{
	this->stream = source;
	this->frameNumber = 0;
	this->endOfFile = false;
	TheoraFileDataSource* fileDataSource = dynamic_cast<TheoraFileDataSource*>(source);
	std::string filename;
	if (fileDataSource != NULL) filename = fileDataSource->getFilename();
	else
	{
		TheoraMemoryFileDataSource* memoryDataSource = dynamic_cast<TheoraMemoryFileDataSource*>(source);
		if (memoryDataSource != NULL) filename = memoryDataSource->getFilename();
		else
		{
			throw TheoraGenericException("Unable to load MP4 file");
		}
	}
	
	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
	NSString* path = [NSString stringWithUTF8String:filename.c_str()];
	NSError* err;
	NSURL *url = [NSURL fileURLWithPath:path];
	AVAsset* asset = [[AVURLAsset alloc] initWithURL:url options:nil];
	this->reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
	NSArray* tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
	if ([tracks count] == 0)
	{
		throw TheoraGenericException("Unable to open video file: " + filename);
	}
	AVAssetTrack *videoTrack = [tracks objectAtIndex:0];

	NSArray* audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
	AVAssetTrack *audioTrack = audioTracks.count > 0 ? [audioTracks objectAtIndex:0] : NULL;
	
#ifdef _AVFOUNDATION_BGRX
	bool yuv_output = (this->outputMode != TH_BGRX && this->outputMode != TH_RGBA);
#else
	bool yuv_output = true;
#endif
	
	NSDictionary *videoOptions = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:(yuv_output) ? kCVPixelFormatType_420YpCbCr8Planar : kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey, nil];

	this->output = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:videoOptions];
	[this->reader addOutput:this->output];
	if ([this->output respondsToSelector:@selector(setAlwaysCopiesSampleData:)]) // Not supported on iOS versions older than 5.0
		this->output.alwaysCopiesSampleData = NO;

	this->fps = videoTrack.nominalFrameRate;
	this->width = this->subFrameWidth = this->stride = videoTrack.naturalSize.width;
	this->height = this->subFrameHeight = videoTrack.naturalSize.height;
	frameDuration = 1.0f / this->fps;
	this->duration = (float) CMTimeGetSeconds(asset.duration);
	this->numFrames = this->duration * this->fps;
	if (this->frameQueue == NULL)
	{
		this->frameQueue = new TheoraFrameQueue(this);
		this->frameQueue->setSize(this->numPrecachedFrames);
	}

	if (this->seekFrame != -1)
	{
		this->frameNumber = this->seekFrame;
		[this->reader setTimeRange: CMTimeRangeMake(CMTimeMakeWithSeconds(this->seekFrame / this->fps, 1), kCMTimePositiveInfinity)];
	}
	if (audioTrack)
	{
		TheoraAudioInterfaceFactory* audio_factory = TheoraVideoManager::getSingleton().getAudioInterfaceFactory();
		if (audio_factory)
		{
			NSDictionary *audioOptions = [NSDictionary dictionaryWithObjectsAndKeys:
										  [NSNumber numberWithInt:kAudioFormatLinearPCM], AVFormatIDKey,
										  [NSNumber numberWithBool:NO], AVLinearPCMIsNonInterleaved,
										  [NSNumber numberWithBool:NO], AVLinearPCMIsBigEndianKey,
										  [NSNumber numberWithBool:YES], AVLinearPCMIsFloatKey,
										  [NSNumber numberWithInt:32], AVLinearPCMBitDepthKey,
										  nil];

			this->audioOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:audioOptions];
			[this->reader addOutput:this->audioOutput];
			if ([this->audioOutput respondsToSelector:@selector(setAlwaysCopiesSampleData:)]) // Not supported on iOS versions older than 5.0
				this->audioOutput.alwaysCopiesSampleData = NO;
			
			NSArray* desclst = audioTrack.formatDescriptions;
			CMAudioFormatDescriptionRef desc = (CMAudioFormatDescriptionRef) [desclst objectAtIndex:0];
			const AudioStreamBasicDescription* audioDesc = CMAudioFormatDescriptionGetStreamBasicDescription(desc);
			this->audioFrequency = (unsigned int) audioDesc->mSampleRate;
			this->numAudioChannels = audioDesc->mChannelsPerFrame;
			
			if (this->seekFrame != -1)
			{
				this->readAudioSamples = this->frameNumber * (this->audioFrequency * this->numAudioChannels) / this->fps;
			}
			else this->readAudioSamples = 0;

			if (this->audioInterface == NULL)
				setAudioInterface(audio_factory->createInstance(this, this->numAudioChannels, this->audioFrequency));
		}
	}
	
#ifdef _DEBUG
	else if (!this->loaded)
	{
		th_writelog("-----\nwidth: " + str(this->width) + ", height: " + str(this->height) + ", fps: " + str((int) getFps()));
		th_writelog("duration: " + strf(this->duration) + " seconds\n-----");
	}
#endif
	[this->reader startReading];
	[pool release];
	this->loaded = true;
}
 
void TheoraVideoClip_AVFoundation::decodedAudioCheck()
{
	if (!this->audioInterface || this->timer->isPaused()) return;
	
	TheoraMutex::ScopeLock lock(this->audioMutex);
	flushAudioPackets(this->audioInterface);
	lock.release();
}

float TheoraVideoClip_AVFoundation::decodeAudio()
{
	if (this->restarted) return -1;

	if (this->reader == NULL || this->endOfFile) return 0;
	AVAssetReaderStatus status = [this->reader status];

	if (this->audioOutput)
	{
		CMSampleBufferRef sampleBuffer = NULL;
		NSAutoreleasePool* pool = NULL;
		bool mutexLocked = 0;
		TheoraMutex::ScopeLock audioMutexLock;

		float factor = 1.0f / (this->audioFrequency * this->numAudioChannels);
		float videoTime = (float) this->frameNumber / this->fps;
		float min = this->frameQueue->getSize() / this->fps + 1.0f;
		
		if (status == AVAssetReaderStatusReading)
		{
			pool = [[NSAutoreleasePool alloc] init];

			// always buffer up of audio ahead of the frames
			while (this->readAudioSamples * factor - videoTime < min)
			{
				if ((sampleBuffer = [this->audioOutput copyNextSampleBuffer]))
				{
					AudioBufferList audioBufferList;
					
					CMBlockBufferRef blockBuffer = NULL;
					CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, NULL, &audioBufferList, sizeof(audioBufferList), NULL, NULL, 0, &blockBuffer);
					
					for (int y = 0; y < audioBufferList.mNumberBuffers; ++y)
					{
						AudioBuffer audioBuffer = audioBufferList.mBuffers[y];
						float *frame = (float*) audioBuffer.mData;

						if (!mutexLocked)
						{
							audioMutexLock.acquire(this->audioMutex);
							mutexLocked = 1;
						}
						addAudioPacket(frame, audioBuffer.mDataByteSize / (this->numAudioChannels * sizeof(float)), this->audioGain);
						
						this->readAudioSamples += audioBuffer.mDataByteSize / (sizeof(float));
					}

					CFRelease(blockBuffer);
					CMSampleBufferInvalidate(sampleBuffer);
					CFRelease(sampleBuffer);
				}
				else
				{
					[this->audioOutput release];
					this->audioOutput = nil;
					break;
				}
			}
			[pool release];
		}
		audioMutexLock.release();
	}
	
	return -1;
}

void TheoraVideoClip_AVFoundation::doSeek()
{
#if _DEBUG
	th_writelog(this->name + " [seek]: seeking to frame " + str(this->seekFrame));
#endif
	int frame;
	float time = this->seekFrame / getFps();
	this->timer->seek(time);
	bool paused = this->timer->isPaused();
	if (!paused) this->timer->pause(); // pause until seeking is done
	
	this->endOfFile = false;
	this->restarted = false;
	
	resetFrameQueue();
	unload();
	load(this->stream);

	if (this->audioInterface)
	{
		TheoraMutex::ScopeLock lock(this->audioMutex);
		destroyAllAudioPackets();
		lock.release();
	}

	if (!paused) this->timer->play();
	this->seekFrame = -1;
}
#endif
