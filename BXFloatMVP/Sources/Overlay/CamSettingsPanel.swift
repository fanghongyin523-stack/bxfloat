import UIKit

protocol CamSettingsPanelDelegate: AnyObject {
    func camSettingsPanelDidCollapse(_ panel: CamSettingsPanel)
}

/// 对标最终图：点开后的设置页（第1期：连接 + 替换摄像头；融合/定时先占位）。
final class CamSettingsPanel: UIView {
    weak var delegate: CamSettingsPanelDelegate?

    private let card = UIView()
    private let titleLabel = UILabel()
    private let modeControl = UISegmentedControl(items: ["局域网", "数据线", "本地视频"])
    private let modeHint = UILabel()
    private let ipField = UITextField()
    private let pasteButton = UIButton(type: .system)
    private let replaceSwitch = UISwitch()
    private let replaceLabel = UILabel()
    private let audioLabel = UILabel()
    private let audioControl = UISegmentedControl(items: ["推流声音", "手机麦克风", "静音"])
    private let collapseButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        reloadFromStore()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func reloadFromStore() {
        let cfg = MediaConfigStore.shared.config
        switch cfg.connectionMode {
        case .lan: modeControl.selectedSegmentIndex = 0
        case .usb: modeControl.selectedSegmentIndex = 1
        case .localVideo: modeControl.selectedSegmentIndex = 2
        case .manual: modeControl.selectedSegmentIndex = 0
        }
        ipField.text = cfg.computerIP
        replaceSwitch.isOn = cfg.replaceCameraEnabled
        switch cfg.audioCaptureMode {
        case .stream: audioControl.selectedSegmentIndex = 0
        case .microphone: audioControl.selectedSegmentIndex = 1
        case .mute: audioControl.selectedSegmentIndex = 2
        }
        updateModeHint()
        refreshStatus()
    }

    private func setup() {
        backgroundColor = UIColor.black.withAlphaComponent(0.35)
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        card.backgroundColor = UIColor(white: 0.12, alpha: 0.96)
        card.layer.cornerRadius = 16
        card.layer.masksToBounds = true
        addSubview(card)

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.text = "素材分辨率：—"

        modeControl.selectedSegmentIndex = 0
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        if #available(iOS 13.0, *) {
            modeControl.selectedSegmentTintColor = UIColor(red: 0.2, green: 0.75, blue: 0.35, alpha: 1)
        }

        modeHint.textColor = UIColor.white.withAlphaComponent(0.65)
        modeHint.font = .systemFont(ofSize: 11)
        modeHint.numberOfLines = 2

