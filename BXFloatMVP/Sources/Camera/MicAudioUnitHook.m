#import "MicAudioUnitHook.h"
#import "fishhook.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <stdint.h>
#import <string.h>

/// frames=采样帧数；channels=该缓冲声道数（非交错平面恒为 1）
FOUNDATION_EXPORT void BXFloatMicPaintFrames(
    void *dst,
    int frames,
    int channels,
    double sampleRate,
    int bytesPerSample,
    int isFloat,
    int mode
);

/// 拉交错 s16，返回峰；由本文件按 AU 真实格式写入 ioData
FOUNDATION_EXPORT int32_t BXFloatMicPullS16(
    int16_t *dst,
    int frames,
    int channels,
    double sampleRate
);

FOUNDATION_EXPORT void BXFloatMicNoteInjectPCM(
    const int16_t *samples,
    int frames,
    int channels,
    int sampleRate
);

FOUNDATION_EXPORT void BXFloatAQNotePaintDstPeak(int32_t peak);

FOUNDATION_EXPORT void BXFloatAQNoteMicTap(
    const void *data,
    int frames,
    int channels,
    int bytesPerSample,
    int isFloat
);

FOUNDATION_EXPORT void BXFloatAQNoteAUFormat(
    double rate,
    int frames,
    int bufBytes,
    int channels,
    int bytesPerSample,
    int isFloat,
    int asbdBits,
    uint32_t asbdFlags,
    int mismatch
);

/// paint/memcpy 之后对「同一块」ioData 取峰：注入 pk / A/s out 以这里为准
FOUNDATION_EXPORT void BXFloatAQNoteInjectTap(
    const void *data,
    int frames,
    int channels,
    int bytesPerSample,
    int isFloat,
    int rate
);

static OSStatus (*orig_AudioUnitRender)(
    AudioUnit inUnit,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inOutputBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) = NULL;

static OSStatus (*orig_AudioComponentInstanceNew)(
    AudioComponent inComponent,
    AudioComponentInstance *outInstance
) = NULL;

static OSStatus (*orig_AudioOutputUnitStart)(AudioUnit ci) = NULL;

static OSStatus (*orig_AudioQueueNewInput)(
    const AudioStreamBasicDescription *inFormat,
    AudioQueueInputCallback inCallbackProc,
    void *inUserData,
    CFRunLoopRef inCallbackRunLoop,
    CFStringRef inCallbackRunLoopMode,
    UInt32 inFlags,
    AudioQueueRef *outAQ
) = NULL;

enum { kAQWrapSlots = 16 };

typedef struct {
    AudioQueueInputCallback orig;
    void *userData;
    AudioStreamBasicDescription asbd;
    _Atomic int used;
} BXAQWrap;

static BXAQWrap gAQWraps[kAQWrapSlots];

static _Atomic int gMode = 0; // 0 mic, 1 stream, 2 mute
static _Atomic int64_t gPaint = 0;
static _Atomic int64_t gCallback = 0;
static _Atomic int64_t gAQPaint = 0;
static _Atomic int64_t gAQCallback = 0;
static _Atomic int64_t gAUCreate = 0;
static _Atomic int64_t gAUStart = 0;
static _Atomic int gInstalled = 0;
static _Atomic int gFmtLogTick = 0;
static _Atomic int gAQFmtLogTick = 0;
// AU/AQ 回调禁止 malloc：固定交错临时区（≤4096 帧 × 8 平面 × 4 字节）
static uint8_t gPaintTmp[4096 * 8 * 4];

void BXFloatMicAUSetMode(int mode) {
    atomic_store(&gMode, mode);
}

int64_t BXFloatMicAUPaintCount(void) {
    return atomic_load(&gPaint);
}

int64_t BXFloatMicAUCallbackCount(void) {
    return atomic_load(&gCallback);
}

int64_t BXFloatMicAQPaintCount(void) {
    return atomic_load(&gAQPaint);
}

int64_t BXFloatMicAQCallbackCount(void) {
    return atomic_load(&gAQCallback);
}

int64_t BXFloatMicAUCreateCount(void) {
    return atomic_load(&gAUCreate);
}

