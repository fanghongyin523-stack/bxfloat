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
    private func isolateTransport(for mode: ConnectionMode) {
        switch mode {
        case .usb:
            USBStreamBridge.shared.start()
        case .lan, .manual, .localVideo:
            USBStreamBridge.shared.stop()
        }
    }

    /// 模式/URL/开关变化时先停干净再起，避免局域网↔数据线↔本地切换粘连旧环。
    /// 硬约束：只有「替换摄像头」才拉流；「推流声音」只切麦注入，绝不单独触发拉流。
    /// 三模式互斥：任一时刻只允许一种源往环里灌（对标参考 Pipeline 单源）。
    private func syncPuller(_ config: MediaConfig) {
        let url = config.resolvedPlaybackURL()
        let needPull = config.replaceCameraEnabled && !url.isEmpty
        // 模式变化即使 replace 关也要换 key，强制 stop+清残帧，禁止粘旧源
        let key = "\(config.connectionMode.rawValue)|\(needPull ? url : "off")"
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
            // 只跑 USB→本机 RTSP；等本机监听 + PC 助手隧道挂上再拉（否则 FFmpeg 2s 超时必败）
            let pullURL = url
            let expectedKey = key
            USBStreamBridge.shared.whenPullReady { [weak self] tunnelArmed in
                guard let self else { return }
                guard self.sourceGeneration == gen, self.pullKey == expectedKey else { return }
                let cfg = MediaConfigStore.shared.config
                guard cfg.connectionMode == .usb, cfg.replaceCameraEnabled else { return }
                LocalVideoPlayer.shared.stop()
                if !tunnelArmed {
                    NSLog("BXFloatCam source=usb WAIT helper gen=%llu (%@)", gen, USBStreamBridge.shared.statusLine())
                }
                // 即使助手晚到也启动：FFmpeg 会重连；助手已挂则首连即可通
                FFRTSPController.start(urlString: pullURL)
                NSLog("BXFloatCam source=usb gen=%llu armed=%d url=%@", gen, tunnelArmed ? 1 : 0, pullURL)
            }
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

    /// 停掉所有灌环源（FF + 本地），清残帧；USB 隧道由 isolateTransport 按模式管。
    private func stopAllMediaSources(reason: String) {
        sourceGeneration &+= 1
        FFRTSPController.stop()
        LocalVideoPlayer.shared.stop()
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
