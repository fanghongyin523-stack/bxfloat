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
        "com.smile.gifmaker", // 快手
        "com.kuaishou.nebula", // 快手极速版
        "com.kuaishou.video", // 偶见变体
        "com.kwai.gifshow.beta1",
        "com.jiangjia.gif", // 旧包名
        "com.xingin.discover",
        "com.taobao.taobao4iphone",
        "com.taobao.taobao",
    ]

    private static let demoURL =
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"

    @objc static func startIfNeeded() {
        let bid = Bundle.main.bundleIdentifier ?? ""
        guard isAllowedHost(bid) else {
            NSLog("BXFloatInject skip host=%@", bid)
            return
        }

        NSLog("BXFloatInject allow host=%@", bid)
        DispatchQueue.main.async {
            activate(reason: "ctor")
            installLifecycleObserversIfNeeded()
        }
    }

    private static func isAllowedHost(_ bid: String) -> Bool {
        if allowedBundleIds.contains(bid) { return true }
        let lower = bid.lowercased()
        // 快手系：包名常变，放宽匹配
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
        // 快手等启动慢：首屏起来后再挂几次
        for second in [2, 4, 7, 10, 15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(second)) {
                activate(reason: "delay-\(second)")
            }
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

        NSLog(
            "BXFloatInject attach reason=%@ window=%@ frame=%@",
            reason,
            String(describing: type(of: window)),
            NSCoder.string(for: window.bounds)
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
        // 兼容旧 API
        if candidates.isEmpty {
            candidates = UIApplication.shared.windows
        }

        let visible = candidates.filter { !$0.isHidden && $0.alpha > 0.01 && $0.bounds.width > 1 }
        if visible.isEmpty { return nil }

        // 优先：前台 scene 的 keyWindow
        for scene in scenes where scene.activationState == .foregroundActive {
            if let key = scene.windows.first(where: { $0.isKeyWindow && !$0.isHidden }) {
                return key
            }
        }

        // 其次：面积最大的普通层级窗口（避开很小的辅助窗）
        return visible.max { a, b in
            let areaA = a.bounds.width * a.bounds.height
            let areaB = b.bounds.width * b.bounds.height
            if areaA != areaB { return areaA < areaB }
            return a.windowLevel.rawValue < b.windowLevel.rawValue
        }
    }
}
