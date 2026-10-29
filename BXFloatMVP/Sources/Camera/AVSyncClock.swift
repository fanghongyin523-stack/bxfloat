import Foundation
import QuartzCore

/// 音画呈现：软变速跟 ring，禁止周期性硬 hold（会两秒一卡）。
/// 仅在真正空窗时 hold；缓冲偏低时放慢时钟而不是冻死画面。
final class AVSyncClock {
    static let shared = AVSyncClock()

    enum Action: String {
        case play
        case slow = "slow"
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

    /// 目标呈现滞后
    private let targetDelay: Double = 1.0
    /// 缓冲过高才加速追
    private let maxDelay: Double = 2.2
    /// 低于此开始放慢（不再硬 hold）
    private let lowWater: Double = 0.45
    /// 仅低于此才硬 hold（真欠载）
    private let criticalLow: Double = 0.06
    /// 高于此略加速消耗积压
    private let highWater: Double = 1.55
    private let warmupNeed: Double = 0.35
    private let maxWarmupWall: Double = 0.45
    private let maxSlewPerCall: Double = 0.04
    private let videoStallSec: Double = 0.35

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

    /// 音频不得甩开视频太远（分队列后曾出现沿差 3s+ → 永久 wait-video）。
    /// 返回 false 时调用方应丢弃该段 PCM，别写入 ring。
    func shouldAcceptAudioEndPTS(_ endPTS: Double) -> Bool {
        guard endPTS.isFinite, endPTS >= 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        if lastVideoPTS < 0 { return true }
        // 允许音频最多超前视频 ~280ms（覆盖一帧抖动）
        return endPTS <= lastVideoPTS + 0.28
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
            let delay = min(targetDelay, max(0.25, live * 0.75))
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

        // 视频真停：冻时钟 + 冻音频（短空窗用 soft 即可，阈值略放宽）
        if lastVideoPTS >= 0, (now - lastVideoWall) > videoStallSec {
            frozenForVideo = true
            lastAction = .freezeAudio
            wallAnchor = now
            refreshMetricsLocked(present: mediaAnchor, live: live)
            return mediaAnchor
        }

        let wallDelta = max(0, now - wallAnchor)
        var rate = 1.0
        var action: Action = .play

        // 先按 1x 估缓冲，决定变速
        var tentative = mediaAnchor + wallDelta
        var buffered = live - tentative

        if buffered < criticalLow {
            // 真欠载：钉住，等源。音频侧应同步冻播放头，避免电流声
            lastAction = .holdLast
            wallAnchor = now
            mediaAnchor = min(mediaAnchor, max(0, live - criticalLow))
            refreshMetricsLocked(present: mediaAnchor, live: live)
            return mediaAnchor
        }

        if buffered < lowWater {
            // 放慢：0.55～0.9，缓冲越薄越慢，平滑过渡，不两秒一卡
            let span = max(0.001, lowWater - criticalLow)
            let x = min(1.0, max(0.0, (buffered - criticalLow) / span))
            rate = 0.55 + 0.35 * x
            action = .slow
        } else if buffered > maxDelay {
            rate = 1.12
            action = .dropOld
            driftResyncCount += 1
        } else if buffered > highWater {
            rate = 1.06
            action = .play
        } else {
            // 朝目标缓冲微调
            let err = buffered - targetDelay
            if err < -0.12 {
                rate = 0.92
                action = .slow
            } else if err > 0.25 {
                rate = 1.04
            }
        }

        var t = mediaAnchor + wallDelta * rate
        // 软钳：不要冲过直播沿
        let maxT = max(0, live - criticalLow)
        if t > maxT {
            t = maxT
            if action == .play { action = .slow }
        }
        // 积压过大时允许小幅快进（有限）
        if buffered > maxDelay {
            let ideal = max(0, live - targetDelay)
            let delta = min(maxSlewPerCall, max(0, ideal - t))
            t += delta
            action = .dropOld
        }

        mediaAnchor = t
        wallAnchor = now
        lastAction = action
        refreshMetricsLocked(present: t, live: live)
        return t
    }

    func shouldFreezeAudio() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // 画面硬 hold / 视频空窗：音频也冻，避免播放头空转再拽回产生电流声
        return frozenForVideo
            || lastAction == .freezeAudio
            || lastAction == .holdLast
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
        // 呈现以视频为主：音频超前已在 shouldAccept 拦住；
        // 音频落后过多时不拖死直播沿（否则又会 wait-video）。
        if lastVideoPTS >= 0 {
            if lastAudioEndPTS >= 0, lastAudioEndPTS + 0.6 >= lastVideoPTS {
                return min(lastVideoPTS, lastAudioEndPTS)
            }
            return lastVideoPTS
        }
        return lastAudioEndPTS
    }
}
