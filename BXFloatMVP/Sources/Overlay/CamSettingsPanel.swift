import UIKit
import UniformTypeIdentifiers
import MobileCoreServices

protocol CamSettingsPanelDelegate: AnyObject {
    func camSettingsPanelDidCollapse(_ panel: CamSettingsPanel)
}

/// 设置面板：功能结构对齐目标照片；视觉深灰中间档通透。
/// 修复：禁止全屏遮罩锁死抖音；卡片外触摸穿透；收起按钮固定可见。
final class CamSettingsPanel: UIView, UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    weak var delegate: CamSettingsPanelDelegate?

    private let card = UIView()
    private let scroll = UIScrollView()
    private let content = UIView()
    private let footer = UIView()

    private let titleLabel = UILabel()
    private let modeControl = UISegmentedControl(items: ["局域网", "数据线", "本地视频"])
    private let modeHint = UILabel()
    private let ipField = UITextField()
    private let pasteButton = UIButton(type: .system)
    private let pickLocalButton = UIButton(type: .system)
    private let replaceRow = UIStackView()
    private let replaceLabel = UILabel()
    private let replaceSwitch = UISwitch()
    private let audioLabel = UILabel()
    private let audioControl = UISegmentedControl(items: ["推流声音", "手机麦克风", "静音"])

    private let advancedToggle = UIButton(type: .system)
    private let advancedBox = UIStackView()
    private let rotateButton = UIButton(type: .system)
    private let mirrorButton = UIButton(type: .system)
    private let blendRow = makeSwitchRow(title: "融合真实摄像头")
    private let blendSlider = UISlider()
    private let blendHint = UILabel()
    private let timedRow = makeSwitchRow(title: "定时显示真实镜头")
    private let intervalControl = UISegmentedControl(items: ["30分", "1小时", "2小时"])
    private let showControl = UISegmentedControl(items: ["1秒", "2秒", "3秒"])
    private let timedHint = UILabel()

    private let statusLabel = UILabel()
    private let logButton = UIButton(type: .system)
    private let collapseButton = UIButton(type: .system)
    private let monitorButton = UIButton(type: .system)

    private var advancedExpanded = false
    private var statusTimer: Timer?
    private var cardHeightConstraint: NSLayoutConstraint?

    /// 深灰 + 中间档透明度（不用系统 semantic，避免注入宿主 trait 导致看不见控件）
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

    /// 卡片外不吃触摸 → 抖音可继续滑，不会「整屏卡住」
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let p = convert(point, to: card)
        if card.bounds.contains(p) {
            return super.hitTest(point, with: event)
        }
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = min(max(bounds.height * 0.62, 300), bounds.height * 0.78)
        if abs((cardHeightConstraint?.constant ?? 0) - h) > 0.5 {
            cardHeightConstraint?.constant = h
        }
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
        switch cfg.audioCaptureMode {
        case .stream: audioControl.selectedSegmentIndex = 0
        case .microphone: audioControl.selectedSegmentIndex = 1
        case .mute: audioControl.selectedSegmentIndex = 2
        }
        // 打开时默认收起高级区，避免卡片过高
        advancedExpanded = false
        blendRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.isOn = cfg.blendRealCamera
        blendSlider.value = Float(cfg.blendOBSPercent)
        timedRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.isOn = cfg.timedRealCamera
        switch cfg.timedRealIntervalSec {
        case ...1800: intervalControl.selectedSegmentIndex = 0
        case ...3600: intervalControl.selectedSegmentIndex = 1
        default: intervalControl.selectedSegmentIndex = 2
        }
        showControl.selectedSegmentIndex = max(0, min(2, cfg.timedRealShowSec - 1))
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

        footer.backgroundColor = UIColor(white: 0.12, alpha: 0.95)
        card.addSubview(footer)
        card.addSubview(scroll)
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = true
        scroll.addSubview(content)

        card.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false

        // 卡片固定占比高度（避免 UIVisualEffect/模糊高度算坏 → 只剩全屏遮罩像卡住）
        cardHeightConstraint = card.heightAnchor.constraint(equalToConstant: 420)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            cardHeightConstraint!,

            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 52),

            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = textPrimary
        titleLabel.text = "素材分辨率：—"

        styleSegment(modeControl)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeHint.font = .systemFont(ofSize: 11)
        modeHint.textColor = textSecondary
        modeHint.numberOfLines = 0

        styleField(ipField, placeholder: "电脑 IP，例如 192.168.1.191")
        ipField.keyboardType = .decimalPad
        ipField.addTarget(self, action: #selector(ipEdited), for: .editingDidEnd)
        // 数字键盘无 Return：点面板空白处也要收键盘并把 key 还给抖音
        let tapBlank = UITapGestureRecognizer(target: self, action: #selector(cardBlankTapped))
        tapBlank.cancelsTouchesInView = false
        card.addGestureRecognizer(tapBlank)
        styleFilledButton(pasteButton, title: "粘贴")
        pasteButton.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)
        styleFilledButton(pickLocalButton, title: "选视频")
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

        audioLabel.text = "直播麦声音"
        audioLabel.font = .systemFont(ofSize: 15, weight: .medium)
        audioLabel.textColor = textPrimary
        styleSegment(audioControl)
        audioControl.addTarget(self, action: #selector(audioChanged), for: .valueChanged)

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
        styleSegment(intervalControl)
        styleSegment(showControl)
        intervalControl.addTarget(self, action: #selector(timedParamsChanged), for: .valueChanged)
        showControl.addTarget(self, action: #selector(timedParamsChanged), for: .valueChanged)
        timedHint.font = .systemFont(ofSize: 11)
        timedHint.textColor = UIColor(red: 1, green: 0.62, blue: 0.28, alpha: 1)
        timedHint.numberOfLines = 0
        timedHint.text = "重要：露真时全屏真镜头，内录音频同步切现场。"

        [orient, blendRow, makeCaption("OBS 画面"), blendSlider, blendHint,
         timedRow, makeCaption("每隔"), intervalControl, makeCaption("显示"), showControl, timedHint]
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
            replaceRow, audioLabel, audioControl,
            advancedToggle, advancedBox,
            statusLabel, logButton,
        ])
        stack.axis = .vertical
        stack.spacing = 10
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
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
        let row = UIStackView(arrangedSubviews: [ipField, pasteButton])
        row.axis = .horizontal
        row.spacing = 8
        pasteButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        pasteButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
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
        row.arrangedSubviews.compactMap { $0 as? UILabel }.forEach {
            $0.textColor = textPrimary
        }
        row.arrangedSubviews.compactMap { $0 as? UISwitch }.forEach {
            $0.onTintColor = accent
        }
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

    private func updateModeHint() {
        pickLocalButton.isHidden = modeControl.selectedSegmentIndex != 2
        ipField.superview?.isHidden = modeControl.selectedSegmentIndex == 2
        switch modeControl.selectedSegmentIndex {
        case 1:
            modeHint.text = "数据线：插线信任，电脑开 MediaMTX+OBS+USB助手。"
        case 2:
            modeHint.text = "本地视频：选文件后，再手动打开「替换摄像头画面」。"
        default:
            modeHint.text = "局域网：手机和电脑同一 Wi‑Fi，只填电脑 IP。"
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
        blendHint.text = "OBS 画面 \(Int(blendSlider.value))% · 卡顿可关融合或降分辨率。"
    }

    private func refreshStatus() {
        monitorButton.setTitle(CamAudioRingMonitor.shared.statusLine, for: .normal)
        let store = CamFrameStore.shared
        titleLabel.text = store.width > 0
            ? "素材分辨率：\(store.width) × \(store.height)"
            : "素材分辨率：—"
        let cfg = MediaConfigStore.shared.config
        let clock = AVSyncClock.shared
        _ = clock.mediaTime()
        statusLabel.text = [
            "收帧 \(store.frameCount) · 音频包 \(CamAudioStore.shared.packetCount) · AU \(BXFloatMicAUPaintCount())",
            "画面：\(cfg.replaceCameraEnabled ? "开" : "关") · \(clock.avsyncPanelLine())",
            cfg.replaceCameraEnabled ? "运行中 · \(clock.actionPanelLabel())" : "替换未开（须手动打开才注入）",
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
        let interval: Int
        switch intervalControl.selectedSegmentIndex {
        case 0: interval = 30 * 60
        case 1: interval = 3600
        default: interval = 2 * 3600
        }
        let showSec = showControl.selectedSegmentIndex + 1
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
            cfg.blendOBSPercent = Int(blendSlider.value)
            cfg.timedRealCamera = timedOn
            cfg.timedRealIntervalSec = interval
            cfg.timedRealShowSec = showSec
            cfg.advancedExpanded = advancedExpanded
        }
        updateAdvancedChrome()
    }

    @objc private func modeChanged() { updateModeHint(); commit() }
    @objc private func ipEdited() {
        commit()
        FloatingOverlayController.restoreHostKeyWindow()
    }
    @objc private func cardBlankTapped() {
        endEditing(true)
        FloatingOverlayController.restoreHostKeyWindow()
    }
    @objc private func replaceChanged() { commit() }
    @objc private func audioChanged() { commit() }
    @objc private func blendChanged() { commit() }
    /// 拖动中只改文案，松手再 commit，避免拖一次 apply 几十次
    @objc private func blendSliderChanged() { updateAdvancedChrome() }
    @objc private func blendSliderCommitted() { updateAdvancedChrome(); commit() }
    @objc private func timedChanged() { CamReplacePolicy.resetCycle(); commit() }
    @objc private func timedParamsChanged() { CamReplacePolicy.resetCycle(); commit() }

    @objc private func pasteTapped() {
        let clip = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !clip.isEmpty {
            ipField.text = clip
            commit()
        }
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
        // 必须从抖音 keyWindow 的 VC present：从悬浮窗空 root 弹会 makeKey + 系统 dim，整屏变暗像卡死
        guard let host = presentationHost() else { return }
        let sheet = UIAlertController(title: "选择本地视频", message: nil, preferredStyle: .actionSheet)
        if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
            sheet.addAction(UIAlertAction(title: "相册", style: .default) { [weak self] _ in
                guard let self, let host = self.presentationHost() else { return }
                let picker = UIImagePickerController()
                picker.sourceType = .photoLibrary
                picker.mediaTypes = ["public.movie"]
                picker.delegate = self
                host.present(picker, animated: true)
            })
        }
        sheet.addAction(UIAlertAction(title: "文件", style: .default) { [weak self] _ in
            guard let self, let host = self.presentationHost() else { return }
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
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = pickLocalButton
            pop.sourceRect = pickLocalButton.bounds
        }
        host.present(sheet, animated: true)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        guard let url = info[.mediaURL] as? URL else { return }
        applyLocalURL(url)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
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

    /// 抖音前台 keyWindow 的顶层 VC；绝不返回悬浮窗自己的空 root。
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