        ipField.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        ipField.textColor = .white
        ipField.font = .systemFont(ofSize: 15)
        ipField.keyboardType = .decimalPad
        ipField.autocapitalizationType = .none
        ipField.layer.cornerRadius = 8
        ipField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        ipField.leftViewMode = .always
        ipField.attributedPlaceholder = NSAttributedString(
            string: "电脑 IP，例如 192.168.1.191",
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.35)]
        )
        ipField.addTarget(self, action: #selector(ipEdited), for: .editingDidEnd)

        pasteButton.setTitle("粘贴", for: .normal)
        pasteButton.setTitleColor(.white, for: .normal)
        pasteButton.backgroundColor = UIColor(red: 0.2, green: 0.75, blue: 0.35, alpha: 1)
        pasteButton.layer.cornerRadius = 8
        pasteButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        pasteButton.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)

        replaceLabel.text = "替换摄像头画面"
        replaceLabel.textColor = .white
        replaceLabel.font = .systemFont(ofSize: 15, weight: .medium)
        replaceSwitch.addTarget(self, action: #selector(replaceChanged), for: .valueChanged)
        replaceSwitch.onTintColor = UIColor(red: 0.2, green: 0.75, blue: 0.35, alpha: 1)

        audioLabel.text = "直播麦声音"
        audioLabel.textColor = .white
        audioLabel.font = .systemFont(ofSize: 15, weight: .medium)
        audioControl.selectedSegmentIndex = 0
        audioControl.addTarget(self, action: #selector(audioChanged), for: .valueChanged)
        if #available(iOS 13.0, *) {
            audioControl.selectedSegmentTintColor = UIColor(red: 0.2, green: 0.75, blue: 0.35, alpha: 1)
        }

        collapseButton.setTitle("收起设置 · 回到悬浮球", for: .normal)
        collapseButton.setTitleColor(UIColor(red: 0.2, green: 0.75, blue: 0.35, alpha: 1), for: .normal)
        collapseButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        collapseButton.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)

        statusLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.numberOfLines = 4

        [titleLabel, modeControl, modeHint, ipField, pasteButton, replaceLabel, replaceSwitch, audioLabel, audioControl, collapseButton, statusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }
        card.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            modeControl.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            modeControl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            modeControl.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            modeHint.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 8),
            modeHint.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            modeHint.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            ipField.topAnchor.constraint(equalTo: modeHint.bottomAnchor, constant: 10),
            ipField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            ipField.heightAnchor.constraint(equalToConstant: 40),

            pasteButton.centerYAnchor.constraint(equalTo: ipField.centerYAnchor),
            pasteButton.leadingAnchor.constraint(equalTo: ipField.trailingAnchor, constant: 8),
            pasteButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            pasteButton.widthAnchor.constraint(equalToConstant: 64),
            pasteButton.heightAnchor.constraint(equalToConstant: 40),

            replaceLabel.topAnchor.constraint(equalTo: ipField.bottomAnchor, constant: 16),
            replaceLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),

            replaceSwitch.centerYAnchor.constraint(equalTo: replaceLabel.centerYAnchor),
            replaceSwitch.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            audioLabel.topAnchor.constraint(equalTo: replaceLabel.bottomAnchor, constant: 14),
            audioLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),

            audioControl.topAnchor.constraint(equalTo: audioLabel.bottomAnchor, constant: 8),
            audioControl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            audioControl.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            collapseButton.topAnchor.constraint(equalTo: audioControl.bottomAnchor, constant: 16),
            collapseButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),

            statusLabel.topAnchor.constraint(equalTo: collapseButton.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func updateModeHint() {
        switch modeControl.selectedSegmentIndex {
        case 1:
            modeHint.text = "数据线：插线信任，电脑开 MediaMTX+OBS+USB助手；手机开替换即可（RTSP 隧道）。"
        case 2:
            modeHint.text = "本地视频：第2期完善；第1期请先用局域网。"
        default:
            modeHint.text = "局域网：手机和电脑连同一 Wi‑Fi，只填电脑 IP，地址自动保存。"
        }
    }

    private func refreshStatus() {
        let store = CamFrameStore.shared
        let age = Date().timeIntervalSince(store.lastUpdate)
        let ageText = store.frameCount == 0 ? "暂无数据" : String(format: "%.1fs前", age)
        titleLabel.text = store.width > 0
            ? "素材分辨率：\(store.width) × \(store.height)"
            : "素材分辨率：—"
        let cfg = MediaConfigStore.shared.config
        let replaceOn = cfg.replaceCameraEnabled
        let audioName: String
        switch cfg.audioCaptureMode {
        case .stream: audioName = "推流"
        case .microphone: audioName = "原麦"
        case .mute: audioName = "静音"
        }
        let audioPkts = CamAudioStore.shared.packetCount
        statusLabel.text = [
            "收帧 \(store.frameCount) · 更新 \(ageText) · 音频包 \(audioPkts)",
            "画面：\(replaceOn ? "开" : "关") · 挂钩 \(CameraReplaceHooks.wrapCount)/回调 \(CameraReplaceHooks.callbackCount)/写 \(CameraReplaceHooks.paintCount)",
            "麦：\(audioName) · AU写 \(BXFloatMicAUPaintCount()) · 音画差 \(String(format: "%.0f", AVSyncClock.shared.estimatedAVDelta() * 1000))ms",
            store.frameCount == 0
                ? (replaceOn
                    ? "收帧=0：电脑未推流到 MediaMTX path=stream（先开 OBS）"
                    : "若收帧=0：检查电脑 MediaMTX/OBS 与 IP")
                : (cfg.audioCaptureMode == .stream && audioPkts == 0
                    ? "有画面无音频包：OBS 推流需勾选音频轨"
                    : (cfg.audioCaptureMode != .microphone && BXFloatMicAUPaintCount() == 0 && MicReplaceHooks.paintCount == 0
                        ? "麦未写入：进「开直播」页试麦，或杀抖音重进"
                        : "运行中")),
        ].joined(separator: "\n")
    }

    private func commit() {
        let mode: ConnectionMode
        switch modeControl.selectedSegmentIndex {
        case 1: mode = .usb
        case 2: mode = .localVideo
        default: mode = .lan
        }
        let audioMode: AudioCaptureMode
        switch audioControl.selectedSegmentIndex {
        case 1: audioMode = .microphone
        case 2: audioMode = .mute
        default: audioMode = .stream
        }
        MediaConfigStore.shared.update { cfg in
            cfg.connectionMode = mode
            cfg.computerIP = (ipField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.replaceCameraEnabled = replaceSwitch.isOn
            cfg.audioCaptureMode = audioMode
            cfg.muted = (audioMode == .mute)
            cfg.overlayEnabled = true
        }
        if mode == .lan, let ip = ipField.text, !ip.isEmpty {
            let url = MediaConfigStore.shared.config.resolvedPlaybackURL()
            if url.hasPrefix("rtsp://") {
                FFRTSPController.start(urlString: url)
            }
        }
    }

    @objc private func modeChanged() {
        updateModeHint()
        commit()
    }

    @objc private func ipEdited() { commit() }

    @objc private func pasteTapped() {
        let clip = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !clip.isEmpty {
            ipField.text = clip
            commit()
        }
    }

    @objc private func replaceChanged() { commit() }

    @objc private func audioChanged() { commit() }

    @objc private func collapseTapped() {
        commit()
        delegate?.camSettingsPanelDidCollapse(self)
    }

    @objc private func backgroundTapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: card)
        if !card.bounds.contains(p) {
            endEditing(true)
        }
    }
}
