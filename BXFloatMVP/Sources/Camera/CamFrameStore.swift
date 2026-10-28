import CoreVideo
import Foundation

/// 带 PTS 的短历史（约 3 秒），按 AVSyncClock.mediaTime 取帧。
final class CamFrameStore {
    static let shared = CamFrameStore()

    private struct TimedFrame {
        var buffer: CVPixelBuffer
        var pts: Double
    }

    private let lock = NSLock()
    private var frames: [TimedFrame] = []
    /// ~3s @30fps
    private let maxFrames = 90
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var frameCount: Int64 = 0
    private(set) var lastUpdate = Date.distantPast
    private(set) var lastPTS: Double = -1

    private init() {}

    func publish(_ buffer: CVPixelBuffer, pts: Double = -1) {
        let mapped = pts >= 0 ? AVSyncClock.shared.mapPTS(pts) : -1
        lock.lock()
        frames.append(TimedFrame(buffer: buffer, pts: mapped))
        if frames.count > maxFrames {
            frames.removeFirst(frames.count - maxFrames)
        }
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        frameCount += 1
        lastUpdate = Date()
        lastPTS = mapped
        lock.unlock()
        if mapped >= 0 {
            AVSyncClock.shared.noteVideoPTS(mapped)
        }
    }

    /// 取 pts ≤ t 的最近帧；没有则取最早一帧（仍是推流，绝不回退真机）。
    func copyForMediaTime(_ t: Double) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        if t < 0 || frames.allSatisfy({ $0.pts < 0 }) {
            return frames.last?.buffer
        }
        var best: TimedFrame?
        var bestLag = Double.greatestFiniteMagnitude
        for f in frames where f.pts >= 0 {
            let lag = t - f.pts
            if lag >= 0, lag < bestLag {
                bestLag = lag
                best = f
            }
        }
        if let best { return best.buffer }
        // t 还早于所有帧：用最早一帧
        return frames.first(where: { $0.pts >= 0 })?.buffer ?? frames.first?.buffer
    }

    func copyLatest() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return frames.last?.buffer
    }

    var hasFreshFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !frames.isEmpty && Date().timeIntervalSince(lastUpdate) < 3
    }

    func reset() {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        lastPTS = -1
        frameCount = 0
        lock.unlock()
        AVSyncClock.shared.reset()
    }
}
