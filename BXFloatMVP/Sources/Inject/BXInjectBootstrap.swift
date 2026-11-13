import UIKit

/// 注入入口：白名单宿主 + 快手系包名模糊匹配。
@objc(BXInjectBootstrap)
final class BXInjectBootstrap: NSObject {
    private static var observersReady = false

    private static let allowedBundleIds: Set<String> = [
        "com.baixiang.bxfloat.host",
        "com.apple.mobilesafari",
        "com.apple.SafariViewService",
        "com.ss.iphone.ugc.Aweme",
        "com.ss.iphone.ugc.Aweme.lite",
        "com.tencent.xin",
        "com.smile.gifmaker",
        "com.kuaishou.nebula",
        "com.kuaishou.video",
        "com.kwai.gifshow.beta1",
        "com.jiangjia.gif",
        "com.xingin.discover",
        "com.taobao.taobao4iphone",
        "com.taobao.taobao",
    ]

    @objc static func startIfNeeded() {
        let bid = Bundle.main.bundleIdentifier ?? ""
        guard isAllowedHost(bid) else {
            NSLog("BXFloatInject skip host=%@", bid)
            return
        }

        NSLog("BXFloatInject allow host=%@", bid)
        DispatchQueue.main.async {
            CameraReplaceHooks.installIfNeeded()
            MicReplaceHooks.installIfNeeded()
            // 拍摄页类名钩子要在第一次 present/push 之前装上，不能等预览层。
            ShootSurfaceDetector.installEntryHookIfNeeded()
            activate(reason: "ctor")
            installLifecycleObserversIfNeeded()
        }
    }

    private static func isAllowedHost(_ bid: String) -> Bool {
        if allowedBundleIds.contains(bid) { return true }
        let lower = bid.lowercased()
        if lower.contains("kuaishou") || lower.contains("gifmaker") || lower.hasPrefix("com.kwai.") {
            return true
        }
        return false
    }

    private static func installLifecycleObserversIfNeeded() {
        guard !observersReady else { return }
        observersReady = true

        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            activate(reason: "active")
        }
        center.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { _ in
            activate(reason: "scene")
        }
        for second in [2, 4, 7, 10, 15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(second)) {
                activate(reason: "delay-\(second)")
            }
        }
    }

    private static func activate(reason: String) {
        // 只在首次 load。每次 activate 都 load+把默认值 save 回去，会在注入早期 UserDefaults 未就绪时，
        // 把上次保存的「摄像头替换 / 推流声音」覆盖成关。
        MediaConfigStore.shared.loadIfNeeded()
        var cfg = MediaConfigStore.shared.config
        if !cfg.overlayEnabled {
            cfg.overlayEnabled = true
            MediaConfigStore.shared.save(cfg, postNotification: false)
        }

        // 拍摄/开直播入口已经打标（或会话安静 / 视频采集在跑）：不要 attach。
        // attach 会改 windowScene / makeKey，预览还在跑但界面假死。首点时预览层可能还没有。
        // 不扫预览层：延迟 activate 打在窗口风暴上会把主线程拖死。
        let onShoot = ShootSurfaceDetector.isShootPageLatched()
            || CameraReplaceHooks.isSessionQuiet()
            || ShootSurfaceDetector.isCaptureSessionRunning()
        if onShoot {
            FloatingOverlayController.shared.suppressReattachForShoot()
            NSLog("BXFloatInject skip reattach reason=%@ (shoot/quiet)", reason)
            return
        }
        // 替换开着且悬浮窗已在：保持原来的跳过，避免再次 makeKey。
        if FloatingOverlayController.overlayWindow != nil, CameraReplaceHooks.isReplaceActive() {
            NSLog("BXFloatInject skip reattach reason=%@ (quiet/replace/shoot)", reason)
            return
        }

        guard let window = preferredWindow() else {
            NSLog("BXFloatInject waiting window reason=%@", reason)
            return
        }

        NSLog(
            "BXFloatInject attach reason=%@ url=%@ replace=%@",
            reason,
            cfg.resolvedPlaybackURL(),
            cfg.replaceCameraEnabled ? "1" : "0"
        )
        FloatingOverlayController.shared.attach(to: window)
        NotificationCenter.default.post(name: .bxMediaConfigDidChange, object: nil)
    }

    private static func preferredWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var candidates: [UIWindow] = []
        for scene in scenes {
            candidates.append(contentsOf: scene.windows)
        }
        if candidates.isEmpty {
            candidates = UIApplication.shared.windows
        }

        let visible = candidates.filter { !$0.isHidden && $0.alpha > 0.01 && $0.bounds.width > 1 }
        if visible.isEmpty { return nil }

        for scene in scenes where scene.activationState == .foregroundActive {
            if let key = scene.windows.first(where: { $0.isKeyWindow && !$0.isHidden }) {
                return key
            }
        }

        return visible.max { a, b in
            let areaA = a.bounds.width * a.bounds.height
            let areaB = b.bounds.width * b.bounds.height
            if areaA != areaB { return areaA < areaB }
            return a.windowLevel.rawValue < b.windowLevel.rawValue
        }
    }
}

// phase1-cam-single-dylib

