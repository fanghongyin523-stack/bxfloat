import UIKit

/// 目标1：悬浮窗挂在主窗口上（不再另开全屏高层 Window，避免挡主界面按钮）。
final class FloatingOverlayController: FloatingOverlayViewDelegate {
    static let shared = FloatingOverlayController()

    private weak var hostWindow: UIWindow?
    private var overlayView: FloatingOverlayView?
    private var player: StreamPlayer?
    private var loadedURL: String?

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
            player?.stop()
            player = nil
            loadedURL = nil
            overlayView?.removeFromSuperview()
            overlayView = nil
            return
        }

        let overlay: FloatingOverlayView
        if let existing = overlayView {
            overlay = existing
            hostWindow.bringSubviewToFront(existing)
        } else {
            let bounds = hostWindow.bounds
            let shortSide = min(max(bounds.width, 1), max(bounds.height, 1))
            let width = max(shortSide * CGFloat(config.windowScale), 160)
            let frame = CGRect(x: 24, y: 120, width: width, height: width * 0.75)
            let created = FloatingOverlayView(frame: frame)
            created.delegate = self
            hostWindow.addSubview(created)
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
        guard let root = hostWindow?.rootViewController else { return }
        var presenter = root
        while let shown = presenter.presentedViewController {
            presenter = shown
        }
        let alert = UIAlertController(title: "无法播放", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        if presenter.presentedViewController == nil {
            presenter.present(alert, animated: true)
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

    func floatingOverlayDidRequestEditURL(_ view: FloatingOverlayView) {
        guard let root = hostWindow?.rootViewController else { return }
        var presenter = root
        while let shown = presenter.presentedViewController {
            presenter = shown
        }

        let alert = UIAlertController(title: "播放地址", message: "支持 http(s) / 本地路径", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = MediaConfigStore.shared.config.streamURL
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            let text = alert.textFields?.first?.text ?? ""
            MediaConfigStore.shared.update { config in
                config.streamURL = text
                config.overlayEnabled = true
            }
        })
        presenter.present(alert, animated: true)
    }
}
