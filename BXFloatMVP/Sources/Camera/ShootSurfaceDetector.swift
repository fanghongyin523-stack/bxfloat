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

    /// 摄像页判定：有预览层，或「running 的采集会话 + 大面积预览宿主」。
    /// 仅 session.isRunning 不够（易误判），避免主 feed 误开替换。
    static func isCameraSurfaceVisible() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = cachedVisible, now - cachedAt < cacheTTL {
            return cached
        }
        let found = hasPreviewLayer() || hasRunningSessionWithLikelyPreview()
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

    /// 抖音等可能不用 AVCaptureVideoPreviewLayer，退而求面积最大的候选视图。
    static func findLikelyPreviewHost(in window: UIWindow?) -> UIView? {
        guard let window else { return nil }
        let root = window.rootViewController?.view ?? window
        let screenArea = window.bounds.width * window.bounds.height
        guard screenArea > 1 else { return nil }
        var best: UIView?
        var bestArea: CGFloat = 0
        func walk(_ v: UIView) {
            // 跳过我们自己的浮层 / 盖层
            if v.tag == 0x42584643 || v.tag == 0x4258464C { return }
            let area = v.bounds.width * v.bounds.height
            // 接近全屏、且是 Metal / GL / 专用预览类名
            if area > screenArea * 0.35, area > bestArea {
                let name = String(describing: type(of: v))
                let layerName = String(describing: type(of: v.layer))
                let hit =
                    name.localizedCaseInsensitiveContains("preview")
                    || name.localizedCaseInsensitiveContains("camera")
                    || name.localizedCaseInsensitiveContains("capture")
                    || name.localizedCaseInsensitiveContains("metal")
                    || layerName.localizedCaseInsensitiveContains("metal")
                    || layerName.localizedCaseInsensitiveContains("sample")
                    || v.layer is AVCaptureVideoPreviewLayer
                if hit {
                    best = v
                    bestArea = area
                }
            }
            for s in v.subviews { walk(s) }
        }
        walk(root)
        return best
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

    private static func hasRunningSessionWithLikelyPreview() -> Bool {
        let running = trackedSessions.allObjects.contains { $0.isRunning }
        guard running else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for w in scene.windows where !w.isHidden {
                if findLikelyPreviewHost(in: w) != nil { return true }
            }
        }
        return false
    }
}
