import AVFoundation
import UIKit

/// 判断当前是否在「加号摄像/拍摄」页，避免主 feed 误盖。
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

    static func isCameraSurfaceVisible() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = cachedVisible, now - cachedAt < cacheTTL {
            return cached
        }
        // 有预览层，或采集会话在跑（拍摄页常见）
        let running = trackedSessions.allObjects.contains { $0.isRunning }
        let found = hasPreviewLayer() || running
        cachedVisible = found
        cachedAt = now
        return found
    }

    static func findPreviewLayerHost(in window: UIWindow?) -> UIView? {
        guard let window else { return nil }
        var found: UIView?
        func walk(_ v: UIView) {
            if found != nil { return }
            if v.tag == 0x42584643 || v.tag == 0x4258464C { return }
            if v.layer is AVCaptureVideoPreviewLayer {
                found = v
                return
            }
            for s in v.subviews { walk(s) }
        }
        walk(window.rootViewController?.view ?? window)
        return found
    }

    /// 按类名/图层猜测预览宿主。
    static func findLikelyPreviewHost(in window: UIWindow?) -> UIView? {
        guard let window else { return nil }
        let root = window.rootViewController?.view ?? window
        let screenArea = window.bounds.width * window.bounds.height
        guard screenArea > 1 else { return nil }
        var best: UIView?
        var bestArea: CGFloat = 0
        func walk(_ v: UIView) {
            if v.tag == 0x42584643 || v.tag == 0x4258464C { return }
            if v is UIControl || v is UIButton { return }
            let area = v.bounds.width * v.bounds.height
            if area > screenArea * 0.30, area > bestArea {
                let name = String(describing: type(of: v))
                let layerName = String(describing: type(of: v.layer))
                let hit =
                    name.localizedCaseInsensitiveContains("preview")
                    || name.localizedCaseInsensitiveContains("camera")
                    || name.localizedCaseInsensitiveContains("capture")
                    || name.localizedCaseInsensitiveContains("metal")
                    || name.localizedCaseInsensitiveContains("render")
                    || name.localizedCaseInsensitiveContains("glk")
                    || layerName.localizedCaseInsensitiveContains("metal")
                    || layerName.localizedCaseInsensitiveContains("sample")
                    || layerName.localizedCaseInsensitiveContains("gl")
                    || v.layer is AVCaptureVideoPreviewLayer
                    || v.layer.contents != nil && area > screenArea * 0.45
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

    /// 最后手段：面积最大的非控件视图（拍摄页预览通常接近全屏）。
    static func findLargestContentView(in window: UIWindow?) -> UIView? {
        guard let window else { return nil }
        let root = window.rootViewController?.view ?? window
        let screenArea = window.bounds.width * window.bounds.height
        guard screenArea > 1 else { return nil }
        var best: UIView?
        var bestArea: CGFloat = 0
        func walk(_ v: UIView) {
            if v.tag == 0x42584643 || v.tag == 0x4258464C { return }
            if v is UIControl || v is UILabel || v is UIButton || v is UIImageView { return }
            if v.isHidden || v.alpha < 0.05 { return }
            let area = v.bounds.width * v.bounds.height
            // 要够大，又不要直接用 root（避免把整页控件都盖住；优先中间层）
            if area > screenArea * 0.40, area < screenArea * 0.98, area > bestArea {
                best = v
                bestArea = area
            }
            for s in v.subviews { walk(s) }
        }
        walk(root)
        if let best { return best }
        // 实在没有中间层，就盖 root（触摸关闭，按钮仍可点，但会被画面挡住看起来）
        return root
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
