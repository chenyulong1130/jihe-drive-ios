import SwiftUI
import UIKit

/// 登录时关掉窗口宿主的键盘安全区，登入后再打开。
enum KeyboardAvoidance {
    static weak var host: UIViewController?

    static func setKeyboardRegion(_ enabled: Bool) {
        let raw: UInt = enabled ? 3 : 1
        func walk(_ vc: UIViewController?) {
            guard let vc else { return }
            apply(raw, to: vc)
            vc.children.forEach { walk($0) }
            walk(vc.presentedViewController)
        }
        walk(host)
        walk(host?.parent)
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

final class LockedHosting: UIHostingController<RootView> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.067, green: 0.094, blue: 0.145, alpha: 1)
                : UIColor(red: 0.933, green: 0.945, blue: 0.961, alpha: 1)
        }
        if #available(iOS 16.4, *) {
            safeAreaRegions = .container
        }
        KeyboardAvoidance.host = self
        KeyboardAvoidance.setKeyboardRegion(false)
    }
}
