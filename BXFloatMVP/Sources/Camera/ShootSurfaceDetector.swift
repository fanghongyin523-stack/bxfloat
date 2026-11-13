import AVFoundation
import ObjectiveC
import UIKit

/// 判断当前是否在「拍摄 / 分段拍 / 分屏拍 / 开直播」采集页，避免主 feed 误盖。
/// 拍摄和开直播是两条入口：开直播类名带 Live，不能跟拍摄标记混在同一条屏蔽里。
/// 预渲染另计：拍摄/分屏拍 30Hz，开直播和推流替换保持 50Hz。这条不影响安静窗和重挂。
enum ShootSurfaceDetector {
    private static var trackedSessions = NSHashTable<AVCaptureSession>.weakObjects()
    /// startRunning 过的会话。主线程只读 isRunning，不碰 inputs。
    private static var cameraSessions = NSHashTable<AVCaptureSession>.weakObjects()
    private static var cachedVisible: Bool?
    private static var cachedAt: CFAbsoluteTime = 0
    private static let cacheTTL: CFAbsoluteTime = 1.0

    /// 拍摄/分段拍摄/开直播页已进入。预览层还没挂上就为真，用来盖住首点竞态。
    private static var shootPageLatched = false
    /// startRunning 之后保持，盖住类名没命中时的会话切换（停了又开）。离开采集才放下。
    private static var hardwareLatched = false
    private static var hardwareLeaveGeneration: UInt64 = 0
    private static var entryHookInstalled = false
    /// 离开页的延迟复查代次；再次进入会作废未完成的离开。
    private static var leaveGeneration: UInt64 = 0
    /// 拍摄/分屏拍正在屏上。开直播和推流替换不置这位。只给预渲染降频，不碰安静窗/重挂。
    private static var nativeShootLatched = false
    private static var nativeLeaveGeneration: UInt64 = 0
    private static let nativeLock = NSLock()

    /// 纯发布 / 编辑 / 信息流。类名里同时带 Camera/Capture/Recorder 的容器仍算采集页。
    private static let shootClassBlocked = [
        "Publish", "Export", "Edit", "Draft", "Feed", "Live", "Comment",
        "Message", "Chat", "Search", "Profile", "Setting", "Download", "History",
    ]
    /// 抖音拍摄 / 分段拍摄。`*CameraViewController` 以前没命中（只有 CameraRecord / CaptureViewController）。
    private static let shootClassMarkers = [
        "AWERecorder", "ACCRecord", "TTKRecord", "TTKRecorder", "AWERecord",
        "RecorderViewController", "RecordViewController", "VideoRecord",
        "CameraRecord", "CaptureViewController", "StudioRecorder",
        "SegmentRecord", "MultiSegment", "ClipRecord",
        "AWECameraView", "AWECaptureView", "ACCCamera", "TTKCamera", "CKCamera", "CKRecord", "CKCapture",
        "CameraViewController", "CameraContainer", "VideoCamera",
        "ACCCapture", "StudioCamera", "StudioCapture",
        "VideoCapture", "CaptureContainer", "RecordContainer",
        "ShootViewController", "ShootingViewController",
        "StoryCamera", "StoryRecord",
        "NowCamera", "NowRecord",
        "IESMMRecoder", "IESMMCamera",
        "CreationCamera", "CreationRecord", "CreationRecorder",
        "DuetRecord", "DuetCamera",
        "AWEStudioViewController", "StudioCreation",
    ]
    /// 分屏拍。和拍摄同一个录像页时不必另判；独立分屏控制器经常不带 AWERecorder。
    /// 不用裸的 Split / Layout / Dual：UISplitViewController 和信息流分栏会误伤。
    /// 类名里带 Live / Anchor 的不算分屏，避免把开直播降频。
    private static let splitClassMarkers = [
        "SplitScreen", "SplitShoot", "SplitRecord", "SplitCapture", "SplitCamera",
        "ScreenSplit", "StudioSplit", "RecordSplit", "CameraSplit", "CaptureSplit",
        "LayoutRecord", "LayoutShoot", "SplitLayout",
        "DualCamera", "DualRecord", "DualShoot",
        "MultiCamRecord", "MultiCameraRecord", "MultiCamShoot",
        "SideBySideRecord", "SideBySideShoot", "SideBySideCamera",
        "CollageRecord", "CollageShoot",
        "FenPing", "Fenping",
    ]
    /// 开直播 / 主播预览。不要用裸的 "Live" 或 "Anchor"（信息流观众间、锚点页会误伤）。
    private static let liveEntryMarkers = [
        "IESLiveGuide", "IESLiveAnchor", "IESLiveOpenLive", "IESLiveStartLive",
        "IESLiveMTGuide", "IESLiveMTAnchor", "IESLiveMTOpen",
        "HTSLiveAnchor", "HTSLiveGuide", "HTSLiveOpenLive",
        "LiveAnchor", "LiveGuide", "LiveNewGuide", "AnchorGuide", "AnchorPreview", "AnchorCamera",
        "OpenLive", "StartLive", "GoLive", "CreateLive", "LivePrepare", "PrepareLive",
        "LiveBroadcast", "StartBroadcast",
        "AWELiveEntrance", "AWELiveStart", "AWEStartLive", "AWELivePreview",
        "AWELiveCamera", "AWELiveRecord", "AWELiveGuide", "AWEOpenLive",
        "WebcastAnchor", "WebcastGuide",
        "GBLAnchor", "GBLGoLive", "GBLGuide",
        "LiveHostViewController",
    ]
    /// 看直播 / 直播信息流，不是开播。
    private static let liveEntryBlocked = [
        "Audience", "LiveFeed", "FeedLive", "LivePlayer", "WatchLive",
        "LiveSlide", "SlideRoom", "LiveRoomSlide", "Playback",
    ]
    private static let captureWindowMarkers = [
        "AWECameraWindow", "AWERecordWindow", "AWECaptureWindow", "AWEStudioWindow",
        "IESLiveAnchorWindow", "HTSLiveAnchorWindow", "LiveGuideWindow", "OpenLiveWindow",
        "GBLAnchorWindow",
    ]

