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

/// 从 ring 拉交错 s16（mediaTime优先，空则 latest）。返回峰（0..32767）。
/// ObjC 负责按 AU 真实 bps/float/平面写入 ioData，避免「fill 有声但平面拷贝后为 0」。
@_cdecl("BXFloatMicPullS16")
public func BXFloatMicPullS16(
    _ dst: UnsafeMutablePointer<Int16>,
    _ frames: Int32,
    _ channels: Int32,
    _ sampleRate: Double
) -> Int32 {
    let f = Int(frames)
    let ch = max(1, min(8, Int(channels)))
    guard f > 0 else { return 0 }
    return CamAudioStore.shared.pullInterleavedS16(
        into: dst,
        frames: f,
        channels: ch,
        sampleRate: sampleRate > 0 ? Int(sampleRate.rounded()) : 0
    )
}

/// AudioUnit：按共用 mediaTime 写入推流 PCM / 静音（旧路径保留）。
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

    let rate = sampleRate > 0 ? sampleRate : 48000
    CamAudioStore.shared.lockTargetFromAU(
        sampleRate: Int(rate.rounded()),
        channels: ch,
        isFloat: floatMode
    )

    // 新路径：先拉 s16 再按格式写，避免 ASBD 与平面几何不一致把能量抹掉
    let tmpCount = f * ch
    var tmp = [Int16](repeating: 0, count: tmpCount)
    let peak = tmp.withUnsafeMutableBufferPointer { buf -> Int32 in
        guard let base = buf.baseAddress else { return 0 }
        return CamAudioStore.shared.pullInterleavedS16(
            into: base,
            frames: f,
            channels: ch,
            sampleRate: Int(rate.rounded())
        )
    }
    if peak <= 0 {
        CamAudioStore.silence(into: dst, byteCount: byteCount)
        return
    }
    // 写入 dst（交错）；多平面由 ObjC 新路径拆分，此旧路径给单缓冲兜底
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = rate
    asbd.mFormatID = kAudioFormatLinearPCM
    asbd.mFormatFlags = floatMode
        ? (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        : (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
    asbd.mBitsPerChannel = UInt32(bps * 8)
    asbd.mChannelsPerFrame = UInt32(ch)
    asbd.mBytesPerFrame = UInt32(bps * ch)
    asbd.mFramesPerPacket = 1
    asbd.mBytesPerPacket = asbd.mBytesPerFrame
    _ = CamAudioStore.shared.fillFromInterleavedS16(
        tmp,
        into: dst,
        frames: f,
        channels: ch,
        asbd: asbd
    )
}

/// 供 ObjC / 诊断查询当前环缓目标采样率（AU 锁定后）
@_cdecl("BXFloatAudioTargetRate")
public func BXFloatAudioTargetRate() -> Int32 {
    Int32(CamAudioStore.shared.storeRate)
}

@_cdecl("BXFloatAudioTargetChannels")
public func BXFloatAudioTargetChannels() -> Int32 {
    Int32(CamAudioStore.shared.storeChannels)
}
