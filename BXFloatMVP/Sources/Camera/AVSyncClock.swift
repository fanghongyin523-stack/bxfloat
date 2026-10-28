import Foundation
import QuartzCore

/// 音画共用呈现时钟。
/// 策略：以「音画都已到达」的较慢一侧为直播沿（min），再统一落后 ~0.5s；
/// 总延迟压在 3 秒内。这样声音不会被画面甩下几十秒。
final class AVSyncClock {
    static let shared = AVSyncClock()

    private let lock = NSLock()
    private var epoch: Double = -1
    private var hasAnchor = false
    private var wallAnchor: CFTimeInterval = 0
    private var mediaAnchor: Double = 0
    private var lastVideoPTS: Double = -1
    /// 音频块结束 PTS（最后一包起点 + 时长）
    private var lastAudioEndPTS: Double = -1

    /// 相对直播沿的目标缓冲（秒）——可共同延迟，换稳定口型
    private let targetDelay: Double = 0.55
    /// 允许的最大落后（秒），留余量不超过用户说的 3 秒
    private let maxDelay: Double = 2.5
    /// 最小落后，避免追到毛刺沿
    private let minDelay: Double = 0.25

    private(set) var driftResyncCount: Int64 = 0

    private init() {}

    func reset() {
        lock.lock()
        epoch = -1
        hasAnchor = false
        wallAnchor = 0
        mediaAnchor = 0
        lastVideoPTS = -1
        lastAudioEndPTS = -1
        lock.unlock()
    }

    /// 把 FFmpeg 原始 PTS 归一到同一起点（首包为 0）
    func mapPTS(_ raw: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard raw.isFinite else { return -1 }
        if epoch < 0 {
            epoch = raw
        }
        return max(0, raw - epoch)
    }

    func noteVideoPTS(_ pts: Double) {
        guard pts.isFinite, pts >= 0 else { return }
        lock.lock()
        lastVideoPTS = pts
        anchorIfNeededLocked()
        lock.unlock()
    }

    func noteAudioEndPTS(_ pts: Double) {
        guard pts.isFinite, pts >= 0 else { return }
        lock.lock()
        lastAudioEndPTS = pts
        anchorIfNeededLocked()
        lock.unlock()
    }

    /// 当前应呈现的媒体时间（音画都用这个）
    func mediaTime() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let live = liveEdgeLocked()
        guard live >= 0 else { return 0 }

        let ideal = max(0, live - targetDelay)
        if !hasAnchor {
            hasAnchor = true
            mediaAnchor = ideal
            wallAnchor = CACurrentMediaTime()
            return ideal
        }

        var t = mediaAnchor + (CACurrentMediaTime() - wallAnchor)
        let minT = max(0, live - maxDelay)
        let maxT = max(0, live - minDelay)

        if t < minT {
            // 落后过多（超过约 2.5s）：跳到目标点，音画一起跟
            t = ideal
            mediaAnchor = t
            wallAnchor = CACurrentMediaTime()
            driftResyncCount += 1
        } else if t > maxT {
            t = maxT
            mediaAnchor = t
            wallAnchor = CACurrentMediaTime()
        }
        return t
    }

    /// 直播沿落后多少秒（端到端延迟估计）
    func latencySeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let live = liveEdgeLocked()
        guard live >= 0, hasAnchor else { return 0 }
        let t = mediaAnchor + (CACurrentMediaTime() - wallAnchor)
        return max(0, live - t)
    }

    /// 原始到达差：正=音频沿超前视频沿
    func estimatedAVDelta() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard lastVideoPTS >= 0, lastAudioEndPTS >= 0 else { return 0 }
        return lastAudioEndPTS - lastVideoPTS
    }

    private func liveEdgeLocked() -> Double {
        if lastVideoPTS >= 0, lastAudioEndPTS >= 0 {
            // 关键：跟较慢的一侧，防止画面单飞、声音落后几十秒
            return min(lastVideoPTS, lastAudioEndPTS)
        }
        return max(lastVideoPTS, lastAudioEndPTS)
    }

    private func anchorIfNeededLocked() {
        if !hasAnchor {
            let live = liveEdgeLocked()
            guard live >= 0 else { return }
            hasAnchor = true
            mediaAnchor = max(0, live - targetDelay)
            wallAnchor = CACurrentMediaTime()
        }
    }
}