    static func trackSession(_ session: AVCaptureSession) {
        trackedSessions.add(session)
        invalidateCache()
    }

    static func invalidateCache() {
        cachedVisible = nil
        cachedAt = 0
    }

    /// 类名闩锁或采集会话闩锁。两者任一为真，悬浮窗都不要迁、不要抢焦点。
    static func isShootPageLatched() -> Bool { shootPageLatched || hardwareLatched }

    /// 拍摄 / 分段拍 / 分屏拍。开直播和推流替换为假，预渲染保持 50Hz。
    /// blit 队列只读这个布尔，不扫视图树。
    static func isNativeShootCapture() -> Bool {
        nativeLock.lock()
        defer { nativeLock.unlock() }
        return nativeShootLatched
    }

    /// 有采集会话已经 startRunning。不扫视图树，也不在主线程读 inputs。
    static func isCaptureSessionRunning() -> Bool {
        cameraSessions.allObjects.contains { $0.isRunning }
    }

    /// startRunning 打标。不读 inputs/outputs：那会跟会话队列抢锁。
    /// 调用线程可能不是主线程。音频会话也会短暂闩上，stop 后复查放开。
    static func noteHardwareCaptureBegan(session: AVCaptureSession) {
        let apply = {
            cameraSessions.add(session)
            hardwareLeaveGeneration &+= 1
            let first = !hardwareLatched
            hardwareLatched = true
            if first {
                NSLog("BXFloatCam capture-session latch")
            }
            FloatingOverlayController.shared.suppressReattachForShoot()
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// stopRunning 后不立刻放开：分段拍会马上再 start。连续几次仍没有视频会话才放下。
    /// 必须等本次 stopRunning 返回后再看 isRunning，否则会看见「还在跑」然后永远不复查。
    static func noteHardwareCaptureEnded() {
        DispatchQueue.main.async {
            guard hardwareLatched else { return }
            hardwareLeaveGeneration &+= 1
            pollHardwareLeave(gen: hardwareLeaveGeneration, tries: 0)
        }
    }

    private static func pollHardwareLeave(gen: UInt64, tries: Int) {
        guard gen == hardwareLeaveGeneration, hardwareLatched else { return }
        if isCaptureSessionRunning() { return }
        if tries < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
                pollHardwareLeave(gen: gen, tries: tries + 1)
            }
            return
        }
        guard gen == hardwareLeaveGeneration, hardwareLatched else { return }
        if isCaptureSessionRunning() { return }
        hardwareLatched = false
        invalidateCache()
        NSLog("BXFloatCam capture-session unlatch")
        if !shootPageLatched {
            FloatingOverlayController.shared.resumeReattachAfterShoot()
        }
    }

