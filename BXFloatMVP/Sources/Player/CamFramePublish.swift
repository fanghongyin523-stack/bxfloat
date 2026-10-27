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
