import AVFoundation
import ObjectiveC
import UIKit

/// 判断当前是否在「加号摄像/拍摄」页，避免主 feed 误盖。
enum ShootSurfaceDetector {
    private static var trackedSessions = NSHashTable<AVCaptureSession>.weakObjects()
    private static var cachedVisible: Bool?
    private static var cachedAt: CFAbsoluteTime = 0
    private static let cacheTTL: CFAbsoluteTime = 1.0

    /// 拍摄/分段拍摄页已进入。预览层还没挂上就为真，用来盖住首点竞态。
    private static var shootPageLatched = false
    private static var entryHookInstalled = false
    /// 离开页的延迟复查代次；再次进入会作废未完成的离开。
    private static var leaveGeneration: UInt64 = 0

    /// 抖音拍摄 / 分段拍摄页类名。预览层出现之前这些类就已经进层级。
    private static let shootClassBlocked = [
        "Publish", "Export", "Edit", "Draft", "Feed", "Live", "Comment",
        "Message", "Chat", "Search", "Profile", "Setting", "Download", "History",
    ]
    private static let shootClassMarkers = [
        "AWERecorder", "ACCRecord", "TTKRecord", "TTKRecorder", "AWERecord",
        "RecorderViewController", "RecordViewController", "VideoRecord",
        "CameraRecord", "CaptureViewController", "StudioRecorder",
        "SegmentRecord", "MultiSegment", "ClipRecord",
    ]

    static func trackSession(_ session: AVCaptureSession) {
        trackedSessions.add(session)
        invalidateCache()
    }

    static func invalidateCache() {
        cachedVisible = nil
        cachedAt = 0
    }

    static func isShootPageLatched() -> Bool { shootPageLatched }

    /// 在 present / push / setRoot / viewWillAppear 当下打标，不等预览层。
    static func markShootPageEntered(reason: String) {
        leaveGeneration &+= 1
        let first = !shootPageLatched
        shootPageLatched = true
        if first {
            // 沿用现有 1.2s 上限，不把安静窗拉回 3.5s。只在进入沿打一次。
            CameraReplaceHooks.markSessionQuiet(seconds: 1.20)
            NSLog("BXFloatCam shoot-page enter %@", reason)
        }
        FloatingOverlayController.shared.suppressReattachForShoot()
    }

    /// 拍摄页 VC 已经不在屏上时放下闩锁。预览若还在，由 isCameraSurfaceVisible 继续挡住重挂。
    static func clearShootPageLatchIfLeft() {
        guard shootPageLatched else { return }
        if appearedShootPageExists() { return }
        leaveGeneration &+= 1
        pollLeave(gen: leaveGeneration, tries: 0)
    }

