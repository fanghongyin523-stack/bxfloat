import AVFoundation
import QuartzCore
import UIKit

/// 点击穿透窗：盖层显示推流，触摸落到下面的抖音。
private final class BXCoverPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        if view === self || view === rootViewController?.view { return nil }
        if view?.tag == 0x42584643 { return nil }
        return view
    }
}

/// 「替换摄像头」：独立窗盖在 App 上。只盖中间预览区，上下左右留白露出抖音按钮。
enum PreviewCover {
    private static var coverWindow: BXCoverPassthroughWindow?
    private static var imageView: UIImageView?
    private static var consumer: CoverConsumer?
    private static var hasFrame = false
    private static var loggedAttach = false

    static func start(in window: UIWindow?) {
        guard MediaConfigStore.shared.config.replaceCameraEnabled else {
            stop()
            return
        }

        let scene =
            window?.windowScene
            ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        guard let scene else {
            NSLog("BXFloatCam PreviewCover no scene")
            return
        }

        ensureWindow(scene: scene)
        layoutContentFrame()

        if consumer == nil {
            let c = CoverConsumer()
            consumer = c
            CamPreviewPresenter.shared.addConsumer(c)
        }

        if let cached = CamPreviewPresenter.shared.latestCGImage {
            applyImage(cached)
        }
    }

    static func stop() {
        if let c = consumer {
            CamPreviewPresenter.shared.removeConsumer(c)
            consumer = nil
        }
        coverWindow?.isHidden = true
        imageView?.layer.contents = nil
        hasFrame = false
        loggedAttach = false
    }

    static func refreshIfNeeded(in window: UIWindow?) {
        if MediaConfigStore.shared.config.replaceCameraEnabled {
            start(in: window)
        } else {
            stop()
        }
    }

    /// 中间预览带：避开顶栏 / 底栏按钮 / 右侧工具条。
    private static func previewRect(in bounds: CGRect) -> CGRect {
        let top = max(bounds.height * 0.11, 88)
        let bottom = max(bounds.height * 0.30, 230)
        let right = max(bounds.width * 0.14, 52)
        let left: CGFloat = 0
        let h = max(bounds.height - top - bottom, 120)
        let w = max(bounds.width - left - right, 120)
        return CGRect(x: left, y: top, width: w, height: h)
    }

    private static func layoutContentFrame() {
        guard let w = coverWindow, let iv = imageView else { return }
        w.frame = w.windowScene?.coordinateSpace.bounds ?? w.frame
        iv.frame = previewRect(in: w.bounds)
    }

    private static func ensureWindow(scene: UIWindowScene) {
        if let w = coverWindow, w.windowScene === scene {
            w.frame = scene.coordinateSpace.bounds
            layoutContentFrame()
            if hasFrame { w.isHidden = false }
            return
        }

        coverWindow?.isHidden = true
        coverWindow = nil
        imageView = nil
        hasFrame = false

        let w = BXCoverPassthroughWindow(windowScene: scene)
        w.frame = scene.coordinateSpace.bounds
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 120)
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = true

        let root = UIViewController()
        root.view.backgroundColor = .clear
        let iv = UIImageView(frame: previewRect(in: w.bounds))
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = .clear
        iv.isOpaque = false
        iv.isHidden = true
        iv.tag = 0x42584643
        iv.isUserInteractionEnabled = false
        root.view.addSubview(iv)
        w.rootViewController = root
        w.isHidden = true
        coverWindow = w
        imageView = iv

        if !loggedAttach {
            loggedAttach = true
            let r = iv.frame
            NSLog(
                "BXFloatCam PreviewCover inset frame=(%.0f,%.0f,%.0fx%.0f)",
                r.origin.x, r.origin.y, r.width, r.height
            )
        }
    }

    fileprivate static func applyImage(_ image: CGImage) {
        guard let iv = imageView, let w = coverWindow else { return }
        layoutContentFrame()
        iv.layer.contents = image
        iv.layer.contentsGravity = .resizeAspectFill
        if !hasFrame {
            hasFrame = true
            iv.isHidden = false
            w.isHidden = false
            NSLog("BXFloatCam PreviewCover first frame %dx%d", image.width, image.height)
        } else if w.isHidden {
            w.isHidden = false
            iv.isHidden = false
        }
    }
}

private final class CoverConsumer: NSObject, CamPreviewConsuming {
    func camPreviewDidUpdate(_ image: CGImage) {
        PreviewCover.applyImage(image)
    }
}
