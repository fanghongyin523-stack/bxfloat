#import "Vcu1AacBridge.h"
#import "FFRTSPBridge.h"

extern int32_t BXFloatAudioTargetRate(void);

#if BXFLOAT_HAS_FFMPEG
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>

#ifndef AV_CH_LAYOUT_MONO
#define AV_CH_LAYOUT_MONO 0x4ULL
#endif
#ifndef AV_CH_LAYOUT_STEREO
#define AV_CH_LAYOUT_STEREO 0x3ULL
#endif
#endif

#if BXFLOAT_HAS_FFMPEG
static AVCodecContext *gAacCtx = NULL;
static struct SwrContext *gSwr = NULL;
static uint8_t *gOutBuf = NULL;
static int gOutBufSamples = 0;
static int gOutRate = 44100;
static int gOutCh = 2;
static dispatch_queue_t gQueue;

static dispatch_queue_t Vcu1AacQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gQueue = dispatch_queue_create("com.baixiang.vcu1.aac", DISPATCH_QUEUE_SERIAL);
    });
    return gQueue;
}

static void Vcu1AacTeardownLocked(void) {
    if (gSwr) { swr_free(&gSwr); gSwr = NULL; }
    av_freep(&gOutBuf);
    gOutBufSamples = 0;
    if (gAacCtx) { avcodec_free_context(&gAacCtx); gAacCtx = NULL; }
}

static BOOL Vcu1AacEnsureDecoderLocked(const uint8_t *asc, int ascLen) {
    if (gAacCtx) return YES;
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_AAC);
    if (!codec) return NO;
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return NO;
    if (asc && ascLen > 0) {
        ctx->extradata = (uint8_t *)av_mallocz((size_t)ascLen + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!ctx->extradata) {
            avcodec_free_context(&ctx);
            return NO;
        }
        memcpy(ctx->extradata, asc, (size_t)ascLen);
        ctx->extradata_size = ascLen;
    }
    ctx->thread_count = 1;
    if (avcodec_open2(ctx, codec, NULL) < 0) {
        avcodec_free_context(&ctx);
        return NO;
    }
    gAacCtx = ctx;
    NSLog(@"BXFloatCam VCU1 AAC decoder open asc=%d", ascLen);
    return YES;
}

static BOOL Vcu1AacEnsureSwrLocked(AVFrame *frame) {
    int inCh = frame->channels > 0 ? frame->channels : 2;
    int inRate = frame->sample_rate > 0 ? frame->sample_rate : 44100;
    int64_t inLayout = frame->channel_layout;
    if (!inLayout) inLayout = av_get_default_channel_layout(inCh);
    int want = (int)BXFloatAudioTargetRate();
    if (want < 8000) want = inRate;
    gOutRate = want;
    gOutCh = inCh >= 2 ? 2 : 1;
    int64_t outLayout = gOutCh == 2 ? AV_CH_LAYOUT_STEREO : AV_CH_LAYOUT_MONO;
    enum AVSampleFormat inFmt = (enum AVSampleFormat)frame->format;
    if (inFmt == AV_SAMPLE_FMT_NONE) inFmt = AV_SAMPLE_FMT_FLTP;
    if (gSwr) {
        // rebuild if rate changed
        swr_free(&gSwr);
        gSwr = NULL;
    }
    gSwr = swr_alloc_set_opts(NULL, outLayout, AV_SAMPLE_FMT_S16, gOutRate,
                              inLayout, inFmt, inRate, 0, NULL);
    if (!gSwr || swr_init(gSwr) < 0) {
        if (gSwr) { swr_free(&gSwr); gSwr = NULL; }
        return NO;
    }
    return YES;
}

static void Vcu1AacPublishFrameLocked(AVFrame *frame, double pts) {
    if (!Vcu1AacEnsureSwrLocked(frame)) return;
    int inRate = frame->sample_rate > 0 ? frame->sample_rate : 44100;
    int outSamples = (int)av_rescale_rnd(
        swr_get_delay(gSwr, inRate) + frame->nb_samples, gOutRate, inRate, AV_ROUND_UP);
    if (outSamples <= 0) outSamples = frame->nb_samples;
    if (outSamples > gOutBufSamples) {
        av_freep(&gOutBuf);
        if (av_samples_alloc(&gOutBuf, NULL, gOutCh, outSamples, AV_SAMPLE_FMT_S16, 0) < 0) {
            gOutBuf = NULL;
            gOutBufSamples = 0;
            return;
        }
        gOutBufSamples = outSamples;
    }
    uint8_t *outPlanes[8] = {0};
    outPlanes[0] = gOutBuf;
    const uint8_t **inPlanes = (const uint8_t **)(frame->extended_data ? frame->extended_data : frame->data);
    int converted = swr_convert(gSwr, outPlanes, outSamples, inPlanes, frame->nb_samples);
    if (converted <= 0) return;
    BXFloatPublishAudioPCM((const int16_t *)gOutBuf, converted, gOutCh, gOutRate, pts);
}
#endif

void Vcu1AacReset(void) {
#if BXFLOAT_HAS_FFMPEG
    dispatch_sync(Vcu1AacQueue(), ^{ Vcu1AacTeardownLocked(); });
#endif
}

BOOL Vcu1AacSetConfig(const uint8_t *asc, int len) {
#if BXFLOAT_HAS_FFMPEG
    if (!asc || len <= 0) return NO;
    __block BOOL ok = NO;
    dispatch_sync(Vcu1AacQueue(), ^{
        Vcu1AacTeardownLocked();
        ok = Vcu1AacEnsureDecoderLocked(asc, len);
    });
    return ok;
#else
    (void)asc; (void)len;
    return NO;
#endif
}

BOOL Vcu1AacFeedADTS(const uint8_t *data, int len, double pts) {
#if BXFLOAT_HAS_FFMPEG
    if (!data || len < 7) return NO;
    __block BOOL ok = NO;
    dispatch_sync(Vcu1AacQueue(), ^{
        // ADTS can open decoder without ASC (parser inside)
        if (!gAacCtx) {
            if (!Vcu1AacEnsureDecoderLocked(NULL, 0)) return;
        }
        AVPacket *pkt = av_packet_alloc();
        AVFrame *frame = av_frame_alloc();
        if (!pkt || !frame) {
            if (pkt) av_packet_free(&pkt);
            if (frame) av_frame_free(&frame);
            return;
        }
        pkt->data = (uint8_t *)data;
        pkt->size = len;
        int dr = avcodec_send_packet(gAacCtx, pkt);
        if (dr == 0) {
            while (avcodec_receive_frame(gAacCtx, frame) == 0) {
                Vcu1AacPublishFrameLocked(frame, pts);
                ok = YES;
                av_frame_unref(frame);
            }
        }
        // ownership: data is caller-owned; clear pointers before free
        pkt->data = NULL;
        pkt->size = 0;
        av_packet_free(&pkt);
        av_frame_free(&frame);
    });
    return ok;
#else
    (void)data; (void)len; (void)pts;
    return NO;
#endif
}
