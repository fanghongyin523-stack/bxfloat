import Foundation

/// 替换策略：融合真实摄像头 + 定时露真（对标目标面板功能；自实现，不依赖参照二进制）。
/// - 融合：推流占比 blendOBSPercent，其余为真摄像头
/// - 定时露真：每隔 interval 全屏真镜头 showSec 秒，期间音频切现场麦
enum CamReplacePolicy {
    private static let lock = NSLock()
    private static var cycleAnchor: CFAbsoluteTime = 0
    private static var revealingUntil: CFAbsoluteTime = 0

    /// 当前是否应透传真摄像头（不写推流帧）
    static func shouldPassThroughRealCamera(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        let cfg = MediaConfigStore.shared.config
        guard cfg.replaceCameraEnabled else { return true }
        guard cfg.timedRealCamera else { return false }
        lock.lock()
        defer { lock.unlock() }
        if cycleAnchor <= 0 { cycleAnchor = now }
        let interval = max(60, Double(cfg.timedRealIntervalSec))
        let show = max(1, Double(cfg.timedRealShowSec))
        if now < revealingUntil { return true }
        let elapsed = now - cycleAnchor
        if elapsed >= interval {
            cycleAnchor = now
            revealingUntil = now + show
            NSLog("BXFloatCam timed-real reveal start show=%.0fs", show)
            return true
        }
        return false
    }

    /// 定时露真进行中：内录音频应切现场（对标目标面板橙字提示）
    static func shouldForceLiveMic(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        shouldPassThroughRealCamera(now: now)
            && MediaConfigStore.shared.config.timedRealCamera
            && MediaConfigStore.shared.config.replaceCameraEnabled
    }

    /// OBS/推流画面融合占比 0...1；未开融合则 1
    static func obsBlendFraction() -> CGFloat {
        let cfg = MediaConfigStore.shared.config
        guard cfg.replaceCameraEnabled, cfg.blendRealCamera else { return 1 }
        return CGFloat(max(0, min(100, cfg.blendOBSPercent))) / 100.0
    }

    static func resetCycle() {
        lock.lock()
        cycleAnchor = 0
        revealingUntil = 0
        lock.unlock()
    }
}
