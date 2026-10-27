#import "FFRTSPBridge.h"

#if BXFLOAT_HAS_FFMPEG

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

#ifndef AV_CH_LAYOUT_MONO
#define AV_CH_LAYOUT_MONO 0x4ULL
#endif

#endif

BOOL BXFloatFFIsAvailable(void) {
    return [FFRTSPBridge isAvailable];
}

void BXFloatFFStartUTF8(const char *urlUTF8) {
    if (!urlUTF8) return;
    NSString *url = [NSString stringWithUTF8String:urlUTF8];
    if (url.length == 0) return;
    [[FFRTSPBridge shared] startWithURL:url];
}

void BXFloatFFStop(void) {
    [[FFRTSPBridge shared] stop];
}

@interface FFRTSPBridge ()
@property (nonatomic, assign) BOOL running;
@property (nonatomic, copy) NSString *currentURL;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) int64_t frameOK;
@property (nonatomic, assign) int64_t frameFail;
@end

@implementation FFRTSPBridge

+ (instancetype)shared {
    static FFRTSPBridge *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[FFRTSPBridge alloc] init];
    });
    return inst;
}

+ (BOOL)isAvailable {
#if BXFLOAT_HAS_FFMPEG
    return YES;
#else
    return NO;
#endif
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.baixiang.ffrtsp", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startWithURL:(NSString *)urlString {
    if (urlString.length == 0) return;
    dispatch_async(self.queue, ^{
        if (self.running && [self.currentURL isEqualToString:urlString]) return;
        [self stopLocked];
        self.currentURL = [urlString copy];
        self.running = YES;
        self.frameOK = 0;
        self.frameFail = 0;
#if BXFLOAT_HAS_FFMPEG
        [self runLoopWithURL:urlString];
#else
        NSLog(@"BXFloatCam FFmpeg not linked; cannot pull %@", urlString);
        self.running = NO;
#endif
    });
}

- (void)stop {
    dispatch_async(self.queue, ^{
        [self stopLocked];
    });
}

- (void)stopLocked {
    self.running = NO;
    self.currentURL = nil;
}

#if BXFLOAT_HAS_FFMPEG

- (void)runLoopWithURL:(NSString *)urlString {
    AVFormatContext *fmt = NULL;
    AVCodecContext *codecCtx = NULL;
    AVCodecContext *audioCtx = NULL;
    struct SwsContext *sws = NULL;
    struct SwrContext *swr = NULL;
    AVFrame *frame = NULL;
    AVFrame *audioFrame = NULL;
    AVPacket *packet = NULL;
    int videoIdx = -1;
    int audioIdx = -1;
    uint8_t *audioOutBuf = NULL;
    int audioOutBufSamples = 0;

    avformat_network_init();

    AVDictionary *opts = NULL;
    av_dict_set(&opts, "rtsp_transport", "tcp", 0);
    av_dict_set(&opts, "stimeout", "5000000", 0); // us
    av_dict_set(&opts, "max_delay", "500000", 0);
    av_dict_set(&opts, "fflags", "nobuffer", 0);
    av_dict_set(&opts, "flags", "low_delay", 0);
    av_dict_set(&opts, "probesize", "32768", 0);
    av_dict_set(&opts, "analyzeduration", "500000", 0);

    const char *url = urlString.UTF8String;
    int ret = avformat_open_input(&fmt, url, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        char err[128];
        av_strerror(ret, err, sizeof(err));
        NSLog(@"BXFloatCam ffmpeg open fail %s (%@)", err, urlString);
        self.running = NO;
        [self scheduleReconnect:urlString];
        return;
    }

    ret = avformat_find_stream_info(fmt, NULL);
    if (ret < 0) {
        NSLog(@"BXFloatCam ffmpeg find stream info fail %d", ret);
        goto cleanup;
    }

    videoIdx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (videoIdx < 0) {
        NSLog(@"BXFloatCam ffmpeg no video stream");
        goto cleanup;
    }

    AVStream *st = fmt->streams[videoIdx];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) {
        NSLog(@"BXFloatCam ffmpeg decoder missing id=%d", st->codecpar->codec_id);
        goto cleanup;
    }
    codecCtx = avcodec_alloc_context3(codec);
    if (!codecCtx) goto cleanup;
    avcodec_parameters_to_context(codecCtx, st->codecpar);
    codecCtx->thread_count = 2;
    codecCtx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    if (avcodec_open2(codecCtx, codec, NULL) < 0) {
        NSLog(@"BXFloatCam ffmpeg open codec fail");
        goto cleanup;
    }

    audioIdx = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (audioIdx >= 0) {
        AVStream *ast = fmt->streams[audioIdx];
        const AVCodec *acodec = avcodec_find_decoder(ast->codecpar->codec_id);
        if (acodec) {
            audioCtx = avcodec_alloc_context3(acodec);
            if (audioCtx) {
                avcodec_parameters_to_context(audioCtx, ast->codecpar);
                if (avcodec_open2(audioCtx, acodec, NULL) < 0) {
                    NSLog(@"BXFloatCam ffmpeg audio open fail");
                    avcodec_free_context(&audioCtx);
                    audioCtx = NULL;
                    audioIdx = -1;
                } else {
                    int64_t inLayout = audioCtx->channel_layout;
                    if (!inLayout) {
                        inLayout = av_get_default_channel_layout(audioCtx->channels);
                    }
                    swr = swr_alloc_set_opts(
                        NULL,
                        AV_CH_LAYOUT_MONO,
                        AV_SAMPLE_FMT_S16,
                        48000,
                        inLayout,
                        audioCtx->sample_fmt,
                        audioCtx->sample_rate,
                        0,
                        NULL
                    );
                    if (!swr || swr_init(swr) < 0) {
                        NSLog(@"BXFloatCam ffmpeg swr init fail");
                        if (swr) { swr_free(&swr); swr = NULL; }
                        avcodec_free_context(&audioCtx);
                        audioCtx = NULL;
                        audioIdx = -1;
                    } else {
                        NSLog(@"BXFloatCam ffmpeg audio %dch %dHz → mono 48k s16",
                              audioCtx->channels, audioCtx->sample_rate);
                    }
                }
            }
        } else {
            NSLog(@"BXFloatCam ffmpeg no audio decoder id=%d", ast->codecpar->codec_id);
            audioIdx = -1;
        }
    } else {
        NSLog(@"BXFloatCam ffmpeg no audio stream (video-only)");
    }

    frame = av_frame_alloc();
    audioFrame = av_frame_alloc();
    packet = av_packet_alloc();
    if (!frame || !packet) goto cleanup;

    NSLog(@"BXFloatCam ffmpeg playing %@ %dx%d audio=%d",
          urlString, codecCtx->width, codecCtx->height, audioIdx >= 0 ? 1 : 0);

    while (self.running) {
        ret = av_read_frame(fmt, packet);
        if (ret < 0) {
            if (ret == AVERROR_EOF || ret == AVERROR(EIO)) {
                NSLog(@"BXFloatCam ffmpeg read end/err %d, reconnect", ret);
            }
            break;
        }
        if (packet->stream_index == videoIdx) {
            ret = avcodec_send_packet(codecCtx, packet);
            av_packet_unref(packet);
            if (ret < 0) {
                self.frameFail++;
                continue;
            }
            while (ret >= 0 && self.running) {
                ret = avcodec_receive_frame(codecCtx, frame);
                if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
                if (ret < 0) {
                    self.frameFail++;
                    break;
                }
                if (![self publishFrame:frame codecCtx:codecCtx sws:&sws]) {
                    self.frameFail++;
                } else {
                    self.frameOK++;
                }
            }
        } else if (audioIdx >= 0 && packet->stream_index == audioIdx && audioCtx && swr && audioFrame) {
            ret = avcodec_send_packet(audioCtx, packet);
            av_packet_unref(packet);
            if (ret < 0) continue;
            while (ret >= 0 && self.running) {
                ret = avcodec_receive_frame(audioCtx, audioFrame);
                if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
                if (ret < 0) break;

                int outSamples = (int)av_rescale_rnd(
                    swr_get_delay(swr, audioCtx->sample_rate) + audioFrame->nb_samples,
                    48000,
                    audioCtx->sample_rate,
                    AV_ROUND_UP
                );
                if (outSamples <= 0) outSamples = audioFrame->nb_samples;
                if (outSamples > audioOutBufSamples) {
                    av_freep(&audioOutBuf);
                    if (av_samples_alloc(&audioOutBuf, NULL, 1, outSamples, AV_SAMPLE_FMT_S16, 0) < 0) {
                        audioOutBuf = NULL;
                        audioOutBufSamples = 0;
                        break;
                    }
                    audioOutBufSamples = outSamples;
                }
                uint8_t *outPlanes[1] = { audioOutBuf };
                int converted = swr_convert(
                    swr,
                    outPlanes,
                    outSamples,
                    (const uint8_t **)audioFrame->data,
                    audioFrame->nb_samples
                );
                if (converted > 0) {
                    BXFloatPublishAudioPCM((const int16_t *)audioOutBuf, converted, 1, 48000);
                }
            }
        } else {
            av_packet_unref(packet);
        }
    }

