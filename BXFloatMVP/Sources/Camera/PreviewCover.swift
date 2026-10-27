import AVFoundation
import QuartzCore
import UIKit

/// 仅在「摄像页」且开启替换时，盖住预览层，显示推流画面。
/// 绝不用空黑底盖住真机；等第一帧到位再显示。
enum PreviewCover {
    private static var coverView: UIImageView?
    private static var hostView: UIView?
    private static var consumer: CoverConsumer?
    private static var hasFrame = false

    static func start(in window: UIWindow?) {
        guard MediaConfigStore.shared.config.replaceCameraEnabled,
              ShootSurfaceDetector.isCameraSurfaceVisible()
        else {
            stop()
            return
        }

        guard let target = resolveHost(in: window) else {
            // 找不到预览宿主就不盖，避免误盖 feed；样本路径仍可替换
            return
        }

        if coverView == nil || hostView !== target {
            coverView?.removeFromSuperview()
            let v = UIImageView(frame: target.bounds)
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.contentMode = .scaleAspectFill
            v.clipsToBounds = true
            v.isUserInteractionEnabled = false
            v.backgroundColor = .clear
            v.isOpaque = false
            v.isHidden = true // 有帧之前不盖，防止黑屏
            v.tag = 0x42584643
            target.addSubview(v)
            coverView = v
            hostView = target
            hasFrame = false
        }
        if hasFrame {
            coverView?.isHidden = false
            target.bringSubviewToFront(coverView!)
        }

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
        hasFrame = false
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
        guard let cover = coverView else { return }
        cover.image = UIImage(cgImage: image)
        if !hasFrame {
            hasFrame = true
            cover.isHidden = false
            cover.superview?.bringSubviewToFront(cover)
            NSLog("BXFloatCam PreviewCover first frame %dx%d", image.width, image.height)
        }
    }

    /// 优先 AVCaptureVideoPreviewLayer；找不到则找摄像页上最大的近似预览视图。
    private static func resolveHost(in window: UIWindow?) -> UIView? {
        if let host = ShootSurfaceDetector.findPreviewLayerHost(in: window) {
            return host
        }
        return ShootSurfaceDetector.findLikelyPreviewHost(in: window)
    }
}

private final class CoverConsumer: NSObject, CamPreviewConsuming {
    func camPreviewDidUpdate(_ image: CGImage) {
        PreviewCover.applyImage(image)
    }
}
