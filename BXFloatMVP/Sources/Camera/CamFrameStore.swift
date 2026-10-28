import CoreVideo
import Foundation

/// 带 PTS 的短历史帧：按 AVSyncClock.mediaTime 取最近画面，保证和声音同一时间轴。
final class CamFrameStore {
    static let shared = CamFrameStore()

    private struct TimedFrame {
        var buffer: CVPixelBuffer
        var pts: Double
    }

    private let lock = NSLock()
    private var frames: [TimedFrame] = []
    private let maxFrames = 24 // ~0.8s @30fps
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var frameCount: Int64 = 0
    private(set) var lastUpdate = Date.distantPast
    private(set) var lastPTS: Double = -1

    private init() {}

    func publish(_ buffer: CVPixelBuffer, pts: Double = -1) {
        let p = pts.isFinite ? pts : -1
        lock.lock()
        frames.append(TimedFrame(buffer: buffer, pts: p))
        if frames.count > maxFrames {
            frames.removeFirst(frames.count - maxFrames)
        }
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        frameCount += 1
        lastUpdate = Date()
        lastPTS = p
        lock.unlock()
        if p >= 0 {
            AVSyncClock.shared.noteVideoPTS(p)
        }
    }

    /// 取最接近 mediaTime 的帧（优先 pts <= t）。
    func copyForMediaTime(_ t: Double) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        if t < 0 || frames.allSatisfy({ $0.pts < 0 }) {
            return frames.last?.buffer
        }
        var best = frames[0]
        var bestScore = Double.greatestFiniteMagnitude
        for f in frames {
            guard f.pts >= 0 else { continue }
            let lag = t - f.pts
            let score: Double
            if lag >= 0 {
                score = lag // 已到达的帧，越近越好
            } else {
                score = -lag + 0.05 // 略罚超前
            }
            if score < bestScore {
                bestScore = score
                best = f
            }
        }
        return best.buffer
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
        lock.unlock()
        AVSyncClock.shared.reset()
    }
}
