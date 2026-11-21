import SwiftUI
import UIKit

extension View {
    /// 登录页专用：不让键盘把整页顶出屏幕。
    func locksKeyboardAvoidance() -> some View {
        background(KeyboardAvoidanceLock())
            .ignoresSafeArea(.keyboard)
    }
}

private struct KeyboardAvoidanceLock: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> LockController {
        LockController()
    }

    func updateUIViewController(_ uiViewController: LockController, context: Context) {}
}

final class LockController: UIViewController {
    private var observers: [NSObjectProtocol] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.pin()
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        pin()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pin()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        pin()
    }

    private func pin() {
        var node: UIViewController? = self
        while let current = node {
            current.additionalSafeAreaInsets.bottom = 0
            disableKeyboardRegion(on: current)
            reset(current.view)
            reset(current.parent?.view)
            node = current.parent
        }
        if let window = view.window {
            window.frame.origin = .zero
            reset(window.rootViewController?.view)
        }
    }

    private func disableKeyboardRegion(on vc: UIViewController) {
        // UIHostingController.safeAreaRegions（iOS 16.4+），普通 VC 没有这个属性
        let sel = NSSelectorFromString("setSafeAreaRegions:")
        guard vc.responds(to: sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        let imp = class_getMethodImplementation(object_getClass(vc), sel)
        guard let imp else { return }
        let setter = unsafeBitCast(imp, to: Setter.self)
        // UISafeAreaRegions.container == 1，去掉 .keyboard
        setter(vc, sel, 1)
    }

    private func reset(_ view: UIView?) {
        guard let view else { return }
        if view.transform != .identity {
            view.transform = .identity
        }
        if abs(view.frame.origin.y) > 0.5 {
            view.layer.removeAllAnimations()
            view.frame.origin.y = 0
        }
    }
}
