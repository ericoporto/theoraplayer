/************************************************************************************
This source file is part of the Theora Video Playback Library
For latest info, see http://libtheoraplayer.googlecode.com
*************************************************************************************
Copyright (c) 2008-2014 Kresimir Spes (kspes@cateia.com)
This program is free software; you can redistribute it and/or modify it under
the terms of the BSD license: http://opensource.org/licenses/BSD-3-Clause
*************************************************************************************/
#if defined(__THEORA) && !defined(THEORA_THEORAVIDEOCLIP_WEBM_H)
#define THEORA_THEORAVIDEOCLIP_WEBM_H

#include <ogg/ogg.h>
#include <vorbis/vorbisfile.h>
#include <theora/theoradec.h>

#include "TheoraAudioPacketQueue.h"
#include "TheoraVideoClip.h"

#include "vpx/vpx_decoder.h"
#include "vpx/vp8dx.h"
#include "webmdec.h"

struct VpxDecInputContext {
	struct VpxInputContext *vpx_input_ctx;
	struct WebmInputContext *webm_ctx;
};

class TheoraVideoClip_WebM : public TheoraVideoClip, public TheoraAudioPacketQueue
{
public:
	TheoraVideoClip_WebM(TheoraDataSource* data_source,
						   TheoraOutputMode output_mode,
						   int nPrecachedFrames,
						   bool usePower2Stride);
	~TheoraVideoClip_WebM();

	bool _readData();
	bool decodeNextFrame();
	void _restart();
	void load(TheoraDataSource* source);
	float decodeAudio();
	void decodedAudioCheck();
	std::string getDecoderName() { return "WebM"; }

protected:
	vpx_codec_ctx_t decoder;
	vpx_codec_dec_cfg_t cfg;
	VpxDecInputContext input;
	VpxInputContext vpx_input_ctx;
	WebmInputContext webm_ctx;
	VpxInterface* fourcc_interface;
	VpxInterface* interf;
	vpx_image* frame;
	int frameNumber;

	void doSeek();
	unsigned long lastDecodedFrameNumber;
};

#endif
