#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 抖音直播麦走 AudioUnit / AudioQueue，不走 AVCaptureAudioDataOutput。
/// 在 AudioUnitRender 拉麦后原地改写 PCM（推流 / 静音）。
FOUNDATION_EXPORT void BXFloatMicAUInstall(void);
FOUNDATION_EXPORT void BXFloatMicAUSetMode(int mode); // 0=原麦 1=推流 2=静音
FOUNDATION_EXPORT int64_t BXFloatMicAUPaintCount(void);
FOUNDATION_EXPORT int64_t BXFloatMicAUCallbackCount(void);

NS_ASSUME_NONNULL_END
