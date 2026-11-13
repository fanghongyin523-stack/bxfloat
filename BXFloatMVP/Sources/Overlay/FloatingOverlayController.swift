import UIKit

/// 点击穿透：只让悬浮球/面板吃到触摸，其它交给下面的抖音窗口。
/// 永远不能成为 keyWindow：否则主页滑动会被抖音当成失焦而暂停。
final class BXFloatPassthroughWindow: UIWindow {
    // iOS 15+ / 新 Xcode：属性名是 canBecomeKey（旧名 canBecomeKeyWindow 已改名）
    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        if view === self || view === rootViewController?.view { return nil }
        return view
    }
}

/// 悬浮球挂在独立 UIWindow；默认不播画面。开「替换」才拉流盖摄像预览区。
final class FloatingOverlayController: CamSettingsPanelDelegate, FloatingBubbleViewDelegate {
    static let shared = FloatingOverlayController()

    /// 供面板 present 时避开自己的窗（禁止从空 rootVC 弹相册抢焦点）
    static var overlayWindow: UIWindow? { shared.floatWindow }

    /// 兼容旧调用：本窗永不抢 key，仍尝试把 key 钉回抖音
    static func restoreHostKeyWindow() {
        shared.restoreHostKeyWindow()
    }

    private var floatWindow: BXFloatPassthroughWindow?
    private var bubbleView: FloatingBubbleView?
    private var settingsPanel: CamSettingsPanel?
    private var panelVisible = false
    private var pickerChromeHidden = false
    private var reattachTimer: Timer?
    /// 避免 isShootSession 扫层级时同步重入，把定时器启动嵌套起来。
    private var startingReattachTimer = false
    private var pullKey: String?
    /// 换源代次：作废 USB 延迟回调，防止旧模式串到新模式
    private var sourceGeneration: UInt64 = 0

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configChanged),
            name: .bxMediaConfigDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneActive),
            name: UIScene.didActivateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowVisible),
            name: UIWindow.didBecomeVisibleNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowHidden),
            name: UIWindow.didBecomeHiddenNotification,
            object: nil
        )
        ShootSurfaceDetector.installEntryHookIfNeeded()
    }

    /// 拍摄/开直播闩锁、采集会话、或切会话安静窗。替换开关单独不算，离开采集页后还要恢复 3s 保活。
    /// 不在这里扫预览层：窗口风暴里扫整棵树会把主线程拖死，而预览层往往还没挂上。
    private func isShootSession() -> Bool {
        ShootSurfaceDetector.isShootPageLatched()
            || CameraReplaceHooks.isSessionQuiet()
            || ShootSurfaceDetector.isCaptureSessionRunning()
    }

    private func isShootOrQuiet() -> Bool {
        isShootSession() || CameraReplaceHooks.isReplaceActive()
    }

    func attach(to window: UIWindow) {
        // 拍摄/分段拍摄/开直播：停掉 3s 重挂，不要迁 windowScene、不要 makeKey、不要 syncReplace。
        if isShootSession() {
            suppressReattachForShoot()
            return
        }
        // 拍摄/录视频中再 attach 会改 windowScene 或 makeKey：预览层仍流畅，界面整页假死。
        if isShootOrQuiet(), floatWindow != nil {
            return
        }
        ensureFloatWindow(preferring: window.windowScene)
        CameraReplaceHooks.installIfNeeded()
        MicReplaceHooks.installIfNeeded()
        ShootSurfaceDetector.installEntryHookIfNeeded()
        if isShootSession() {
            suppressReattachForShoot()
            return
        }
        if isShootOrQuiet() {
            // 只是替换开着、人不在拍摄页：仍然要有保活定时器。拍摄/安静时 start 会直接拒绝。
            startReattachTimer()
            return
        }
        syncReplaceForCurrentSurface()
        apply(MediaConfigStore.shared.config)
        startReattachTimer()
        restoreHostKeyWindow()
    }

    func refreshSceneIfNeeded(_ scene: UIWindowScene?) {
        if isShootSession() { return }
        ensureFloatWindow(preferring: scene)
    }

    func show() {
        MediaConfigStore.shared.update { $0.overlayEnabled = true }
    }

    func hide() {
        MediaConfigStore.shared.update { $0.overlayEnabled = false }
    }

    func applyOpacityLive(_ opacity: Float) {
        MediaConfigStore.shared.update(postNotification: false) { $0.opacity = max(0.2, min(opacity, 1)) }
    }

    @objc private func configChanged() { apply(MediaConfigStore.shared.config) }
    @objc private func appActive() {
        if isShootSession() {
            suppressReattachForShoot()
            return
        }
        resumeReattachAfterShoot()
        if isShootOrQuiet() { return }
        reattachIfNeeded(reason: "active")
        // 点直播/替换开着时禁止 makeKey：抢抖音直播窗焦点 → 整页假死，退出重进才好
        restoreHostKeyWindow()
    }
    @objc private func sceneActive() {
        if isShootSession() {
            suppressReattachForShoot()
            return
        }
        resumeReattachAfterShoot()
        if isShootOrQuiet() { return }
        reattachIfNeeded(reason: "scene")
    }
    @objc private func windowVisible(_ note: Notification) {
        guard let w = note.object as? UIWindow,
              w !== floatWindow,
              !(w is BXFloatPassthroughWindow) else { return }
        // 已经在拍摄/开直播：立刻停表返回。不要先扫预览层，也不要 markSessionQuiet 把安静窗往后推。
        if isShootSession() {
            suppressReattachForShoot()
            return
        }
        // 类名能判定就在重挂之前打标。开直播和拍摄都走这里。
        if ShootSurfaceDetector.windowLooksLikeCapture(w) {
            ShootSurfaceDetector.markShootPageEntered(reason: "window:\(NSStringFromClass(type(of: w)))")
            if let root = w.rootViewController {
                ShootSurfaceDetector.noteBlitSurface(root)
            }
            suppressReattachForShoot()
            return
        }
        resumeReattachAfterShoot()
        if isShootOrQuiet() { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShootSession(), !self.isShootOrQuiet() else { return }
            self.reattachIfNeeded(reason: "win")
        }
    }

    @objc private func windowHidden(_ note: Notification) {
        guard let w = note.object as? UIWindow,
              w !== floatWindow,
              !(w is BXFloatPassthroughWindow) else { return }
        if isShootSession() { return }
        resumeReattachAfterShoot()
    }

    /// 拍摄/安静期间：作废并且不要再排 3s 重挂。离开拍摄后才恢复。
    func suppressReattachForShoot() {
        let had = reattachTimer != nil
        stopReattachTimer()
        if had {
            NSLog("BXFloatCam reattach timer cancelled (shoot)")
        }
    }

    func resumeReattachAfterShoot() {
        if isShootSession() { return }
        guard MediaConfigStore.shared.config.overlayEnabled else { return }
        guard reattachTimer == nil else { return }
        NSLog("BXFloatCam reattach timer resumed")
        startReattachTimer()
    }

    private func stopReattachTimer() {
        reattachTimer?.invalidate()
        reattachTimer = nil
    }

    private func startReattachTimer() {
        if startingReattachTimer { return }
        startingReattachTimer = true
        defer { startingReattachTimer = false }
        if isShootSession() {
            let had = reattachTimer != nil
            stopReattachTimer()
            if had {
                NSLog("BXFloatCam reattach timer cancelled (shoot)")
            }
            return
        }
        reattachTimer?.invalidate()
        // 3s 足够保活悬浮球；别用 1s 高频扫（主线程压力）。拍摄全程不排这个定时器。
        reattachTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isShootSession() {
                self.suppressReattachForShoot()
                return
            }
            self.reattachIfNeeded(reason: "timer")
        }
        if let t = reattachTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func syncReplaceForCurrentSurface() {
        // 切会话窗内禁止重挂钩 / setDelegate。拍摄或开直播的 start/begin 都会把安静窗拉起来。
        if CameraReplaceHooks.isSessionQuiet() { return }
        let cfg = MediaConfigStore.shared.config
        PreviewCover.stop()
        CameraReplaceHooks.applyReplaceMode(cfg.replaceCameraEnabled)
        MicReplaceHooks.applyAudioMode(cfg.audioCaptureMode)
    }

    private func reattachIfNeeded(reason: String) {
        guard MediaConfigStore.shared.config.overlayEnabled else { return }
        if pickerChromeHidden { return }
        // 点拍摄 / 录视频 / 开直播：安静期或替换开着时，连 windowLevel / scene 切换都不要碰。
        // 抖音进拍摄或开播会狂闪 UIWindow；再动悬浮窗 = 整屏假死，甚至要强制大退。
        if isShootOrQuiet() {
            return
        }

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        let fwBefore = floatWindow
        let sceneMismatch = fwBefore != nil && scene != nil && fwBefore?.windowScene !== scene
        let missingWindow = floatWindow == nil

        ensureFloatWindow(preferring: scene)
        guard let fw = floatWindow else {
            apply(MediaConfigStore.shared.config)
            return
        }

        let bubbleMissing = bubbleView == nil
        let bubbleOrphan = bubbleView.map { $0.superview !== fw } ?? false

        // 定时器只做窗/球保活，禁止每秒 applyReplace/setDelegate。
        // 参照不会在拍摄中反复动挂钩；按住拍照键时再 setDelegate = 卡死/闪退主因。
        if reason == "timer",
           !missingWindow,
           !sceneMismatch,
           !bubbleMissing,
           !bubbleOrphan,
           !fw.isHidden
        {
            return
        }

        if bubbleMissing {
            apply(MediaConfigStore.shared.config)
            return
        }
        if bubbleOrphan, let bubble = bubbleView {
            NSLog("BXFloatCam reattach bubble reason=%@", reason)
            fw.addSubview(bubble)
        }
        fw.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 200)
        if !pickerChromeHidden {
            fw.isHidden = false
        }
        fw.alpha = 1
        // 对齐参照：拍摄中（切分段拍会狂闪 UIWindow）只保活悬浮窗，
        // 禁止再 syncReplace / applyAudio / setDelegate —— 那是整屏卡死主因。
        // 挂钩只在用户改面板 / attach / apply(config) 时动。
        if reason == "win" || reason == "active" || reason == "scene" || reason == "timer" {
            return
        }
        syncReplaceForCurrentSurface()
        syncPuller(MediaConfigStore.shared.config)
    }

    private func ensureFloatWindow(preferring scene: UIWindowScene?) {
        // 拍摄/开直播全程不要新建悬浮窗，也不要把已有窗迁到别的 scene。
        if isShootSession() { return }
        let activeScene = scene
            ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        if let fw = floatWindow {
            // 拍摄中把悬浮窗迁到新 scene = 预览还在、界面假死。
            if isShootOrQuiet() { return }
            if let activeScene, fw.windowScene !== activeScene {
                fw.windowScene = activeScene
                fw.frame = activeScene.coordinateSpace.bounds
            }
            return
        }
        guard let activeScene else { return }
        let fw = BXFloatPassthroughWindow(windowScene: activeScene)
        fw.frame = activeScene.coordinateSpace.bounds
        fw.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 200)
        fw.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        fw.rootViewController = root
        fw.isHidden = false
        floatWindow = fw
    }

    private func apply(_ config: MediaConfig) {
        syncReplaceForCurrentSurface()

        if !config.overlayEnabled {
            stopPuller()
            PreviewCover.stop()
            if !CameraReplaceHooks.isSessionQuiet() {
                CameraReplaceHooks.applyReplaceMode(false)
            }
            bubbleView?.removeFromSuperview()
            bubbleView = nil
            hidePanel()
            floatWindow?.isHidden = true
            return
        }

        // 拍摄/开直播：允许面板改挂钩（安静窗之外），但不新建、不迁 scene、不改层级、不 makeKey。
        if isShootSession() {
            isolateTransport(for: config.connectionMode)
            if let bubble = bubbleView {
                bubble.setReplaceActive(config.replaceCameraEnabled)
            }
            syncPuller(config)
            return
        }

        ensureFloatWindow(preferring: nil)
        guard let host = floatWindow else { return }
        if !pickerChromeHidden {
            host.isHidden = false
        }

        // 三模式互斥：只用当前模式的基础设施。
        // USB 仅在数据线模式起隧道监听（≠拉流）；局域网/本地必须停掉 USB，禁止串线。
        isolateTransport(for: config.connectionMode)

        ensureBubble(on: host)
        bubbleView?.setReplaceActive(config.replaceCameraEnabled)
        bubbleView?.isHidden = panelVisible || pickerChromeHidden
        if panelVisible, !pickerChromeHidden, let panel = settingsPanel {
            host.bringSubviewToFront(panel)
        }

        syncPuller(config)
    }

    /// 传输层互斥：局域网 / 数据线 / 本地 同时只活一路。
    /// USB：保留 RTSP 隧道基础设施作回退；VCU1 收端由 syncPuller 在替换开时启停。
    private func isolateTransport(for mode: ConnectionMode) {
        switch mode {
        case .usb:
            USBStreamBridge.shared.start()
        case .lan, .manual, .localVideo:
            USBStreamBridge.shared.stop()
            Vcu1UsbPuller.shared.stop()
        }
    }

    /// 模式/URL/开关变化时先停干净再起，避免局域网↔数据线↔本地切换粘连旧环。
    /// 硬约束：只有「替换摄像头」才拉流；「推流声音」只切麦注入，绝不单独触发拉流。
    /// 三模式互斥：任一时刻只允许一种源往环里灌（对标参考 Pipeline 单源）。
    private func syncPuller(_ config: MediaConfig) {
        let url = config.resolvedPlaybackURL()
        // USB 直连：VCU1 listen 不依赖 RTSP URL；其它模式仍要有可播地址
        let needPull: Bool
        switch config.connectionMode {
        case .usb:
            needPull = config.replaceCameraEnabled
        default:
            needPull = config.replaceCameraEnabled && !url.isEmpty
        }
        let key: String
        switch config.connectionMode {
        case .usb:
            key = "usb|vcu1:\(config.vcu1Port)|\(needPull ? "on" : "off")"
        default:
            key = "\(config.connectionMode.rawValue)|\(needPull ? url : "off")"
        }
        if pullKey == key {
            return
        }
        // 换源：先整路停掉另外两路 + 清残帧，再只起当前模式
        stopAllMediaSources(reason: "switch:\(key)")
        pullKey = key
        let gen = sourceGeneration
        guard needPull else { return }

        switch config.connectionMode {
        case .localVideo:
            // 只跑本地播放器；FF/USB 已在 stopAll 停掉
            LocalVideoPlayer.shared.start(urlString: url)
            NSLog("BXFloatCam source=localVideo gen=%llu", gen)
        case .usb:
            // VCU1 直连主线：listen 好即可等 PC Connect；不强制再拉 18554 RTSP（避免两套抢流）
            LocalVideoPlayer.shared.stop()
            FFRTSPController.stop()
            Vcu1UsbPuller.shared.start(port: config.vcu1Port)
            NSLog(
                "BXFloatCam source=usb-vcu1 gen=%llu port=%d (%@)",
                gen, config.vcu1Port, Vcu1UsbPuller.shared.statusLine()
            )
        case .lan, .manual:
            // 只跑局域网/手动 URL；本地与 USB 隧道已隔离
            LocalVideoPlayer.shared.stop()
            if url.hasPrefix("rtsp://") || url.lowercased().hasPrefix("http") {
                FFRTSPController.start(urlString: url)
                NSLog("BXFloatCam source=%@ gen=%llu url=%@", config.connectionMode.rawValue, gen, url)
            } else {
                stopAllMediaSources(reason: "lan-empty-url")
            }
        }
    }

    /// 停掉所有灌环源（FF + 本地 + VCU1），清残帧；USB RTSP 隧道由 isolateTransport 按模式管。
    private func stopAllMediaSources(reason: String) {
        sourceGeneration &+= 1
        FFRTSPController.stop()
        LocalVideoPlayer.shared.stop()
        Vcu1UsbPuller.shared.stop()
        CamFrameStore.shared.reset()
        CamAudioStore.shared.reset()
        AVSyncClock.shared.reset()
        CamBufferPainter.bumpSourceEpochAndClearHold()
        pullKey = nil
        NSLog("BXFloatCam stopAllMediaSources reason=%@", reason)
    }

    private func stopPuller() {
        stopAllMediaSources(reason: "stopPuller")
    }

    private func ensureBubble(on host: UIWindow) {
        if let bubble = bubbleView {
            if bubble.superview !== host {
                host.addSubview(bubble)
            }
            host.bringSubviewToFront(bubble)
            return
        }
        let side: CGFloat = 56
        let created = FloatingBubbleView(
            frame: CGRect(
                x: host.bounds.width - side - 16,
                y: host.bounds.height * 0.42,
                width: side,
                height: side
            )
        )
        created.delegate = self
        host.addSubview(created)
        bubbleView = created
    }

    private func showPanel() {
        ensureFloatWindow(preferring: nil)
        guard let host = floatWindow else { return }
        panelVisible = true
        bubbleView?.isHidden = true
        if settingsPanel == nil {
            let panel = CamSettingsPanel(frame: host.bounds)
            panel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            panel.delegate = self
            settingsPanel = panel
            host.addSubview(panel)
            panel.layoutIfNeeded()
        } else {
            settingsPanel?.reloadFromStore()
            settingsPanel?.isHidden = false
            host.bringSubviewToFront(settingsPanel!)
            settingsPanel?.layoutIfNeeded()
        }
        restoreHostKeyWindow()
    }

    private func hidePanel() {
        panelVisible = false
        settingsPanel?.endEditing(true)
        settingsPanel?.removeFromSuperview()
        settingsPanel = nil
        bubbleView?.isHidden = pickerChromeHidden
        restoreHostKeyWindow()
    }

    /// 选相册/文件时整窗隐藏，避免盖住系统选片器。
    func camSettingsPanelSetPickerMode(_ on: Bool) {
        pickerChromeHidden = on
        guard let fw = floatWindow else { return }
        if on {
            fw.isHidden = true
            restoreHostKeyWindow()
        } else {
            fw.isHidden = false
            if !isShootSession() {
                fw.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 200)
            }
            if panelVisible {
                settingsPanel?.isHidden = false
                bubbleView?.isHidden = true
            } else {
                bubbleView?.isHidden = false
            }
            restoreHostKeyWindow()
        }
    }

    private func restoreHostKeyWindow() {
        if isShootOrQuiet() {
            return
        }
        let float = floatWindow
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var windows: [UIWindow] = []
        for scene in scenes { windows.append(contentsOf: scene.windows) }
        if windows.isEmpty { windows = UIApplication.shared.windows }
        let host = windows
            .filter {
                $0 !== float
                    && !($0 is BXFloatPassthroughWindow)
                    && !$0.isHidden
                    && $0.alpha > 0.01
                    && $0.bounds.width > 1
            }
            .max(by: {
                ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height)
            })
        guard let host, !host.isKeyWindow else { return }
        host.makeKey()
        NSLog("BXFloatCam restoreHostKeyWindow host=%@", host.description)
    }

    func camSettingsPanelDidCollapse(_ panel: CamSettingsPanel) {
        hidePanel()
        apply(MediaConfigStore.shared.config)
    }

    func floatingBubbleDidTap(_ bubble: FloatingBubbleView) {
        showPanel()
    }

    func floatingBubbleDidRequestClose(_ bubble: FloatingBubbleView) {
        hide()
    }
}