    private static func pollLeave(gen: UInt64, tries: Int) {
        guard gen == leaveGeneration, shootPageLatched else { return }
        if appearedShootPageExists() { return }
        // 会话还在收尾（安静窗 ≤1.2s，或预览层还没拆）：短等几次，不要在分段拍切换时误放开。
        if tries < 4, CameraReplaceHooks.isSessionQuiet() || isCameraSurfaceVisible() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
                pollLeave(gen: gen, tries: tries + 1)
            }
            return
        }
        guard gen == leaveGeneration, shootPageLatched else { return }
        if appearedShootPageExists() { return }
        shootPageLatched = false
        invalidateCache()
        NSLog("BXFloatCam shoot-page leave")
        FloatingOverlayController.shared.resumeReattachAfterShoot()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            guard gen == leaveGeneration else { return }
            FloatingOverlayController.shared.resumeReattachAfterShoot()
        }
    }

    static func looksLikeShootPageClass(_ name: String) -> Bool {
        if shootClassBlocked.contains(where: { name.contains($0) }) { return false }
        return shootClassMarkers.contains(where: { name.contains($0) })
    }

    /// 只看即将进入的那一层（present/push/root），不扫整棵离屏树。
    static func entryLooksLikeShoot(_ vc: UIViewController) -> Bool {
        func match(_ c: UIViewController) -> Bool {
            looksLikeShootPageClass(NSStringFromClass(type(of: c)))
        }
        if match(vc) { return true }
        if let nav = vc as? UINavigationController {
            if let top = nav.topViewController, match(top) { return true }
            if let first = nav.viewControllers.first, match(first) { return true }
        }
        if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
            if match(selected) { return true }
            if let nav = selected as? UINavigationController, let top = nav.topViewController, match(top) {
                return true
            }
        }
        for child in vc.children {
            if match(child) { return true }
            if let nav = child as? UINavigationController, let top = nav.topViewController, match(top) {
                return true
            }
        }
        return false
    }

    static func installEntryHookIfNeeded() {
        if entryHookInstalled { return }
        entryHookInstalled = true
        swizzleViewWillAppear()
        swizzleViewDidDisappear()
        swizzlePresent()
        swizzlePush()
        swizzleSetRootViewController()
        NSLog("BXFloatCam shoot-entry hook installed")
    }

    private static func swizzleViewWillAppear() {
        let cls: AnyClass = UIViewController.self
        let sel = NSSelectorFromString("viewWillAppear:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, Bool) -> Void = { obj, animated in
            if let vc = obj as? UIViewController {
                let name = NSStringFromClass(type(of: vc))
                if looksLikeShootPageClass(name) {
                    markShootPageEntered(reason: "willAppear:\(name)")
                }
            }
            typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, animated)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleViewDidDisappear() {
        let cls: AnyClass = UIViewController.self
        let sel = NSSelectorFromString("viewDidDisappear:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, Bool) -> Void = { obj, animated in
            let name = (obj as? UIViewController).map { NSStringFromClass(type(of: $0)) } ?? ""
            let shoot = looksLikeShootPageClass(name)
            typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, animated)
            if shoot {
                DispatchQueue.main.async { clearShootPageLatchIfLeft() }
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzlePresent() {
        let cls: AnyClass = UIViewController.self
        let sel = NSSelectorFromString("presentViewController:animated:completion:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, UIViewController, Bool, AnyObject?) -> Void = { obj, presented, animated, completion in
            if entryLooksLikeShoot(presented) {
                markShootPageEntered(reason: "present:\(NSStringFromClass(type(of: presented)))")
            }
            typealias Fn = @convention(c) (AnyObject, Selector, UIViewController, Bool, AnyObject?) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, presented, animated, completion)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzlePush() {
        let cls: AnyClass = UINavigationController.self
        let sel = NSSelectorFromString("pushViewController:animated:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, UIViewController, Bool) -> Void = { obj, pushed, animated in
            if entryLooksLikeShoot(pushed) {
                markShootPageEntered(reason: "push:\(NSStringFromClass(type(of: pushed)))")
            }
            typealias Fn = @convention(c) (AnyObject, Selector, UIViewController, Bool) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, pushed, animated)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleSetRootViewController() {
        let cls: AnyClass = UIWindow.self
        let sel = NSSelectorFromString("setRootViewController:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, UIViewController?) -> Void = { obj, root in
            // 只在已经可见的窗口上换 root 才算进入。离屏预热不打标，避免把保活定时器停死。
            if let root, let window = obj as? UIWindow,
               !window.isHidden, window.alpha > 0.01, !(window is BXFloatPassthroughWindow),
               entryLooksLikeShoot(root)
            {
                markShootPageEntered(reason: "setRoot:\(NSStringFromClass(type(of: root)))")
            }
            typealias Fn = @convention(c) (AnyObject, Selector, UIViewController?) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, root)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func appearedShootPageExists() -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for w in scene.windows where !w.isHidden && w.alpha > 0.01 {
                if w is BXFloatPassthroughWindow { continue }
                if let root = w.rootViewController, appearedShoot(root, depth: 0) { return true }
            }
        }
        return false
    }

    private static func appearedShoot(_ vc: UIViewController, depth: Int) -> Bool {
        if depth > 8 { return false }
        if looksLikeShootPageClass(NSStringFromClass(type(of: vc))),
           vc.isViewLoaded,
           let view = vc.viewIfLoaded,
           view.window != nil,
           !view.isHidden
        {
            return true
        }
        if let presented = vc.presentedViewController, appearedShoot(presented, depth: depth + 1) { return true }
        if let nav = vc as? UINavigationController, let top = nav.topViewController,
           appearedShoot(top, depth: depth + 1) { return true }
        if let tab = vc as? UITabBarController, let selected = tab.selectedViewController,
           appearedShoot(selected, depth: depth + 1) { return true }
        for child in vc.children {
            if appearedShoot(child, depth: depth + 1) { return true }
        }
        return false
    }

    static func isCameraSurfaceVisible() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = cachedVisible, now - cachedAt < cacheTTL {
            return cached
        }
        // 有预览层，或采集会话在跑（拍摄页常见）
        let running = trackedSessions.allObjects.contains { $0.isRunning }
        let found = hasPreviewLayer() || running
        cachedVisible = found
        cachedAt = now
        return found
    }

    static func findPreviewLayerHost(in window: UIWindow?) -> UIView? {
        guard let window else { return nil }
        var found: UIView?
        func walk(_ v: UIView) {
            if found != nil { return }
            if v.tag == 0x42584643 || v.tag == 0x4258464C { return }
            if v.layer is AVCaptureVideoPreviewLayer {
                found = v
                return
            }
            for s in v.subviews { walk(s) }
        }
        walk(window.rootViewController?.view ?? window)
        return found
    }

    /// 按类名/图层猜测预览宿主。
    static func findLikelyPreviewHost(in window: UIWindow?) -> UIView? {
        guard let window else { return nil }
        let root = window.rootViewController?.view ?? window
        let screenArea = window.bounds.width * window.bounds.height
        guard screenArea > 1 else { return nil }
        var best: UIView?
        var bestArea: CGFloat = 0
        func walk(_ v: UIView) {
            if v.tag == 0x42584643 || v.tag == 0x4258464C { return }
            if v is UIControl || v is UIButton { return }
            let area = v.bounds.width * v.bounds.height
            if area > screenArea * 0.30, area > bestArea {
                let name = String(describing: type(of: v))
                let layerName = String(describing: type(of: v.layer))
                let hit =
                    name.localizedCaseInsensitiveContains("preview")
                    || name.localizedCaseInsensitiveContains("camera")
                    || name.localizedCaseInsensitiveContains("capture")
                    || name.localizedCaseInsensitiveContains("metal")
                    || name.localizedCaseInsensitiveContains("render")
                    || name.localizedCaseInsensitiveContains("glk")
                    || layerName.localizedCaseInsensitiveContains("metal")
                    || layerName.localizedCaseInsensitiveContains("sample")
                    || layerName.localizedCaseInsensitiveContains("gl")
                    || v.layer is AVCaptureVideoPreviewLayer
                    || v.layer.contents != nil && area > screenArea * 0.45
                if hit {
                    best = v
                    bestArea = area
                }
            }
            for s in v.subviews { walk(s) }
        }
        walk(root)
        return best
    }

    /// 最后手段：面积最大的非控件视图（拍摄页预览通常接近全屏）。
    static func findLargestContentView(in window: UIWindow?) -> UIView? {
        guard let window else { return nil }
        let root = window.rootViewController?.view ?? window
        let screenArea = window.bounds.width * window.bounds.height
        guard screenArea > 1 else { return nil }
        var best: UIView?
        var bestArea: CGFloat = 0
        func walk(_ v: UIView) {
            if v.tag == 0x42584643 || v.tag == 0x4258464C { return }
            if v is UIControl || v is UILabel || v is UIButton || v is UIImageView { return }
            if v.isHidden || v.alpha < 0.05 { return }
            let area = v.bounds.width * v.bounds.height
            // 要够大，又不要直接用 root（避免把整页控件都盖住；优先中间层）
            if area > screenArea * 0.40, area < screenArea * 0.98, area > bestArea {
                best = v
                bestArea = area
            }
            for s in v.subviews { walk(s) }
        }
        walk(root)
        if let best { return best }
        // 实在没有中间层，就盖 root（触摸关闭，按钮仍可点，但会被画面挡住看起来）
        return root
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
