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
static _Atomic int gLoggedFmt = 0;

void BXFloatMicAUSetMode(int mode) {
    atomic_store(&gMode, mode);
}

int64_t BXFloatMicAUPaintCount(void) {
    return atomic_load(&gPaint);
}

int64_t BXFloatMicAUCallbackCount(void) {
    return atomic_load(&gCallback);
}

static void paintABL(
    AudioBufferList *ioData,
    UInt32 frames,
    const AudioStreamBasicDescription *asbd,
    int mode
) {
    if (!ioData || frames == 0 || mode == 0 || ioData->mNumberBuffers == 0) return;

    AudioBuffer *b0 = &ioData->mBuffers[0];
    if (!b0->mData || b0->mDataByteSize == 0) return;

    // 用缓冲几何推断格式（比 ASBD 更可靠；ASBD 常出现 bits=0）
    int bytesPerFrameInBuf = (int)(b0->mDataByteSize / frames);
    if (bytesPerFrameInBuf <= 0) return;

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
    if (asbd && (asbd->mFormatFlags & kAudioFormatFlagIsFloat)) {
        isFloat = 1;
    } else if (bytesPerSample == 4) {
        // iOS RemoteIO / VPIO 输入几乎都是 Float32
        isFloat = 1;
    } else if (bytesPerSample == 2) {
        isFloat = 0;
    } else if (bytesPerSample == 8) {
        // 极少见 double
        isFloat = 1;
        bytesPerSample = 8;
    }

    // 纠正：float 却推成 2 字节 → 电流声根因
    if (isFloat && bytesPerSample < 4) {
        bytesPerSample = 4;
        chInBuf = bytesPerFrameInBuf / 4;
        if (chInBuf <= 0) chInBuf = 1;
    }
    if (!isFloat && bytesPerSample != 2 && bytesPerSample != 4) {
        // 回退：按缓冲宽猜测
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
    }

    double rate = 48000.0;
    if (asbd && asbd->mSampleRate > 0) {
        rate = asbd->mSampleRate;
    }

    if (!atomic_exchange(&gLoggedFmt, 1)) {
        NSLog(
            @"BXFloatMic AU fmt rate=%.0f frames=%u bufs=%u bytes/buf=%u bpf=%d ch=%d bps=%d float=%d asbdBits=%u asbdFlags=0x%x",
            rate,
            (unsigned)frames,
            (unsigned)ioData->mNumberBuffers,
            (unsigned)b0->mDataByteSize,
            bytesPerFrameInBuf,
            chInBuf,
            bytesPerSample,
            isFloat,
            asbd ? (unsigned)asbd->mBitsPerChannel : 0,
            asbd ? (unsigned)asbd->mFormatFlags : 0
        );
    }

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
    if (st != noErr || mode == 0 || !ioData || inNumberFrames == 0 || inOutputBusNumber == 0) {
        return st;
    }

    atomic_fetch_add(&gCallback, 1);

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
