import Foundation
import QuartzCore

/// 音画呈现：对标 VCamTang AVSYNC 动作表。
/// play / hold-last / freeze-audio(仅恢复期) / drop-old / wait-video。
/// 禁止 soft-rate / 软变速拧时钟——那会把连续 PCM 拧成一帧一帧蹦。
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
    private var lastFreezeLogAt: CFTimeInterval = 0
    private var lastSkewSnapAt: CFTimeInterval = 0
    private var skewSnapPending = false

    /// 目标呈现滞后：USB 直连「几百毫秒」；略收紧到 ~200ms（勿拉回 1.5～2s）。
    private let targetDelay: Double = 0.20
    /// 缓冲过高：更早 drop-old，避免收端把延迟撑到接近 1s。
    private let maxDelay: Double = 0.48
    /// 仅低于此才 hold（真欠载）；对标参照 DBL 0.08
    private let criticalLow: Double = 0.04
    private let warmupNeed: Double = 0.10
    private let maxWarmupWall: Double = 0.20
    /// 积压时每拍多跳一点，尽快贴回目标延迟（仍禁止 soft-rate）
    private let maxDropPerCall: Double = 0.16
    /// 视频墙钟停更：进入恢复期冻音频（对标 audio frozen for video recovery）
    private let videoStallSec: Double = 1.20
    /// 音画媒体轴 |A−V| 超过此值 → 离散 snap（稳态目标 |skew|<300ms）
    private let skewSnapThreshold: Double = 0.50
    /// 两次 skew snap 最小间隔（禁止每帧 snap）
    private let skewSnapCooldown: Double = 0.55

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
        lastSkewSnapAt = 0
        skewSnapPending = false
        lastAction = .play
        lastSkewMs = 0
        lastBufferedMs = 0
        driftResyncCount = 0
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
        let now = CACurrentMediaTime()
        let wasFrozen = frozenForVideo
        let stalledGap = lastVideoWall > 0 && (now - lastVideoWall) > videoStallSec
        lastVideoPTS = pts
        lastVideoWall = now
        // 新视频沿到达：解除恢复期冻音频
        if frozenForVideo { frozenForVideo = false }
        // 稀疏来帧 / 刚解冻：把播头贴到近直播沿，禁止爬 2 秒才切到新画面
        if warmedUp, hasAnchor, (wasFrozen || stalledGap) {
            mediaAnchor = max(0, pts - targetDelay)
            wallAnchor = now
            lastAction = .play
            // 解冻后立刻检查音轴是否已狂奔
            _ = maybeSnapForSkewLocked(now: now, reason: wasFrozen ? "unfreeze" : "stall-gap")
        } else {
            _ = maybeSnapForSkewLocked(now: now, reason: "video-pts")
        }
        lock.unlock()
    }

    /// 上屏用：视频停更/恢复期 → Blitter 应取「最新已解码帧」，勿钉在冻结 mediaTime。
    func isVideoPresentationStalled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if frozenForVideo { return true }
        if lastVideoPTS >= 0, (CACurrentMediaTime() - lastVideoWall) > videoStallSec {
            return true
        }
        return false
    }

    /// 对标 VCamTang RECOVERY「audio frozen」：解码重建 / 大间隔显式进入恢复期。
    func beginVideoRecoveryFreeze(reason: String) {
        lock.lock()
        let now = CACurrentMediaTime()
        let was = frozenForVideo
        frozenForVideo = true
        lastAction = .waitVideo
        if !was || (now - lastFreezeLogAt) > 1.0 {
            lastFreezeLogAt = now
            NSLog("[BXFloat][AVSYNC] audio frozen for video recovery reason=%@", reason)
        }
        lock.unlock()
    }

    func noteAudioEndPTS(_ pts: Double) {
        guard pts.isFinite, pts >= 0 else { return }
        lock.lock()
        lastAudioEndPTS = pts
        lastAudioWall = CACurrentMediaTime()
        // 音沿狂奔时不必等下一视频帧才 snap
        _ = maybeSnapForSkewLocked(now: lastAudioWall, reason: "audio-pts")
        lock.unlock()
    }

    /// 若刚发生过 skew 离散对齐，消费一次标志（供声环 flush/裁超前）。
    func takeSkewSnapFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if skewSnapPending {
            skewSnapPending = false
            return true
        }
        return false
    }

    /// 软接纳窗：与 skew snap 阈值同簇，禁止音轴领先视频到数秒
    private let audioSoftLead: Double = 0.55
    /// 可暂存等待视频追上的最大超前（failclosed/backlog 有界）
    private let audioHoldLead: Double = 1.20

    enum AudioAdmit {
        case accept
        case pending(lead: Double)
        /// 保留枚举兼容调用方；实现上不再挖 PTS 洞，改为 pending
        case rebase(startPTS: Double, lead: Double)
        case reject
    }

    func shouldAcceptAudioEndPTS(_ endPTS: Double) -> Bool {
        if case .accept = admitAudio(endPTS: endPTS, duration: 0) { return true }
        return false
    }

    /// 音频接纳：超窗 pending + backlog 裁旧；禁止 rebase 挖洞（洞→一帧帧）。
    func admitAudio(endPTS: Double, duration: Double) -> AudioAdmit {
        guard endPTS.isFinite, endPTS >= 0 else { return .reject }
        _ = duration
        lock.lock()
        defer { lock.unlock() }
        if lastVideoPTS < 0 { return .accept }
        if lastVideoPTS < 0.50 { return .accept }
        let lead = endPTS - lastVideoPTS
        if lead <= audioSoftLead { return .accept }
        // 超前过多：pending 等视频追上（trimPending 有界）；禁止硬拒挖洞
        _ = audioHoldLead
        return .pending(lead: lead)
    }

    func audioSoftLeadSeconds() -> Double { audioSoftLead }

    func audioLeadSeconds(endPTS: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard lastVideoPTS >= 0, endPTS.isFinite else { return 0 }
        return endPTS - lastVideoPTS
    }

    /// 1x 墙钟推进。禁止 rate≠1 的软变速。
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
            let delay = min(targetDelay, max(0.06, live * 0.55))
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

        // 视频真停 / 已处恢复期：冻音频；播头贴 live，避免上屏钉旧帧。
        if frozenForVideo || (lastVideoPTS >= 0 && (now - lastVideoWall) > videoStallSec) {
            if !frozenForVideo {
                frozenForVideo = true
                if (now - lastFreezeLogAt) > 1.0 {
                    lastFreezeLogAt = now
                    NSLog("[BXFloat][AVSYNC] audio frozen for video recovery")
                }
            }
            lastAction = .waitVideo
            mediaAnchor = max(0, live - criticalLow)
            wallAnchor = now
            refreshMetricsLocked(present: mediaAnchor, live: live)
            return mediaAnchor
        }

        // 音画媒体轴互偏过大：同一次离散贴回 live−target（禁止 soft-rate）
        if maybeSnapForSkewLocked(now: now, reason: "media-tick") {
            let snappedLive = liveEdgeLocked()
            refreshMetricsLocked(present: mediaAnchor, live: snappedLive >= 0 ? snappedLive : live)
            return mediaAnchor
        }

        let wallDelta = max(0, now - wallAnchor)
        // 固定 1x，绝不 soft-rate
        var t = mediaAnchor + wallDelta
        var buffered = live - t
        var action: Action = .play

        if buffered < criticalLow {
            lastAction = .waitVideo
            wallAnchor = now
            mediaAnchor = min(mediaAnchor, max(0, live - criticalLow))
            refreshMetricsLocked(present: mediaAnchor, live: live)
            return mediaAnchor
        }

        // 积压：drop-old 离散跳到目标延迟，禁止 1.06x/1.12x 软加速
        if buffered > maxDelay {
            let ideal = max(0, live - targetDelay)
            let delta = min(maxDropPerCall, max(0, ideal - t))
            if delta > 0.0005 {
                t += delta
                action = .dropOld
                driftResyncCount += 1
            }
            buffered = live - t
        }

        // 软钳：不要冲过直播沿
        let maxT = max(0, live - criticalLow)
        if t > maxT {
            t = maxT
            action = .waitVideo
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
        if frozenForVideo { return true }
        if lastVideoPTS >= 0, (CACurrentMediaTime() - lastVideoWall) > videoStallSec {
            return true
        }
        return false
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
    /// 对标 VCamTang target_ms
    func targetMs() -> Double { targetDelay * 1000.0 }

    /// 面板用：对标参照主表 play / drop-old / wait-video（冻音频另见日志）
    func actionPanelLabel() -> String {
        lock.lock()
        defer { lock.unlock() }
        if frozenForVideo || (lastVideoPTS >= 0 && (CACurrentMediaTime() - lastVideoWall) > videoStallSec) {
            return "wait-video"
        }
        switch lastAction {
        case .play: return "play"
        case .dropOld: return "drop-old"
        case .holdLast, .freezeAudio, .waitVideo, .silence: return "wait-video"
        }
    }

    /// 对标 [VCAM][AVSYNC] skew_ms= target_ms= buffered_ms= action=
    func avsyncPanelLine() -> String {
        String(
            format: "AVSYNC skew=%.0fms target=%.0fms buffered=%.0fms action=%@",
            lastSkewMs, targetDelay * 1000.0, lastBufferedMs, actionPanelLabel()
        )
    }

    func diagSnapshot() -> (epoch: Double, lastVideoPTS: Double, lastAudioEndPTS: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (epoch, lastVideoPTS, lastAudioEndPTS)
    }

    /// |A−V|≥阈值且冷却期满 → 播头贴 live−target；返回是否 snap。
    @discardableResult
    private func maybeSnapForSkewLocked(now: CFTimeInterval, reason: String) -> Bool {
        guard warmedUp, hasAnchor else { return false }
        guard lastVideoPTS >= 0, lastAudioEndPTS >= 0 else { return false }
        let skew = abs(lastAudioEndPTS - lastVideoPTS)
        guard skew >= skewSnapThreshold else { return false }
        guard now - lastSkewSnapAt >= skewSnapCooldown else { return false }
        let live = liveEdgeLocked()
        guard live >= 0 else { return false }
        lastSkewSnapAt = now
        mediaAnchor = max(0, live - targetDelay)
        wallAnchor = now
        lastAction = .dropOld
        driftResyncCount += 1
        skewSnapPending = true
        if (now - lastFreezeLogAt) > 0.45 {
            lastFreezeLogAt = now
            NSLog(
                "[BXFloat][AVSYNC] skew-snap reason=%@ skew=%.0fms live=%.3f target=%.0fms",
                reason, skew * 1000.0, live, targetDelay * 1000.0
            )
        }
        return true
    }

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
        if lastVideoPTS >= 0 {
            if lastAudioEndPTS >= 0, lastAudioEndPTS + 0.6 >= lastVideoPTS {
                return min(lastVideoPTS, lastAudioEndPTS)
            }
            return lastVideoPTS
        }
        return lastAudioEndPTS
    }
}
