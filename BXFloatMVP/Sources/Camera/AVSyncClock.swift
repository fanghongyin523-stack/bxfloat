import Foundation
import QuartzCore

/// 推流音画共用时钟：墙钟锚定到首包 PTS，消费侧按同一 mediaTime 取画面/声音。
final class AVSyncClock {
    static let shared = AVSyncClock()

    private let lock = NSLock()
    private var hasAnchor = false
    private var wallAnchor: CFTimeInterval = 0
    private var mediaAnchor: Double = 0
    private var lastVideoPTS: Double = -1
    private var lastAudioPTS: Double = -1

    /// 故意落后直播沿一点，吸收抖动（秒）
    private let latency: Double = 0.12
    /// 落后太多则跳到直播沿（秒）
    private let maxLag: Double = 0.45

    private(set) var driftResyncCount: Int64 = 0

    private init() {}

    func reset() {
        lock.lock()
        hasAnchor = false
        wallAnchor = 0
        mediaAnchor = 0
        lastVideoPTS = -1
        lastAudioPTS = -1
        lock.unlock()
    }

    func noteVideoPTS(_ pts: Double) {
        guard pts.isFinite, pts >= 0 else { return }
        lock.lock()
        lastVideoPTS = pts
        anchorIfNeeded(pts)
        lock.unlock()
    }

    func noteAudioPTS(_ pts: Double) {
        guard pts.isFinite, pts >= 0 else { return }
        lock.lock()
        lastAudioPTS = pts
        anchorIfNeeded(pts)
        lock.unlock()
    }

    /// 当前应呈现的媒体时间（秒，流内 PTS）
    func mediaTime() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let live = max(lastVideoPTS, lastAudioPTS)
        guard hasAnchor else {
            return live >= 0 ? max(0, live - latency) : 0
        }
        var t = mediaAnchor + (CACurrentMediaTime() - wallAnchor)
        if live >= 0 {
            let target = live - latency
            if t > target {
                t = target
            }
            if live - t > maxLag {
                t = target
                mediaAnchor = t
                wallAnchor = CACurrentMediaTime()
                driftResyncCount += 1
            }
        }
        return max(0, t)
    }

    /// 音画时间差估算：正=声音 PTS 超前画面
    func estimatedAVDelta() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard lastVideoPTS >= 0, lastAudioPTS >= 0 else { return 0 }
        return lastAudioPTS - lastVideoPTS
    }

    private func anchorIfNeeded(_ pts: Double) {
        if !hasAnchor {
            hasAnchor = true
            mediaAnchor = pts
            wallAnchor = CACurrentMediaTime()
        }
    }
}