    /// 在 present / push / setRoot / viewWillAppear 当下打标，不等预览层。
    static func markShootPageEntered(reason: String) {
        leaveGeneration &+= 1
        let first = !shootPageLatched
        shootPageLatched = true
        if first {
            // 沿用现有 1.2s 上限，不把安静窗拉回 3.5s。只在进入沿打一次。
            CameraReplaceHooks.markSessionQuiet(seconds: 1.20)
            NSLog("BXFloatCam capture-page enter %@", reason)
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
        NSLog("BXFloatCam capture-page leave")
        FloatingOverlayController.shared.resumeReattachAfterShoot()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            guard gen == leaveGeneration else { return }
            FloatingOverlayController.shared.resumeReattachAfterShoot()
        }
    }

    /// 采集页进入时顺带区分拍摄/分屏和开直播。不调用 markSessionQuiet，不改重挂。
    static func noteBlitSurface(_ vc: UIViewController) {
        if isInsideLiveEntry(vc) {
            clearNativeShootIfNoLongerVisible()
            return
        }
        if entryLooksLikeNativeShoot(vc) {
            markNativeShootEntered()
            return
        }
        if entryLooksLikeLive(vc) {
            clearNativeShootIfNoLongerVisible()
        }
    }

    private static func markNativeShootEntered() {
        nativeLock.lock()
        nativeLeaveGeneration &+= 1
        let first = !nativeShootLatched
        nativeShootLatched = true
        nativeLock.unlock()
        if first {
            NSLog("BXFloatCam native-shoot prerender 30Hz")
        }
    }

    private static func clearNativeShootIfLeft() {
        nativeLock.lock()
        let latched = nativeShootLatched
        nativeLock.unlock()
        guard latched else { return }
        if appearedNativeShootExists() { return }
        nativeLock.lock()
        nativeLeaveGeneration &+= 1
        let gen = nativeLeaveGeneration
        nativeLock.unlock()
        pollNativeLeave(gen: gen, tries: 0)
    }

    /// 已经能确定不是拍摄页（例如进入开直播）时立刻回到 50Hz，不等安静窗。
    private static func clearNativeShootIfNoLongerVisible() {
        nativeLock.lock()
        let latched = nativeShootLatched
        nativeLock.unlock()
        guard latched else { return }
        if appearedNativeShootExists() { return }
        nativeLock.lock()
        let was = nativeShootLatched
        if was {
            nativeShootLatched = false
            nativeLeaveGeneration &+= 1
        }
        nativeLock.unlock()
        if was {
            NSLog("BXFloatCam native-shoot prerender 50Hz")
        }
    }

