import CoreVideo
import Foundation

/// ObjC FFmpeg 桥回调：写入共享帧库，供小窗预览与摄像替换共用。
@_cdecl("BXFloatPublishVideoFrame")
public func BXFloatPublishVideoFrame(_ buffer: CVPixelBuffer) {
    CamFrameStore.shared.publish(buffer)
}
