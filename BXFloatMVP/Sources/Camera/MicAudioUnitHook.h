#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 抖音直播麦走 AudioUnit / AudioQueue，不走 AVCaptureAudioDataOutput。
/// 多入口：AU Render 改写 + AQ Input 改写；Create/Start 仅探针计数。
FOUNDATION_EXPORT void BXFloatMicAUInstall(void);
FOUNDATION_EXPORT void BXFloatMicAUSetMode(int mode); // 0=原麦 1=推流 2=静音
/// 对标 VCamTang hasMaterialAudio：推流环有新鲜素材才允许替麦
FOUNDATION_EXPORT int BXFloatMicHasMaterialAudio(void);
FOUNDATION_EXPORT int64_t BXFloatMicAUPaintCount(void);
FOUNDATION_EXPORT int64_t BXFloatMicAUCallbackCount(void);
FOUNDATION_EXPORT int64_t BXFloatMicAQPaintCount(void);
FOUNDATION_EXPORT int64_t BXFloatMicAQCallbackCount(void);
FOUNDATION_EXPORT int64_t BXFloatMicAUCreateCount(void);
FOUNDATION_EXPORT int64_t BXFloatMicAUStartCount(void);

NS_ASSUME_NONNULL_END
