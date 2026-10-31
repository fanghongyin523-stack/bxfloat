#import "FFRTSPBridge.h"

extern void BXFloatDiagVideoDecodeOK(void);
extern void BXFloatDiagVideoDecodeFail(void);
extern void BXFloatDiagVideoSlotWait(void);
extern void BXFloatDiagNoteVideoRaw(int64_t tick, int32_t tbNum, int32_t tbDen, double rawSec);
extern void BXFloatDiagNoteAudioRaw(int64_t tick, int32_t tbNum, int32_t tbDen, double rawSec);

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
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, strong) dispatch_queue_t audioDecodeQueue;
@property (nonatomic, assign) int64_t frameOK;
@property (nonatomic, assign) int64_t frameFail;
@property (nonatomic, assign) uint64_t sessionGen;
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
        _decodeQueue = dispatch_queue_create("com.baixiang.ffrtsp.decode", DISPATCH_QUEUE_SERIAL);
        // 音画分队：关键帧解码不再堵住音频（约 2s GOP 时尤其明显）
        _audioDecodeQueue = dispatch_queue_create("com.baixiang.ffrtsp.audio", DISPATCH_QUEUE_SERIAL);
        _sessionGen = 0;
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
    self.sessionGen += 1;
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
    // __block 必须在任何 goto cleanup 之前声明（Clang 不能跨越初始化跳转）
    __block struct SwsContext *swsBlock = NULL;
    __block struct SwrContext *swrBlock = NULL;
    __block uint8_t *audioOutBufBlock = NULL;
    __block int audioOutBufSamplesBlock = 0;
    __block AVFrame *vframe = NULL;
    __block AVFrame *aframe = NULL;
    __block AVCodecContext *vctx = NULL;
    __block AVCodecContext *actx = NULL;
    dispatch_semaphore_t slots = NULL;
    dispatch_semaphore_t vSlots = NULL;
    dispatch_semaphore_t aSlots = NULL;
    BOOL startedDecodeSplit = NO;
    uint64_t gen = 0;
    AVRational videoTB = {1, 1};
    AVRational audioTB = {1, 1};

    avformat_network_init();

    // 抗抖靠 ring(1.5～2s)，不再用 nobuffer 硬扛（一抖就空窗导致音画双卡）
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "rtsp_transport", "tcp", 0);
    av_dict_set(&opts, "stimeout", "5000000", 0); // us
    av_dict_set(&opts, "max_delay", "1500000", 0);
    av_dict_set(&opts, "fflags", "discardcorrupt", 0);
    av_dict_set(&opts, "flags", "low_delay", 0);
    av_dict_set(&opts, "probesize", "65536", 0);
    av_dict_set(&opts, "analyzeduration", "800000", 0);

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

    NSLog(@"BXFloatCam ffmpeg playing %@ %dx%d audio=%d (read∥decode ring)",
          urlString, codecCtx->width, codecCtx->height, audioIdx >= 0 ? 1 : 0);

    videoTB = fmt->streams[videoIdx]->time_base;
    if (audioIdx >= 0) {
        audioTB = fmt->streams[audioIdx]->time_base;
    }

    // 读包与解码分离。音画分槽背压，禁止互相抢名额。
    gen = self.sessionGen;
    vSlots = dispatch_semaphore_create(48);
    aSlots = dispatch_semaphore_create(24);
    slots = vSlots;
    swrBlock = swr;
    swr = NULL; // 所有权交给 decode 路径，cleanup 前 sync 回收
    vframe = frame;
    aframe = audioFrame;
    frame = NULL;
    audioFrame = NULL;
    vctx = codecCtx;
    actx = audioCtx;
    startedDecodeSplit = YES;

    while (self.running) {
        ret = av_read_frame(fmt, packet);
        if (ret < 0) {
            if (ret == AVERROR_EOF || ret == AVERROR(EIO)) {
                NSLog(@"BXFloatCam ffmpeg read end/err %d, reconnect", ret);
            }
            break;
        }
        const int si = packet->stream_index;
        const BOOL isVideo = (si == videoIdx);
        const BOOL isAudio = (audioIdx >= 0 && si == audioIdx && actx && swrBlock && aframe);
        if (!isVideo && !isAudio) {
            av_packet_unref(packet);
            continue;
        }

        AVPacket *owned = av_packet_clone(packet);
        av_packet_unref(packet);
        if (!owned) continue;

        dispatch_semaphore_t slot = isAudio ? aSlots : vSlots;
        // 一直等到有解码槽：宁可延迟涨，也不丢 OBS 已稳定推来的包
        while (self.running) {
            if (dispatch_semaphore_wait(slot, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) == 0) {
                break;
            }
            if (isVideo) {
                BXFloatDiagVideoSlotWait();
            }
        }
        if (!self.running) {
            av_packet_free(&owned);
            break;
        }

        dispatch_queue_t q = isAudio ? self.audioDecodeQueue : self.decodeQueue;
        dispatch_async(q, ^{
            if (self.sessionGen != gen || !self.running) {
                av_packet_free(&owned);
                dispatch_semaphore_signal(slot);
                return;
            }
            if (isVideo && vctx && vframe) {
                int dr = avcodec_send_packet(vctx, owned);
                av_packet_free(&owned);
                if (dr < 0) {
                    self.frameFail++;
                    BXFloatDiagVideoDecodeFail();
                    dispatch_semaphore_signal(slot);
                    return;
                }
                while (dr >= 0 && self.running && self.sessionGen == gen) {
                    dr = avcodec_receive_frame(vctx, vframe);
                    if (dr == AVERROR(EAGAIN) || dr == AVERROR_EOF) break;
                    if (dr < 0) {
                        self.frameFail++;
                        BXFloatDiagVideoDecodeFail();
                        break;
                    }
                    int64_t ts = vframe->best_effort_timestamp;
                    if (ts == AV_NOPTS_VALUE) ts = vframe->pts;
                    double pts = -1;
                    if (ts != AV_NOPTS_VALUE) {
                        pts = ts * av_q2d(videoTB);
                        BXFloatDiagNoteVideoRaw(ts, (int32_t)videoTB.num, (int32_t)videoTB.den, pts);
                    }
                    if (![self publishFrame:vframe codecCtx:vctx sws:&swsBlock pts:pts]) {
                        self.frameFail++;
                        BXFloatDiagVideoDecodeFail();
                    } else {
                        self.frameOK++;
                        BXFloatDiagVideoDecodeOK();
                    }
                }
            } else if (isAudio && actx && swrBlock && aframe) {
                int dr = avcodec_send_packet(actx, owned);
                av_packet_free(&owned);
                if (dr < 0) {
                    dispatch_semaphore_signal(slot);
                    return;
                }
                while (dr >= 0 && self.running && self.sessionGen == gen) {
                    dr = avcodec_receive_frame(actx, aframe);
                    if (dr == AVERROR(EAGAIN) || dr == AVERROR_EOF) break;
                    if (dr < 0) break;
                    int outSamples = (int)av_rescale_rnd(
                        swr_get_delay(swrBlock, actx->sample_rate) + aframe->nb_samples,
                        48000,
                        actx->sample_rate,
                        AV_ROUND_UP
                    );
                    if (outSamples <= 0) outSamples = aframe->nb_samples;
                    if (outSamples > audioOutBufSamplesBlock) {
                        av_freep(&audioOutBufBlock);
                        if (av_samples_alloc(&audioOutBufBlock, NULL, 1, outSamples, AV_SAMPLE_FMT_S16, 0) < 0) {
                            audioOutBufBlock = NULL;
                            audioOutBufSamplesBlock = 0;
                            break;
                        }
                        audioOutBufSamplesBlock = outSamples;
                    }
                    uint8_t *outPlanes[1] = { audioOutBufBlock };
                    // convert 前读 delay：输出首样对应时间 ≈ input_pts - delay/outRate
                    int64_t delayBefore = swr_get_delay(swrBlock, 48000);
                    int converted = swr_convert(
                        swrBlock,
                        outPlanes,
                        outSamples,
                        (const uint8_t **)aframe->data,
                        aframe->nb_samples
                    );
                    if (converted > 0) {
                        int64_t ts = aframe->best_effort_timestamp;
                        if (ts == AV_NOPTS_VALUE) ts = aframe->pts;
                        double pts = -1;
                        if (ts != AV_NOPTS_VALUE) {
                            pts = ts * av_q2d(audioTB);
                            // 扣 swr 延迟，避免 endPTS 虚高 → 门控误判超前 → 连续拒收断音
                            if (delayBefore > 0) {
                                pts -= (double)delayBefore / 48000.0;
                            }
                            BXFloatDiagNoteAudioRaw(ts, (int32_t)audioTB.num, (int32_t)audioTB.den, pts);
                        }
                        BXFloatPublishAudioPCM((const int16_t *)audioOutBufBlock, converted, 1, 48000, pts);
                    }
                }
            } else {
                av_packet_free(&owned);
            }
            dispatch_semaphore_signal(slot);
        });
    }

    if (startedDecodeSplit) {
        // 等音画解码排空再释放
        dispatch_sync(self.decodeQueue, ^{
            if (swsBlock) {
                sws_freeContext(swsBlock);
                swsBlock = NULL;
            }
            if (vframe) {
                av_frame_free(&vframe);
                vframe = NULL;
            }
        });
        dispatch_sync(self.audioDecodeQueue, ^{
            if (swrBlock) {
                swr_free(&swrBlock);
                swrBlock = NULL;
            }
            av_freep(&audioOutBufBlock);
            if (aframe) {
                av_frame_free(&aframe);
                aframe = NULL;
            }
        });
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
    self.sessionGen += 1;
    if (shouldReconnect) {
        [self scheduleReconnect:urlCopy];
    }
}

- (BOOL)publishFrame:(AVFrame *)frame
            codecCtx:(AVCodecContext *)codecCtx
                 sws:(struct SwsContext **)swsInOut
                 pts:(double)pts {
    (void)codecCtx;
    int w = frame->width;
    int h = frame->height;
    if (w <= 0 || h <= 0) return NO;

    enum AVPixelFormat srcFmt = (enum AVPixelFormat)frame->format;
        *swsInOut = sws_getCachedContext(
        *swsInOut, w, h, srcFmt, w, h, AV_PIX_FMT_BGRA, SWS_FAST_BILINEAR, NULL, NULL, NULL
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

    BXFloatPublishVideoFrame(pb, pts);
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
