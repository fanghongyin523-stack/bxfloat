import AudioToolbox
import CoreVideo
import Foundation

/// ObjC FFmpeg 桥回调：写入共享帧库（带 PTS）。
@_cdecl("BXFloatPublishVideoFrame")
public func BXFloatPublishVideoFrame(_ buffer: CVPixelBuffer, _ pts: Double) {
    CamFrameStore.shared.publish(buffer, pts: pts)
}

/// ObjC FFmpeg 桥回调：PCM + PTS → 麦克风环缓。
@_cdecl("BXFloatPublishAudioPCM")
public func BXFloatPublishAudioPCM(
    _ samples: UnsafePointer<Int16>,
    _ frames: Int32,
    _ channels: Int32,
    _ sampleRate: Int32,
    _ pts: Double
) {
    guard frames > 0, channels > 0 else { return }
    CamAudioStore.shared.publish(
        samples: samples,
        frames: Int(frames),
        channels: Int(channels),
        sampleRate: Int(sampleRate),
        pts: pts
    )
}

/// AudioUnit：按共用 mediaTime 写入推流 PCM / 静音。
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
    // 交错 PCM（多平面由 hook 拆分）；flags 必须与 bps/float 一致
    asbd.mFormatFlags = floatMode
        ? (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        : (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
    asbd.mBitsPerChannel = UInt32(bps * 8)
    asbd.mChannelsPerFrame = UInt32(ch)
    asbd.mBytesPerFrame = UInt32(bps * ch)
    asbd.mFramesPerPacket = 1
    asbd.mBytesPerPacket = asbd.mBytesPerFrame

    if CamAudioStore.shared.hasFreshAudio {
        _ = CamAudioStore.shared.fillContinuous(into: dst, byteCount: byteCount, asbd: asbd)
    } else {
        // 无新鲜包：静音（非末样垫），避免注入路径自造底噪
        CamAudioStore.silence(into: dst, byteCount: byteCount)
    }
}
