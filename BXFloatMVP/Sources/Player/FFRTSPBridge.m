#import "FFRTSPBridge.h"

extern void BXFloatDiagVideoDecodeOK(void);
extern void BXFloatDiagVideoDecodeFail(void);
extern void BXFloatDiagVideoSlotWait(void);
extern void BXFloatDiagNoteVideoRaw(int64_t tick, int32_t tbNum, int32_t tbDen, double rawSec);
extern void BXFloatDiagNoteAudioRaw(int64_t tick, int32_t tbNum, int32_t tbDen, double rawSec);
extern int32_t BXFloatAudioTargetRate(void);

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
@property (nonatomic, strong) dispatch_queue_t pullQueue;
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, strong) dispatch_queue_t audioDecodeQueue;
@property (nonatomic, assign) int64_t frameOK;
@property (nonatomic, assign) int64_t frameFail;
@property (nonatomic, assign) uint64_t sessionGen;
@end

#if BXFLOAT_HAS_FFMPEG
/// av_read_frame / open 可中断：running 被清掉后尽快返回，避免卡死在 socket 读
static int BXFloatFFInterrupt(void *opaque) {
    FFRTSPBridge *bridge = (__bridge FFRTSPBridge *)opaque;
    if (!bridge || !bridge.running) return 1;
    return 0;
}
#endif

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
        // 读包循环绝不能占控制队列，否则 stop/reconnect 无法把 running 置假
        _pullQueue = dispatch_queue_create("com.baixiang.ffrtsp.pull", DISPATCH_QUEUE_SERIAL);
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
        NSString *urlCopy = [urlString copy];
        dispatch_async(self.pullQueue, ^{
            [self runLoopWithURL:urlCopy];
        });
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
    __block int audioOutCh = 1;
    __block int audioOutRate = 48000;
    __block int64_t audioInLayoutBlock = 0;
    __block enum AVSampleFormat audioInFmtBlock = AV_SAMPLE_FMT_NONE;
    __block int audioInRateBlock = 0;
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

    // 秒连：缩小探测；抗抖仍靠 ring，不用 nobuffer
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "rtsp_transport", "tcp", 0);
    // USB(127.0.0.1) 经 usbmux 更慢：给 8s；局域网仍 2s 快失败
    BOOL isLoopback = [urlString containsString:@"127.0.0.1"] || [urlString containsString:@"localhost"];
    const char *timeoutUs = isLoopback ? "8000000" : "2000000";
    av_dict_set(&opts, "stimeout", timeoutUs, 0);
    av_dict_set(&opts, "rw_timeout", timeoutUs, 0);
    av_dict_set(&opts, "max_delay", "500000", 0);
    av_dict_set(&opts, "fflags", "discardcorrupt", 0);
    // 原 2.5s analyze 是「很慢」主因；0.5s 探测 + 环缓冲，对齐参照秒开
    av_dict_set(&opts, "probesize", "327680", 0);
    av_dict_set(&opts, "analyzeduration", isLoopback ? "1500000" : "500000", 0);

    AVFormatContext *fmtOpen = avformat_alloc_context();
    if (!fmtOpen) {
        NSLog(@"BXFloatCam ffmpeg alloc format fail");
        self.running = NO;
        [self scheduleReconnect:urlString];
        return;
    }
    fmtOpen->interrupt_callback.callback = BXFloatFFInterrupt;
    fmtOpen->interrupt_callback.opaque = (__bridge void *)self;

    const char *url = urlString.UTF8String;
    int ret = avformat_open_input(&fmtOpen, url, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        char err[128];
        av_strerror(ret, err, sizeof(err));
        NSLog(@"BXFloatCam ffmpeg open fail %s (%@)", err, urlString);
        // open 失败时 FFmpeg 已释放用户传入的 context
        self.running = NO;
        [self scheduleReconnect:urlString];
        return;
    }
    fmt = fmtOpen;

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
                    int inCh = audioCtx->channels;
                    if (inCh <= 0 && ast->codecpar) {
                        inCh = ast->codecpar->channels;
                    }
                    if (inCh <= 0) inCh = 2;
                    int inRate = audioCtx->sample_rate;
                    if (inRate <= 0 && ast->codecpar) {
                        inRate = (int)ast->codecpar->sample_rate;
                    }
                    if (inRate <= 0) inRate = 48000;
                    audioCtx->channels = inCh;
                    audioCtx->sample_rate = inRate;
                    int64_t inLayout = audioCtx->channel_layout;
                    if (!inLayout) {
                        inLayout = av_get_default_channel_layout(inCh);
                    }
                    // 音乐多为立体声：解码后保 2ch。AAC open 时 fmt 常 NONE → 用 FLTP 兜底；失败则首帧惰性建 swr
                    const int outCh = inCh >= 2 ? 2 : 1;
                    const int64_t outLayout = outCh == 2 ? AV_CH_LAYOUT_STEREO : AV_CH_LAYOUT_MONO;
                    enum AVSampleFormat openFmt = audioCtx->sample_fmt;
                    if (openFmt == AV_SAMPLE_FMT_NONE && ast->codecpar) {
                        openFmt = (enum AVSampleFormat)ast->codecpar->format;
                    }
                    if (openFmt == AV_SAMPLE_FMT_NONE) {
                        openFmt = AV_SAMPLE_FMT_FLTP;
                    }
                    // 优先 AU 目标率（有则入环即 1:1）；未锁 AU 前跟源率
                    int openWant = (int)BXFloatAudioTargetRate();
                    if (openWant < 8000) openWant = inRate > 0 ? inRate : 48000;
                    swr = swr_alloc_set_opts(
                        NULL, outLayout, AV_SAMPLE_FMT_S16, openWant,
                        inLayout, openFmt, inRate, 0, NULL
                    );
                    if (swr) {
                        av_opt_set_int(swr, "filter_size", 128, 0);
                        av_opt_set_int(swr, "phase_shift", 14, 0);
                        av_opt_set_double(swr, "cutoff", 0.92, 0);
                    }
                    audioOutCh = outCh;
                    audioOutRate = openWant;
                    audioInLayoutBlock = inLayout;
                    audioInFmtBlock = openFmt;
                    audioInRateBlock = inRate;
                    if (!swr || swr_init(swr) < 0) {
                        NSLog(@"BXFloatCam ffmpeg swr defer inCh=%d rate=%d fmt=%d (keep audio track)",
                              inCh, inRate, (int)openFmt);
                        if (swr) { swr_free(&swr); swr = NULL; }
                    } else {
                        NSLog(@"BXFloatCam ffmpeg audio %dch %dHz fmt=%d → %dch %dk s16 (swr hq, keep stereo)",
                              inCh, inRate, (int)openFmt, outCh, audioOutRate);
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
    if (!frame || !audioFrame || !packet) goto cleanup;

    NSLog(@"BXFloatCam ffmpeg playing %@ %dx%d audio=%d swr=%d (read||decode ring)",
          urlString, codecCtx->width, codecCtx->height, audioIdx >= 0 ? 1 : 0, swr ? 1 : 0);

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
            char err[128];
            av_strerror(ret, err, sizeof(err));
            NSLog(@"BXFloatCam ffmpeg read end/err %d (%s), reconnect", ret, err);
            break;
        }
        const int si = packet->stream_index;
        const BOOL isVideo = (si == videoIdx);
        // 不要求 swrBlock：首帧可惰性建；否则 demux 层直接把 AAC 扔掉 → 音频包永远 0
        const BOOL isAudio = (audioIdx >= 0 && si == audioIdx && actx && aframe);
        if (!isVideo && !isAudio) {
            av_packet_unref(packet);
            continue;
        }

        AVPacket *owned = av_packet_clone(packet);
        av_packet_unref(packet);
        if (!owned) continue;

        dispatch_semaphore_t slot = isAudio ? aSlots : vSlots;
        // 直播：槽位等太久就丢包继续读，禁止死等把 TCP 塞死（约 1s/~30 帧后整路停）
        int waitedMs = 0;
        BOOL gotSlot = NO;
        while (self.running) {
            if (dispatch_semaphore_wait(slot, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) == 0) {
                gotSlot = YES;
                break;
            }
            waitedMs += 50;
            if (isVideo) {
                BXFloatDiagVideoSlotWait();
            }
            if (waitedMs >= 400) {
                break;
            }
        }
        if (!self.running) {
            av_packet_free(&owned);
            break;
        }
        if (!gotSlot) {
            av_packet_free(&owned);
            continue;
        }

        dispatch_queue_t q = isAudio ? self.audioDecodeQueue : self.decodeQueue;
        dispatch_async(q, ^{
            if (self.sessionGen != gen || !self.running) {
                av_packet_free(&owned);
                dispatch_semaphore_signal(slot);
                return;
            }
            if (isVideo && vctx && vframe) {
                // EAGAIN：解码器满了，必须先 drain 再重送；绝不能把包当失败丢掉（会卡死在几帧后）
                int dr = avcodec_send_packet(vctx, owned);
                if (dr == AVERROR(EAGAIN)) {
                    while (self.running && self.sessionGen == gen) {
                        int rr = avcodec_receive_frame(vctx, vframe);
                        if (rr == AVERROR(EAGAIN) || rr == AVERROR_EOF) break;
                        if (rr < 0) {
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
                    dr = avcodec_send_packet(vctx, owned);
                }
                av_packet_free(&owned);
                if (dr < 0) {
                    if (dr != AVERROR_EOF) {
                        self.frameFail++;
                        BXFloatDiagVideoDecodeFail();
                    }
                    dispatch_semaphore_signal(slot);
                    return;
                }
                while (self.running && self.sessionGen == gen) {
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
            } else if (isAudio && actx && aframe) {
                // 发布一帧 PCM（惰性 swr：按实际 aframe 格式建，避免 open 时 NONE 废掉音轨）
                void (^publishAFrame)(void) = ^{
                    int inCh = aframe->channels > 0 ? aframe->channels : actx->channels;
                    if (inCh <= 0) inCh = audioOutCh > 0 ? audioOutCh : 2;
                    int inRate = aframe->sample_rate > 0 ? aframe->sample_rate : actx->sample_rate;
                    if (inRate <= 0) inRate = audioInRateBlock > 0 ? audioInRateBlock : 48000;
                    enum AVSampleFormat inFmt = (enum AVSampleFormat)aframe->format;
                    if (inFmt == AV_SAMPLE_FMT_NONE) inFmt = audioInFmtBlock;
                    if (inFmt == AV_SAMPLE_FMT_NONE) inFmt = AV_SAMPLE_FMT_FLTP;
                    int64_t inLayout = av_get_default_channel_layout(inCh);
                    // 有 AU 锁则 swr 直接出 AU 率；否则跟源（避免拉环块 SRC→一帧帧）
                    int wantRate = (int)BXFloatAudioTargetRate();
                    if (wantRate < 8000) wantRate = inRate > 0 ? inRate : 48000;
                    const int och = inCh >= 2 ? 2 : 1;
                    const int64_t outLayout = och == 2 ? AV_CH_LAYOUT_STEREO : AV_CH_LAYOUT_MONO;
                    BOOL needSwr = (swrBlock == NULL)
                        || (inFmt != audioInFmtBlock)
                        || (inRate != audioInRateBlock)
                        || (och != audioOutCh)
                        || (wantRate != audioOutRate);
                    if (needSwr) {
                        struct SwrContext *nw = swr_alloc_set_opts(
                            NULL, outLayout, AV_SAMPLE_FMT_S16, wantRate,
                            inLayout, inFmt, inRate, 0, NULL
                        );
                        if (nw) {
                            av_opt_set_int(nw, "filter_size", 128, 0);
                            av_opt_set_int(nw, "phase_shift", 14, 0);
                            av_opt_set_double(nw, "cutoff", 0.92, 0);
                        }
                        if (nw && swr_init(nw) >= 0) {
                            if (swrBlock) swr_free(&swrBlock);
                            swrBlock = nw;
                            audioInFmtBlock = inFmt;
                            audioInRateBlock = inRate;
                            audioInLayoutBlock = inLayout;
                            audioOutCh = och;
                            audioOutRate = wantRate;
                            av_freep(&audioOutBufBlock);
                            audioOutBufSamplesBlock = 0;
                            NSLog(@"BXFloatCam swr ready %dch %dHz fmt=%d → %dch %dHz",
                                  inCh, inRate, (int)inFmt, och, wantRate);
                        } else {
                            if (nw) swr_free(&nw);
                            return;
                        }
                    }
                    if (!swrBlock) return;
                    const int outRate = audioOutRate > 0 ? audioOutRate : 48000;
                    int outSamples = (int)av_rescale_rnd(
                        swr_get_delay(swrBlock, inRate) + aframe->nb_samples,
                        outRate, inRate, AV_ROUND_UP
                    );
                    if (outSamples <= 0) outSamples = aframe->nb_samples;
                    if (outSamples > audioOutBufSamplesBlock) {
                        av_freep(&audioOutBufBlock);
                        if (av_samples_alloc(&audioOutBufBlock, NULL, och, outSamples, AV_SAMPLE_FMT_S16, 0) < 0) {
                            audioOutBufBlock = NULL;
                            audioOutBufSamplesBlock = 0;
                            return;
                        }
                        audioOutBufSamplesBlock = outSamples;
                    }
                    uint8_t *outPlanes[8] = {0};
                    outPlanes[0] = audioOutBufBlock;
                    int64_t delayBefore = swr_get_delay(swrBlock, outRate);
                    const uint8_t **inPlanes = (const uint8_t **)(aframe->extended_data
                        ? aframe->extended_data
                        : aframe->data);
                    int converted = swr_convert(
                        swrBlock, outPlanes, outSamples, inPlanes, aframe->nb_samples
                    );
                    if (converted <= 0) return;
                    int64_t ts = aframe->best_effort_timestamp;
                    if (ts == AV_NOPTS_VALUE) ts = aframe->pts;
                    double pts = -1;
                    if (ts != AV_NOPTS_VALUE) {
                        pts = ts * av_q2d(audioTB);
                        if (delayBefore > 0) pts -= (double)delayBefore / (double)outRate;
                        BXFloatDiagNoteAudioRaw(ts, (int32_t)audioTB.num, (int32_t)audioTB.den, pts);
                    }
                    BXFloatPublishAudioPCM((const int16_t *)audioOutBufBlock, converted, och, outRate, pts);
                };

                int dr = avcodec_send_packet(actx, owned);
                if (dr == AVERROR(EAGAIN)) {
                    while (self.running && self.sessionGen == gen) {
                        int rr = avcodec_receive_frame(actx, aframe);
                        if (rr == AVERROR(EAGAIN) || rr == AVERROR_EOF) break;
                        if (rr < 0) break;
                        publishAFrame();
                    }
                    dr = avcodec_send_packet(actx, owned);
                }
                av_packet_free(&owned);
                if (dr < 0) {
                    dispatch_semaphore_signal(slot);
                    return;
                }
                while (self.running && self.sessionGen == gen) {
                    dr = avcodec_receive_frame(actx, aframe);
                    if (dr == AVERROR(EAGAIN) || dr == AVERROR_EOF) break;
                    if (dr < 0) break;
                    publishAFrame();
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
        *swsInOut, w, h, srcFmt, w, h, AV_PIX_FMT_BGRA, SWS_BICUBIC, NULL, NULL, NULL
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
    // 0.2s 重连：USB 隧道晚到半拍时也能很快跟上（原 1s 体感「非常慢」）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), self.queue, ^{
        if (self.running) return;
        if (urlString.length == 0) return;
        NSLog(@"BXFloatCam ffmpeg reconnect %@", urlString);
        self.currentURL = [urlString copy];
        self.running = YES;
        self.frameOK = 0;
        self.frameFail = 0;
        NSString *urlCopy = [urlString copy];
        dispatch_async(self.pullQueue, ^{
            [self runLoopWithURL:urlCopy];
        });
    });
}

#endif // BXFLOAT_HAS_FFMPEG

@end
