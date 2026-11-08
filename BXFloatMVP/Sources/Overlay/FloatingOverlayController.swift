import UIKit

/// 点击穿透：只让悬浮球/面板吃到触摸，其它交给下面的抖音窗口。
final class BXFloatPassthroughWindow: UIWindow {
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

    /// 输完 IP / 收起面板后：把 key 还给抖音，否则悬浮窗一直占 key → 主页像卡住
    static func restoreHostKeyWindow() {
        shared.restoreHostKeyWindow()
    }

    private var floatWindow: BXFloatPassthroughWindow?
    private var bubbleView: FloatingBubbleView?
    private var settingsPanel: CamSettingsPanel?
    private var panelVisible = false
    private var reattachTimer: Timer?
    private var didMakeKeyOnce = false
    private var pullURL: String?

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
    }

    func attach(to window: UIWindow) {
        ensureFloatWindow(preferring: window.windowScene)
        CameraReplaceHooks.installIfNeeded()
        MicReplaceHooks.installIfNeeded()
        syncReplaceForCurrentSurface()
        apply(MediaConfigStore.shared.config)
        startReattachTimer()
    }

    func refreshSceneIfNeeded(_ scene: UIWindowScene?) {
        ensureFloatWindow(preferring: scene)
    }

    func show() {
        MediaConfigStore.shared.update { $0.overlayEnabled = true }
    }

    func hide() {
        MediaConfigStore.shared.update { $0.overlayEnabled = false }
    }

    func applyOpacityLive(_ opacity: Float) {
        // 悬浮球模式暂不跟透明度；保留接口兼容
        MediaConfigStore.shared.update(postNotification: false) { $0.opacity = max(0.2, min(opacity, 1)) }
    }

    @objc private func configChanged() { apply(MediaConfigStore.shared.config) }
    @objc private func appActive() { reattachIfNeeded(reason: "active") }
    @objc private func sceneActive() { reattachIfNeeded(reason: "scene") }
    @objc private func windowVisible(_ note: Notification) {
        guard let w = note.object as? UIWindow, w !== floatWindow else { return }
        DispatchQueue.main.async { [weak self] in
            self?.reattachIfNeeded(reason: "win")
        }
    }

    private func startReattachTimer() {
        reattachTimer?.invalidate()
        reattachTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reattachIfNeeded(reason: "timer")
        }
        if let t = reattachTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func syncReplaceForCurrentSurface() {
        let cfg = MediaConfigStore.shared.config
        // 真替换：只走 sample 画帧；盖层窗会挡住开播按钮/标题，永久关掉
        PreviewCover.stop()
        // 硬约束：未手动开替换则绝不注入
        CameraReplaceHooks.applyReplaceMode(cfg.replaceCameraEnabled)
        // 定时露真会强制现场麦，故每秒同步一次
        MicReplaceHooks.applyAudioMode(cfg.audioCaptureMode)
    }

    private func reattachIfNeeded(reason: String) {
        guard MediaConfigStore.shared.config.overlayEnabled else { return }
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

        // 定时器：结构正常时只刷策略（定时露真切麦），禁止每秒 syncPuller 重入
        if reason == "timer",
           !missingWindow,
           !sceneMismatch,
           !bubbleMissing,
           !bubbleOrphan,
           !fw.isHidden
        {
            syncReplaceForCurrentSurface()
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
        // 对标 VCamTang 悬浮面板：显示即可，禁止 makeKey 抢抖音焦点（主页滑动暂停根因）
        fw.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 200)
        fw.isHidden = false
        fw.alpha = 1
        didMakeKeyOnce = true
        syncReplaceForCurrentSurface()
        // win/active 只保结构+策略；拉流只在 apply/配置变更时同步，避免抖音弹窗频繁重置环
        if reason != "win", reason != "active", reason != "scene" {
            syncPuller(MediaConfigStore.shared.config)
        }
    }

    private func ensureFloatWindow(preferring scene: UIWindowScene?) {
        let activeScene = scene
            ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        if let fw = floatWindow {
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
        didMakeKeyOnce = false
    }

    private func apply(_ config: MediaConfig) {
        syncReplaceForCurrentSurface()

        if !config.overlayEnabled {
            stopPuller()
            PreviewCover.stop()
            CameraReplaceHooks.applyReplaceMode(false)
            bubbleView?.removeFromSuperview()
            bubbleView = nil
            hidePanel()
            floatWindow?.isHidden = true
            return
        }

        ensureFloatWindow(preferring: nil)
        guard let host = floatWindow else { return }
        host.isHidden = false

        // 禁止 startAndWait：主线程 sleep 最多 2.5s → 点面板/切模式像整机卡死（参照不会这么做）
        if config.connectionMode == .usb {
            USBStreamBridge.shared.start()
        } else {
            USBStreamBridge.shared.stop()
        }

        ensureBubble(on: host)
        bubbleView?.setReplaceActive(config.replaceCameraEnabled)
        bubbleView?.isHidden = panelVisible
        if panelVisible, let panel = settingsPanel {
            host.bringSubviewToFront(panel)
        }

        syncPuller(config)
    }

    /// 开「替换摄像头」或「推流声音」时拉源（对标 VCam：rtsp / usb 隧道 / 本地文件分派）。
    private func syncPuller(_ config: MediaConfig) {
        let url = config.resolvedPlaybackURL()
        let needPull = (config.replaceCameraEnabled || config.audioCaptureMode == .stream) && !url.isEmpty
        guard needPull else {
            stopPuller()
            return
        }
        switch config.connectionMode {
        case .localVideo:
            FFRTSPController.stop()
            LocalVideoPlayer.shared.start(urlString: url)
            pullURL = url
        case .lan, .usb, .manual:
            LocalVideoPlayer.shared.stop()
            if url.hasPrefix("rtsp://") || url.lowercased().hasPrefix("http") {
                FFRTSPController.start(urlString: url)
                pullURL = url
            } else {
                stopPuller()
            }
        }
    }

    private func stopPuller() {
        FFRTSPController.stop()
        LocalVideoPlayer.shared.stop()
        pullURL = nil
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
                y: host.bounds.height * 0.55,
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
            // 先 layout：否则 card.bounds=0 → hitTest 全穿透，面板看得见点不着
            panel.layoutIfNeeded()
        } else {
            settingsPanel?.reloadFromStore()
            settingsPanel?.isHidden = false
            host.bringSubviewToFront(settingsPanel!)
            settingsPanel?.layoutIfNeeded()
        }
    }

    private func hidePanel() {
        panelVisible = false
        settingsPanel?.endEditing(true)
        settingsPanel?.removeFromSuperview()
        settingsPanel = nil
        bubbleView?.isHidden = false
        restoreHostKeyWindow()
    }

    private func restoreHostKeyWindow() {
        guard let float = floatWindow, float.isKeyWindow else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var windows: [UIWindow] = []
        for scene in scenes { windows.append(contentsOf: scene.windows) }
        if windows.isEmpty { windows = UIApplication.shared.windows }
        let host = windows
            .filter { $0 !== float && !($0 is BXFloatPassthroughWindow) && !$0.isHidden && $0.alpha > 0.01 }
            .max(by: {
                ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height)
            })
        host?.makeKey()
        NSLog("BXFloatCam restoreHostKeyWindow host=%@", host?.description ?? "nil")
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