    private static func pollNativeLeave(gen: UInt64, tries: Int) {
        nativeLock.lock()
        let still = gen == nativeLeaveGeneration && nativeShootLatched
        nativeLock.unlock()
        guard still else { return }
        if appearedNativeShootExists() { return }
        // 和采集页离开同一套短等：分段拍/分屏切换时会话还在，不要把 30Hz 提前放开。
        if tries < 4, CameraReplaceHooks.isSessionQuiet() || isCameraSurfaceVisible() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
                pollNativeLeave(gen: gen, tries: tries + 1)
            }
            return
        }
        nativeLock.lock()
        guard gen == nativeLeaveGeneration, nativeShootLatched else {
            nativeLock.unlock()
            return
        }
        nativeLock.unlock()
        if appearedNativeShootExists() { return }
        nativeLock.lock()
        guard gen == nativeLeaveGeneration, nativeShootLatched else {
            nativeLock.unlock()
            return
        }
        nativeShootLatched = false
        nativeLock.unlock()
        NSLog("BXFloatCam native-shoot prerender 50Hz")
    }

    /// 父链上有开直播页。拍摄页是 present 出来的，不把 presenting 当成「在直播里」。
    private static func isInsideLiveEntry(_ vc: UIViewController) -> Bool {
        if vcLooksLikeLiveEntry(vc) { return true }
        var current = vc.parent
        var depth = 0
        while let node = current, depth < 8 {
            if vcLooksLikeLiveEntry(node) { return true }
            current = node.parent
            depth += 1
        }
        return false
    }

    private static func appearedNativeShootExists() -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for w in scene.windows where !w.isHidden && w.alpha > 0.01 {
                if w is BXFloatPassthroughWindow { continue }
                if let root = w.rootViewController, appearedNativeShoot(root, depth: 0) { return true }
            }
        }
        return false
    }

    private static func appearedNativeShoot(_ vc: UIViewController, depth: Int) -> Bool {
        if depth > 8 { return false }
        // 先看盖在上面的页面。开直播节点不再扫子相机，但上面如果又 present 了拍摄，仍然算拍摄。
        if let presented = vc.presentedViewController, appearedNativeShoot(presented, depth: depth + 1) {
            return true
        }
        if vcLooksLikeLiveEntry(vc) { return false }
        if vcLooksLikeNativeShoot(vc),
           vc.isViewLoaded,
           let view = vc.viewIfLoaded,
           view.window != nil,
           !view.isHidden
        {
            return true
        }
        if let nav = vc as? UINavigationController, let top = nav.topViewController,
           appearedNativeShoot(top, depth: depth + 1)
        {
            return true
        }
        if let tab = vc as? UITabBarController, let selected = tab.selectedViewController,
           appearedNativeShoot(selected, depth: depth + 1)
        {
            return true
        }
        for child in vc.children {
            if appearedNativeShoot(child, depth: depth + 1) { return true }
        }
        return false
    }

    static func looksLikeShootPageClass(_ name: String) -> Bool {
        if looksLikeLiveEntryClass(name) { return true }
        if !matchesCaptureMarker(name) { return false }
        // 屏蔽词优先，但「发布/编辑容器套了相机」仍算采集页。
        // 纯 AWERecordEdit 没有 Camera/Capture/Recorder，继续排除。
        if shootClassBlocked.contains(where: { name.contains($0) }) {
            let cameraToken = name.contains("Camera") || name.contains("Capture") || name.contains("Recorder")
            if !cameraToken { return false }
        }
        return true
    }

    /// 拍摄/分屏拍类名。开直播（Live / Anchor / 直播入口）一律不算，避免把推流替换降到 30Hz。
    static func looksLikeNativeShootClass(_ name: String) -> Bool {
        if looksLikeLiveEntryClass(name) { return false }
        if name.contains("Live") || name.contains("Anchor") || name.contains("Webcast")
            || name.contains("Broadcast")
        {
            return false
        }
        if !matchesCaptureMarker(name) { return false }
        if shootClassBlocked.contains(where: { name.contains($0) }) {
            let cameraToken = name.contains("Camera") || name.contains("Capture") || name.contains("Recorder")
            if !cameraToken { return false }
        }
        return true
    }

    private static func matchesCaptureMarker(_ name: String) -> Bool {
        if shootClassMarkers.contains(where: { name.contains($0) }) { return true }
        // 分屏标记不套到开直播类名上。拍摄标记仍按原逻辑，Live+Camera 的旧判定不变。
        if name.contains("Live") || name.contains("Anchor") || name.contains("Webcast")
            || name.contains("Broadcast")
        {
            return false
        }
        return splitClassMarkers.contains(where: { name.contains($0) })
    }

    static func looksLikeLiveEntryClass(_ name: String) -> Bool {
        if liveEntryBlocked.contains(where: { name.contains($0) }) { return false }
        return liveEntryMarkers.contains(where: { name.contains($0) })
    }

    /// 叶子类名没命中时再看父类（抖音子类经常不带 AWERecorder 这几个字）。
    static func vcLooksLikeCapture(_ vc: UIViewController) -> Bool {
        var cls: AnyClass? = type(of: vc)
        var depth = 0
        while let current = cls, depth < 6, current != UIViewController.self, current != UINavigationController.self {
            if looksLikeShootPageClass(NSStringFromClass(current)) { return true }
            cls = class_getSuperclass(current)
            depth += 1
        }
        return false
    }

    static func vcLooksLikeNativeShoot(_ vc: UIViewController) -> Bool {
        var cls: AnyClass? = type(of: vc)
        var depth = 0
        while let current = cls, depth < 6, current != UIViewController.self, current != UINavigationController.self {
            let name = NSStringFromClass(current)
            if looksLikeLiveEntryClass(name) { return false }
            if looksLikeNativeShootClass(name) { return true }
            cls = class_getSuperclass(current)
            depth += 1
        }
        return false
    }

    static func vcLooksLikeLiveEntry(_ vc: UIViewController) -> Bool {
        var cls: AnyClass? = type(of: vc)
        var depth = 0
        while let current = cls, depth < 6, current != UIViewController.self, current != UINavigationController.self {
            if looksLikeLiveEntryClass(NSStringFromClass(current)) { return true }
            cls = class_getSuperclass(current)
            depth += 1
        }
        return false
    }

    static func windowLooksLikeCapture(_ window: UIWindow) -> Bool {
        if window is BXFloatPassthroughWindow { return false }
        let name = NSStringFromClass(type(of: window))
        if captureWindowMarkers.contains(where: { name.contains($0) }) { return true }
        if let root = window.rootViewController, entryLooksLikeShoot(root) { return true }
        return false
    }

    /// 只看即将进入的那一层（present/push/root）及其父类，不扫整棵离屏树。
    static func entryLooksLikeShoot(_ vc: UIViewController) -> Bool {
        entryLooksLikeShoot(vc, depth: 0)
    }

    private static func entryLooksLikeShoot(_ vc: UIViewController, depth: Int) -> Bool {
        if depth > 6 { return false }
        if vcLooksLikeCapture(vc) { return true }
        if let nav = vc as? UINavigationController {
            if let top = nav.topViewController, entryLooksLikeShoot(top, depth: depth + 1) { return true }
            if let visible = nav.visibleViewController, visible !== nav.topViewController,
               entryLooksLikeShoot(visible, depth: depth + 1) { return true }
            for child in nav.viewControllers where entryLooksLikeShoot(child, depth: depth + 1) {
                return true
            }
        }
        if let tab = vc as? UITabBarController {
            if let selected = tab.selectedViewController, entryLooksLikeShoot(selected, depth: depth + 1) {
                return true
            }
            for child in tab.viewControllers ?? [] where entryLooksLikeShoot(child, depth: depth + 1) {
                return true
            }
        }
        for child in vc.children where entryLooksLikeShoot(child, depth: depth + 1) {
            return true
        }
        if let presented = vc.presentedViewController, entryLooksLikeShoot(presented, depth: depth + 1) {
            return true
        }
        return false
    }

    /// 即将进入的那一层是不是拍摄/分屏。开直播节点不再往下看子相机，避免把主播预览降频。
    private static func entryLooksLikeNativeShoot(_ vc: UIViewController) -> Bool {
        entryLooksLikeNativeShoot(vc, depth: 0)
    }

    private static func entryLooksLikeNativeShoot(_ vc: UIViewController, depth: Int) -> Bool {
        if depth > 6 { return false }
        if vcLooksLikeLiveEntry(vc) { return false }
        if vcLooksLikeNativeShoot(vc) { return true }
        if let nav = vc as? UINavigationController {
            if let top = nav.topViewController, entryLooksLikeNativeShoot(top, depth: depth + 1) { return true }
            if let visible = nav.visibleViewController, visible !== nav.topViewController,
               entryLooksLikeNativeShoot(visible, depth: depth + 1) { return true }
            return false
        }
        if let tab = vc as? UITabBarController {
            if let selected = tab.selectedViewController {
                return entryLooksLikeNativeShoot(selected, depth: depth + 1)
            }
            return false
        }
        for child in vc.children where entryLooksLikeNativeShoot(child, depth: depth + 1) {
            return true
        }
        if let presented = vc.presentedViewController, entryLooksLikeNativeShoot(presented, depth: depth + 1) {
            return true
        }
        return false
    }

    private static func entryLooksLikeLive(_ vc: UIViewController) -> Bool {
        entryLooksLikeLive(vc, depth: 0)
    }

    private static func entryLooksLikeLive(_ vc: UIViewController, depth: Int) -> Bool {
        if depth > 6 { return false }
        if vcLooksLikeLiveEntry(vc) { return true }
        if let nav = vc as? UINavigationController {
            if let top = nav.topViewController, entryLooksLikeLive(top, depth: depth + 1) { return true }
            if let visible = nav.visibleViewController, visible !== nav.topViewController,
               entryLooksLikeLive(visible, depth: depth + 1) { return true }
            for child in nav.viewControllers where entryLooksLikeLive(child, depth: depth + 1) {
                return true
            }
        }
        if let tab = vc as? UITabBarController {
            if let selected = tab.selectedViewController, entryLooksLikeLive(selected, depth: depth + 1) {
                return true
            }
        }
        for child in vc.children where entryLooksLikeLive(child, depth: depth + 1) {
            return true
        }
        if let presented = vc.presentedViewController, entryLooksLikeLive(presented, depth: depth + 1) {
            return true
        }
        return false
    }

    static func installEntryHookIfNeeded() {
        if entryHookInstalled { return }
        entryHookInstalled = true
        swizzleViewDidLoad()
        swizzleViewWillAppear()
        swizzleViewDidDisappear()
        swizzlePresent()
        swizzlePush()
        swizzleShow()
        swizzleAddChild()
        swizzleSetViewControllers()
        swizzleTabSelection()
        swizzleSetRootViewController()
        NSLog("BXFloatCam capture-entry hook installed")
    }

    /// 正在 present / push / 转场。离屏预热不算。
    private static func hostIsEntering(_ vc: UIViewController) -> Bool {
        if vc.isBeingPresented || vc.isMovingToParent { return true }
        if vc.transitionCoordinator != nil { return true }
        return false
    }

    /// 已经在屏上，或正在进入。
    private static func hostIsVisible(_ vc: UIViewController) -> Bool {
        if hostIsEntering(vc) { return true }
        if vc.isViewLoaded, let view = vc.viewIfLoaded, view.window != nil, !view.isHidden, view.alpha > 0.01 {
            return true
        }
        return false
    }

    /// viewDidLoad 只有在这次真的要上台时才打标，避免预热把保活定时器停死。
    private static func shouldMarkLoad(_ vc: UIViewController) -> Bool {
        if hostIsEntering(vc) { return true }
        var parent = vc.parent
        var depth = 0
        while let current = parent, depth < 4 {
            if hostIsEntering(current) { return true }
            parent = current.parent
            depth += 1
        }
        return false
    }

    private static func swizzleViewDidLoad() {
        let cls: AnyClass = UIViewController.self
        let sel = NSSelectorFromString("viewDidLoad")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Void = { obj in
            if let vc = obj as? UIViewController, vcLooksLikeCapture(vc), shouldMarkLoad(vc) {
                markShootPageEntered(reason: "load:\(NSStringFromClass(type(of: vc)))")
                noteBlitSurface(vc)
            }
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleViewWillAppear() {
        let cls: AnyClass = UIViewController.self
        let sel = NSSelectorFromString("viewWillAppear:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, Bool) -> Void = { obj, animated in
            if let vc = obj as? UIViewController, vcLooksLikeCapture(vc) {
                markShootPageEntered(reason: "willAppear:\(NSStringFromClass(type(of: vc)))")
                noteBlitSurface(vc)
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
            let shoot = (obj as? UIViewController).map { vcLooksLikeCapture($0) } ?? false
            let native = (obj as? UIViewController).map { vcLooksLikeNativeShoot($0) } ?? false
            typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, animated)
            if shoot {
                DispatchQueue.main.async { clearShootPageLatchIfLeft() }
            }
            if native {
                DispatchQueue.main.async { clearNativeShootIfLeft() }
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
                noteBlitSurface(presented)
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
                noteBlitSurface(pushed)
            }
            typealias Fn = @convention(c) (AnyObject, Selector, UIViewController, Bool) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, pushed, animated)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleShow() {
        let cls: AnyClass = UIViewController.self
        let sel = NSSelectorFromString("showViewController:sender:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, UIViewController, AnyObject?) -> Void = { obj, shown, sender in
            if entryLooksLikeShoot(shown) {
                markShootPageEntered(reason: "show:\(NSStringFromClass(type(of: shown)))")
                noteBlitSurface(shown)
            }
            typealias Fn = @convention(c) (AnyObject, Selector, UIViewController, AnyObject?) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, shown, sender)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// 拍摄容器在 viewDidLoad 里 addChild 相机/开播页。打标必须在子控制器 loadView 之前。
    private static func swizzleAddChild() {
        let cls: AnyClass = UIViewController.self
        let sel = NSSelectorFromString("addChildViewController:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, UIViewController) -> Void = { obj, child in
            // 只在父控制器正在进入时打标。已经在信息流上的父控制器预加载子页不打标。
            if let parent = obj as? UIViewController, hostIsEntering(parent), entryLooksLikeShoot(child) {
                markShootPageEntered(reason: "addChild:\(NSStringFromClass(type(of: child)))")
                noteBlitSurface(child)
            }
            typealias Fn = @convention(c) (AnyObject, Selector, UIViewController) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, child)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleSetViewControllers() {
        let cls: AnyClass = UINavigationController.self
        let sel = NSSelectorFromString("setViewControllers:animated:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, NSArray, Bool) -> Void = { obj, controllers, animated in
            if let nav = obj as? UINavigationController, hostIsVisible(nav) {
                var marked = false
                for item in controllers {
                    if let vc = item as? UIViewController, entryLooksLikeShoot(vc) {
                        markShootPageEntered(reason: "setViewControllers")
                        marked = true
                        break
                    }
                }
                // 只看当前可见的那一层。栈里离屏的拍摄页不能把推流替换降到 30Hz。
                if marked || entryLooksLikeLive(nav) {
                    noteBlitSurface(nav)
                }
            }
            typealias Fn = @convention(c) (AnyObject, Selector, NSArray, Bool) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, controllers, animated)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleTabSelection() {
        swizzleSetSelectedViewController()
        swizzleSetSelectedIndex()
    }

    private static func swizzleSetSelectedViewController() {
        let cls: AnyClass = UITabBarController.self
        let sel = NSSelectorFromString("setSelectedViewController:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, UIViewController?) -> Void = { obj, selected in
            if let tab = obj as? UITabBarController, hostIsVisible(tab),
               let selected, entryLooksLikeShoot(selected)
            {
                markShootPageEntered(reason: "tab:\(NSStringFromClass(type(of: selected)))")
                noteBlitSurface(selected)
            }
            typealias Fn = @convention(c) (AnyObject, Selector, UIViewController?) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, selected)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleSetSelectedIndex() {
        let cls: AnyClass = UITabBarController.self
        let sel = NSSelectorFromString("setSelectedIndex:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, UInt) -> Void = { obj, index in
            let idx = Int(index)
            if let tab = obj as? UITabBarController, hostIsVisible(tab),
               let controllers = tab.viewControllers, controllers.indices.contains(idx),
               entryLooksLikeShoot(controllers[idx])
            {
                markShootPageEntered(reason: "tabIndex:\(idx)")
                noteBlitSurface(controllers[idx])
            }
            typealias Fn = @convention(c) (AnyObject, Selector, UInt) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, index)
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
                noteBlitSurface(root)
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
        if vcLooksLikeCapture(vc),
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
        // 会话已在跑就不要扫整棵窗口树。窗口风暴里扫层级会把主线程拖死。
        if isCaptureSessionRunning() { return true }
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = cachedVisible, now - cachedAt < cacheTTL {
            return cached
        }
        let found = hasPreviewLayer()
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
