import UIKit

/// 登录时关掉窗口宿主的键盘安全区，登入后再打开。
/// 实测只在 onAppear 调一次 setSafeAreaRegions 不够：键盘弹出时系统仍会把宿主视图整体上移，
/// 所以在"关闭"状态下监听键盘通知，把被顶起来的视图实时按回去；登入后解除监听。
/// 注意只处理 SwiftUI 宿主窗口，绝不碰键盘自己的 UITextEffectsWindow / UITextLayoutWindow。
enum KeyboardAvoidance {
    private static var enabled = true
    private static var observers: [NSObjectProtocol] = []

    static func setKeyboardRegion(_ enabled: Bool) {
        self.enabled = enabled
        applyAll(raw: enabled ? 3 : 1)
        if enabled {
            removeObservers()
        } else {
            installObservers()
        }
    }

    // MARK: - 私有

    /// 只挑 SwiftUI 宿主窗口：rootViewController 响应 setSafeAreaRegions（即 UIHostingController）。
    private static func hostingWindows() -> [UIWindow] {
        var result: [UIWindow] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                let sel = NSSelectorFromString("setSafeAreaRegions:")
                if let root = window.rootViewController, root.responds(to: sel) {
                    result.append(window)
                }
            }
        }
        return result
    }

    private static func applyAll(raw: UInt) {
        func walk(_ vc: UIViewController?) {
            guard let vc else { return }
            apply(raw, to: vc)
            vc.children.forEach { walk($0) }
            walk(vc.presentedViewController)
        }
        for window in hostingWindows() {
            walk(window.rootViewController)
            window.frame.origin = .zero
        }
    }

    private static func apply(_ raw: UInt, to vc: UIViewController) {
        let sel = NSSelectorFromString("setSafeAreaRegions:")
        guard vc.responds(to: sel), let imp = vc.method(for: sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(imp, to: Setter.self)(vc, sel, raw)
        vc.additionalSafeAreaInsets.bottom = 0
    }

    /// 键盘通知兜底：系统把视图顶上去之后立刻归位（只处理被顶成负偏移的根视图，不碰正常布局）。
    private static func pinLiftedViews() {
        for window in hostingWindows() {
            window.frame.origin = .zero
            reset(window.rootViewController?.view)
            var stack: [UIViewController] = []
            if let root = window.rootViewController { stack.append(root) }
            while let vc = stack.popLast() {
                reset(vc.view)
                stack.append(contentsOf: vc.children)
                if let presented = vc.presentedViewController { stack.append(presented) }
            }
        }
    }

    private static func reset(_ view: UIView?) {
        guard let view else { return }
        if view.transform != .identity { view.transform = .identity }
        if view.frame.origin.y < -0.5 {
            view.layer.removeAllAnimations()
            view.frame.origin.y = 0
        }
    }

    private static func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                guard !enabled else { return }
                applyAll(raw: 1)
                pinLiftedViews()
                // 弹簧动画收尾后系统可能再抬一次，延迟补两针
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard enabled else { return }
                    pinLiftedViews()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard enabled else { return }
                    pinLiftedViews()
                }
            })
        }
    }

    private static func removeObservers() {
        guard !observers.isEmpty else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}
