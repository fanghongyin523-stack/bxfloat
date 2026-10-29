import Foundation
import QuartzCore

/// 音画呈现：按实际能攒到的 ring（约 0.6～1.0s）开播。
/// 禁止长时间 wait-video 钉在 pts=0（会整段冻住第一帧）。
/// 源不够时 hold-last；只有明显积压才 drop-old。
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
    private var warmupWallStart: CFTimeInterval = 0

    /// 目标呈现滞后。实测解码 ring 常只有 ~0.8～1.0s，1.7 会永远养不满。
    private let targetDelay: Double = 0.85
    /// 只有 ring 过大才丢旧
    private let maxDelay: Double = 1.8
    /// 低于此 hold；须明显低于 targetDelay，否则一开播就 hold 冻死
    private let minPlayBuffer: Double = 0.35
    /// 暖机需要的直播沿（秒）
    private let warmupNeed: Double = 0.55
    /// 墙钟超时强制开播，避免 wait-video 永久钉第一帧
    private let maxWarmupWall: Double = 0.65
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
        warmupWallStart = 0
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

        // 暖机：凑够一小段缓冲就开播；超时也强制开，避免永久 return 0 冻第一帧
        if !warmedUp {
            if warmupWallStart <= 0 { warmupWallStart = now }
            let waited = now - warmupWallStart
            if live < warmupNeed, waited < maxWarmupWall {
                lastAction = .waitVideo
                lastBufferedMs = live * 1000
                refreshSkewLocked()
                return 0
            }
            warmedUp = true
            hasAnchor = true
            let delay = min(targetDelay, max(0.2, live * 0.7))
            mediaAnchor = max(0, live - delay)
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
            // ring 变薄：hold 上一帧，等源把缓冲养回来
            lastAction = .holdLast
            refreshMetricsLocked(present: mediaAnchor, live: live)
            wallAnchor = now
            mediaAnchor = min(mediaAnchor, max(0, live - minPlayBuffer))
            return mediaAnchor
        }

        if buffered > maxDelay {
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

        mediaAnchor = t
        wallAnchor = now
        lastAction = .play
        refreshMetricsLocked(present: t, live: live)
        return t
    }

    func shouldFreezeAudio() -> Bool {
        lock.lock()
        defer { lock.unlock() }
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
