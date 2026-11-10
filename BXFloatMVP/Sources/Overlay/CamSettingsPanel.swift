import UIKit
import UniformTypeIdentifiers
import MobileCoreServices

protocol CamSettingsPanelDelegate: AnyObject {
    func camSettingsPanelDidCollapse(_ panel: CamSettingsPanel)
    /// 选相册/文件时隐藏悬浮窗，避免挡住系统选片器
    func camSettingsPanelSetPickerMode(_ on: Bool)
}

/// 设置面板：功能结构对齐目标照片；视觉深灰中间档通透。
/// - 卡片外穿透；可拖动；默认偏上，少挡抖音底栏/选片
/// - 定时露真支持手填秒数；选视频前整窗隐藏
final class CamSettingsPanel: UIView, UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    weak var delegate: CamSettingsPanelDelegate?

    private let card = UIView()
    private let dragHandle = UIView()
    private let scroll = UIScrollView()
    private let content = UIView()
    private let footer = UIView()

    private let titleLabel = UILabel()
    private let modeControl = UISegmentedControl(items: ["局域网", "数据线", "本地视频"])
    private let modeHint = UILabel()
    private let ipField = UITextField()
    private let pasteButton = UIButton(type: .system)
    private let editIPButton = UIButton(type: .system)
    private let pickLocalButton = UIButton(type: .system)
    private let replaceRow = UIStackView()
    private let replaceLabel = UILabel()
    private let replaceSwitch = UISwitch()
    private let streamAudioRow = UIStackView()
    private let streamAudioLabel = UILabel()
    private let streamAudioSwitch = UISwitch()
    private let muteRow = UIStackView()
    private let muteLabel = UILabel()
    private let muteSwitch = UISwitch()

    private let advancedToggle = UIButton(type: .system)
    private let advancedBox = UIStackView()
    private let rotateButton = UIButton(type: .system)
    private let mirrorButton = UIButton(type: .system)
    private let blendRow = makeSwitchRow(title: "融合真实摄像头")
    private let blendSlider = UISlider()
    private let blendHint = UILabel()
    private let timedRow = makeSwitchRow(title: "定时显示真实镜头")
    private let intervalField = UITextField()
    private let showSecField = UITextField()
    private let timedPreset = UISegmentedControl(items: ["30分", "1小时", "2小时"])
    private let timedHint = UILabel()

    private let statusLabel = UILabel()
    private let logButton = UIButton(type: .system)
    private let collapseButton = UIButton(type: .system)
    private let monitorButton = UIButton(type: .system)

    private var advancedExpanded = false
    private var statusTimer: Timer?
    private var cardHeightConstraint: NSLayoutConstraint?
    private var cardCenterYConstraint: NSLayoutConstraint?
    private var cardDragOffset: CGFloat = -72

    private let cardBg = UIColor(white: 0.16, alpha: 0.88)
    private let fieldBg = UIColor(white: 1.0, alpha: 0.12)
    private let textPrimary = UIColor.white
    private let textSecondary = UIColor(white: 1.0, alpha: 0.62)
    private let accent = UIColor(red: 0.35, green: 0.78, blue: 0.55, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        reloadFromStore()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    deinit {
        statusTimer?.invalidate()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let p = convert(point, to: card)
        if card.bounds.contains(p) {
            return super.hitTest(point, with: event)
        }
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = min(max(bounds.height * 0.52, 280), bounds.height * 0.68)
        if abs((cardHeightConstraint?.constant ?? 0) - h) > 0.5 {
            cardHeightConstraint?.constant = h
        }
        clampCardOffset()
        cardCenterYConstraint?.constant = cardDragOffset
    }

    func reloadFromStore() {
        let cfg = MediaConfigStore.shared.config
        switch cfg.connectionMode {
        case .lan, .manual: modeControl.selectedSegmentIndex = 0
        case .usb: modeControl.selectedSegmentIndex = 1
        case .localVideo: modeControl.selectedSegmentIndex = 2
        }
        ipField.text = cfg.computerIP
        replaceSwitch.isOn = cfg.replaceCameraEnabled
        streamAudioSwitch.isOn = (cfg.audioCaptureMode == .stream)
        muteSwitch.isOn = (cfg.audioCaptureMode == .mute)
        if cfg.audioCaptureMode == .mute {
            streamAudioSwitch.isOn = false
        }
        advancedExpanded = false
        blendRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.isOn = cfg.blendRealCamera
        blendSlider.value = Float(cfg.blendStreamPercent)
        timedRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.isOn = cfg.timedRealCamera
        intervalField.text = "\(max(10, cfg.timedRealIntervalSec))"
        showSecField.text = "\(max(1, min(60, cfg.timedRealShowSec)))"
        switch cfg.timedRealIntervalSec {
        case 1800: timedPreset.selectedSegmentIndex = 0
        case 3600: timedPreset.selectedSegmentIndex = 1
        case 7200: timedPreset.selectedSegmentIndex = 2
        default: timedPreset.selectedSegmentIndex = UISegmentedControl.noSegment
        }
        rotateButton.setTitle("旋转 \(cfg.rotationDegrees)°", for: .normal)
        mirrorButton.isSelected = cfg.mirrored
        updateModeHint()
        updateAdvancedChrome()
        refreshStatus()
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false

        card.backgroundColor = cardBg
        card.layer.cornerRadius = 14
        card.layer.masksToBounds = true
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        addSubview(card)

        dragHandle.backgroundColor = UIColor(white: 1, alpha: 0.28)
        dragHandle.layer.cornerRadius = 2.5
        card.addSubview(dragHandle)

        footer.backgroundColor = UIColor(white: 0.12, alpha: 0.95)
        card.addSubview(footer)
        card.addSubview(scroll)
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = true
        scroll.addSubview(content)

        card.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false

        cardHeightConstraint = card.heightAnchor.constraint(equalToConstant: 380)
        cardCenterYConstraint = card.centerYAnchor.constraint(equalTo: centerYAnchor, constant: cardDragOffset)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            cardCenterYConstraint!,
            cardHeightConstraint!,

            dragHandle.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            dragHandle.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            dragHandle.widthAnchor.constraint(equalToConstant: 36),
            dragHandle.heightAnchor.constraint(equalToConstant: 5),

            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 52),

            scroll.topAnchor.constraint(equalTo: dragHandle.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleCardPan(_:)))
        pan.cancelsTouchesInView = false
        card.addGestureRecognizer(pan)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = textPrimary
        titleLabel.text = "素材分辨率：— · 拖顶条可移动面板"

        styleSegment(modeControl)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeHint.font = .systemFont(ofSize: 11)
        modeHint.textColor = textSecondary
        modeHint.numberOfLines = 0

        // 悬浮窗禁止成为 keyWindow → 本框只展示；改 IP 用抖音窗弹框，避免主页暂停
        styleField(ipField, placeholder: "电脑 IP（点填写/粘贴）")
        ipField.isEnabled = false
        styleFilledButton(pasteButton, title: "粘贴")
        pasteButton.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)
        styleFilledButton(editIPButton, title: "填写")
        editIPButton.addTarget(self, action: #selector(editIPTapped), for: .touchUpInside)
        styleFilledButton(pickLocalButton, title: "选视频（相册/文件）")
        pickLocalButton.addTarget(self, action: #selector(pickLocalTapped), for: .touchUpInside)

        replaceLabel.text = "替换摄像头画面"
        replaceLabel.font = .systemFont(ofSize: 15, weight: .medium)
        replaceLabel.textColor = textPrimary
        replaceSwitch.onTintColor = accent
        replaceSwitch.addTarget(self, action: #selector(replaceChanged), for: .valueChanged)
        replaceRow.axis = .horizontal
        replaceRow.alignment = .center
        replaceRow.addArrangedSubview(replaceLabel)
        replaceRow.addArrangedSubview(UIView())
        replaceRow.addArrangedSubview(replaceSwitch)

        // 推流声音：和「替换摄像头」一样的独立开关；默认关=手机麦克风
        streamAudioLabel.text = "推流声音"
        streamAudioLabel.font = .systemFont(ofSize: 15, weight: .medium)
        streamAudioLabel.textColor = textPrimary
        streamAudioSwitch.onTintColor = accent
        streamAudioSwitch.addTarget(self, action: #selector(streamAudioChanged), for: .valueChanged)
        streamAudioRow.axis = .horizontal
        streamAudioRow.alignment = .center
        streamAudioRow.addArrangedSubview(streamAudioLabel)
        streamAudioRow.addArrangedSubview(UIView())
        streamAudioRow.addArrangedSubview(streamAudioSwitch)

        muteLabel.text = "静音"
        muteLabel.font = .systemFont(ofSize: 15, weight: .medium)
        muteLabel.textColor = textPrimary
        muteSwitch.onTintColor = accent
        muteSwitch.addTarget(self, action: #selector(muteChanged), for: .valueChanged)
        muteRow.axis = .horizontal
        muteRow.alignment = .center
        muteRow.addArrangedSubview(muteLabel)
        muteRow.addArrangedSubview(UIView())
        muteRow.addArrangedSubview(muteSwitch)

        advancedToggle.contentHorizontalAlignment = .left
        advancedToggle.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        advancedToggle.setTitleColor(accent, for: .normal)
        advancedToggle.addTarget(self, action: #selector(advancedTapped), for: .touchUpInside)

        advancedBox.axis = .vertical
        advancedBox.spacing = 10
        styleOutlineButton(rotateButton, title: "旋转 0°")
        rotateButton.addTarget(self, action: #selector(rotateTapped), for: .touchUpInside)
        styleOutlineButton(mirrorButton, title: "镜像")
        mirrorButton.addTarget(self, action: #selector(mirrorTapped), for: .touchUpInside)
        let orient = UIStackView(arrangedSubviews: [rotateButton, mirrorButton])
        orient.axis = .horizontal
        orient.spacing = 8
        orient.distribution = .fillEqually

        styleSwitchRow(blendRow)
        blendRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.addTarget(
            self, action: #selector(blendChanged), for: .valueChanged
        )
        blendSlider.minimumValue = 10
        blendSlider.maximumValue = 100
        blendSlider.tintColor = accent
        blendSlider.addTarget(self, action: #selector(blendSliderChanged), for: .valueChanged)
        blendSlider.addTarget(self, action: #selector(blendSliderCommitted), for: .touchUpInside)
        blendSlider.addTarget(self, action: #selector(blendSliderCommitted), for: .touchUpOutside)
        blendHint.font = .systemFont(ofSize: 11)
        blendHint.textColor = textSecondary
        blendHint.numberOfLines = 0

        styleSwitchRow(timedRow)
        timedRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.addTarget(
            self, action: #selector(timedChanged), for: .valueChanged
        )
        styleField(intervalField, placeholder: "间隔秒，如 1800")
        intervalField.keyboardType = .numberPad
        intervalField.addTarget(self, action: #selector(timedParamsChanged), for: .editingDidEnd)
        styleField(showSecField, placeholder: "露真秒，如 2")
        showSecField.keyboardType = .numberPad
        showSecField.addTarget(self, action: #selector(timedParamsChanged), for: .editingDidEnd)
        // 定时字段在抖音窗填写更稳：点框弹 alert
        intervalField.isEnabled = false
        showSecField.isEnabled = false
        let editTimed = UIButton(type: .system)
        styleFilledButton(editTimed, title: "填写间隔/露真秒")
        editTimed.addTarget(self, action: #selector(editTimedTapped), for: .touchUpInside)
        styleSegment(timedPreset)
        timedPreset.addTarget(self, action: #selector(timedPresetChanged), for: .valueChanged)
        timedHint.font = .systemFont(ofSize: 11)
        timedHint.textColor = UIColor(red: 1, green: 0.62, blue: 0.28, alpha: 1)
        timedHint.numberOfLines = 0
        timedHint.text = "重要：露真时全屏真镜头，内录音频同步切现场。可手填任意秒数。"

        let timedRowFields = UIStackView(arrangedSubviews: [intervalField, showSecField])
        timedRowFields.axis = .horizontal
        timedRowFields.spacing = 8
        timedRowFields.distribution = .fillEqually
        intervalField.heightAnchor.constraint(equalToConstant: 40).isActive = true
        showSecField.heightAnchor.constraint(equalToConstant: 40).isActive = true

        [orient, blendRow, makeCaption("推流画面占比"), blendSlider, blendHint,
         timedRow, makeCaption("快捷间隔"), timedPreset, timedRowFields, editTimed, timedHint]
            .forEach { advancedBox.addArrangedSubview($0) }

        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = textSecondary
        statusLabel.numberOfLines = 0

        styleOutlineButton(logButton, title: "查看运行诊断日志")
        logButton.addTarget(self, action: #selector(copyLogTapped), for: .touchUpInside)

        collapseButton.setTitle("收起", for: .normal)
        collapseButton.setTitleColor(.white, for: .normal)
        collapseButton.backgroundColor = accent
        collapseButton.layer.cornerRadius = 8
        collapseButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        collapseButton.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)

        styleOutlineButton(monitorButton, title: "听:关")
        monitorButton.addTarget(self, action: #selector(monitorTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, modeControl, modeHint,
            makeIPRow(), pickLocalButton,
            replaceRow, streamAudioRow, muteRow,
            advancedToggle, advancedBox,
            statusLabel, logButton,
        ])
        stack.axis = .vertical
        stack.spacing = 10
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])

        footer.addSubview(collapseButton)
        footer.addSubview(monitorButton)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        monitorButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collapseButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            collapseButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            collapseButton.heightAnchor.constraint(equalToConstant: 36),
            collapseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),

            monitorButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            monitorButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            monitorButton.heightAnchor.constraint(equalToConstant: 32),
            monitorButton.widthAnchor.constraint(equalToConstant: 56),
        ])

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        if let t = statusTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func makeIPRow() -> UIView {
        let row = UIStackView(arrangedSubviews: [ipField, editIPButton, pasteButton])
        row.axis = .horizontal
        row.spacing = 8
        pasteButton.widthAnchor.constraint(equalToConstant: 56).isActive = true
        editIPButton.widthAnchor.constraint(equalToConstant: 56).isActive = true
        pasteButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        editIPButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        ipField.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return row
    }

    private static func makeSwitchRow(title: String) -> UIStackView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 15, weight: .medium)
        let sw = UISwitch()
        let row = UIStackView(arrangedSubviews: [label, UIView(), sw])
        row.axis = .horizontal
        row.alignment = .center
        return row
    }

    private func styleSwitchRow(_ row: UIStackView) {
        row.arrangedSubviews.compactMap { $0 as? UILabel }.forEach { $0.textColor = textPrimary }
        row.arrangedSubviews.compactMap { $0 as? UISwitch }.forEach { $0.onTintColor = accent }
    }

    private func makeCaption(_ t: String) -> UILabel {
        let l = UILabel()
        l.text = t
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = textSecondary
        return l
    }

    private func styleSegment(_ c: UISegmentedControl) {
        c.backgroundColor = fieldBg
        c.setTitleTextAttributes([.foregroundColor: textSecondary], for: .normal)
        c.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        if #available(iOS 13.0, *) {
            c.selectedSegmentTintColor = UIColor(white: 0.35, alpha: 1)
        }
    }

    private func styleField(_ f: UITextField, placeholder: String) {
        f.backgroundColor = fieldBg
        f.textColor = textPrimary
        f.font = .systemFont(ofSize: 15)
        f.layer.cornerRadius = 8
        f.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        f.leftViewMode = .always
        f.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(white: 1, alpha: 0.35)]
        )
        f.autocapitalizationType = .none
        f.keyboardAppearance = .dark
    }

    private func styleFilledButton(_ b: UIButton, title: String) {
        b.setTitle(title, for: .normal)
        b.setTitleColor(textPrimary, for: .normal)
        b.backgroundColor = fieldBg
        b.layer.cornerRadius = 8
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
    }

    private func styleOutlineButton(_ b: UIButton, title: String) {
        b.setTitle(title, for: .normal)
        b.setTitleColor(textPrimary, for: .normal)
        b.backgroundColor = fieldBg
        b.layer.cornerRadius = 8
        b.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    }

    private func clampCardOffset() {
        let cardH = cardHeightConstraint?.constant ?? 380
        let maxUp = -(bounds.height - cardH) / 2 + 24
        let maxDown = (bounds.height - cardH) / 2 - 24
        cardDragOffset = min(max(cardDragOffset, maxUp), maxDown)
    }

    @objc private func handleCardPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self).y
        if g.state == .changed || g.state == .ended {
            cardDragOffset += t
            clampCardOffset()
            cardCenterYConstraint?.constant = cardDragOffset
            g.setTranslation(.zero, in: self)
        }
    }

    private func updateModeHint() {
        pickLocalButton.isHidden = modeControl.selectedSegmentIndex != 2
        // 数据线/本地都不填推流地址：USB 自动 127.0.0.1，本地走选文件
        let showIP = modeControl.selectedSegmentIndex == 0
        ipField.superview?.isHidden = !showIP
        switch modeControl.selectedSegmentIndex {
        case 1:
            modeHint.text = "数据线：无需填地址。电脑开「USB直连助手」推 VCU1，再开「替换摄像头」。\(Vcu1UsbPuller.shared.statusLine()) · \(USBStreamBridge.shared.statusLine())"
        case 2:
            modeHint.text = "本地视频：先选文件。开「替换摄像头」才播放；「推流声音」只控制用推流声还是原麦。"
        default:
            modeHint.text = "局域网：填电脑 IP。开「替换摄像头」才拉流；「推流声音」只出声、不触发拉流。"
        }
    }

    private func updateAdvancedChrome() {
        advancedBox.isHidden = !advancedExpanded
        let blendOn = blendRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.isOn == true
        let timedOn = timedRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.isOn == true
        let summary = [
            advancedExpanded ? "收起高级设置" : "展开高级设置",
            blendOn ? "融合开" : "融合关",
            timedOn ? "定时开" : "定时关",
        ].joined(separator: " · ")
        advancedToggle.setTitle(summary, for: .normal)
        blendHint.text = "真融合：推流 \(Int(blendSlider.value))% + 真机 \(100 - Int(blendSlider.value))%（主线程隔行加速）。"
    }

    private func refreshStatus() {
        monitorButton.setTitle(CamAudioRingMonitor.shared.statusLine, for: .normal)
        let store = CamFrameStore.shared
        titleLabel.text = store.width > 0
            ? "素材 \(store.width)×\(store.height) · 拖顶条可移动"
            : "素材 — · 拖顶条可移动面板"
        let cfg = MediaConfigStore.shared.config
        let clock = AVSyncClock.shared
        _ = clock.mediaTime()
        var lines = [
            "收帧 \(store.frameCount) · 音频包 \(CamAudioStore.shared.packetCount) · AU \(BXFloatMicAUPaintCount())",
            "画面：\(cfg.replaceCameraEnabled ? "开" : "关") · \(clock.avsyncPanelLine())",
            cfg.replaceCameraEnabled ? "运行中 · \(clock.actionPanelLabel())" : "替换未开（须手动打开才注入）",
        ]
        if cfg.connectionMode == .usb {
            lines.append(Vcu1UsbPuller.shared.statusLine())
            lines.append(USBStreamBridge.shared.statusLine())
        }
        statusLabel.text = lines.joined(separator: "\n")
    }

    private func parsedIntervalSec() -> Int {
        let v = Int(intervalField.text ?? "") ?? MediaConfigStore.shared.config.timedRealIntervalSec
        return max(10, min(24 * 3600, v))
    }

    private func parsedShowSec() -> Int {
        let v = Int(showSecField.text ?? "") ?? MediaConfigStore.shared.config.timedRealShowSec
        return max(1, min(60, v))
    }

    private func commit() {
        let mode: ConnectionMode
        switch modeControl.selectedSegmentIndex {
        case 1: mode = .usb
        case 2: mode = .localVideo
        default: mode = .lan
        }
        let audioMode: AudioCaptureMode
        if muteSwitch.isOn {
            audioMode = .mute
        } else if streamAudioSwitch.isOn {
            audioMode = .stream
        } else {
            audioMode = .microphone
        }
        let blendOn = blendRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.isOn == true
        let timedOn = timedRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.isOn == true
        MediaConfigStore.shared.update { cfg in
            cfg.connectionMode = mode
            cfg.computerIP = (ipField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.replaceCameraEnabled = replaceSwitch.isOn
            cfg.audioCaptureMode = audioMode
            cfg.muted = (audioMode == .mute)
            cfg.overlayEnabled = true
            cfg.blendRealCamera = blendOn
            cfg.blendStreamPercent = Int(blendSlider.value)
            cfg.timedRealCamera = timedOn
            cfg.timedRealIntervalSec = parsedIntervalSec()
            cfg.timedRealShowSec = parsedShowSec()
            cfg.advancedExpanded = advancedExpanded
        }
        updateAdvancedChrome()
    }

    @objc private func modeChanged() {
        updateModeHint()
        // 三模式互斥：一切换就提交，FloatingOverlay 会停掉另外两路并清残帧
        stopPullHintAndCommit()
    }
    @objc private func replaceChanged() { commit() }
    @objc private func streamAudioChanged() {
        if streamAudioSwitch.isOn { muteSwitch.isOn = false }
        commit()
    }
    @objc private func muteChanged() {
        if muteSwitch.isOn { streamAudioSwitch.isOn = false }
        commit()
    }

    private func stopPullHintAndCommit() {
        // 先写配置；FloatingOverlay syncPuller 见 mode 变化会 stop+清 epoch
        commit()
    }
    @objc private func blendChanged() { commit() }
    @objc private func blendSliderChanged() { updateAdvancedChrome() }
    @objc private func blendSliderCommitted() { updateAdvancedChrome(); commit() }
    @objc private func timedChanged() { CamReplacePolicy.resetCycle(); commit() }
    @objc private func timedParamsChanged() {
        intervalField.text = "\(parsedIntervalSec())"
        showSecField.text = "\(parsedShowSec())"
        CamReplacePolicy.resetCycle()
        commit()
    }

    @objc private func timedPresetChanged() {
        switch timedPreset.selectedSegmentIndex {
        case 0: intervalField.text = "\(30 * 60)"
        case 1: intervalField.text = "\(3600)"
        case 2: intervalField.text = "\(2 * 3600)"
        default: break
        }
        timedParamsChanged()
    }

    @objc private func pasteTapped() {
        let clip = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !clip.isEmpty {
            ipField.text = clip
            commit()
        }
    }

    @objc private func editIPTapped() {
        guard let host = presentationHost() else { return }
        let alert = UIAlertController(title: "电脑 IP", message: "在抖音窗口填写，避免悬浮窗抢焦点", preferredStyle: .alert)
        alert.addTextField { [weak self] tf in
            tf.keyboardType = .decimalPad
            tf.text = self?.ipField.text
            tf.placeholder = "192.168.x.x"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            guard let self else { return }
            self.ipField.text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.commit()
        })
        host.present(alert, animated: true)
    }

    @objc private func editTimedTapped() {
        guard let host = presentationHost() else { return }
        let alert = UIAlertController(
            title: "定时露真",
            message: "间隔秒数 / 每次露真秒数（可自定义）",
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] tf in
            tf.keyboardType = .numberPad
            tf.text = self?.intervalField.text
            tf.placeholder = "间隔秒 如 1800"
        }
        alert.addTextField { [weak self] tf in
            tf.keyboardType = .numberPad
            tf.text = self?.showSecField.text
            tf.placeholder = "露真秒 如 2"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            guard let self else { return }
            self.intervalField.text = alert.textFields?[0].text
            self.showSecField.text = alert.textFields?[1].text
            self.timedPreset.selectedSegmentIndex = UISegmentedControl.noSegment
            self.timedParamsChanged()
        })
        host.present(alert, animated: true)
    }

    @objc private func rotateTapped() {
        MediaConfigStore.shared.update { cfg in
            cfg.rotationDegrees = (cfg.rotationDegrees + 90) % 360
        }
        rotateButton.setTitle("旋转 \(MediaConfigStore.shared.config.rotationDegrees)°", for: .normal)
    }

    @objc private func mirrorTapped() {
        MediaConfigStore.shared.update { $0.mirrored.toggle() }
        mirrorButton.isSelected = MediaConfigStore.shared.config.mirrored
    }

    @objc private func advancedTapped() {
        advancedExpanded.toggle()
        updateAdvancedChrome()
    }

    @objc private func pickLocalTapped() {
        guard let host = presentationHost() else { return }
        let sheet = UIAlertController(title: "选择本地视频", message: nil, preferredStyle: .actionSheet)
        if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
            sheet.addAction(UIAlertAction(title: "相册", style: .default) { [weak self] _ in
                self?.presentMediaPicker(from: host, kind: .album)
            })
        }
        sheet.addAction(UIAlertAction(title: "文件", style: .default) { [weak self] _ in
            self?.presentMediaPicker(from: host, kind: .files)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = pickLocalButton
            pop.sourceRect = pickLocalButton.bounds
        }
        host.present(sheet, animated: true)
    }

    private enum PickerKind { case album, files }

    private func presentMediaPicker(from host: UIViewController, kind: PickerKind) {
        delegate?.camSettingsPanelSetPickerMode(true)
        switch kind {
        case .album:
            let picker = UIImagePickerController()
            picker.sourceType = .photoLibrary
            picker.mediaTypes = ["public.movie"]
            picker.delegate = self
            host.present(picker, animated: true)
        case .files:
            let picker: UIDocumentPickerViewController
            if #available(iOS 14, *) {
                picker = UIDocumentPickerViewController(
                    forOpeningContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                    asCopy: true
                )
            } else {
                picker = UIDocumentPickerViewController(
                    documentTypes: [kUTTypeMovie as String],
                    in: .import
                )
            }
            picker.delegate = self
            host.present(picker, animated: true)
        }
    }

    private func endPickerMode() {
        delegate?.camSettingsPanelSetPickerMode(false)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true) { [weak self] in self?.endPickerMode() }
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        let url = info[.mediaURL] as? URL
        picker.dismiss(animated: true) { [weak self] in
            self?.endPickerMode()
            if let url { self?.applyLocalURL(url) }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        endPickerMode()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        defer { endPickerMode() }
        guard let url = urls.first else { return }
        _ = url.startAccessingSecurityScopedResource()
        applyLocalURL(url)
    }

    private func applyLocalURL(_ url: URL) {
        MediaConfigStore.shared.update { cfg in
            cfg.connectionMode = .localVideo
            cfg.streamURL = url.path
        }
        modeControl.selectedSegmentIndex = 2
        updateModeHint()
        commit()
    }

    @objc private func collapseTapped() {
        endEditing(true)
        commit()
        FloatingOverlayController.restoreHostKeyWindow()
        delegate?.camSettingsPanelDidCollapse(self)
    }

    @objc private func monitorTapped() {
        CamAudioRingMonitor.shared.cycleSource()
        monitorButton.setTitle(CamAudioRingMonitor.shared.statusLine, for: .normal)
    }

    @objc private func copyLogTapped() {
        let snap = CamPipelineDiag.shared.panelSnapshotForCopy()
        let panel = statusLabel.text ?? ""
        let exp = CamPipelineDiag.shared.exportLogText()
        UIPasteboard.general.string = [snap, panel, exp.text].joined(separator: "\n")
        logButton.setTitle("已复制", for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.logButton.setTitle("查看运行诊断日志", for: .normal)
        }
    }

    private func presentationHost() -> UIViewController? {
        let float = FloatingOverlayController.overlayWindow
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var windows: [UIWindow] = []
        for scene in scenes { windows.append(contentsOf: scene.windows) }
        if windows.isEmpty { windows = UIApplication.shared.windows }

        let usable = windows.filter { w in
            w !== float
                && !(w is BXFloatPassthroughWindow)
                && !w.isHidden
                && w.alpha > 0.01
                && w.bounds.width > 1
        }
        let preferred =
            usable.first(where: { $0.isKeyWindow })
            ?? usable.max(by: {
                ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height)
            })
        guard let root = preferred?.rootViewController else { return nil }
        return topMost(root)
    }

    private func topMost(_ root: UIViewController) -> UIViewController {
        if let presented = root.presentedViewController { return topMost(presented) }
        if let nav = root as? UINavigationController, let visible = nav.visibleViewController {
            return topMost(visible)
        }
        if let tab = root as? UITabBarController, let selected = tab.selectedViewController {
            return topMost(selected)
        }
        return root
    }
}
