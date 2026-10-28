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

/// AudioUnit 钩子：按帧数写入推流 PCM / 静音。mode 1=推流 2=静音
/// bytesPerSample: 2=Int16, 4=Float32（iOS 麦几乎都是 Float32）
@_cdecl("BXFloatMicPaintFrames")
public func BXFloatMicPaintFrames(
    _ dst: UnsafeMutableRawPointer,
    _ frames: Int32,
    _ channels: Int32,
    _ sampleRate: Double,
    _ bytesPerSample: Int32,
    _ isFloat: Int32,
    _ mode: Int32
) {
    let f = Int(frames)
    let ch = max(1, Int(channels))
    var bps = Int(bytesPerSample)
    let floatMode = isFloat != 0
    if floatMode, bps < 4 { bps = 4 }
    if !floatMode, bps != 2, bps != 4 { bps = 2 }
    guard f > 0, bps > 0 else { return }

    let byteCount = f * ch * bps
    if mode == 2 {
        CamAudioStore.silence(into: dst, byteCount: byteCount)
        return
    }
    guard mode == 1 else { return }

    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = sampleRate > 0 ? sampleRate : 48000
    asbd.mFormatID = kAudioFormatLinearPCM
    asbd.mFormatFlags = floatMode
        ? (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        : (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
    asbd.mBitsPerChannel = UInt32(bps * 8)
    asbd.mChannelsPerFrame = UInt32(ch)
    asbd.mBytesPerFrame = UInt32(bps * ch)
    asbd.mFramesPerPacket = 1
    asbd.mBytesPerPacket = asbd.mBytesPerFrame

    if CamAudioStore.shared.hasFreshAudio {
        if !CamAudioStore.shared.fill(into: dst, byteCount: byteCount, asbd: asbd) {
            CamAudioStore.silence(into: dst, byteCount: byteCount)
        }
    } else {
        CamAudioStore.silence(into: dst, byteCount: byteCount)
    }
}
