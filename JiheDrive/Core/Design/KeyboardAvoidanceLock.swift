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
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pin()
        })
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pin()
        })
        observers.append(center.addObserver(
            forName: UIResponder.keyboardDidShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pin()
        })
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
            if #available(iOS 16.4, *) {
                current.safeAreaRegions = .container
            }
            reset(current.view)
            if let parentView = current.parent?.view {
                reset(parentView)
            }
            node = current.parent
        }
        if let window = view.window {
            window.frame.origin = .zero
            reset(window.rootViewController?.view)
        }
    }

    private func reset(_ view: UIView?) {
        guard let view else { return }
        if view.transform != .identity {
            view.transform = .identity
        }
        if abs(view.frame.origin.y) > 0.5 {
            view.frame.origin.y = 0
        }
        if let layerY = view.layer.presentation()?.frame.origin.y, abs(layerY) > 0.5 {
            view.layer.removeAllAnimations()
            view.frame.origin.y = 0
        }
    }
}
