import AVFoundation
import UIKit

/// 判断当前是否在「加号摄像/拍摄」页，避免主 feed 盖预览层。
/// 结果短时缓存，避免抖音巨大视图树被 0.6s 定时器反复全量遍历。
enum ShootSurfaceDetector {
    private static var trackedSessions = NSHashTable<AVCaptureSession>.weakObjects()
    private static var cachedVisible: Bool?
    private static var cachedAt: CFAbsoluteTime = 0
    private static let cacheTTL: CFAbsoluteTime = 1.0

    static func trackSession(_ session: AVCaptureSession) {
        trackedSessions.add(session)
        invalidateCache()
    }

    static func invalidateCache() {
        cachedVisible = nil
        cachedAt = 0
    }

    /// 有正在跑的采集会话或预览层 → 视为摄像页。
    static func isCameraSurfaceVisible() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = cachedVisible, now - cachedAt < cacheTTL {
            return cached
        }
        // 轻量路径优先：已跟踪且 running 的 session，不必扫整棵视图树
        for s in trackedSessions.allObjects where s.isRunning {
            cachedVisible = true
            cachedAt = now
            return true
        }
        let found = hasPreviewLayer()
        cachedVisible = found
        cachedAt = now
        return found
    }

    static func findPreviewLayerHost(in window: UIWindow?) -> UIView? {
        guard let window else { return nil }
        var found: UIView?
        func walk(_ v: UIView) {
            if found != nil { return }
            if v.layer is AVCaptureVideoPreviewLayer {
                found = v
                return
            }
            for s in v.subviews { walk(s) }
        }
        if let root = window.rootViewController?.view {
            walk(root)
        } else {
            walk(window)
        }
        return found
    }

    private static func hasPreviewLayer() -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for w in scene.windows where !w.isHidden {
                if findPreviewLayerHost(in: w) != nil { return true }
            }
        }
        return false
    }
}
