import UIKit

/// 小悬浮窗 ↔ 设置面板；局域网 RTSP；可选替换摄像头。
final class FloatingOverlayController: FloatingOverlayViewDelegate, CamSettingsPanelDelegate {
    static let shared = FloatingOverlayController()

    private weak var hostWindow: UIWindow?
    private var overlayView: FloatingOverlayView?
    private var settingsPanel: CamSettingsPanel?
    private var player: StreamPlayer?
    private var loadedURL: String?
    private var panelVisible = false

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configChanged),
            name: .bxMediaConfigDidChange,
            object: nil
        )
    }

    func attach(to window: UIWindow) {
        hostWindow = window
        CameraReplaceHooks.installIfNeeded()
        apply(MediaConfigStore.shared.config)
    }

    func refreshSceneIfNeeded(_ scene: UIWindowScene?) {
        guard let scene else { return }
        if let existing = hostWindow, existing.windowScene === scene { return }
        if let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            hostWindow = win
        }
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

    @objc private func configChanged() {
        apply(MediaConfigStore.shared.config)
    }

    private func apply(_ config: MediaConfig) {
        guard let hostWindow else { return }

        if !config.overlayEnabled {
            USBStreamBridge.shared.stop()
            RTSPVTPuller.shared.stop()
            PreviewCover.stop()
            player?.stop()
            player = nil
            loadedURL = nil
            overlayView?.removeFromSuperview()
            overlayView = nil
            hidePanel()
            return
        }

        if config.connectionMode == .usb {
            USBStreamBridge.shared.startAndWait()
        } else {
            USBStreamBridge.shared.stop()
        }

        let overlay: FloatingOverlayView
        if let existing = overlayView {
            overlay = existing
            hostWindow.bringSubviewToFront(existing)
        } else {
            let frame = CGRect(x: 24, y: 120, width: 168, height: 126)
            let created = FloatingOverlayView(frame: frame)
            created.delegate = self
            hostWindow.addSubview(created)
            overlayView = created
            overlay = created
        }

        overlay.alpha = CGFloat(max(0.2, min(config.opacity, 1)))
        overlay.setConnectionHint(config)
        if panelVisible {
            hostWindow.bringSubviewToFront(settingsPanel ?? overlay)
        }

        if config.replaceCameraEnabled {
            PreviewCover.start(in: hostWindow)
        } else {
            PreviewCover.stop()
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
                    self.presentError(error.localizedDescription)
                }
            }
        } else if let player {
            player.isMuted = config.muted
            overlay.setPlaying(player.isPlaying)
            // 替换开关变化时也确保 RTSP 在拉
            if config.connectionMode == .lan, !url.isEmpty, url.hasPrefix("rtsp://") {
                #if !canImport(MobileVLCKit)
                RTSPVTPuller.shared.start(urlString: url)
                #endif
            }
        }
    }

    private func startPlayback(urlString: String, muted: Bool, into overlay: FloatingOverlayView) throws {
        guard !urlString.isEmpty else {
            throw StreamPlayerError.emptyURL
        }

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

        // 注入路径：额外保证拉流进 FrameStore（替换摄像头用）
        if kind == .rtsp {
            #if !canImport(MobileVLCKit)
            RTSPVTPuller.shared.start(urlString: urlString)
            #endif
        }
    }

    private func presentError(_ message: String) {
        NSLog("BXFloat overlay error: %@", message)
    }

    private func showPanel() {
        guard let hostWindow else { return }
        panelVisible = true
        if settingsPanel == nil {
            let panel = CamSettingsPanel(frame: hostWindow.bounds)
            panel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            panel.delegate = self
            settingsPanel = panel
            hostWindow.addSubview(panel)
        } else {
            settingsPanel?.reloadFromStore()
            settingsPanel?.isHidden = false
            hostWindow.bringSubviewToFront(settingsPanel!)
        }
        overlayView?.isHidden = true
    }

    private func hidePanel() {
        panelVisible = false
        settingsPanel?.removeFromSuperview()
        settingsPanel = nil
        overlayView?.isHidden = false
        if let overlayView, let hostWindow {
            hostWindow.bringSubviewToFront(overlayView)
        }
    }

    func camSettingsPanelDidCollapse(_ panel: CamSettingsPanel) {
        hidePanel()
        apply(MediaConfigStore.shared.config)
    }

    func floatingOverlayDidRequestClose(_ view: FloatingOverlayView) {
        hide()
    }

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

    func floatingOverlayDidRequestEditURL(_ view: FloatingOverlayView) {
        showPanel()
    }
}
