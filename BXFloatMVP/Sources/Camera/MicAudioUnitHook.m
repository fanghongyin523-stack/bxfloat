#import "MicAudioUnitHook.h"
#import "fishhook.h"

#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>
#import <string.h>

// Swift CamAudioStore bridge
FOUNDATION_EXPORT void BXFloatMicPaintRaw(
    void *dst,
    int byteCount,
    double sampleRate,
    int channels,
    int bitsPerChannel,
    int isFloat,
    int mode // 1=stream 2=mute
);

static OSStatus (*orig_AudioUnitRender)(
    AudioUnit inUnit,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inOutputBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) = NULL;

static OSStatus (*orig_AudioQueueNewInput)(
    const AudioStreamBasicDescription *inFormat,
    AudioQueueInputCallback inCallback,
    void *inUserData,
    CFRunLoopRef inCallbackRunLoop,
    CFStringRef inCallbackRunLoopMode,
    UInt32 inFlags,
    AudioQueueRef *outAQ
) = NULL;

static _Atomic int gMode = 0; // 0 mic, 1 stream, 2 mute
static _Atomic int64_t gPaint = 0;
static _Atomic int64_t gCallback = 0;

void BXFloatMicAUSetMode(int mode) {
    atomic_store(&gMode, mode);
}

int64_t BXFloatMicAUPaintCount(void) {
    return atomic_load(&gPaint);
}

int64_t BXFloatMicAUCallbackCount(void) {
    return atomic_load(&gCallback);
}

static void paintABL(AudioBufferList *ioData, UInt32 frames, const AudioStreamBasicDescription *asbd, int mode) {
    if (!ioData || frames == 0 || mode == 0) return;
    double rate = asbd && asbd->mSampleRate > 0 ? asbd->mSampleRate : 48000.0;
    int bits = asbd && asbd->mBitsPerChannel > 0 ? (int)asbd->mBitsPerChannel : 16;
    int isFloat = asbd ? ((asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0) : 0;
    int nonInterleaved = asbd ? ((asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) : 0;

    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
        AudioBuffer *buf = &ioData->mBuffers[i];
        if (!buf->mData || buf->mDataByteSize == 0) continue;
        int ch = nonInterleaved ? 1 : (int)(buf->mNumberChannels > 0 ? buf->mNumberChannels : 1);
        if (asbd && !nonInterleaved && asbd->mChannelsPerFrame > 0) {
            ch = (int)asbd->mChannelsPerFrame;
        }
        BXFloatMicPaintRaw(buf->mData, (int)buf->mDataByteSize, rate, ch, bits, isFloat, mode);
        atomic_fetch_add(&gPaint, 1);
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
    OSStatus st = orig_AudioUnitRender
        ? orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData)
        : -1;
    int mode = atomic_load(&gMode);
    // RemoteIO / VPIO：input bus 一般为 1；bus0 是扬声器，绝不能改
    if (st != noErr || mode == 0 || !ioData || inNumberFrames == 0 || inOutputBusNumber == 0) {
        return st;
    }

    atomic_fetch_add(&gCallback, 1);

    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    UInt32 sz = sizeof(asbd);
    // 优先 input scope（拉麦），失败再试 output
    OSStatus gs = AudioUnitGetProperty(
        inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inOutputBusNumber, &asbd, &sz
    );
    if (gs != noErr || asbd.mSampleRate <= 0) {
        sz = sizeof(asbd);
        AudioUnitGetProperty(
            inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inOutputBusNumber, &asbd, &sz
        );
    }
    paintABL(ioData, inNumberFrames, &asbd, mode);
    return st;
}

typedef struct {
    AudioQueueInputCallback orig;
    void *userData;
} BXFloatAQCtx;

static void hooked_AQInputCallback(
    void *inUserData,
    AudioQueueRef inAQ,
    AudioQueueBufferRef inBuffer,
    const AudioTimeStamp *inStartTime,
    UInt32 inNumberPacketDescriptions,
    const AudioStreamPacketDescription *inPacketDescs
) {
    BXFloatAQCtx *ctx = (BXFloatAQCtx *)inUserData;
    int mode = atomic_load(&gMode);
    if (mode != 0 && inBuffer && inBuffer->mAudioData && inBuffer->mAudioDataByteSize > 0) {
        atomic_fetch_add(&gCallback, 1);
        AudioStreamBasicDescription asbd;
        memset(&asbd, 0, sizeof(asbd));
        UInt32 sz = sizeof(asbd);
        if (AudioQueueGetProperty(inAQ, kAudioQueueProperty_StreamDescription, &asbd, &sz) != noErr) {
            asbd.mSampleRate = 48000;
            asbd.mChannelsPerFrame = 1;
            asbd.mBitsPerChannel = 16;
            asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        }
        BXFloatMicPaintRaw(
            inBuffer->mAudioData,
            (int)inBuffer->mAudioDataByteSize,
            asbd.mSampleRate,
            (int)(asbd.mChannelsPerFrame > 0 ? asbd.mChannelsPerFrame : 1),
            (int)(asbd.mBitsPerChannel > 0 ? asbd.mBitsPerChannel : 16),
            (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? 1 : 0,
            mode
        );
        atomic_fetch_add(&gPaint, 1);
    }
    if (ctx && ctx->orig) {
        ctx->orig(ctx->userData, inAQ, inBuffer, inStartTime, inNumberPacketDescriptions, inPacketDescs);
    }
}

static OSStatus hooked_AudioQueueNewInput(
    const AudioStreamBasicDescription *inFormat,
    AudioQueueInputCallback inCallback,
    void *inUserData,
    CFRunLoopRef inCallbackRunLoop,
    CFStringRef inCallbackRunLoopMode,
    UInt32 inFlags,
    AudioQueueRef *outAQ
) {
    if (!orig_AudioQueueNewInput) return -1;
    if (!inCallback) {
        return orig_AudioQueueNewInput(
            inFormat, inCallback, inUserData, inCallbackRunLoop, inCallbackRunLoopMode, inFlags, outAQ
        );
    }
    BXFloatAQCtx *ctx = (BXFloatAQCtx *)calloc(1, sizeof(BXFloatAQCtx));
    if (!ctx) {
        return orig_AudioQueueNewInput(
            inFormat, inCallback, inUserData, inCallbackRunLoop, inCallbackRunLoopMode, inFlags, outAQ
        );
    }
    ctx->orig = inCallback;
    ctx->userData = inUserData;
    NSLog(@"BXFloatMic AQ NewInput hooked");
    return orig_AudioQueueNewInput(
        inFormat, hooked_AQInputCallback, ctx, inCallbackRunLoop, inCallbackRunLoopMode, inFlags, outAQ
    );
}

void BXFloatMicAUInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct rebinding rebs[2] = {
            {"AudioUnitRender", (void *)hooked_AudioUnitRender, (void **)&orig_AudioUnitRender},
            {"AudioQueueNewInput", (void *)hooked_AudioQueueNewInput, (void **)&orig_AudioQueueNewInput},
        };
        int rc = rebind_symbols(rebs, 2);
        NSLog(@"BXFloatMic AU fishhook rc=%d origRender=%p origAQ=%p",
              rc, orig_AudioUnitRender, orig_AudioQueueNewInput);
    });
}