int64_t BXFloatMicAUStartCount(void) {
    return atomic_load(&gAUStart);
}

/// 解析 AU 缓冲与 ASBD：优先信任有效 ASBD，缓冲几何做交叉校验
static int resolveFormat(
    AudioBufferList *ioData,
    UInt32 frames,
    const AudioStreamBasicDescription *asbd,
    int *outCh,
    int *outBps,
    int *outFloat,
    int *outMismatch,
    double *outRate
) {
    if (!ioData || frames == 0 || ioData->mNumberBuffers == 0) return 0;
    AudioBuffer *b0 = &ioData->mBuffers[0];
    if (!b0->mData || b0->mDataByteSize == 0) return 0;

    int bytesPerFrameInBuf = (int)(b0->mDataByteSize / frames);
    if (bytesPerFrameInBuf <= 0) return 0;

    int chInBuf = (int)(b0->mNumberChannels > 0 ? b0->mNumberChannels : 1);
    BOOL multiPlane = (ioData->mNumberBuffers > 1);
    BOOL asbdNonInterleaved = asbd && (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    BOOL nonInterleaved = multiPlane || asbdNonInterleaved;

    if (nonInterleaved) {
        chInBuf = 1;
    } else if (asbd && asbd->mChannelsPerFrame > 0) {
        chInBuf = (int)asbd->mChannelsPerFrame;
    }

    int bytesPerSample = bytesPerFrameInBuf / (chInBuf > 0 ? chInBuf : 1);
    if (bytesPerSample <= 0) {
        bytesPerSample = bytesPerFrameInBuf;
        chInBuf = 1;
    }

    int isFloat = 0;
    int mismatch = 0;
    // ASBD 有效时优先：float / signed int 标志；bits>0 时对齐 bps
    if (asbd && asbd->mBitsPerChannel > 0) {
        int asbdBps = (int)(asbd->mBitsPerChannel / 8);
        if (asbdBps > 0 && asbdBps != bytesPerSample) {
            mismatch = 1;
            // 缓冲几何与 ASBD 冲突时以缓冲为准（写入必须匹配真实布局）
        }
        if (asbd->mFormatFlags & kAudioFormatFlagIsFloat) {
            isFloat = 1;
        } else if (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) {
            isFloat = 0;
        } else if (bytesPerSample == 4) {
            isFloat = 1;
            mismatch = 1;
        }
        if (isFloat && bytesPerSample == 2) {
            // ASBD 说 float 但缓冲是 2 字节 → 严重不一致，按缓冲写 int16
            isFloat = 0;
            mismatch = 1;
        }
        if (!isFloat && bytesPerSample == 4 && !(asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger)) {
            // bits=32 无 signed 标志：iOS 输入几乎都是 float
            isFloat = 1;
        }
    } else {
        // ASBD bits=0：仅靠缓冲宽推断（历史电流声坑）
        if (bytesPerSample == 4) {
            isFloat = 1;
        } else if (bytesPerSample == 2) {
            isFloat = 0;
        } else if (bytesPerSample == 8) {
            isFloat = 1;
            bytesPerSample = 8;
        } else if (bytesPerFrameInBuf % 4 == 0) {
            isFloat = 1;
            bytesPerSample = 4;
            chInBuf = bytesPerFrameInBuf / 4;
            mismatch = 1;
        } else {
            isFloat = 0;
            bytesPerSample = 2;
            chInBuf = bytesPerFrameInBuf / 2;
            mismatch = 1;
        }
    }

    if (isFloat && bytesPerSample < 4) {
        bytesPerSample = 4;
        chInBuf = bytesPerFrameInBuf / 4;
        if (chInBuf <= 0) chInBuf = 1;
        mismatch = 1;
    }
    if (!isFloat && bytesPerSample != 2 && bytesPerSample != 4) {
        if (bytesPerFrameInBuf % 4 == 0) {
            isFloat = 1;
            bytesPerSample = 4;
            chInBuf = bytesPerFrameInBuf / 4;
        } else {
            isFloat = 0;
            bytesPerSample = 2;
            chInBuf = bytesPerFrameInBuf / 2;
        }
        if (chInBuf <= 0) chInBuf = 1;
        mismatch = 1;
    }

    double rate = 48000.0;
    if (asbd && asbd->mSampleRate > 0) {
        rate = asbd->mSampleRate;
    }

    *outCh = chInBuf;
    *outBps = bytesPerSample;
    *outFloat = isFloat;
    *outMismatch = mismatch;
    *outRate = rate;
    return 1;
}

static void logFormatThrottled(
    double rate,
    UInt32 frames,
    AudioBufferList *ioData,
    int ch,
    int bps,
    int isFloat,
    const AudioStreamBasicDescription *asbd,
    int mismatch
) {
    int tick = atomic_fetch_add(&gFmtLogTick, 1);
    // 首次 + 之后每 ~2s（按 ~50Hz 回调估）或 mismatch 时立刻
    if (tick != 0 && !mismatch && (tick % 100) != 0) return;
    AudioBuffer *b0 = &ioData->mBuffers[0];
    NSLog(
        @"BXFloatMic AU fmt rate=%.0f frames=%u bufs=%u bytes/buf=%u bpf=%d ch=%d bps=%d float=%d asbdBits=%u asbdFlags=0x%x mis=%d",
        rate,
        (unsigned)frames,
        (unsigned)ioData->mNumberBuffers,
        (unsigned)b0->mDataByteSize,
        (int)(b0->mDataByteSize / frames),
        ch,
        bps,
        isFloat,
        asbd ? (unsigned)asbd->mBitsPerChannel : 0,
        asbd ? (unsigned)asbd->mFormatFlags : 0,
        mismatch
    );
    BXFloatAQNoteAUFormat(
        rate,
        (int)frames,
        (int)b0->mDataByteSize,
        ch,
        bps,
        isFloat,
        asbd ? (int)asbd->mBitsPerChannel : 0,
        asbd ? (uint32_t)asbd->mFormatFlags : 0,
        mismatch
    );
}

static void tapMicABL(
    AudioBufferList *ioData,
    UInt32 frames,
    const AudioStreamBasicDescription *asbd
) {
    int ch = 1, bps = 4, isFloat = 1, mismatch = 0;
    double rate = 48000;
    if (!resolveFormat(ioData, frames, asbd, &ch, &bps, &isFloat, &mismatch, &rate)) return;
    AudioBuffer *b0 = &ioData->mBuffers[0];
    BXFloatAQNoteMicTap(b0->mData, (int)frames, ch, bps, isFloat);
}

/// 把一帧 s16 写入目标（按真实 bps/float）
static void writeOneSample(void *dst, int16_t s, int bps, int isFloat) {
    if (isFloat && bps >= 4) {
        float f = (float)s / 32768.0f;
        memcpy(dst, &f, 4);
    } else if (bps == 2) {
        memcpy(dst, &s, 2);
    } else if (bps == 4 && !isFloat) {
        int32_t v = ((int32_t)s) << 16;
        memcpy(dst, &v, 4);
    } else {
        memset(dst, 0, (size_t)bps > 0 ? (size_t)bps : 1);
    }
}

static void paintABL(
    AudioBufferList *ioData,
    UInt32 frames,
    const AudioStreamBasicDescription *asbd,
    int mode
) {
    if (!ioData || frames == 0 || mode == 0 || ioData->mNumberBuffers == 0) return;

    int chInBuf = 1, bytesPerSample = 4, isFloat = 1, mismatch = 0;
    double rate = 48000;
    if (!resolveFormat(ioData, frames, asbd, &chInBuf, &bytesPerSample, &isFloat, &mismatch, &rate)) {
        return;
    }

    BOOL multiPlane = (ioData->mNumberBuffers > 1);
    BOOL asbdNonInterleaved = asbd && (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    BOOL nonInterleaved = multiPlane || asbdNonInterleaved;

    logFormatThrottled(rate, frames, ioData, chInBuf, bytesPerSample, isFloat, asbd, mismatch);

    int outCh = nonInterleaved ? (int)ioData->mNumberBuffers : chInBuf;
    if (outCh < 1) outCh = 1;
    if (outCh > 8) outCh = 8;
    if (frames > 4096) frames = 4096;

    size_t s16Bytes = (size_t)frames * (size_t)outCh * sizeof(int16_t);
    if (s16Bytes > sizeof(gPaintTmp)) {
        // 极端超限：退回旧单平面路径
        AudioBuffer *b0 = &ioData->mBuffers[0];
        BXFloatMicPaintFrames(b0->mData, (int)frames, 1, rate, bytesPerSample, isFloat, mode);
        return;
    }

    int16_t *pcm = (int16_t *)gPaintTmp;
    memset(pcm, 0, s16Bytes);

    if (mode == 2) {
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            AudioBuffer *buf = &ioData->mBuffers[i];
            if (buf->mData && buf->mDataByteSize) memset(buf->mData, 0, buf->mDataByteSize);
        }
        BXFloatAQNotePaintDstPeak(0);
        return;
    }

    // 1) 拉推流 s16（固定延迟连续；欠载已 hold 末样）；2) 按 AU 几何整缓冲覆盖
    int32_t pullPk = BXFloatMicPullS16(pcm, (int)frames, outCh, rate);
    if (pullPk <= 0) {
        // 仍无内容：不交还原麦（录轨会变原麦）；写 0 并记峰
        for (UInt32 bi = 0; bi < ioData->mNumberBuffers; bi++) {
            AudioBuffer *buf = &ioData->mBuffers[bi];
            if (buf->mData && buf->mDataByteSize) memset(buf->mData, 0, buf->mDataByteSize);
        }
        BXFloatAQNotePaintDstPeak(0);
        static _Atomic int sPullZeroLog = 0;
        int n = atomic_fetch_add(&sPullZeroLog, 1);
        if (n < 8 || (n % 64) == 0) {
            NSLog(@"BXFloatMic PULL-ZERO hold-zero rate=%.0f ch=%d", rate, outCh);
        }
        return;
    }

    int planeBps = bytesPerSample;
    if (isFloat && planeBps < 4) planeBps = 4;

    // 整缓冲覆盖写满：禁止残留原麦与注入拼缝
    if (nonInterleaved) {
        int planes = (int)ioData->mNumberBuffers;
        for (int p = 0; p < planes; p++) {
            AudioBuffer *buf = &ioData->mBuffers[p];
            if (!buf->mData || buf->mDataByteSize == 0) continue;
            uint8_t *dst = (uint8_t *)buf->mData;
            size_t cap = buf->mDataByteSize;
            int srcCh = p < outCh ? p : (outCh - 1);
            if (srcCh < 0) srcCh = 0;
            int16_t last = pcm[srcCh];
            for (UInt32 i = 0; i < frames; i++) {
                size_t off = (size_t)i * (size_t)planeBps;
                if (off + (size_t)planeBps > cap) break;
                last = pcm[i * outCh + srcCh];
                writeOneSample(dst + off, last, planeBps, isFloat);
            }
            // 写满 cap：末样延续，禁静音硬边
            size_t off = (size_t)frames * (size_t)planeBps;
            for (; off + (size_t)planeBps <= cap; off += (size_t)planeBps) {
                writeOneSample(dst + off, last, planeBps, isFloat);
            }
        }
    } else {
        AudioBuffer *b0 = &ioData->mBuffers[0];
        if (b0->mData && b0->mDataByteSize) {
            uint8_t *dst = (uint8_t *)b0->mData;
            size_t cap = b0->mDataByteSize;
            int ch = chInBuf > 0 ? chInBuf : 1;
            int16_t lastL = 0, lastR = 0;
            size_t nextOff = 0;
            for (UInt32 i = 0; i < frames; i++) {
                for (int c = 0; c < ch; c++) {
                    size_t off = ((size_t)i * (size_t)ch + (size_t)c) * (size_t)planeBps;
                    if (off + (size_t)planeBps > cap) { nextOff = off; goto fill_rest_i; }
                    int src = c < outCh ? c : (outCh > 1 ? (c % outCh) : 0);
                    int16_t s = pcm[i * outCh + src];
                    if (c == 0) lastL = s;
                    if (c == 1) lastR = s;
                    writeOneSample(dst + off, s, planeBps, isFloat);
                    nextOff = off + (size_t)planeBps;
                }
            }
        fill_rest_i:
            for (size_t off = nextOff; off + (size_t)planeBps <= cap; off += (size_t)planeBps) {
                int c = ch > 0 ? (int)((off / (size_t)planeBps) % (size_t)ch) : 0;
                int16_t fill = (c == 1 && outCh > 1) ? lastR : lastL;
                writeOneSample(dst + off, fill, planeBps, isFloat);
            }
        }
    }

    // 写后峰 + 听:注：从真实 AU 缓冲回读 s16（与录制轨同内容）
    int32_t dstPk = 0;
    AudioBuffer *b0 = &ioData->mBuffers[0];
    if (b0->mData && b0->mDataByteSize && frames > 0) {
        int tapCh = nonInterleaved ? 1 : (chInBuf > 0 ? chInBuf : 1);
        if (tapCh > 2) tapCh = 2;
        int16_t *tap = pcm; // 复用 tmp：重填为写后内容
        if (isFloat && planeBps >= 4) {
            if (nonInterleaved) {
                const float *fp = (const float *)b0->mData;
                UInt32 n = b0->mDataByteSize / 4;
                if (n > frames) n = frames;
                for (UInt32 i = 0; i < n; i++) {
                    float v = fp[i];
                    int32_t s = (int32_t)(v * 32767.0f);
                    if (s > 32767) s = 32767;
                    if (s < -32768) s = -32768;
                    tap[i] = (int16_t)s;
                    int32_t a = s >= 0 ? s : -s;
                    if (a > dstPk) dstPk = a;
                }
                tapCh = 1;
                BXFloatMicNoteInjectPCM(tap, (int)n, 1, (int)rate);
            } else {
                const float *fp = (const float *)b0->mData;
                int ch = chInBuf > 0 ? chInBuf : 1;
                UInt32 n = b0->mDataByteSize / (4 * (size_t)ch);
                if (n > frames) n = frames;
                for (UInt32 i = 0; i < n; i++) {
                    for (int c = 0; c < tapCh && c < ch; c++) {
                        float v = fp[i * ch + c];
                        int32_t s = (int32_t)(v * 32767.0f);
                        if (s > 32767) s = 32767;
                        if (s < -32768) s = -32768;
                        tap[i * tapCh + c] = (int16_t)s;
                        if (c == 0) {
                            int32_t a = s >= 0 ? s : -s;
                            if (a > dstPk) dstPk = a;
                        }
                    }
                }
                BXFloatMicNoteInjectPCM(tap, (int)n, tapCh, (int)rate);
            }
        } else if (planeBps == 2) {
            if (nonInterleaved) {
                const int16_t *sp = (const int16_t *)b0->mData;
                UInt32 n = b0->mDataByteSize / 2;
                if (n > frames) n = frames;
                for (UInt32 i = 0; i < n; i++) {
                    int16_t s = sp[i];
                    tap[i] = s;
                    int32_t a = s >= 0 ? s : -s;
                    if (a > dstPk) dstPk = a;
                }
                BXFloatMicNoteInjectPCM(tap, (int)n, 1, (int)rate);
            } else {
                const int16_t *sp = (const int16_t *)b0->mData;
                int ch = chInBuf > 0 ? chInBuf : 1;
                UInt32 n = b0->mDataByteSize / (2 * (size_t)ch);
                if (n > frames) n = frames;
                for (UInt32 i = 0; i < n; i++) {
                    for (int c = 0; c < tapCh && c < ch; c++) {
                        int16_t s = sp[i * ch + c];
                        tap[i * tapCh + c] = s;
                        if (c == 0) {
                            int32_t a = s >= 0 ? s : -s;
                            if (a > dstPk) dstPk = a;
                        }
                    }
                }
                BXFloatMicNoteInjectPCM(tap, (int)n, tapCh, (int)rate);
            }
        }
    }
    BXFloatAQNotePaintDstPeak(dstPk);
    if (pullPk > 200 && dstPk <= 200) {
        NSLog(@"BXFloatMic WRITE-DROP pull=%d dst=%d ch=%d bps=%d float=%d planes=%u",
              (int)pullPk, (int)dstPk, outCh, planeBps, isFloat, (unsigned)ioData->mNumberBuffers);
    }
}

/// 在 paint 写完后的真实 AU 缓冲上取峰（非 scratchOut）
static void probeInjectAfterPaint(
    AudioBufferList *ioData,
    UInt32 frames,
    const AudioStreamBasicDescription *asbd
) {
    if (!ioData || frames == 0 || ioData->mNumberBuffers == 0) return;
    int chInBuf = 1, bytesPerSample = 4, isFloat = 1, mismatch = 0;
    double rate = 48000;
    if (!resolveFormat(ioData, frames, asbd, &chInBuf, &bytesPerSample, &isFloat, &mismatch, &rate)) {
        return;
    }
    AudioBuffer *b0 = &ioData->mBuffers[0];
    if (!b0->mData || b0->mDataByteSize == 0) return;
    // 非交错：每平面 ch=1；交错：按缓冲声道。只采第一路。
    int probeCh = 1;
    BOOL multiPlane = (ioData->mNumberBuffers > 1);
    BOOL asbdNI = asbd && (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    if (!multiPlane && !asbdNI) {
        probeCh = chInBuf > 0 ? chInBuf : 1;
    }
    BXFloatAQNoteInjectTap(
        b0->mData,
        (int)frames,
        probeCh,
        bytesPerSample,
        isFloat,
        (int)(rate > 0 ? rate : 48000)
    );
}

static OSStatus hooked_AudioUnitRender(
    AudioUnit inUnit,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inOutputBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) {
    if (!orig_AudioUnitRender) {
        return -1;
    }
    OSStatus st = orig_AudioUnitRender(
        inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData
    );
    int mode = atomic_load(&gMode);
    // bus0 = 扬声器输出，绝不能改
    if (st != noErr || !ioData || inNumberFrames == 0 || inOutputBusNumber == 0) {
        return st;
    }

    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    UInt32 sz = sizeof(asbd);
    OSStatus gs = AudioUnitGetProperty(
        inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inOutputBusNumber, &asbd, &sz
    );
    if (gs != noErr || asbd.mSampleRate <= 0) {
        sz = sizeof(asbd);
        AudioUnitGetProperty(
            inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inOutputBusNumber, &asbd, &sz
        );
    }

    // 原麦模式：不改缓冲，只抽检音质对照
    if (mode == 0) {
        tapMicABL(ioData, inNumberFrames, &asbd);
        return st;
    }

    atomic_fetch_add(&gCallback, 1);
    paintABL(ioData, inNumberFrames, &asbd, mode);
    // 必须在 paint 之后、return 之前采同一块 ioData（分清空写 / 探针错位 / 事后清零）
    probeInjectAfterPaint(ioData, inNumberFrames, &asbd);
    atomic_fetch_add(&gPaint, 1);
    return st;
}

static OSStatus hooked_AudioComponentInstanceNew(
    AudioComponent inComponent,
    AudioComponentInstance *outInstance
) {
    if (!orig_AudioComponentInstanceNew) return -1;
    OSStatus st = orig_AudioComponentInstanceNew(inComponent, outInstance);
    if (st == noErr) {
        int64_t n = atomic_fetch_add(&gAUCreate, 1) + 1;
        if (n <= 8 || (n % 32) == 0) {
            AudioComponentDescription desc;
            memset(&desc, 0, sizeof(desc));
            if (inComponent) {
                AudioComponentGetDescription(inComponent, &desc);
            }
            uint32_t t = CFSwapInt32HostToBig(desc.componentType);
            uint32_t s = CFSwapInt32HostToBig(desc.componentSubType);
            uint32_t m = CFSwapInt32HostToBig(desc.componentManufacturer);
            NSLog(
                @"BXFloatMic AU create #%lld type=%.4s subtype=%.4s manuf=%.4s",
                (long long)n,
                (char *)&t,
                (char *)&s,
                (char *)&m
            );
        }
    }
    return st;
}

static OSStatus hooked_AudioOutputUnitStart(AudioUnit ci) {
    if (!orig_AudioOutputUnitStart) return -1;
    OSStatus st = orig_AudioOutputUnitStart(ci);
    if (st == noErr) {
        int64_t n = atomic_fetch_add(&gAUStart, 1) + 1;
        if (n <= 8 || (n % 32) == 0) {
            NSLog(@"BXFloatMic AU start #%lld unit=%p", (long long)n, ci);
        }
    }
    return st;
}

static void hooked_AudioQueueInputCallback(
    void *inUserData,
    AudioQueueRef inAQ,
    AudioQueueBufferRef inBuffer,
    const AudioTimeStamp *inStartTime,
    UInt32 inNumberPacketDescriptions,
    const AudioStreamPacketDescription *inPacketDescs
) {
    BXAQWrap *wrap = (BXAQWrap *)inUserData;
    if (!wrap) return;

    atomic_fetch_add(&gAQCallback, 1);
    int mode = atomic_load(&gMode);

    if (mode != 0 && inBuffer && inBuffer->mAudioData && inBuffer->mAudioDataByteSize > 0) {
        AudioStreamBasicDescription asbd = wrap->asbd;
        UInt32 bpf = asbd.mBytesPerPacket > 0
            ? asbd.mBytesPerPacket
            : (asbd.mBytesPerFrame > 0 ? asbd.mBytesPerFrame : 0);
        UInt32 frames = 0;
        if (bpf > 0) {
            frames = inBuffer->mAudioDataByteSize / bpf;
        }
        if (frames > 0) {
            AudioBufferList abl;
            memset(&abl, 0, sizeof(abl));
            abl.mNumberBuffers = 1;
            abl.mBuffers[0].mNumberChannels =
                asbd.mChannelsPerFrame > 0 ? asbd.mChannelsPerFrame : 1;
            abl.mBuffers[0].mDataByteSize = inBuffer->mAudioDataByteSize;
            abl.mBuffers[0].mData = inBuffer->mAudioData;

            int tick = atomic_fetch_add(&gAQFmtLogTick, 1);
            if (tick == 0 || (tick % 100) == 0) {
                NSLog(
                    @"BXFloatMic AQ fmt rate=%.0f frames=%u bytes=%u ch=%u bits=%u flags=0x%x mode=%d",
                    asbd.mSampleRate,
                    (unsigned)frames,
                    (unsigned)inBuffer->mAudioDataByteSize,
                    (unsigned)asbd.mChannelsPerFrame,
                    (unsigned)asbd.mBitsPerChannel,
                    (unsigned)asbd.mFormatFlags,
                    mode
                );
            }

            // 系统已填好原麦 → 原地改写后再交给宿主回调（与 VCam AQ 路径同序）
            paintABL(&abl, frames, &asbd, mode);
            atomic_fetch_add(&gAQPaint, 1);
        }
    } else if (mode == 0 && inBuffer && inBuffer->mAudioData && inBuffer->mAudioDataByteSize > 0) {
        AudioStreamBasicDescription asbd = wrap->asbd;
        UInt32 bpf = asbd.mBytesPerPacket > 0
            ? asbd.mBytesPerPacket
            : (asbd.mBytesPerFrame > 0 ? asbd.mBytesPerFrame : 0);
        if (bpf > 0) {
            UInt32 frames = inBuffer->mAudioDataByteSize / bpf;
            if (frames > 0) {
                AudioBufferList abl;
                memset(&abl, 0, sizeof(abl));
                abl.mNumberBuffers = 1;
                abl.mBuffers[0].mNumberChannels =
                    asbd.mChannelsPerFrame > 0 ? asbd.mChannelsPerFrame : 1;
                abl.mBuffers[0].mDataByteSize = inBuffer->mAudioDataByteSize;
                abl.mBuffers[0].mData = inBuffer->mAudioData;
                tapMicABL(&abl, frames, &asbd);
            }
        }
    }

    if (wrap->orig) {
        wrap->orig(
            wrap->userData,
            inAQ,
            inBuffer,
            inStartTime,
            inNumberPacketDescriptions,
            inPacketDescs
        );
    }
}

static OSStatus hooked_AudioQueueNewInput(
    const AudioStreamBasicDescription *inFormat,
    AudioQueueInputCallback inCallbackProc,
    void *inUserData,
    CFRunLoopRef inCallbackRunLoop,
    CFStringRef inCallbackRunLoopMode,
    UInt32 inFlags,
    AudioQueueRef *outAQ
) {
    if (!orig_AudioQueueNewInput) return -1;

    AudioQueueInputCallback cb = inCallbackProc;
    void *ud = inUserData;
    BXAQWrap *slot = NULL;

    if (inCallbackProc) {
        for (int i = 0; i < kAQWrapSlots; i++) {
            int expected = 0;
            if (atomic_compare_exchange_strong(&gAQWraps[i].used, &expected, 1)) {
                slot = &gAQWraps[i];
                break;
            }
        }
    }

    if (slot) {
        slot->orig = inCallbackProc;
        slot->userData = inUserData;
        memset(&slot->asbd, 0, sizeof(slot->asbd));
        if (inFormat) {
            slot->asbd = *inFormat;
        }
        cb = hooked_AudioQueueInputCallback;
        ud = slot;
        NSLog(
            @"BXFloatMic AQ NewInput wrap rate=%.0f ch=%u bits=%u",
            slot->asbd.mSampleRate,
            (unsigned)slot->asbd.mChannelsPerFrame,
            (unsigned)slot->asbd.mBitsPerChannel
        );
    } else if (inCallbackProc) {
        NSLog(@"BXFloatMic AQ NewInput wrap slots full — pass-through");
    }

    OSStatus st = orig_AudioQueueNewInput(
        inFormat, cb, ud, inCallbackRunLoop, inCallbackRunLoopMode, inFlags, outAQ
    );
    if (st != noErr && slot) {
        slot->orig = NULL;
        slot->userData = NULL;
        atomic_store(&slot->used, 0);
    }
    return st;
}

void BXFloatMicAUInstall(void) {
    if (atomic_load(&gInstalled)) return;

    if (!orig_AudioUnitRender) {
        orig_AudioUnitRender = (void *)dlsym(RTLD_DEFAULT, "AudioUnitRender");
    }
    if (!orig_AudioComponentInstanceNew) {
        orig_AudioComponentInstanceNew = (void *)dlsym(RTLD_DEFAULT, "AudioComponentInstanceNew");
    }
    if (!orig_AudioOutputUnitStart) {
        orig_AudioOutputUnitStart = (void *)dlsym(RTLD_DEFAULT, "AudioOutputUnitStart");
    }
    if (!orig_AudioQueueNewInput) {
        orig_AudioQueueNewInput = (void *)dlsym(RTLD_DEFAULT, "AudioQueueNewInput");
    }

    if (!orig_AudioUnitRender && !orig_AudioQueueNewInput) {
        NSLog(@"BXFloatMic AU/AQ dlsym failed — skip hook");
        return;
    }

    struct rebinding rebs[4];
    int n = 0;
    if (orig_AudioUnitRender) {
        rebs[n++] = (struct rebinding){
            "AudioUnitRender", (void *)hooked_AudioUnitRender, (void **)&orig_AudioUnitRender
        };
    }
    if (orig_AudioComponentInstanceNew) {
        rebs[n++] = (struct rebinding){
            "AudioComponentInstanceNew",
            (void *)hooked_AudioComponentInstanceNew,
            (void **)&orig_AudioComponentInstanceNew
        };
    }
    if (orig_AudioOutputUnitStart) {
        rebs[n++] = (struct rebinding){
            "AudioOutputUnitStart",
            (void *)hooked_AudioOutputUnitStart,
            (void **)&orig_AudioOutputUnitStart
        };
    }
    if (orig_AudioQueueNewInput) {
        rebs[n++] = (struct rebinding){
            "AudioQueueNewInput",
            (void *)hooked_AudioQueueNewInput,
            (void **)&orig_AudioQueueNewInput
        };
    }

    int rc = rebind_symbols(rebs, n);
    atomic_store(&gInstalled, 1);
    NSLog(
        @"BXFloatMic AudioUnit and AudioQueue probes installed rc=%d n=%d render=%p aq=%p create=%p start=%p",
        rc,
        n,
        orig_AudioUnitRender,
        orig_AudioQueueNewInput,
        orig_AudioComponentInstanceNew,
        orig_AudioOutputUnitStart
    );
}
