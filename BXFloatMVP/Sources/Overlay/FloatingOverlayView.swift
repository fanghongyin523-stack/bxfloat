import UIKit

protocol FloatingOverlayViewDelegate: AnyObject {
    func floatingOverlayDidRequestClose(_ view: FloatingOverlayView)
    func floatingOverlayDidRequestTogglePlay(_ view: FloatingOverlayView)
}

/// 对标 BXPreviewPassthroughView：可拖拽悬浮预览壳，内容区交给播放器 view。
final class FloatingOverlayView: UIView {
    weak var delegate: FloatingOverlayViewDelegate?

    private let chrome = UIView()
    private let contentHost = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let resizeHandle = UIView()

    private var playerView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPlayerView(_ view: UIView?) {
        playerView?.removeFromSuperview()
        playerView = view
        guard let view else { return }
        contentHost.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
    }

    func setPlaying(_ playing: Bool) {
        playButton.setTitle(playing ? "暂停" : "播放", for: .normal)
    }

    private func setup() {
        backgroundColor = .clear
        layer.cornerRadius = 12
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor

        chrome.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        contentHost.backgroundColor = .black

        titleLabel.text = "BXFloat"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        playButton.setTitle("播放", for: .normal)
        playButton.setTitleColor(.white, for: .normal)
        playButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)

        resizeHandle.backgroundColor = UIColor.white.withAlphaComponent(0.55)
        resizeHandle.layer.cornerRadius = 2

        addSubview(contentHost)
        addSubview(chrome)
        chrome.addSubview(titleLabel)
        chrome.addSubview(playButton)
        chrome.addSubview(closeButton)
        addSubview(resizeHandle)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        chrome.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        playButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: topAnchor),
            chrome.leadingAnchor.constraint(equalTo: leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: trailingAnchor),
            chrome.heightAnchor.constraint(equalToConstant: 36),

            contentHost.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: chrome.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: chrome.centerYAnchor),

            playButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -12),
            playButton.centerYAnchor.constraint(equalTo: chrome.centerYAnchor),

            resizeHandle.widthAnchor.constraint(equalToConstant: 28),
            resizeHandle.heightAnchor.constraint(equalToConstant: 4),
            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        chrome.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
    }

    @objc private func closeTapped() {
        delegate?.floatingOverlayDidRequestClose(self)
    }

    @objc private func playTapped() {
        delegate?.floatingOverlayDidRequestTogglePlay(self)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }
        let translation = gesture.translation(in: superview)
        center = CGPoint(x: center.x + translation.x, y: center.y + translation.y)
        gesture.setTranslation(.zero, in: superview)
        keepInsideSuperview()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .ended else { return }
        let minSide: CGFloat = 140
        let maxSide = (superview?.bounds.width ?? 400) * 0.95
        var next = bounds.size
        next.width = min(max(next.width * gesture.scale, minSide), maxSide)
        next.height = next.width * 0.75
        bounds.size = next
        gesture.scale = 1
        keepInsideSuperview()
        setNeedsLayout()
    }

    private func keepInsideSuperview() {
        guard let superview else { return }
        var f = frame
        f.origin.x = min(max(f.origin.x, 8), superview.bounds.width - f.width - 8)
        f.origin.y = min(max(f.origin.y, 48), superview.bounds.height - f.height - 8)
        frame = f
    }
}
