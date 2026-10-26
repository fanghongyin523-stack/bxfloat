import UIKit
import UniformTypeIdentifiers
import PhotosUI

/// 主 App 根：连接 / 画面 / 帮助
final class RootTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1)
        tabBar.tintColor = UIColor(red: 0.2, green: 0.55, blue: 0.95, alpha: 1)

        let connect = UINavigationController(rootViewController: ConnectionViewController())
        connect.tabBarItem = UITabBarItem(title: "连接", image: UIImage(systemName: "wifi"), tag: 0)

        let display = UINavigationController(rootViewController: DisplayViewController())
        display.tabBarItem = UITabBarItem(title: "画面", image: UIImage(systemName: "rectangle.on.rectangle"), tag: 1)

        let help = UINavigationController(rootViewController: HelpViewController())
        help.tabBarItem = UITabBarItem(title: "帮助", image: UIImage(systemName: "questionmark.circle"), tag: 2)

        viewControllers = [connect, display, help]
    }
}

// MARK: - 连接

final class ConnectionViewController: UIViewController, UITextFieldDelegate {
    private let modeControl = UISegmentedControl(items: ["局域网", "手动地址", "本地视频", "数据线"])
    private let field = UITextField()
    private let hintLabel = UILabel()
    private let resolvedLabel = UILabel()
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "连接"
        view.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1)
        navigationController?.navigationBar.prefersLargeTitles = true
        setupUI()
        reloadFromStore()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadFromStore),
            name: .bxMediaConfigDidChange,
            object: nil
        )
    }

    private func setupUI() {
        modeControl.selectedSegmentIndex = 0
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.keyboardType = .URL
        field.returnKeyType = .done
        field.textColor = .label
        field.delegate = self

        hintLabel.numberOfLines = 0
        hintLabel.textColor = .secondaryLabel
        hintLabel.font = .systemFont(ofSize: 13)

        resolvedLabel.numberOfLines = 0
        resolvedLabel.textColor = .tertiaryLabel
        resolvedLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .systemFont(ofSize: 13)

        let save = makeButton(title: "保存连接", color: UIColor(white: 0.22, alpha: 1), action: #selector(saveTapped))
        let start = makeButton(title: "打开悬浮窗", color: UIColor(red: 0.2, green: 0.55, blue: 0.95, alpha: 1), action: #selector(startOverlay))
        let stop = makeButton(title: "关闭悬浮窗", color: UIColor(white: 0.25, alpha: 1), action: #selector(stopOverlay))
        let fillLAN = makeButton(title: "填入本机常用 IP", color: UIColor(red: 0.85, green: 0.45, blue: 0.2, alpha: 1), action: #selector(fillLANIP))
        let fillDemo = makeButton(title: "填公网测试视频", color: UIColor(red: 0.55, green: 0.35, blue: 0.85, alpha: 1), action: #selector(fillDemo))
        let pick = makeButton(title: "从相册选本地视频", color: UIColor(red: 0.15, green: 0.65, blue: 0.45, alpha: 1), action: #selector(pickVideo))

        let stack = UIStackView(arrangedSubviews: [
            makeCaption("连接方式"),
            modeControl,
            hintLabel,
            makeCaption("填写"),
            field,
            fillLAN,
            fillDemo,
            pick,
            resolvedLabel,
            save,
            start,
            stop,
            statusLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .onDrag
        view.addSubview(scroll)
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(endEditing))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc private func reloadFromStore() {
        let config = MediaConfigStore.shared.config
        switch config.connectionMode {
        case .lan: modeControl.selectedSegmentIndex = 0
        case .manual: modeControl.selectedSegmentIndex = 1
        case .localVideo: modeControl.selectedSegmentIndex = 2
        case .usb: modeControl.selectedSegmentIndex = 3
        }
        applyModeUI(animated: false)
        switch config.connectionMode {
        case .lan:
            field.text = config.computerIP
        case .manual, .localVideo:
            field.text = config.streamURL
        case .usb:
            field.text = "http://127.0.0.1:\(config.hlsPort)/\(config.streamPath)/index.m3u8"
        }
        refreshResolved()
        let on = config.overlayEnabled ? "开" : "关"
        statusLabel.text = "悬浮窗：\(on)"
    }

    @objc private func modeChanged() {
        applyModeUI(animated: true)
        if modeControl.selectedSegmentIndex == 3 {
            let cfg = MediaConfigStore.shared.config
            field.text = "http://127.0.0.1:\(cfg.hlsPort)/\(cfg.streamPath)/index.m3u8"
        }
        refreshResolved()
    }

    private func applyModeUI(animated: Bool) {
        let idx = modeControl.selectedSegmentIndex
        let usb = idx == 3
        field.isEnabled = !usb
        field.alpha = usb ? 0.45 : 1

        switch idx {
        case 0:
            hintLabel.text = "同一 Wi‑Fi，只填电脑 IP。本 App 自动播 RTSP（低延迟）。注入到抖音等仍走 HLS。"
            field.placeholder = "例如 192.168.3.60"
            field.keyboardType = .decimalPad
        case 1:
            hintLabel.text = "手动完整地址：http / https / rtsp / m3u8。"
            field.placeholder = "http://… 或 rtsp://…"
            field.keyboardType = .URL
        case 2:
            hintLabel.text = "用下面按钮选相册视频，或粘贴本地文件路径。"
            field.placeholder = "本地视频路径"
            field.keyboardType = .default
        default:
            hintLabel.text = """
            数据线（不需要手机卡 / 不需要个人热点）：
            1. 数据线插电脑，手机点「信任」
            2. 电脑装过 iTunes 或「Apple 设备」驱动
            3. 电脑 MediaMTX+OBS 照常推流
            4. 电脑运行「BXFloat-USB助手.bat」并保持窗口开着
            5. 手机选数据线 → 打开悬浮窗
            """
            field.placeholder = "自动使用 127.0.0.1（无需填写）"
            field.keyboardType = .default
        }
        _ = animated
    }

    private func refreshResolved() {
        var draft = MediaConfigStore.shared.config
        applyDraft(to: &draft)
        let url = draft.resolvedPlaybackURL()
        if url.isEmpty {
            resolvedLabel.text = "实际播放：尚未完整"
        } else {
            resolvedLabel.text = "实际播放：\n\(url)"
        }
    }

    private func applyDraft(to config: inout MediaConfig) {
        let raw = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch modeControl.selectedSegmentIndex {
        case 0:
            config.connectionMode = .lan
            config.computerIP = raw
        case 1:
            config.connectionMode = .manual
            config.streamURL = raw
        case 2:
            config.connectionMode = .localVideo
            config.streamURL = raw
        default:
            config.connectionMode = .usb
        }
    }

    private func persist(overlayEnabled: Bool? = nil) {
        MediaConfigStore.shared.update { config in
            applyDraft(to: &config)
            if let overlayEnabled {
                config.overlayEnabled = overlayEnabled
            }
        }
        reloadFromStore()
    }

    @objc private func saveTapped() {
        view.endEditing(true)
        persist()
        statusLabel.text = "连接已保存"
    }

    @objc private func fillLANIP() {
        modeControl.selectedSegmentIndex = 0
        applyModeUI(animated: false)
        field.text = "192.168.3.60"
        persist()
        statusLabel.text = "已填局域网 IP"
    }

    @objc private func fillDemo() {
        modeControl.selectedSegmentIndex = 1
        applyModeUI(animated: false)
        field.text = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"
        persist()
        statusLabel.text = "已填公网测试视频"
    }

    @objc private func startOverlay() {
        view.endEditing(true)
        persist(overlayEnabled: true)
        FloatingOverlayController.shared.show()
        statusLabel.text = modeControl.selectedSegmentIndex == 3
            ? "已按数据线地址打开悬浮窗"
            : "已打开悬浮窗"
    }

    @objc private func stopOverlay() {
        FloatingOverlayController.shared.hide()
        statusLabel.text = "悬浮窗已关闭"
        reloadFromStore()
    }

    @objc private func pickVideo() {
        modeControl.selectedSegmentIndex = 2
        applyModeUI(animated: false)
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func endEditing() {
        view.endEditing(true)
        refreshResolved()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        refreshResolved()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        refreshResolved()
    }

    private func makeCaption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 13, weight: .medium)
        return label
    }

    private func makeButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = color
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
}

extension ConnectionViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.statusLabel.text = "选视频失败：\(error.localizedDescription)"
                }
                return
            }
            guard let url else { return }
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dest = dir.appendingPathComponent("baixiang-localvideo.mp4")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                DispatchQueue.main.async {
                    self.modeControl.selectedSegmentIndex = 2
                    self.applyModeUI(animated: false)
                    self.field.text = dest.path
                    self.persist()
                    self.statusLabel.text = "已导入本地视频"
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.text = "复制失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - 画面

final class DisplayViewController: UIViewController {
    private let opacitySlider = UISlider()
    private let opacityValueLabel = UILabel()
    private let muteSwitch = UISwitch()
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "画面"
        view.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1)
        navigationController?.navigationBar.prefersLargeTitles = true
        setupUI()
        reload()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reload),
            name: .bxMediaConfigDidChange,
            object: nil
        )
    }

    private func setupUI() {
        opacitySlider.minimumValue = 0.2
        opacitySlider.maximumValue = 1.0
        opacitySlider.addTarget(self, action: #selector(opacityChanged), for: .valueChanged)
        opacitySlider.addTarget(self, action: #selector(opacityEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        opacityValueLabel.textColor = .secondaryLabel
        opacityValueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)

        muteSwitch.addTarget(self, action: #selector(muteChanged), for: .valueChanged)

        let muteRow = UIStackView(arrangedSubviews: [makeCaption("静音"), muteSwitch])
        muteRow.axis = .horizontal
        muteRow.alignment = .center
        muteRow.distribution = .equalSpacing

        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .systemFont(ofSize: 13)

        let start = makeButton(title: "打开悬浮窗", color: UIColor(red: 0.2, green: 0.55, blue: 0.95, alpha: 1), action: #selector(startOverlay))
        let stop = makeButton(title: "关闭悬浮窗", color: UIColor(white: 0.25, alpha: 1), action: #selector(stopOverlay))

        let stack = UIStackView(arrangedSubviews: [
            makeCaption("透明度（拖动时悬浮窗即时变化）"),
            opacitySlider,
            opacityValueLabel,
            muteRow,
            start,
            stop,
            statusLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    @objc private func reload() {
        let config = MediaConfigStore.shared.config
        opacitySlider.value = config.opacity
        opacityValueLabel.text = String(format: "%.0f%%", config.opacity * 100)
        muteSwitch.isOn = config.muted
        statusLabel.text = config.overlayEnabled ? "悬浮窗：开" : "悬浮窗：关"
    }

    @objc private func opacityChanged() {
        opacityValueLabel.text = String(format: "%.0f%%", opacitySlider.value * 100)
        FloatingOverlayController.shared.applyOpacityLive(opacitySlider.value)
    }

    @objc private func opacityEnded() {
        MediaConfigStore.shared.update(postNotification: false) { $0.opacity = opacitySlider.value }
        reload()
    }

    @objc private func muteChanged() {
        MediaConfigStore.shared.update { $0.muted = muteSwitch.isOn }
    }

    @objc private func startOverlay() {
        FloatingOverlayController.shared.show()
        statusLabel.text = "已打开悬浮窗"
    }

    @objc private func stopOverlay() {
        FloatingOverlayController.shared.hide()
        statusLabel.text = "悬浮窗已关闭"
    }

    private func makeCaption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.numberOfLines = 0
        return label
    }

    private func makeButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = color
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
}

// MARK: - 帮助

final class HelpViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "帮助"
        view.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1)
        navigationController?.navigationBar.prefersLargeTitles = true

        let text = UILabel()
        text.numberOfLines = 0
        text.textColor = .secondaryLabel
        text.font = .systemFont(ofSize: 15)
        text.text = """
        怎么用（局域网 · 低延迟）
        1. 电脑开 MediaMTX + OBS 推流
        2. 「连接」选局域网，填电脑 IP
        3. 本 App 自动播 RTSP（一般几秒内）
        4. OBS 关键帧间隔建议 1～2 秒

        怎么用（数据线）
        1. 插线信任，开 BXFloat-USB-Bridge.bat
        2. 选数据线 → 打开悬浮窗（仍为 HLS，延迟会高于局域网）

        注入
        抖音等注入版无 VLC，局域网也会走 HLS，延迟通常高于本 App。

        版本
        BXFloat MVP · 局域网 RTSP / USB HLS
        """

        text.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            text.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            text.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }
}

/// 兼容旧引用名
typealias HomeViewController = ConnectionViewController
