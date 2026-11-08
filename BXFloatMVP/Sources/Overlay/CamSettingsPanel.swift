import UIKit
import UniformTypeIdentifiers
import MobileCoreServices

protocol CamSettingsPanelDelegate: AnyObject {
    func camSettingsPanelDidCollapse(_ panel: CamSettingsPanel)
}

/// 目标面板功能结构（照片）+ 苹果原生深灰中间档通透视觉；替换默认关。
final class CamSettingsPanel: UIView, UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    weak var delegate: CamSettingsPanelDelegate?

    private let dim = UIView()
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
    private let scroll = UIScrollView()
    private let content = UIView()

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

    private var advancedExpanded = true

    /// 苹果质感：深灰偏浅黑 + 中间档透明度
    private let accent = UIColor.label
    private let cardFill = UIColor(white: 0.18, alpha: 0.82)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        reloadFromStore()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

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
        advancedExpanded = cfg.advancedExpanded
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
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        addSubview(dim)
        dim.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: topAnchor),
            dim.bottomAnchor.constraint(equalTo: bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        let bgTap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        bgTap.cancelsTouchesInView = false
        dim.addGestureRecognizer(bgTap)

        card.layer.cornerRadius = 14
        card.clipsToBounds = true
        card.contentView.backgroundColor = cardFill
        addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.86),
        ])

        scroll.alwaysBounceVertical = true
        card.contentView.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
        ])
        scroll.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.text = "素材分辨率：—"

        styleSegment(modeControl)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeHint.font = .systemFont(ofSize: 11)
        modeHint.textColor = .secondaryLabel
        modeHint.numberOfLines = 0

        styleField(ipField, placeholder: "电脑 IP，例如 192.168.1.191")
        ipField.keyboardType = .decimalPad
        ipField.addTarget(self, action: #selector(ipEdited), for: .editingDidEnd)
        styleFilledButton(pasteButton, title: "粘贴")
        pasteButton.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)
        styleFilledButton(pickLocalButton, title: "选视频")
        pickLocalButton.addTarget(self, action: #selector(pickLocalTapped), for: .touchUpInside)

        replaceLabel.text = "替换摄像头画面"
        replaceLabel.font = .systemFont(ofSize: 15, weight: .medium)
        replaceLabel.textColor = .label
        replaceSwitch.addTarget(self, action: #selector(replaceChanged), for: .valueChanged)
        replaceRow.axis = .horizontal
        replaceRow.alignment = .center
        replaceRow.addArrangedSubview(replaceLabel)
        replaceRow.addArrangedSubview(UIView())
        replaceRow.addArrangedSubview(replaceSwitch)

        audioLabel.text = "直播麦声音"
        audioLabel.font = .systemFont(ofSize: 15, weight: .medium)
        audioLabel.textColor = .label
        styleSegment(audioControl)
        audioControl.addTarget(self, action: #selector(audioChanged), for: .valueChanged)

        advancedToggle.contentHorizontalAlignment = .left
        advancedToggle.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        advancedToggle.setTitleColor(.systemGreen, for: .normal)
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

        blendRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.addTarget(
            self, action: #selector(blendChanged), for: .valueChanged
        )
        blendSlider.minimumValue = 10
        blendSlider.maximumValue = 100
        blendSlider.addTarget(self, action: #selector(blendSliderChanged), for: .valueChanged)
        blendHint.font = .systemFont(ofSize: 11)
        blendHint.textColor = .secondaryLabel
        blendHint.numberOfLines = 0
        blendHint.text = "将显示真实摄像头；若卡顿请关闭融合或降低分辨率。"

        timedRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.addTarget(
            self, action: #selector(timedChanged), for: .valueChanged
        )
        styleSegment(intervalControl)
        styleSegment(showControl)
        intervalControl.addTarget(self, action: #selector(timedParamsChanged), for: .valueChanged)
        showControl.addTarget(self, action: #selector(timedParamsChanged), for: .valueChanged)
        timedHint.font = .systemFont(ofSize: 11)
        timedHint.textColor = .systemOrange
        timedHint.numberOfLines = 0
        timedHint.text = "重要：将全屏显示真实镜头；内录音频会同步切换为现场声。"

        [orient, blendRow, makeCaption("OBS 画面"), blendSlider, blendHint,
         timedRow, makeCaption("每隔"), intervalControl, makeCaption("显示"), showControl, timedHint]
            .forEach { advancedBox.addArrangedSubview($0) }

        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        styleOutlineButton(logButton, title: "查看运行诊断日志")
        logButton.addTarget(self, action: #selector(copyLogTapped), for: .touchUpInside)
        styleOutlineButton(monitorButton, title: "听:关")
        monitorButton.addTarget(self, action: #selector(monitorTapped), for: .touchUpInside)
        collapseButton.setTitle("收起设置 · 回到悬浮球", for: .normal)
        collapseButton.setTitleColor(.systemGreen, for: .normal)
        collapseButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        collapseButton.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, modeControl, modeHint,
            makeIPRow(), pickLocalButton,
            replaceRow, audioLabel, audioControl,
            advancedToggle, advancedBox,
            statusLabel, logButton,
            makeBottomRow(),
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

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStatus()
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

    private func makeBottomRow() -> UIView {
        let row = UIStackView(arrangedSubviews: [collapseButton, UIView(), monitorButton])
        row.axis = .horizontal
        row.alignment = .center
        monitorButton.widthAnchor.constraint(equalToConstant: 56).isActive = true
        return row
    }

    private static func makeSwitchRow(title: String) -> UIStackView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .label
        let sw = UISwitch()
        let row = UIStackView(arrangedSubviews: [label, UIView(), sw])
        row.axis = .horizontal
        row.alignment = .center
        return row
    }

    private func makeCaption(_ t: String) -> UILabel {
        let l = UILabel()
        l.text = t
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .secondaryLabel
        return l
    }

    private func styleSegment(_ c: UISegmentedControl) {
        if #available(iOS 13.0, *) {
            c.selectedSegmentTintColor = UIColor.tertiarySystemFill
        }
    }

    private func styleField(_ f: UITextField, placeholder: String) {
        f.backgroundColor = UIColor.tertiarySystemFill
        f.textColor = .label
        f.font = .systemFont(ofSize: 15)
        f.layer.cornerRadius = 8
        f.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        f.leftViewMode = .always
        f.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor.placeholderText]
        )
        f.autocapitalizationType = .none
    }

    private func styleFilledButton(_ b: UIButton, title: String) {
        b.setTitle(title, for: .normal)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = UIColor.tertiarySystemFill
        b.layer.cornerRadius = 8
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
    }

    private func styleOutlineButton(_ b: UIButton, title: String) {
        b.setTitle(title, for: .normal)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = UIColor.tertiarySystemFill
        b.layer.cornerRadius = 8
        b.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    }

    private func updateModeHint() {
        pickLocalButton.isHidden = modeControl.selectedSegmentIndex != 2
        ipField.isHidden = modeControl.selectedSegmentIndex == 2
        pasteButton.isHidden = modeControl.selectedSegmentIndex == 2
        switch modeControl.selectedSegmentIndex {
        case 1:
            modeHint.text = "数据线：插线信任，电脑开 MediaMTX+OBS+USB助手；自研隧道到本机 RTSP（对标 USB 进画目标）。"
        case 2:
            modeHint.text = "本地视频：从相册或文件选择后，开「替换摄像头画面」即可注入。"
        default:
            modeHint.text = "局域网：手机和电脑连同一 Wi‑Fi，只填电脑 IP，地址自动保存。"
        }
    }

    private func updateAdvancedChrome() {
        advancedBox.isHidden = !advancedExpanded
        let blendOn = blendRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.isOn == true
        let timedOn = timedRow.arrangedSubviews.compactMap { $0 as? UISwitch }.first?.isOn == true
        let summary = [
            advancedExpanded ? "收起设置" : "展开设置",
            blendOn ? "融合已开" : "融合已关",
            timedOn ? "定时已开" : "定时已关",
        ].joined(separator: " · ")
        advancedToggle.setTitle(summary, for: .normal)
        let pct = Int(blendSlider.value)
        blendHint.text = "OBS 画面 \(pct)% · 将显示真实摄像头；若卡顿请关闭融合或降低分辨率。"
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
        let age = Date().timeIntervalSince(store.lastUpdate)
        let ageText = store.frameCount == 0 ? "暂无数据" : String(format: "%.1fs前", age)
        let fpsHint = store.frameCount == 0 ? "0.0" : String(format: "%.1f", min(30, 1.0 / max(0.033, age)))
        statusLabel.text = [
            "接收 \(fpsHint) 帧/秒 · 送出 \(CameraReplaceHooks.paintCount) · 更新 \(ageText)",
            "当前延迟 \(String(format: "%.1f", clock.latencySeconds()))s · \(clock.avsyncPanelLine())",
            "画面：\(cfg.replaceCameraEnabled ? "开" : "关") · 麦：\(cfg.audioCaptureMode.rawValue) · AU \(BXFloatMicAUPaintCount())",
            CamPipelineDiag.shared.paintGatePanelLine(),
            cfg.replaceCameraEnabled ? "运行中 · \(clock.actionPanelLabel())" : "替换未开：真机画面（须手开才注入）",
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
    @objc private func ipEdited() { commit() }
    @objc private func replaceChanged() { commit() }
    @objc private func audioChanged() { commit() }
    @objc private func blendChanged() { commit() }
    @objc private func blendSliderChanged() { updateAdvancedChrome(); commit() }
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
        MediaConfigStore.shared.update { cfg in
            cfg.mirrored.toggle()
        }
        mirrorButton.isSelected = MediaConfigStore.shared.config.mirrored
    }

    @objc private func advancedTapped() {
        advancedExpanded.toggle()
        updateAdvancedChrome()
        commit()
    }

    @objc private func pickLocalTapped() {
        guard let host = parentViewController() else { return }
        let sheet = UIAlertController(title: "选择本地视频", message: nil, preferredStyle: .actionSheet)
        if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
            sheet.addAction(UIAlertAction(title: "相册", style: .default) { [weak self] _ in
                let picker = UIImagePickerController()
                picker.sourceType = .photoLibrary
                picker.mediaTypes = ["public.movie"]
                picker.delegate = self
                host.present(picker, animated: true)
                _ = self
            })
        }
        sheet.addAction(UIAlertAction(title: "文件", style: .default) { [weak self] _ in
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
            _ = self
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
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

    private func applyLocalURL(_ url: URL) {
        MediaConfigStore.shared.update { cfg in
            cfg.connectionMode = .localVideo
            cfg.streamURL = url.path
        }
        modeControl.selectedSegmentIndex = 2
        updateModeHint()
        commit()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        _ = url.startAccessingSecurityScopedResource()
        applyLocalURL(url)
    }

    @objc private func collapseTapped() {
        commit()
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
        logButton.setTitle("已复制诊断日志", for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.logButton.setTitle("查看运行诊断日志", for: .normal)
        }
    }

    @objc private func backgroundTapped(_ g: UITapGestureRecognizer) {
        endEditing(true)
    }

    private func parentViewController() -> UIViewController? {
        var r: UIResponder? = self
        while let cur = r {
            if let vc = cur as? UIViewController { return vc }
            r = cur.next
        }
        return nil
    }
}
