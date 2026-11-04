#import "MicAudioUnitHook.h"
#import "fishhook.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreFoundation/CoreFoundation.h>
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
        // 立体声：交错取一次再拆平面；禁止「只取 mono 再 memcpy 到 R」把声像抹掉
        int planes = (int)ioData->mNumberBuffers;
        if (planes < 1) planes = 1;
        if (planes > 8) planes = 8;
        size_t tmpBytes = (size_t)frames * (size_t)planes * (size_t)bytesPerSample;
        if (tmpBytes > sizeof(gPaintTmp) || frames > 4096) {
            // 超限兜底：只写第一平面，避免回调里堆分配
            BXFloatMicPaintFrames(b0->mData, (int)frames, 1, rate, bytesPerSample, isFloat, mode);
            for (UInt32 i = 1; i < ioData->mNumberBuffers; i++) {
                AudioBuffer *buf = &ioData->mBuffers[i];
                if (!buf->mData || buf->mDataByteSize == 0) continue;
                size_t n = buf->mDataByteSize < b0->mDataByteSize ? buf->mDataByteSize : b0->mDataByteSize;
                memcpy(buf->mData, b0->mData, n);
            }
        } else {
            memset(gPaintTmp, 0, tmpBytes);
            BXFloatMicPaintFrames(gPaintTmp, (int)frames, planes, rate, bytesPerSample, isFloat, mode);
            for (int p = 0; p < planes; p++) {
                AudioBuffer *buf = &ioData->mBuffers[p];
                if (!buf->mData || buf->mDataByteSize == 0) continue;
                uint8_t *dst = (uint8_t *)buf->mData;
                size_t planeCap = buf->mDataByteSize;
                for (UInt32 i = 0; i < frames; i++) {
                    size_t off = (size_t)i * (size_t)bytesPerSample;
                    if (off + (size_t)bytesPerSample > planeCap) break;
                    size_t srcOff = ((size_t)i * (size_t)planes + (size_t)p) * (size_t)bytesPerSample;
                    memcpy(dst + off, gPaintTmp + srcOff, (size_t)bytesPerSample);
                }
            }
        }
    } else {
        BXFloatMicPaintFrames(
            b0->mData, (int)frames, chInBuf, rate, bytesPerSample, isFloat, mode
        );
    }
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
