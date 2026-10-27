import AVFoundation
import QuartzCore
import UIKit

/// 当抖音还没走到 sampleBuffer 回调（回调=0）时，用电脑画面盖住预览层，先保证「看得见替换」。
/// 真正进直播推流仍依赖 CameraReplaceHooks；本类是预览兜底。
enum PreviewCover {
    private static var coverView: UIImageView?
    private static var link: CADisplayLink?
    private static var hostWindow: UIWindow?

    static func start(in window: UIWindow?) {
        hostWindow = window
        guard MediaConfigStore.shared.config.replaceCameraEnabled else {
            stop()
            return
        }
        if link == nil {
            let l = CADisplayLink(target: TickTarget.shared, selector: #selector(TickTarget.tick))
            l.add(to: .main, forMode: .common)
            link = l
        }
        TickTarget.shared.onTick = { tick() }
    }

    static func stop() {
        link?.invalidate()
        link = nil
        TickTarget.shared.onTick = nil
        coverView?.removeFromSuperview()
        coverView = nil
    }

    private static func tick() {
        guard MediaConfigStore.shared.config.replaceCameraEnabled else {
            stop()
            return
        }
        guard let window = hostWindow ?? UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else { return }
        guard let pb = CamFrameStore.shared.copyLatest() else { return }

        // 已有 sample 回调时，不必盖预览（避免双画面）
        if CameraReplaceHooks.callbackCount > 30, CameraReplaceHooks.paintCount > 0 {
            coverView?.isHidden = true
            return
        }

        let target = findPreviewHost(in: window) ?? fallbackLargeView(in: window)
        guard let target else { return }

        let cover: UIImageView
        if let existing = coverView, existing.superview === target {
            cover = existing
        } else {
            coverView?.removeFromSuperview()
            let v = UIImageView(frame: target.bounds)
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.contentMode = .scaleAspectFill
            v.clipsToBounds = true
            v.isUserInteractionEnabled = false
            v.tag = 0x42584643 // 'BXFC'
            target.addSubview(v)
            coverView = v
            cover = v
        }
        cover.isHidden = false
        cover.image = UIImage(ciImage: CIImage(cvPixelBuffer: pb))
        target.bringSubviewToFront(cover)
    }

    private static func findPreviewHost(in root: UIView) -> UIView? {
        var found: UIView?
        func walk(_ v: UIView) {
            if let layer = v.layer as? AVCaptureVideoPreviewLayer {
                found = v
                return
            }
            for name in ["preview", "Preview", "camera", "Camera", "capture", "Capture"] {
                if String(describing: type(of: v)).contains(name) {
                    if v.bounds.width * v.bounds.height > 200 * 200 {
                        found = v
                    }
                }
            }
            for s in v.subviews { walk(s) }
        }
        walk(root)
        return found
    }

    private static func fallbackLargeView(in window: UIWindow) -> UIView? {
        // 找接近全屏的深色视图（直播准备页黑底预览）
        var best: UIView?
        var bestArea: CGFloat = 0
        let screenArea = window.bounds.width * window.bounds.height
        func walk(_ v: UIView) {
            let area = v.bounds.width * v.bounds.height
            if area > screenArea * 0.35, area > bestArea {
                let bg = v.backgroundColor
                let dark: Bool = {
                    guard let bg, let c = bg.cgColor.components, c.count >= 3 else {
                        return v.subviews.isEmpty
                    }
                    return (c[0] + c[1] + c[2]) / 3.0 < 0.25
                }()
                if dark || v.layer is AVCaptureVideoPreviewLayer {
                    best = v
                    bestArea = area
                }
            }
            for s in v.subviews where s.tag != 0x42584643 { walk(s) }
        }
        if let root = window.rootViewController?.view {
            walk(root)
        } else {
            walk(window)
        }
        return best
    }
}

private final class TickTarget: NSObject {
    static let shared = TickTarget()
    var onTick: (() -> Void)?
    @objc func tick() { onTick?() }
}
