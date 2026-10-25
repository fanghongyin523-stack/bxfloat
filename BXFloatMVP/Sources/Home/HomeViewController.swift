import UIKit
import UniformTypeIdentifiers
import PhotosUI

final class HomeViewController: UIViewController {
    private let urlField = UITextField()
    private let opacitySlider = UISlider()
    private let opacityValueLabel = UILabel()
    private let muteSwitch = UISwitch()
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "BXFloat MVP"
        view.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1)
        navigationController?.navigationBar.prefersLargeTitles = true
        setupUI()
        reloadFromStore()
    }

    private func setupUI() {
        let tip = makeCaption("本 App：http / 本地 / RTSP（局域网）。注入版 dylib 暂仍以 http 为主。")
        let urlCaption = makeCaption("播放地址（http / https / rtsp / 本地路径）")
        urlField.borderStyle = .roundedRect
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.returnKeyType = .done
        urlField.placeholder = "例如 rtsp://192.168.1.100:554/stream"
        urlField.textColor = .label
        urlField.delegate = self

        let opacityCaption = makeCaption("透明度")
        opacitySlider.minimumValue = 0.2
        opacitySlider.maximumValue = 1.0
        opacitySlider.addTarget(self, action: #selector(opacityChanged), for: .valueChanged)
        opacitySlider.addTarget(self, action: #selector(opacityEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        opacityValueLabel.textColor = .secondaryLabel
        opacityValueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)

        let muteRow = UIStackView(arrangedSubviews: [makeCaption("静音"), muteSwitch])
        muteRow.axis = .horizontal
        muteRow.alignment = .center
        muteRow.distribution = .equalSpacing
        muteSwitch.addTarget(self, action: #selector(muteChanged), for: .valueChanged)

        let demoButton = makeButton(title: "填入公网测试视频", color: UIColor(red: 0.55, green: 0.35, blue: 0.85, alpha: 1), action: #selector(fillDemoURL))
        let rtspButton = makeButton(title: "填入局域网 RTSP 模板", color: UIColor(red: 0.85, green: 0.45, blue: 0.2, alpha: 1), action: #selector(fillRTSPTemplate))
        let startButton = makeButton(title: "打开悬浮窗", color: UIColor(red: 0.2, green: 0.55, blue: 0.95, alpha: 1), action: #selector(startOverlay))
        let stopButton = makeButton(title: "关闭悬浮窗", color: UIColor(white: 0.25, alpha: 1), action: #selector(stopOverlay))
        let pickButton = makeButton(title: "选本地视频", color: UIColor(red: 0.15, green: 0.65, blue: 0.45, alpha: 1), action: #selector(pickVideo))
        let saveButton = makeButton(title: "保存配置", color: UIColor(white: 0.2, alpha: 1), action: #selector(saveConfig))

        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 13)

        let stack = UIStackView(arrangedSubviews: [
            tip,
            urlCaption,
            urlField,
            demoButton,
            rtspButton,
            pickButton,
            opacityCaption,
            opacitySlider,
            opacityValueLabel,
            muteRow,
            startButton,
            stopButton,
            saveButton,
            statusLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(endEditing))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
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

    private func reloadFromStore() {
        let config = MediaConfigStore.shared.config
        urlField.text = config.streamURL
        opacitySlider.value = config.opacity
        opacityValueLabel.text = String(format: "%.0f%%", config.opacity * 100)
        muteSwitch.isOn = config.muted
        statusLabel.text = config.overlayEnabled ? "悬浮窗：开" : "悬浮窗：关"
    }

    private func persistFields(overlayEnabled: Bool? = nil) {
        MediaConfigStore.shared.update { config in
            config.streamURL = urlField.text ?? ""
            config.opacity = opacitySlider.value
            config.muted = muteSwitch.isOn
            if let overlayEnabled {
                config.overlayEnabled = overlayEnabled
            }
        }
        reloadFromStore()
    }

    @objc private func endEditing() {
        view.endEditing(true)
    }

    @objc private func opacityChanged() {
        opacityValueLabel.text = String(format: "%.0f%%", opacitySlider.value * 100)
        FloatingOverlayController.shared.applyOpacityLive(opacitySlider.value)
    }

    @objc private func opacityEnded() {
        // 松手时再写盘并同步状态文案
        MediaConfigStore.shared.update(postNotification: false) { config in
            config.opacity = opacitySlider.value
        }
        reloadFromStore()
    }

    @objc private func muteChanged() {
        persistFields()
    }

    @objc private func saveConfig() {
        persistFields()
        statusLabel.text = "配置已保存（对标 baixiang.conf）"
    }

    @objc private func fillDemoURL() {
        // 公开测试流，方便无本地视频时先验证悬浮窗
        urlField.text = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"
        persistFields()
        statusLabel.text = "已填入苹果公开测试视频，点「打开悬浮窗」即可"
    }

    @objc private func fillRTSPTemplate() {
        // 模板：请改成你电脑/摄像头的局域网 IP 与路径
        urlField.text = "rtsp://192.168.1.100:554/stream1"
        persistFields()
        statusLabel.text = "已填入 RTSP 模板：请把 IP/路径改成你的设备，手机与设备同一 Wi‑Fi"
    }

    @objc private func startOverlay() {
        view.endEditing(true)
        persistFields(overlayEnabled: true)
        FloatingOverlayController.shared.show()
        statusLabel.text = "已请求打开悬浮窗"
    }

    @objc private func stopOverlay() {
        FloatingOverlayController.shared.hide()
        statusLabel.text = "悬浮窗已关闭"
        reloadFromStore()
    }

    @objc private func pickVideo() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }
}

extension HomeViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

extension HomeViewController: PHPickerViewControllerDelegate {
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
                    self.urlField.text = dest.path
                    self.persistFields()
                    self.statusLabel.text = "已导入本地视频 baixiang-localvideo.mp4"
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.text = "复制失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
