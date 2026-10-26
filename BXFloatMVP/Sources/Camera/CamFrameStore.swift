import CoreVideo
import Foundation

/// 最新一帧画面：RTSP 解码写入，摄像头 Hook / 小窗预览读取。
final class CamFrameStore {
    static let shared = CamFrameStore()

    private let lock = NSLock()
    private var pixelBuffer: CVPixelBuffer?
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var frameCount: Int64 = 0
    private(set) var lastUpdate = Date.distantPast

    private init() {}

    func publish(_ buffer: CVPixelBuffer) {
        lock.lock()
        pixelBuffer = buffer
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        frameCount += 1
        lastUpdate = Date()
        lock.unlock()
    }

    func copyLatest() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return pixelBuffer
    }

    var hasFreshFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pixelBuffer != nil && Date().timeIntervalSince(lastUpdate) < 3
    }
}
