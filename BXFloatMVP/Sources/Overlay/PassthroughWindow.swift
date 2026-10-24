import UIKit

/// 只有点到子视图（悬浮窗）才接管触摸，空白处穿透到下面的主界面。
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if hit === self || hit === rootViewController?.view {
            return nil
        }
        return hit
    }
}

final class PassthroughRootView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self {
            return nil
        }
        return hit
    }
}
