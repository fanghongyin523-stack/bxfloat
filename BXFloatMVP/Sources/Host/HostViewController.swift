import UIKit

/// 巨魔可安装的「注入试验壳」：本身无悬浮窗，专供注入器列表里选中。
final class HostViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.08, green: 0.1, blue: 0.14, alpha: 1)

        let title = UILabel()
        title.text = "BXFloat 注入壳"
        title.textColor = .white
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textAlignment = .center

        let body = UILabel()
        body.text = """
        这个 App 是给巨魔注入器用的试验靶。

        1. 用巨魔安装本 App
        2. 打开注入器，应能看到「BXFloat壳」
        3. 把 BXFloatInject.dylib 注入进来
        4. 划掉本 App 再打开
        5. 几秒内应出现悬浮窗

        说明：系统 Safari 往往不在注入器列表里，所以改用本壳测试。
        """
        body.textColor = .secondaryLabel
        body.font = .systemFont(ofSize: 15)
        body.numberOfLines = 0
        body.textAlignment = .left

        let bid = UILabel()
        bid.text = "Bundle ID:\ncom.baixiang.bxfloat.host"
        bid.textColor = UIColor(white: 0.7, alpha: 1)
        bid.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        bid.numberOfLines = 0
        bid.textAlignment = .center

        let testButton = UIButton(type: .system)
        testButton.setTitle("点我测试：宿主还能不能点", for: .normal)
        testButton.setTitleColor(.white, for: .normal)
        testButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        testButton.backgroundColor = UIColor(red: 0.2, green: 0.55, blue: 0.95, alpha: 1)
        testButton.layer.cornerRadius = 10
        testButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        testButton.addTarget(self, action: #selector(testHostTap), for: .touchUpInside)

        let tip = UILabel()
        tip.text = "上面这段是说明文字，本身不可点。请点蓝色按钮测穿透。"
        tip.textColor = .tertiaryLabel
        tip.font = .systemFont(ofSize: 13)
        tip.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, body, testButton, tip, bid])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func testHostTap() {
        let alert = UIAlertController(
            title: "穿透正常",
            message: "能弹出这个提示，说明悬浮窗没有挡住宿主按钮。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
