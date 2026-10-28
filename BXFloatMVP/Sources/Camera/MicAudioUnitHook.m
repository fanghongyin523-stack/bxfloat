#import "MicAudioUnitHook.h"
#import "fishhook.h"

#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <string.h>

FOUNDATION_EXPORT void BXFloatMicPaintRaw(
    void *dst,
    int byteCount,
    double sampleRate,
    int channels,
    int bitsPerChannel,
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
    if (!orig_AudioUnitRender) {
        return -1;
    }
    OSStatus st = orig_AudioUnitRender(
        inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData
    );
    int mode = atomic_load(&gMode);
    // bus0 = 输出；只改 input bus
    if (st != noErr || mode == 0 || !ioData || inNumberFrames == 0 || inOutputBusNumber == 0) {
        return st;
    }

    atomic_fetch_add(&gCallback, 1);

    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    UInt32 sz = sizeof(asbd);
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

void BXFloatMicAUInstall(void) {
    if (atomic_load(&gInstalled)) return;

    // 先 dlsym 拿到真函数，避免 GOT 重绑失败时 orig 为空
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
