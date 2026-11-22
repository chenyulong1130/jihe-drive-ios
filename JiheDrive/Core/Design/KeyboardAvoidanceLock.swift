import SwiftUI
import UIKit

/// 登录页关掉 SwiftUI 宿主的键盘安全区，避免整页被压成空视图。
///
/// 29 号包能用，是因为它只改 UIHostingController，绝不去碰键盘自己的窗口。
/// 后来几版用 CADisplayLink / 延迟 removeAllAnimations 去「钉」所有窗口，
/// 键盘弹起后宿主视图高度被改成 0，或者渲染动画被清掉，看起来就是整页没了。
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

    static func applyLoginLock() {
        applyAll(raw: 1)
        pinHostWindows()
    }

    /// 只挑 SwiftUI 宿主窗口。键盘的 UITextEffectsWindow / UIRemoteKeyboardWindow
    /// 也有 rootViewController，改它们的 frame 或底色会把整页盖住。
    private static func hostingWindows() -> [UIWindow] {
        var result: [UIWindow] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where isHostingWindow(window) {
                result.append(window)
            }
        }
        return result
    }

    static func isHostingWindow(_ window: UIWindow) -> Bool {
        if isSystemOverlayWindow(window) { return false }
        let sel = NSSelectorFromString("setSafeAreaRegions:")
        return window.rootViewController?.responds(to: sel) == true
    }

    static func isSystemOverlayWindow(_ window: UIWindow) -> Bool {
        let name = NSStringFromClass(type(of: window))
        return name.contains("TextEffects")
            || name.contains("Keyboard")
            || name.contains("RemoteKeyboard")
            || name.contains("InputSet")
            || name.contains("Prediction")
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
            if window.frame.origin != .zero {
                window.frame.origin = .zero
            }
        }
    }

    private static func apply(_ raw: UInt, to vc: UIViewController) {
        let sel = NSSelectorFromString("setSafeAreaRegions:")
        guard vc.responds(to: sel), let imp = vc.method(for: sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(imp, to: Setter.self)(vc, sel, raw)
        if vc.additionalSafeAreaInsets.bottom != 0 {
            vc.additionalSafeAreaInsets.bottom = 0
        }
    }

    private static func pinHostWindows() {
        for window in hostingWindows() {
            if window.frame.origin != .zero {
                window.frame.origin = .zero
            }
            guard let view = window.rootViewController?.view else { continue }
            if view.transform != .identity {
                view.transform = .identity
            }
            if view.frame.origin.y < -0.5 {
                view.frame.origin.y = 0
            }
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
                pinHostWindows()
            })
        }
    }

    private static func removeObservers() {
        guard !observers.isEmpty else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}

extension View {
    /// 登录页挂一个不可见探针：键盘改安全区时再关掉一次 keyboard region。
    func locksKeyboardAvoidance() -> some View {
        background(KeyboardAvoidanceProbe())
            .ignoresSafeArea(.keyboard)
    }
}

private struct KeyboardAvoidanceProbe: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> KeyboardAvoidanceProbeController {
        KeyboardAvoidanceProbeController()
    }

    func updateUIViewController(_ uiViewController: KeyboardAvoidanceProbeController, context: Context) {}
}

final class KeyboardAvoidanceProbeController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        KeyboardAvoidance.applyLoginLock()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        KeyboardAvoidance.applyLoginLock()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        KeyboardAvoidance.applyLoginLock()
    }
}