cleanup:
    if (sws) sws_freeContext(sws);
    if (swr) swr_free(&swr);
    av_freep(&audioOutBuf);
    if (packet) av_packet_free(&packet);
    if (frame) av_frame_free(&frame);
    if (audioFrame) av_frame_free(&audioFrame);
    if (codecCtx) avcodec_free_context(&codecCtx);
    if (audioCtx) avcodec_free_context(&audioCtx);
    if (fmt) avformat_close_input(&fmt);

    BOOL shouldReconnect = self.running;
    NSString *urlCopy = [urlString copy];
    self.running = NO;
    if (shouldReconnect) {
        [self scheduleReconnect:urlCopy];
    }
}

- (BOOL)publishFrame:(AVFrame *)frame
            codecCtx:(AVCodecContext *)codecCtx
                 sws:(struct SwsContext **)swsInOut {
    (void)codecCtx;
    int w = frame->width;
    int h = frame->height;
    if (w <= 0 || h <= 0) return NO;

    enum AVPixelFormat srcFmt = (enum AVPixelFormat)frame->format;
    *swsInOut = sws_getCachedContext(
        *swsInOut, w, h, srcFmt, w, h, AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL
    );
    if (!*swsInOut) return NO;

    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES
    };
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb) {
        return NO;
    }

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    int dstStride = (int)CVPixelBufferGetBytesPerRow(pb);
    uint8_t *dstPlanes[4] = { dst, NULL, NULL, NULL };
    int dstStrides[4] = { dstStride, 0, 0, 0 };
    sws_scale(*swsInOut,
              (const uint8_t *const *)frame->data, frame->linesize,
              0, h, dstPlanes, dstStrides);
    CVPixelBufferUnlockBaseAddress(pb, 0);

    BXFloatPublishVideoFrame(pb);
    CVPixelBufferRelease(pb);
    return YES;
}

- (void)scheduleReconnect:(NSString *)urlString {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), self.queue, ^{
        if (self.running) return;
        if (urlString.length == 0) return;
        NSLog(@"BXFloatCam ffmpeg reconnect %@", urlString);
        self.currentURL = [urlString copy];
        self.running = YES;
        [self runLoopWithURL:urlString];
    });
}

#endif // BXFLOAT_HAS_FFMPEG

@end
