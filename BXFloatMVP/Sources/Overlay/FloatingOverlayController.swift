import UIKit

/// 在当前 App 的 WindowScene 上叠一层高 level 窗口（目标1：不注入别的 App）。
final class FloatingOverlayController: FloatingOverlayViewDelegate {
    static let shared = FloatingOverlayController()

    private var overlayWindow: PassthroughWindow?
    private var overlayView: FloatingOverlayView?
    private var player: StreamPlayer?
    private var windowScene: UIWindowScene?
    private var loadedURL: String?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configChanged),
            name: .bxMediaConfigDidChange,
            object: nil
        )
    }

    func attach(to scene: UIWindowScene) {
        windowScene = scene
        ensureWindow()
        apply(MediaConfigStore.shared.config)
    }

    func refreshSceneIfNeeded(_ scene: UIWindowScene?) {
        guard let scene else { return }
        windowScene = scene
        overlayWindow?.windowScene = scene
    }

    func show() {
        MediaConfigStore.shared.update { $0.overlayEnabled = true }
    }

    func hide() {
        MediaConfigStore.shared.update { $0.overlayEnabled = false }
    }

    /// 滑动透明度时即时生效，不重载播放。
    func applyOpacityLive(_ opacity: Float) {
        let clamped = max(0.2, min(opacity, 1))
        overlayView?.alpha = CGFloat(clamped)
        MediaConfigStore.shared.update(postNotification: false) { $0.opacity = clamped }
    }

    @objc private func configChanged() {
        apply(MediaConfigStore.shared.config)
    }

    private func ensureWindow() {
        guard let windowScene else { return }
        if overlayWindow == nil {
            let window = PassthroughWindow(windowScene: windowScene)
            window.windowLevel = .alert + 1
            window.backgroundColor = .clear
            window.isHidden = true

            let root = UIViewController()
            let rootView = PassthroughRootView(frame: .zero)
            rootView.backgroundColor = .clear
            root.view = rootView
            window.rootViewController = root
            overlayWindow = window
        } else {
            overlayWindow?.windowScene = windowScene
        }
    }

    private func apply(_ config: MediaConfig) {
        ensureWindow()
        guard let overlayWindow, let root = overlayWindow.rootViewController?.view else { return }

        if !config.overlayEnabled {
            player?.stop()
            player = nil
            loadedURL = nil
            overlayView?.removeFromSuperview()
            overlayView = nil
            overlayWindow.isHidden = true
            return
        }

        overlayWindow.isHidden = false

        let overlay: FloatingOverlayView
        if let existing = overlayView {
            overlay = existing
        } else {
            let shortSide = min(max(root.bounds.width, 1), max(root.bounds.height, 1))
            let width = max(shortSide * CGFloat(config.windowScale), 160)
            let frame = CGRect(x: 24, y: 120, width: width, height: width * 0.75)
            let created = FloatingOverlayView(frame: frame)
            created.delegate = self
            root.addSubview(created)
            overlayView = created
            overlay = created
        }

        overlay.alpha = CGFloat(max(0.2, min(config.opacity, 1)))

        let url = config.streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let needReload = loadedURL != url || player == nil
        if needReload {
            do {
                try startPlayback(urlString: url, muted: config.muted, into: overlay)
                loadedURL = url
            } catch {
                presentError(error.localizedDescription)
            }
        } else if let player {
            player.isMuted = config.muted
            overlay.setPlaying(player.isPlaying)
        }
    }

    private func startPlayback(urlString: String, muted: Bool, into overlay: FloatingOverlayView) throws {
        guard !urlString.isEmpty else { throw StreamPlayerError.emptyURL }

        if player == nil {
            player = try StreamPlayerFactory.makePlayer(for: urlString)
        } else if StreamURLAnalyzer.kind(of: urlString) == .rtsp {
            throw StreamPlayerError.rtspNotLinkedYet
        }

        guard let player else { return }
        try player.load(urlString: urlString)
        player.isMuted = muted
        player.play()
        overlay.setPlayerView(player.view)
        overlay.setPlaying(true)
    }

    private func presentError(_ message: String) {
        NSLog("BXFloat overlay error: \(message)")
        guard let root = overlayWindow?.rootViewController else { return }

        let alert = UIAlertController(title: "无法播放", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        if root.presentedViewController == nil {
            root.present(alert, animated: true)
        }
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
}
