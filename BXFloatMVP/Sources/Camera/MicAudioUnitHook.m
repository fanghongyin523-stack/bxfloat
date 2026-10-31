#import "MicAudioUnitHook.h"
#import "fishhook.h"

#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <stdatomic.h>
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

static OSStatus (*orig_AudioUnitRender)(
    AudioUnit inUnit,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inOutputBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) = NULL;

static _Atomic int gMode = 0; // 0 mic, 1 stream, 2 mute
static _Atomic int64_t gPaint = 0;
static _Atomic int64_t gCallback = 0;
static _Atomic int gInstalled = 0;
static _Atomic int gFmtLogTick = 0;

void BXFloatMicAUSetMode(int mode) {
    atomic_store(&gMode, mode);
}

int64_t BXFloatMicAUPaintCount(void) {
    return atomic_load(&gPaint);
}

int64_t BXFloatMicAUCallbackCount(void) {
    return atomic_load(&gCallback);
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

    AudioBuffer *b0 = &ioData->mBuffers[0];
    if (nonInterleaved || multiPlane) {
        // 只从环缓读一次，复制到各平面，避免左右声道各吃一段 PCM 变成噪声
        BXFloatMicPaintFrames(b0->mData, (int)frames, 1, rate, bytesPerSample, isFloat, mode);
        for (UInt32 i = 1; i < ioData->mNumberBuffers; i++) {
            AudioBuffer *buf = &ioData->mBuffers[i];
            if (!buf->mData || buf->mDataByteSize == 0) continue;
            size_t n = buf->mDataByteSize < b0->mDataByteSize ? buf->mDataByteSize : b0->mDataByteSize;
            memcpy(buf->mData, b0->mData, n);
        }
    } else {
        BXFloatMicPaintFrames(
            b0->mData, (int)frames, chInBuf, rate, bytesPerSample, isFloat, mode
        );
    }
    atomic_fetch_add(&gPaint, 1);
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
    return st;
}

void BXFloatMicAUInstall(void) {
    if (atomic_load(&gInstalled)) return;

    if (!orig_AudioUnitRender) {
        orig_AudioUnitRender = (void *)dlsym(RTLD_DEFAULT, "AudioUnitRender");
    }
    if (!orig_AudioUnitRender) {
        NSLog(@"BXFloatMic AU dlsym AudioUnitRender failed — skip hook");
        return;
    }

    struct rebinding rebs[1] = {
        {"AudioUnitRender", (void *)hooked_AudioUnitRender, (void **)&orig_AudioUnitRender},
    };
    int rc = rebind_symbols(rebs, 1);
    atomic_store(&gInstalled, 1);
    NSLog(@"BXFloatMic AU fishhook rc=%d origRender=%p", rc, orig_AudioUnitRender);
}
