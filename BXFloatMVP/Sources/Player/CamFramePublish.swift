import AudioToolbox
import CoreVideo
import Foundation

/// ObjC FFmpeg 桥回调：写入共享帧库，供小窗预览与摄像替换共用。
@_cdecl("BXFloatPublishVideoFrame")
public func BXFloatPublishVideoFrame(_ buffer: CVPixelBuffer) {
    CamFrameStore.shared.publish(buffer)
}

/// ObjC FFmpeg 桥回调：PCM → 麦克风替换环缓。
@_cdecl("BXFloatPublishAudioPCM")
public func BXFloatPublishAudioPCM(
    _ samples: UnsafePointer<Int16>,
    _ frames: Int32,
    _ channels: Int32,
    _ sampleRate: Int32
) {
    guard frames > 0, channels > 0 else { return }
    CamAudioStore.shared.publish(
        samples: samples,
        frames: Int(frames),
        channels: Int(channels),
        sampleRate: Int(sampleRate)
    )
}

/// AudioUnit / AudioQueue 钩子：按目标格式写入推流 PCM 或静音。mode 1=推流 2=静音
@_cdecl("BXFloatMicPaintRaw")
public func BXFloatMicPaintRaw(
    _ dst: UnsafeMutableRawPointer,
    _ byteCount: Int32,
    _ sampleRate: Double,
    _ channels: Int32,
    _ bitsPerChannel: Int32,
    _ isFloat: Int32,
    _ mode: Int32
) {
    let n = Int(byteCount)
    guard n > 0 else { return }
    if mode == 2 {
        CamAudioStore.silence(into: dst, byteCount: n)
        return
    }
    guard mode == 1 else { return }

    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = sampleRate > 0 ? sampleRate : 48000
    asbd.mFormatID = kAudioFormatLinearPCM
    asbd.mFormatFlags = isFloat != 0
        ? (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        : (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
    asbd.mBitsPerChannel = UInt32(max(8, bitsPerChannel))
    asbd.mChannelsPerFrame = UInt32(max(1, channels))
    asbd.mBytesPerFrame = (asbd.mBitsPerChannel / 8) * asbd.mChannelsPerFrame
    asbd.mFramesPerPacket = 1
    asbd.mBytesPerPacket = asbd.mBytesPerFrame

    if CamAudioStore.shared.hasFreshAudio {
        _ = CamAudioStore.shared.fill(into: dst, byteCount: n, asbd: asbd)
    } else {
        // 推流模式但暂无 PCM：静音，避免漏出原麦
        CamAudioStore.silence(into: dst, byteCount: n)
    }
}
