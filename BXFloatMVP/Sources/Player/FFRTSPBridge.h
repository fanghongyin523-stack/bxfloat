#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// 单文件注入用：内嵌 FFmpeg 拉 RTSP（TCP），解码后回调 CVPixelBuffer。
/// 对标参考版 BXFloat：播放引擎打进 dylib，无需再拷 Framework。
@interface FFRTSPBridge : NSObject

+ (instancetype)shared;
+ (BOOL)isAvailable;

- (void)startWithURL:(NSString *)urlString;
- (void)stop;

@property (nonatomic, readonly) int64_t frameOK;
@property (nonatomic, readonly) int64_t frameFail;

@end

/// 由 Swift 侧实现：把帧写入 CamFrameStore
FOUNDATION_EXPORT void BXFloatPublishVideoFrame(CVPixelBufferRef buffer);

/// C 入口（免 bridging header，供 Swift @_silgen_name 调用）
FOUNDATION_EXPORT BOOL BXFloatFFIsAvailable(void);
FOUNDATION_EXPORT void BXFloatFFStartUTF8(const char * _Nonnull urlUTF8);
FOUNDATION_EXPORT void BXFloatFFStop(void);

NS_ASSUME_NONNULL_END
