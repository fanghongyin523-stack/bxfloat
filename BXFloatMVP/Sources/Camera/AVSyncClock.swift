import Foundation
import QuartzCore

/// 音画呈现：先把 ring 养到约 1.5～2s，再 play。
/// 源不够时 hold-last，禁止靠猛 drop-old 追赶（会把卡顿放大）。
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
    private var warmedUp = false
    private var wallAnchor: CFTimeInterval = 0
    private var mediaAnchor: Double = 0
    private var lastVideoPTS: Double = -1
    private var lastAudioEndPTS: Double = -1
    private var lastVideoWall: CFTimeInterval = 0
    private var lastAudioWall: CFTimeInterval = 0
    private var frozenForVideo = false

    /// 目标缓冲（用户选 1.5～2s）
    private let targetDelay: Double = 1.7
    /// 只有 ring 过大才丢旧
    private let maxDelay: Double = 2.8
    /// 低于此就 hold，不再往直播沿贴
    private let minPlayBuffer: Double = 1.1
    private let maxSlewPerCall: Double = 0.025
    private let videoStallSec: Double = 0.25

    private(set) var driftResyncCount: Int64 = 0
    private(set) var lastAction: Action = .play
    private(set) var lastSkewMs: Double = 0
    private(set) var lastBufferedMs: Double = 0

    private init() {}

    func reset() {
        lock.lock()
        epoch = -1
        hasAnchor = false
        warmedUp = false
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
        lock.unlock()
    }

    func noteAudioEndPTS(_ pts: Double) {
        guard pts.isFinite, pts >= 0 else { return }
        lock.lock()
        lastAudioEndPTS = pts
        lastAudioWall = CACurrentMediaTime()
        lock.unlock()
    }

    func mediaTime() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let live = liveEdgeLocked()
        guard live >= 0 else {
            lastAction = .waitVideo
            lastBufferedMs = 0
            return max(0, mediaAnchor)
        }

        // 暖机：直播沿还没攒够目标缓冲 → hold，不开追
        if !warmedUp {
            if live < targetDelay * 0.85 {
                lastAction = .waitVideo
                lastBufferedMs = live * 1000
                refreshSkewLocked()
                return 0
            }
            warmedUp = true
            hasAnchor = true
            mediaAnchor = max(0, live - targetDelay)
            wallAnchor = now
            lastAction = .play
            refreshMetricsLocked(present: mediaAnchor, live: live)
            return mediaAnchor
        }

        if !hasAnchor {
            hasAnchor = true
            mediaAnchor = max(0, live - targetDelay)
            wallAnchor = now
        }

        // 视频空窗：冻时钟 + 冻音频
        if lastVideoPTS >= 0, (now - lastVideoWall) > videoStallSec {
            frozenForVideo = true
            lastAction = .freezeAudio
            refreshMetricsLocked(present: mediaAnchor, live: live)
            return mediaAnchor
        }

        var t = mediaAnchor + (now - wallAnchor)
        let buffered = live - t

        if buffered < minPlayBuffer {
            // ring 变薄：hold 上一帧，等源把缓冲养回来（绝不 drop-old 硬追）
            lastAction = .holdLast
            refreshMetricsLocked(present: mediaAnchor, live: live)
            // 轻微把 wall 对齐，避免恢复时一次性猛冲
            wallAnchor = now
            mediaAnchor = min(mediaAnchor, max(0, live - minPlayBuffer))
            return mediaAnchor
        }

        if buffered > maxDelay {
            // 只有明显积压才丢掉过旧呈现点
            let ideal = max(0, live - targetDelay)
            let delta = min(maxSlewPerCall, max(0, ideal - t))
            t += delta
            mediaAnchor = t
            wallAnchor = now
            driftResyncCount += 1
            lastAction = .dropOld
            refreshMetricsLocked(present: t, live: live)
            return t
        }

        // 正常播放：时钟跟墙钟走
        mediaAnchor = t
        wallAnchor = now
        lastAction = .play
        refreshMetricsLocked(present: t, live: live)
        return t
    }

    func shouldFreezeAudio() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // 仅视频真停时冻声；hold-last 时仍按播放头出声，避免无故静音
        return frozenForVideo || lastAction == .freezeAudio
    }

    func latencySeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let live = liveEdgeLocked()
        guard live >= 0, hasAnchor else { return 0 }
        return max(0, live - mediaAnchor)
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

    private func refreshSkewLocked() {
        if lastVideoPTS >= 0, lastAudioEndPTS >= 0 {
            lastSkewMs = (lastAudioEndPTS - lastVideoPTS) * 1000.0
        } else {
            lastSkewMs = 0
        }
    }

    private func refreshMetricsLocked(present: Double, live: Double) {
        refreshSkewLocked()
        lastBufferedMs = max(0, (live - present) * 1000.0)
    }

    private func liveEdgeLocked() -> Double {
        if lastVideoPTS >= 0, lastAudioEndPTS >= 0 {
            return min(lastVideoPTS, lastAudioEndPTS)
        }
        return max(lastVideoPTS, lastAudioEndPTS)
    }
}
