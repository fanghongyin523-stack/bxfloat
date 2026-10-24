import UIKit

/// 注入入口：白名单宿主（系统 Safari 常不在注入器列表，优先用 BXFloat壳）。
@objc(BXInjectBootstrap)
final class BXInjectBootstrap: NSObject {
    private static var observersReady = false

    private static let allowedBundleIds: Set<String> = [
        "com.baixiang.bxfloat.host", // 巨魔安装的注入试验壳（推荐）
        "com.apple.mobilesafari",
        "com.apple.SafariViewService",
    ]

    private static let demoURL =
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"

    @objc static func startIfNeeded() {
        let bid = Bundle.main.bundleIdentifier ?? ""
        guard allowedBundleIds.contains(bid) else {
            NSLog("BXFloatInject skip host=%@", bid)
            return
        }

        DispatchQueue.main.async {
            activate(reason: "ctor")
            installLifecycleObserversIfNeeded()
        }
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
    }

    private static func activate(reason: String) {
        MediaConfigStore.shared.load()
        var cfg = MediaConfigStore.shared.config
        if cfg.streamURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cfg.streamURL = demoURL
        }
        cfg.overlayEnabled = true
        MediaConfigStore.shared.save(cfg, postNotification: false)

        guard let window = preferredWindow() else {
            NSLog("BXFloatInject waiting window reason=%@", reason)
            return
        }

        NSLog("BXFloatInject attach reason=%@ window=%@", reason, String(describing: type(of: window)))
        FloatingOverlayController.shared.attach(to: window)
        // 触发一次 apply
        NotificationCenter.default.post(name: .bxMediaConfigDidChange, object: nil)
    }

    private static func preferredWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            if let key = scene.windows.first(where: \.isKeyWindow) {
                return key
            }
            if let first = scene.windows.first {
                return first
            }
        }
        for scene in scenes {
            if let key = scene.windows.first(where: \.isKeyWindow) {
                return key
            }
        }
        return scenes.flatMap(\.windows).first
    }
}
