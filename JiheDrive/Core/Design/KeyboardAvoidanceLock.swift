import UIKit

/// 登录时关掉窗口宿主的键盘安全区，登入后再打开。
enum KeyboardAvoidance {
    static func setKeyboardRegion(_ enabled: Bool) {
        let raw: UInt = enabled ? 3 : 1
        func walk(_ vc: UIViewController?) {
            guard let vc else { return }
            apply(raw, to: vc)
            vc.children.forEach { walk($0) }
            walk(vc.presentedViewController)
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                walk(window.rootViewController)
                window.frame.origin = .zero
            }
        }
    }

    private static func apply(_ raw: UInt, to vc: UIViewController) {
        let sel = NSSelectorFromString("setSafeAreaRegions:")
        guard vc.responds(to: sel), let imp = vc.method(for: sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(imp, to: Setter.self)(vc, sel, raw)
        vc.additionalSafeAreaInsets.bottom = 0
    }
}
