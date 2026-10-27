#import "CameraProxyForward.h"
#import <objc/message.h>
#import <objc/runtime.h>

void BXFloatForwardDidOutput(
    id target,
    AVCaptureOutput *output,
    CMSampleBufferRef sampleBuffer,
    AVCaptureConnection *connection
) {
    if (!target || !output || !sampleBuffer || !connection) { return; }
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    if (![target respondsToSelector:sel]) { return; }
    void (*msg)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) =
        (void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))objc_msgSend;
    msg(target, sel, output, sampleBuffer, connection);
}

void BXFloatForwardDidDrop(
    id target,
    AVCaptureOutput *output,
    CMSampleBufferRef sampleBuffer,
    AVCaptureConnection *connection
) {
    if (!target || !output || !sampleBuffer || !connection) { return; }
    SEL sel = @selector(captureOutput:didDropSampleBuffer:fromConnection:);
    if (![target respondsToSelector:sel]) { return; }
    void (*msg)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) =
        (void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))objc_msgSend;
    msg(target, sel, output, sampleBuffer, connection);
}

void BXFloatRestoreSampleBufferDelegate(
    AVCaptureVideoDataOutput *output,
    id delegate,
    dispatch_queue_t queue
) {
    BXFloatRestoreSampleBufferDelegateAny(output, delegate, queue);
}

void BXFloatRestoreSampleBufferDelegateAny(
    id output,
    id delegate,
    dispatch_queue_t queue
) {
    if (!output) { return; }
    if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
        [(AVCaptureVideoDataOutput *)output setSampleBufferDelegate:delegate queue:queue];
        return;
    }
    if ([output isKindOfClass:[AVCaptureAudioDataOutput class]]) {
        [(AVCaptureAudioDataOutput *)output setSampleBufferDelegate:delegate queue:queue];
        return;
    }
}
