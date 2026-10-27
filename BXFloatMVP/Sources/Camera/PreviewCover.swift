import AVFoundation
import QuartzCore
import UIKit

/// 摄像页开启「替换摄像头」时，用推流画面盖住预览区域。
/// 不碰 AVCapture 样本回调（避免冻帧）；等第一帧再显示。
enum PreviewCover {
    private static var coverView: UIImageView?
    private static var hostView: UIView?
    private static var consumer: CoverConsumer?
    private static var hasFrame = false
    private static var lastHostLog = ""

    static func start(in window: UIWindow?) {
        guard MediaConfigStore.shared.config.replaceCameraEnabled else {
            stop()
            return
        }
        // 摄像页判定失败时仍尝试盖（用户已点开替换，多半在拍摄页）
        guard let target = resolveHost(in: window) else {
            let msg = "no-host"
            if lastHostLog != msg {
                lastHostLog = msg
                NSLog("BXFloatCam PreviewCover host not found")
            }
            return
        }

        let hostDesc = String(describing: type(of: target))
        if coverView == nil || hostView !== target {
            coverView?.removeFromSuperview()
            let v = UIImageView(frame: target.bounds)
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.contentMode = .scaleAspectFill
            v.clipsToBounds = true
            v.isUserInteractionEnabled = false
            v.backgroundColor = .clear
            v.isOpaque = false
            v.isHidden = true
            v.tag = 0x42584643
            // 盖在预览视图内部最前；触摸关闭所以底下按钮仍可点（若盖的是纯预览层）
            target.addSubview(v)
            coverView = v
            hostView = target
            hasFrame = false
            lastHostLog = hostDesc
            NSLog(
                "BXFloatCam PreviewCover attach host=%@ frame=%.0fx%.0f",
                hostDesc,
                target.bounds.width,
                target.bounds.height
            )
        }
        if hasFrame {
            coverView?.isHidden = false
            coverView?.frame = target.bounds
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
        lastHostLog = ""
    }

    static func refreshIfNeeded(in window: UIWindow?) {
        if MediaConfigStore.shared.config.replaceCameraEnabled {
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

    private static func resolveHost(in window: UIWindow?) -> UIView? {
        if let host = ShootSurfaceDetector.findPreviewLayerHost(in: window) {
            return host
        }
        if let host = ShootSurfaceDetector.findLikelyPreviewHost(in: window) {
            return host
        }
        return ShootSurfaceDetector.findLargestContentView(in: window)
    }
}

private final class CoverConsumer: NSObject, CamPreviewConsuming {
    func camPreviewDidUpdate(_ image: CGImage) {
        PreviewCover.applyImage(image)
    }
}
