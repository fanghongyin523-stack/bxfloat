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
    private var pullKey: String?

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
        restoreHostKeyWindow()
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
        MediaConfigStore.shared.update(postNotification: false) { $0.opacity = max(0.2, min(opacity, 1)) }
    }

    @objc private func configChanged() { apply(MediaConfigStore.shared.config) }
    @objc private func appActive() {
        reattachIfNeeded(reason: "active")
        restoreHostKeyWindow()
    }
    @objc private func sceneActive() { reattachIfNeeded(reason: "scene") }
    @objc private func windowVisible(_ note: Notification) {
        guard let w = note.object as? UIWindow, w !== floatWindow else { return }
        DispatchQueue.main.async { [weak self] in
            self?.reattachIfNeeded(reason: "win")
            self?.restoreHostKeyWindow()
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
        PreviewCover.stop()
        CameraReplaceHooks.applyReplaceMode(cfg.replaceCameraEnabled)
        MicReplaceHooks.applyAudioMode(cfg.audioCaptureMode)
    }

    private func reattachIfNeeded(reason: String) {
        guard MediaConfigStore.shared.config.overlayEnabled else { return }
        if pickerChromeHidden { return }

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
        fw.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 200)
        if !pickerChromeHidden {
            fw.isHidden = false
        }
        fw.alpha = 1
        syncReplaceForCurrentSurface()
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
        if !pickerChromeHidden {
            host.isHidden = false
        }

        // 选数据线：只起本机隧道监听（让 PC 助手先连上）；不等于拉流。
        // 真正 FFmpeg 拉流仍只在「替换摄像头」打开后走 syncPuller。
        if config.connectionMode == .usb {
            USBStreamBridge.shared.start()
        } else {
            USBStreamBridge.shared.stop()
        }

        ensureBubble(on: host)
        bubbleView?.setReplaceActive(config.replaceCameraEnabled)
        bubbleView?.isHidden = panelVisible || pickerChromeHidden
        if panelVisible, !pickerChromeHidden, let panel = settingsPanel {
            host.bringSubviewToFront(panel)
        }

        syncPuller(config)
    }

    /// 模式/URL/开关变化时先停干净再起，避免局域网↔数据线↔本地切换粘连旧环。
    /// 硬约束：只有「替换摄像头」才拉流；「推流声音」只切麦注入，绝不单独触发拉流。
    private func syncPuller(_ config: MediaConfig) {
        let url = config.resolvedPlaybackURL()
        let needPull = config.replaceCameraEnabled && !url.isEmpty
        // 模式变化即使 replace 关也要换 key，强制 stop+清残帧，禁止粘旧源
        let key = "\(config.connectionMode.rawValue)|\(needPull ? url : "off")"
        if pullKey == key {
            return
        }
        // 换源必须整路停干净 + 清残帧 epoch，禁止本地画面粘到局域网/USB
        stopPuller()
        pullKey = key
        guard needPull else { return }

        switch config.connectionMode {
        case .localVideo:
            LocalVideoPlayer.shared.start(urlString: url)
        case .usb:
            // 等本机 :18554 监听就绪再拉，避免「点替换没反应」（连上被拒）
            let pullURL = url
            let expectedKey = key
            USBStreamBridge.shared.whenLocalReady {
                guard self.pullKey == expectedKey else { return }
                let cfg = MediaConfigStore.shared.config
                guard cfg.connectionMode == .usb, cfg.replaceCameraEnabled else { return }
                FFRTSPController.start(urlString: pullURL)
            }
        case .lan, .manual:
            if url.hasPrefix("rtsp://") || url.lowercased().hasPrefix("http") {
                FFRTSPController.start(urlString: url)
            } else {
                stopPuller()
            }
        }
    }

    private func stopPuller() {
        FFRTSPController.stop()
        LocalVideoPlayer.shared.stop()
        CamFrameStore.shared.reset()
        CamAudioStore.shared.reset()
        AVSyncClock.shared.reset()
        CamBufferPainter.bumpSourceEpochAndClearHold()
        pullKey = nil
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
            fw.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 200)
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
