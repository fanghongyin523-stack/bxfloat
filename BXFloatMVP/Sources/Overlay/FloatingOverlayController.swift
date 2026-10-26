import UIKit

/// 悬浮窗挂在宿主主窗口上；支持局域网「只填 IP」。
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
            USBStreamBridge.shared.stop()
            player?.stop()
            player = nil
            loadedURL = nil
            overlayView?.removeFromSuperview()
            overlayView = nil
            return
        }

        if config.connectionMode == .usb {
            // 先把本机 18888 / 隧道 19888 听起来，再让播放器连，避免黑窗
            USBStreamBridge.shared.startAndWait()
        } else {
            USBStreamBridge.shared.stop()
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
        overlay.setConnectionHint(config)

        let url = config.resolvedPlaybackURL()
        let needReload = loadedURL != url || player == nil
        if needReload {
            // USB：再稍等助手连上隧道
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
        }
    }

    private func startPlayback(urlString: String, muted: Bool, into overlay: FloatingOverlayView) throws {
        guard !urlString.isEmpty else {
            throw StreamPlayerError.emptyURL
        }

        let kind = StreamURLAnalyzer.kind(of: urlString)
        let needNewPlayer: Bool
        if player == nil {
            needNewPlayer = true
        } else {
            #if canImport(MobileVLCKit)
            let isVLC = String(describing: type(of: player!)).contains("VLC")
            needNewPlayer = (kind == .rtsp) != isVLC
            #else
            needNewPlayer = (kind == .rtsp)
            #endif
        }

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
    }

    private func presentError(_ message: String) {
        NSLog("BXFloat overlay error: %@", message)
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

    private func presenter() -> UIViewController? {
        guard let root = hostWindow?.rootViewController else { return nil }
        var presenter = root
        while let shown = presenter.presentedViewController {
            presenter = shown
        }
        return presenter
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
        guard let presenter = presenter() else { return }
        let sheet = UIAlertController(title: "画面连接方式", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "局域网（只填电脑 IP）", style: .default) { [weak self] _ in
            self?.presentLANIPEditor(from: presenter)
        })
        sheet.addAction(UIAlertAction(title: "手动完整地址", style: .default) { [weak self] _ in
            self?.presentManualURLEditor(from: presenter)
        })
        sheet.addAction(UIAlertAction(title: "数据线（USB 热点）", style: .default) { [weak self] _ in
            self?.presentUSBEditor(from: presenter)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = view.bounds
        }
        presenter.present(sheet, animated: true)
    }

    private func presentLANIPEditor(from presenter: UIViewController) {
        let cfg = MediaConfigStore.shared.config
        let alert = UIAlertController(
            title: "局域网",
            message: "同一 Wi‑Fi，只填电脑 IP。\nApp：rtsp://IP:\(cfg.rtspPort)/\(cfg.streamPath)\n注入版：自动改用 HLS",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = cfg.computerIP
            field.placeholder = "例如 192.168.3.60"
            field.keyboardType = .decimalPad
            field.autocapitalizationType = .none
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "粘贴并填入", style: .default) { _ in
            let clip = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.commitLAN(ip: clip.isEmpty ? (alert.textFields?.first?.text ?? "") : clip)
        })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            self.commitLAN(ip: alert.textFields?.first?.text ?? "")
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presenter.present(alert, animated: true)
    }

    private func commitLAN(ip: String) {
        MediaConfigStore.shared.update { config in
            config.connectionMode = .lan
            config.computerIP = ip
            config.overlayEnabled = true
        }
    }

    private func presentManualURLEditor(from presenter: UIViewController) {
        let alert = UIAlertController(title: "完整播放地址", message: "http / https / rtsp / 本地路径", preferredStyle: .alert)
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
                config.connectionMode = .manual
                config.streamURL = text
                config.overlayEnabled = true
            }
        })
        presenter.present(alert, animated: true)
    }

    private func presentUSBEditor(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: "数据线",
            message: "不需要手机卡和个人热点。\n1. 线插电脑并信任\n2. 电脑跑 MediaMTX+OBS\n3. 电脑运行 BXFloat-USB助手.bat 并保持开着\n4. 确定后打开悬浮窗",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "启用数据线", style: .default) { _ in
            MediaConfigStore.shared.update { config in
                config.connectionMode = .usb
                config.overlayEnabled = true
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presenter.present(alert, animated: true)
    }
}
