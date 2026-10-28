#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// 单文件注入用：内嵌 FFmpeg 拉 RTSP（TCP），解码后回调 CVPixelBuffer。
@interface FFRTSPBridge : NSObject

+ (instancetype)shared;
+ (BOOL)isAvailable;

- (void)startWithURL:(NSString *)urlString;
- (void)stop;

@property (nonatomic, readonly) int64_t frameOK;
@property (nonatomic, readonly) int64_t frameFail;

@end

/// pts：流媒体时间（秒）；未知时传 -1
FOUNDATION_EXPORT void BXFloatPublishVideoFrame(CVPixelBufferRef buffer, double pts);

FOUNDATION_EXPORT void BXFloatPublishAudioPCM(
    const int16_t *samples,
    int frames,
    int channels,
    int sampleRate,
    double pts
);

FOUNDATION_EXPORT BOOL BXFloatFFIsAvailable(void);
FOUNDATION_EXPORT void BXFloatFFStartUTF8(const char * _Nonnull urlUTF8);
FOUNDATION_EXPORT void BXFloatFFStop(void);

NS_ASSUME_NONNULL_END
