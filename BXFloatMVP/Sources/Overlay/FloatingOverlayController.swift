import UIKit

/// 点击穿透：只让小窗/面板吃到触摸，其它交给下面的抖音窗口。
private final class BXFloatPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        if view === self || view === rootViewController?.view { return nil }
        return view
    }
}

/// 小悬浮窗挂在独立 UIWindow 上；替换预览仅在摄像页启用。
final class FloatingOverlayController: FloatingOverlayViewDelegate, CamSettingsPanelDelegate {
    static let shared = FloatingOverlayController()

    private var floatWindow: BXFloatPassthroughWindow?
    private var overlayView: FloatingOverlayView?
    private var settingsPanel: CamSettingsPanel?
    private var player: StreamPlayer?
    private var loadedURL: String?
    private var panelVisible = false
    private var reattachTimer: Timer?
    private var didMakeKeyOnce = false

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
        let clamped = max(0.2, min(opacity, 1))
        overlayView?.alpha = CGFloat(clamped)
        MediaConfigStore.shared.update(postNotification: false) { $0.opacity = clamped }
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
        // 1.0s 足够保活悬浮窗；摄像页检测另有短缓存，避免主线程被视图树扫描拖死
        reattachTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reattachIfNeeded(reason: "timer")
        }
        if let t = reattachTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    /// 替换摄像头：独立盖层窗（PreviewCover），不包装采集回调（防冻帧）。
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
        if overlayView == nil {
            apply(MediaConfigStore.shared.config)
        } else if let overlay = overlayView, overlay.superview !== fw {
            NSLog("BXFloatCam reattach overlay reason=%@", reason)
            fw.addSubview(overlay)
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
            USBStreamBridge.shared.stop()
            RTSPVTPuller.shared.stop()
            PreviewCover.stop()
            CameraReplaceHooks.applyReplaceMode(false)
            player?.stop()
            player = nil
            loadedURL = nil
            overlayView?.removeFromSuperview()
            overlayView = nil
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

        let overlay: FloatingOverlayView
        if let existing = overlayView {
            overlay = existing
            if existing.superview !== host { host.addSubview(existing) }
            host.bringSubviewToFront(existing)
        } else {
            let frame = CGRect(x: 24, y: 120, width: 168, height: 126)
            let created = FloatingOverlayView(frame: frame)
            created.delegate = self
            host.addSubview(created)
            overlayView = created
            overlay = created
        }

        overlay.alpha = CGFloat(max(0.2, min(config.opacity, 1)))
        overlay.setConnectionHint(config)
        if panelVisible, let panel = settingsPanel {
            host.bringSubviewToFront(panel)
        }

        let url = config.resolvedPlaybackURL()
        let needReload = loadedURL != url || player == nil
        if needReload {
            let delay: TimeInterval = config.connectionMode == .usb ? 0.35 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                do {
                    try self.startPlayback(urlString: url, muted: config.muted, into: overlay)
                    self.loadedURL = url
                } catch {
                    NSLog("BXFloat overlay error: %@", error.localizedDescription)
                }
            }
        } else if let player {
            player.isMuted = config.muted
            overlay.setPlaying(player.isPlaying)
            if config.connectionMode == .lan, url.hasPrefix("rtsp://") {
                #if !canImport(MobileVLCKit)
                FFRTSPController.start(urlString: url)
                #endif
            }
        }
    }

    private func startPlayback(urlString: String, muted: Bool, into overlay: FloatingOverlayView) throws {
        guard !urlString.isEmpty else { throw StreamPlayerError.emptyURL }
        let kind = StreamURLAnalyzer.kind(of: urlString)
        #if canImport(MobileVLCKit)
        let wantVLC = (kind == .rtsp)
        let isVLC = player.map { String(describing: type(of: $0)).contains("VLC") } ?? false
        let needNewPlayer = player == nil || wantVLC != isVLC
        #else
        let wantRTSPVT = (kind == .rtsp)
        let isRTSPVT = player is RTSPVTPlayer
        let needNewPlayer = player == nil || wantRTSPVT != isRTSPVT
        #endif

        if needNewPlayer {
            player?.stop()
            player = try StreamPlayerFactory.makePlayer(for: urlString)
        }
        guard let player else { return }
        try player.load(urlString: urlString)
        player.isMuted = muted
        player.play()
        overlay.setPlayerView(player.view)
        overlay.setPlaying(true)
        if kind == .rtsp {
            #if !canImport(MobileVLCKit)
            FFRTSPController.start(urlString: urlString)
            #endif
        }
    }

    private func showPanel() {
        ensureFloatWindow(preferring: nil)
        guard let host = floatWindow else { return }
        panelVisible = true
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
        overlayView?.isHidden = true
    }

    private func hidePanel() {
        panelVisible = false
        settingsPanel?.removeFromSuperview()
        settingsPanel = nil
        overlayView?.isHidden = false
    }

    func camSettingsPanelDidCollapse(_ panel: CamSettingsPanel) {
        hidePanel()
        apply(MediaConfigStore.shared.config)
    }

    func floatingOverlayDidRequestClose(_ view: FloatingOverlayView) { hide() }

    func floatingOverlayDidRequestTogglePlay(_ view: FloatingOverlayView) {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            view.setPlaying(false)
        } else {
            player.play()
            view.setPlaying(true)
        }
    }

    func floatingOverlayDidRequestEditURL(_ view: FloatingOverlayView) { showPanel() }
}
