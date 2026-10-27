import UIKit

/// 点击穿透：只让悬浮球/面板吃到触摸，其它交给下面的抖音窗口。
private final class BXFloatPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        if view === self || view === rootViewController?.view { return nil }
        return view
    }
}

/// 悬浮球挂在独立 UIWindow；默认不播画面。开「替换」才拉流盖摄像预览区。
final class FloatingOverlayController: CamSettingsPanelDelegate, FloatingBubbleViewDelegate {
    static let shared = FloatingOverlayController()

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
        let cfgOn = MediaConfigStore.shared.config.replaceCameraEnabled
        CameraReplaceHooks.applyReplaceMode(cfgOn)

        let scene = floatWindow?.windowScene
            ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let host = scene?.windows.first { $0 !== floatWindow && !$0.isHidden } ?? floatWindow

        if cfgOn {
            PreviewCover.refreshIfNeeded(in: host)
        } else {
            PreviewCover.stop()
        }
    }

    private func reattachIfNeeded(reason: String) {
        guard MediaConfigStore.shared.config.overlayEnabled else { return }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        ensureFloatWindow(preferring: scene)
        guard let fw = floatWindow else {
            apply(MediaConfigStore.shared.config)
            return
        }
        if bubbleView == nil {
            apply(MediaConfigStore.shared.config)
        } else if let bubble = bubbleView, bubble.superview !== fw {
            NSLog("BXFloatCam reattach bubble reason=%@", reason)
            fw.addSubview(bubble)
        }
        fw.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 200)
        fw.isHidden = false
        fw.alpha = 1
        if !didMakeKeyOnce {
            fw.makeKeyAndVisible()
            didMakeKeyOnce = true
            DispatchQueue.main.async {
                scene?.windows.first { $0 !== fw && !$0.isHidden }?.makeKey()
            }
        }
        syncReplaceForCurrentSurface()
        syncPuller(MediaConfigStore.shared.config)
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

        if config.connectionMode == .usb {
            USBStreamBridge.shared.startAndWait()
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

    /// 只有开「替换摄像头」才拉流；平常悬浮球不跑画面。
    private func syncPuller(_ config: MediaConfig) {
        let url = config.resolvedPlaybackURL()
        if config.replaceCameraEnabled, !url.isEmpty {
            if config.connectionMode == .lan, url.hasPrefix("rtsp://") {
                if pullURL != url {
                    FFRTSPController.start(urlString: url)
                    pullURL = url
                } else {
                    FFRTSPController.start(urlString: url)
                }
            }
        } else {
            stopPuller()
        }
    }

    private func stopPuller() {
        FFRTSPController.stop()
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
        } else {
            settingsPanel?.reloadFromStore()
            settingsPanel?.isHidden = false
            host.bringSubviewToFront(settingsPanel!)
        }
    }

    private func hidePanel() {
        panelVisible = false
        settingsPanel?.removeFromSuperview()
        settingsPanel = nil
        bubbleView?.isHidden = false
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
