import AVFoundation
import QuartzCore
import UIKit

/// 仅在「摄像页」且开启替换时，盖住 AVCaptureVideoPreviewLayer。
/// 绝不在主 feed 用大面积黑底兜底（那会盖掉同城/关注里的视频）。
enum PreviewCover {
    private static var coverView: UIImageView?
    private static var hostView: UIView?
    private static var consumer: CoverConsumer?

    static func start(in window: UIWindow?) {
        guard MediaConfigStore.shared.config.replaceCameraEnabled,
              ShootSurfaceDetector.isCameraSurfaceVisible()
        else {
            stop()
            return
        }
        // 只挂预览层宿主；找不到就不盖（避免 feed 误盖）
        guard let target = ShootSurfaceDetector.findPreviewLayerHost(in: window) else {
            stop()
            return
        }
        // 已有 sample 绘制成功时不必盖
        if CameraReplaceHooks.callbackCount > 30, CameraReplaceHooks.paintCount > 0 {
            coverView?.isHidden = true
            return
        }

        if coverView == nil || hostView !== target {
            coverView?.removeFromSuperview()
            let v = UIImageView(frame: target.bounds)
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.contentMode = .scaleAspectFill
            v.clipsToBounds = true
            v.isUserInteractionEnabled = false
            v.tag = 0x42584643
            target.addSubview(v)
            coverView = v
            hostView = target
        }
        coverView?.isHidden = false
        target.bringSubviewToFront(coverView!)

        if consumer == nil {
            let c = CoverConsumer()
            consumer = c
            CamPreviewPresenter.shared.addConsumer(c)
        }
    }

    static func stop() {
        if let c = consumer {
            CamPreviewPresenter.shared.removeConsumer(c)
            consumer = nil
        }
        coverView?.removeFromSuperview()
        coverView = nil
        hostView = nil
    }

    static func refreshIfNeeded(in window: UIWindow?) {
        if MediaConfigStore.shared.config.replaceCameraEnabled,
           ShootSurfaceDetector.isCameraSurfaceVisible()
        {
            start(in: window)
        } else {
            stop()
        }
    }

    fileprivate static func applyImage(_ image: CGImage) {
        coverView?.image = UIImage(cgImage: image)
    }
}

private final class CoverConsumer: NSObject, CamPreviewConsuming {
    func camPreviewDidUpdate(_ image: CGImage) {
        PreviewCover.applyImage(image)
    }
}
