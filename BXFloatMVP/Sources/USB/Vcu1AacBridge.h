#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// VCU1 type=3 AAC path — mirrors FFRTSPBridge AAC→PCM→BXFloatPublishAudioPCM (FFmpeg).
FOUNDATION_EXPORT void Vcu1AacReset(void);
FOUNDATION_EXPORT BOOL Vcu1AacSetConfig(const uint8_t *asc, int len);
FOUNDATION_EXPORT BOOL Vcu1AacFeedADTS(const uint8_t *data, int len, double pts);

NS_ASSUME_NONNULL_END
