#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

/// 安全把 sampleBuffer 转发给原始 ObjC/Swift delegate，避免 class_getInstanceMethod 调错。
void BXFloatForwardDidOutput(
    id _Nullable target,
    AVCaptureOutput *output,
    CMSampleBufferRef sampleBuffer,
    AVCaptureConnection *connection
);

void BXFloatForwardDidDrop(
    id _Nullable target,
    AVCaptureOutput *output,
    CMSampleBufferRef sampleBuffer,
    AVCaptureConnection *connection
);

/// 绕过 Swift 协议转换，直接把任意 ObjC delegate 设回去（关替换时防黑屏）。
void BXFloatRestoreSampleBufferDelegate(
    AVCaptureVideoDataOutput *output,
    id _Nullable delegate,
    dispatch_queue_t _Nullable queue
);

NS_ASSUME_NONNULL_END
