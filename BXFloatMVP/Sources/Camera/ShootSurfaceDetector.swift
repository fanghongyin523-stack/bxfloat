import AVFoundation
import UIKit

/// 判断当前是否在「加号摄像/拍摄」页，避免主 feed 盖预览层。
enum ShootSurfaceDetector {
    private static var trackedSessions = NSHashTable<AVCaptureSession>.weakObjects()

    static func trackSession(_ session: AVCaptureSession) {
        trackedSessions.add(session)
    }

    /// 有预览层或正在跑的采集会话 → 视为摄像页。
    static func isCameraSurfaceVisible() -> Bool {
        if hasPreviewLayer() { return true }
        for s in trackedSessions.allObjects where s.isRunning {
            return true
        }
        return false
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
