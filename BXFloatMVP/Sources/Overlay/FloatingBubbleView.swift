import UIKit

protocol FloatingBubbleViewDelegate: AnyObject {
    func floatingBubbleDidTap(_ bubble: FloatingBubbleView)
    func floatingBubbleDidRequestClose(_ bubble: FloatingBubbleView)
}

/// 收起后的悬浮球：不播画面，只占位；点一下打开设置面板。
final class FloatingBubbleView: UIView {
    weak var delegate: FloatingBubbleViewDelegate?

    private let label = UILabel()
    private let closeButton = UIButton(type: .system)
    private var replaceDot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func setReplaceActive(_ on: Bool) {
        replaceDot.isHidden = !on
    }

    private func setup() {
        backgroundColor = UIColor(red: 0.12, green: 0.78, blue: 0.38, alpha: 0.95)
        layer.cornerRadius = 28
        layer.masksToBounds = true
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor

        label.text = "BX"
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .bold)
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        addSubview(label)

        replaceDot.backgroundColor = UIColor(red: 1, green: 0.35, blue: 0.2, alpha: 1)
        replaceDot.layer.cornerRadius = 4
        replaceDot.isHidden = true
        addSubview(replaceDot)

        closeButton.setTitle("×", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        closeButton.layer.cornerRadius = 10
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
        label.frame = bounds
        replaceDot.frame = CGRect(x: bounds.width - 14, y: 6, width: 8, height: 8)
        closeButton.frame = CGRect(x: -2, y: -2, width: 20, height: 20)
    }

    @objc private func tapped() {
        delegate?.floatingBubbleDidTap(self)
    }

    @objc private func closeTapped() {
        delegate?.floatingBubbleDidRequestClose(self)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }
        let t = gesture.translation(in: superview)
        center = CGPoint(x: center.x + t.x, y: center.y + t.y)
        gesture.setTranslation(.zero, in: superview)
        var f = frame
        f.origin.x = min(max(f.origin.x, 4), superview.bounds.width - f.width - 4)
        f.origin.y = min(max(f.origin.y, 48), superview.bounds.height - f.height - 4)
        frame = f
    }
}
