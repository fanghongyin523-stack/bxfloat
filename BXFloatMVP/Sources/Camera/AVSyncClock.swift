import Foundation
import QuartzCore

/// 音画共用呈现引擎（对标 VCamTang AVSYNC 动作表）。
/// 目标缓冲 1.5～2.0s，总延迟封顶约 2.6s。
final class AVSyncClock {
    static let shared = AVSyncClock()

    enum Action: String {
        case play
        case holdLast = "hold-last"
        case freezeAudio = "freeze-audio"
        case dropOld = "drop-old"
        case waitVideo = "wait-video"
        case silence = "silence"
    }

    private let lock = NSLock()
    private var epoch: Double = -1
    private var hasAnchor = false
    private var wallAnchor: CFTimeInterval = 0
    private var mediaAnchor: Double = 0
    private var lastVideoPTS: Double = -1
    private var lastAudioEndPTS: Double = -1
    private var lastVideoWall: CFTimeInterval = 0
    private var lastAudioWall: CFTimeInterval = 0
    private var frozenForVideo = false

    /// 目标延迟（秒）— 用户选定 1.5～2s 居中
    private let targetDelay: Double = 1.7
    private let maxDelay: Double = 2.6
    private let minDelay: Double = 1.35
    private let maxSlewPerCall: Double = 0.03
    /// 视频超过该时间无新帧 → hold / freeze-audio
    private let videoStallSec: Double = 0.18

    private(set) var driftResyncCount: Int64 = 0
    private(set) var lastAction: Action = .play
    private(set) var lastSkewMs: Double = 0
    private(set) var lastBufferedMs: Double = 0

    private init() {}

    func reset() {
        lock.lock()
        epoch = -1
        hasAnchor = false
        wallAnchor = 0
        mediaAnchor = 0
        lastVideoPTS = -1
        lastAudioEndPTS = -1
        lastVideoWall = 0
        lastAudioWall = 0
        frozenForVideo = false
        lastAction = .play
        lastSkewMs = 0
        lastBufferedMs = 0
        lock.unlock()
    }

    func mapPTS(_ raw: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard raw.isFinite else { return -1 }
        if epoch < 0 { epoch = raw }
        return max(0, raw - epoch)
    }

    func noteVideoPTS(_ pts: Double) {
        guard pts.isFinite, pts >= 0 else { return }
        lock.lock()
        lastVideoPTS = pts
        lastVideoWall = CACurrentMediaTime()
        if frozenForVideo { frozenForVideo = false }
        anchorIfNeededLocked()
        lock.unlock()
    }

    func noteAudioEndPTS(_ pts: Double) {
        guard pts.isFinite, pts >= 0 else { return }
        lock.lock()
        lastAudioEndPTS = pts
        lastAudioWall = CACurrentMediaTime()
        anchorIfNeededLocked()
        lock.unlock()
    }

    /// 当前应呈现的媒体时间；副作用：更新 action / skew / buffered。
    func mediaTime() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let live = liveEdgeLocked()
        guard live >= 0 else {
            lastAction = .waitVideo
            return 0
        }

        let ideal = max(0, live - targetDelay)
        if !hasAnchor {
            hasAnchor = true
            mediaAnchor = ideal
            wallAnchor = now
            lastAction = .play
            return ideal
        }

        let videoStalled = lastVideoPTS >= 0 && (now - lastVideoWall) > videoStallSec
        if videoStalled {
            // 对标 VCam：视频空窗 hold 画面，冻住呈现时钟与音频消费
            frozenForVideo = true
            lastAction = .freezeAudio
            let t = mediaAnchor + max(0, (lastVideoWall > 0 ? lastVideoWall : wallAnchor) - wallAnchor)
            refreshMetricsLocked(present: t, live: live, now: now)
            return max(0, mediaAnchor) // 不往前走
        }

        var t = mediaAnchor + (now - wallAnchor)
        let minT = max(0, live - maxDelay)
        let maxT = max(0, live - minDelay)

        if t < minT {
            let want = min(ideal, minT + 0.1)
            t += min(maxSlewPerCall, max(0, want - t))
            mediaAnchor = t
            wallAnchor = now
            driftResyncCount += 1
            lastAction = .dropOld
        } else if t > maxT {
            // 缓冲过大：丢掉过旧呈现点，靠向目标
            let want = max(ideal, maxT - 0.05)
            t -= min(maxSlewPerCall * 1.5, max(0, t - want))
            mediaAnchor = t
            wallAnchor = now
            lastAction = .dropOld
        } else {
            let buffered = live - t
            if buffered < minDelay - 0.15 {
                lastAction = .waitVideo
            } else {
                lastAction = .play
            }
        }

        refreshMetricsLocked(present: t, live: live, now: now)
        return t
    }

    /// 音频是否应冻结（视频恢复中）
    func shouldFreezeAudio() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return frozenForVideo || lastAction == .freezeAudio || lastAction == .waitVideo
    }

    func latencySeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let live = liveEdgeLocked()
        guard live >= 0, hasAnchor else { return 0 }
        let t = mediaAnchor + (CACurrentMediaTime() - wallAnchor)
        return max(0, live - t)
    }

    func estimatedAVDelta() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard lastVideoPTS >= 0, lastAudioEndPTS >= 0 else { return 0 }
        return lastAudioEndPTS - lastVideoPTS
    }

    func actionName() -> String { lastAction.rawValue }

    func skewMs() -> Double { lastSkewMs }

    func bufferedMs() -> Double { lastBufferedMs }

    // MARK: - private

    private func refreshMetricsLocked(present: Double, live: Double, now: CFTimeInterval) {
        if lastVideoPTS >= 0, lastAudioEndPTS >= 0 {
            lastSkewMs = (lastAudioEndPTS - lastVideoPTS) * 1000.0
        } else {
            lastSkewMs = 0
        }
        lastBufferedMs = max(0, (live - present) * 1000.0)
        _ = now
    }

    private func liveEdgeLocked() -> Double {
        if lastVideoPTS >= 0, lastAudioEndPTS >= 0 {
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
