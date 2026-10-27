import AVFoundation
import QuartzCore
import UIKit

/// 点击穿透窗：盖层全屏显示推流，触摸落到下面的抖音。
private final class BXCoverPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        if view === self || view === rootViewController?.view { return nil }
        // 盖层本身也不吃触摸
        if view?.tag == 0x42584643 { return nil }
        return view
    }
}

/// 「替换摄像头」视觉实现：独立 UIWindow 盖在宿主 App 之上、小窗之下。
/// 不再依赖在抖音视图树里找预览层（经常找不到 → 看起来像没替换）。
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

        if consumer == nil {
            let c = CoverConsumer()
            consumer = c
            CamPreviewPresenter.shared.addConsumer(c)
        }

        // 已有缓存帧立刻亮起来
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
        imageView?.image = nil
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

    private static func ensureWindow(scene: UIWindowScene) {
        if let w = coverWindow, w.windowScene === scene {
            w.frame = scene.coordinateSpace.bounds
            imageView?.frame = w.bounds
            if hasFrame { w.isHidden = false }
            return
        }

        coverWindow?.isHidden = true
        coverWindow = nil
        imageView = nil
        hasFrame = false

        let w = BXCoverPassthroughWindow(windowScene: scene)
        w.frame = scene.coordinateSpace.bounds
        // 低于小窗(statusBar+200)，高于普通 App 窗
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 120)
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = true // hitTest 会穿透

        let root = UIViewController()
        root.view.backgroundColor = .clear
        let iv = UIImageView(frame: w.bounds)
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
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
            NSLog(
                "BXFloatCam PreviewCover window ready level=%.0f size=%.0fx%.0f",
                w.windowLevel.rawValue,
                w.bounds.width,
                w.bounds.height
            )
        }
    }

    fileprivate static func applyImage(_ image: CGImage) {
        guard let iv = imageView, let w = coverWindow else { return }
        // 用 layer.contents 少一层 UIImage 开销
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
