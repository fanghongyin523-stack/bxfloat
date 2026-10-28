import CoreVideo
import Foundation

/// 视频 ring：按 AVSyncClock.mediaTime 取帧；空窗 hold 最后一帧（对标 VCam hold-last）。
final class CamFrameStore {
    static let shared = CamFrameStore()

    private struct TimedFrame {
        var buffer: CVPixelBuffer
        var pts: Double
    }

    private let lock = NSLock()
    private var frames: [TimedFrame] = []
    /// ~3.5s @30fps，覆盖 1.5～2s 目标 + 抖动
    private let maxFrames = 110
    private var lastHeld: CVPixelBuffer?

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
        lastHeld = buffer
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        frameCount += 1
        lastUpdate = Date()
        lastPTS = mapped
        // 丢掉过旧（相对最新超过 3.2s）
        if mapped >= 0 {
            let floorPTS = mapped - 3.2
            while let first = frames.first, first.pts >= 0, first.pts < floorPTS {
                frames.removeFirst()
            }
        }
        lock.unlock()
        if mapped >= 0 {
            AVSyncClock.shared.noteVideoPTS(mapped)
        }
    }

    /// 取 pts ≤ t 的最近帧；没有则 hold 最后一帧。
    func copyForMediaTime(_ t: Double) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return lastHeld }
        if t < 0 || frames.allSatisfy({ $0.pts < 0 }) {
            return frames.last?.buffer ?? lastHeld
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
        // t 早于所有帧：最早一帧；若 t 已超过全部 → hold 最新（不黑闪）
        if let last = frames.last(where: { $0.pts >= 0 }) {
            if t > last.pts { return last.buffer }
        }
        return frames.first(where: { $0.pts >= 0 })?.buffer ?? lastHeld
    }

    func copyLatest() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return frames.last?.buffer ?? lastHeld
    }

    /// ring 内可播时长（相对最新 PTS）
    func bufferedSeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let first = frames.first(where: { $0.pts >= 0 }),
              let last = frames.last(where: { $0.pts >= 0 })
        else { return 0 }
        return max(0, last.pts - first.pts)
    }

    var hasFreshFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (!frames.isEmpty || lastHeld != nil) && Date().timeIntervalSince(lastUpdate) < 4
    }

    func reset() {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        lastHeld = nil
        lastPTS = -1
        frameCount = 0
        lock.unlock()
        AVSyncClock.shared.reset()
    }
}
