import SwiftUI
import UIKit

extension View {
    /// 登录页：从窗口根上关掉键盘安全区，并在键盘弹出期间钉住整页，避免被顶出屏幕。
    func locksKeyboardAvoidance() -> some View {
        background(KeyboardAvoidanceLock())
            .ignoresSafeArea(.keyboard)
    }
}

enum KeyboardAvoidance {
    static func install() {
        pin()
    }

    static func pin() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.frame.origin = .zero
                if let root = window.rootViewController {
                    walkController(root)
                }
                walkView(window, windowBounds: window.bounds)
            }
        }
    }

    private static func walkController(_ vc: UIViewController) {
        vc.additionalSafeAreaInsets.bottom = 0
        disableKeyboardRegion(on: vc)
        for child in vc.children {
            walkController(child)
        }
        if let presented = vc.presentedViewController {
            walkController(presented)
        }
    }

    private static func disableKeyboardRegion(on vc: UIViewController) {
        let sel = NSSelectorFromString("setSafeAreaRegions:")
        guard vc.responds(to: sel), let imp = vc.method(for: sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(imp, to: Setter.self)(vc, sel, 1)
    }

    private static func walkView(_ view: UIView, windowBounds: CGRect) {
        let fullWidth = view.bounds.width >= windowBounds.width - 2
        let tall = view.bounds.height >= windowBounds.height * 0.55
        if fullWidth && tall {
            if view.transform != .identity {
                view.transform = .identity
            }
            if abs(view.frame.origin.y) > 0.5 {
                view.layer.removeAllAnimations()
                view.frame.origin.y = 0
            }
        }
        for sub in view.subviews {
            walkView(sub, windowBounds: windowBounds)
        }
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
    private var link: CADisplayLink?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear

        let center = NotificationCenter.default
        let startNames: [Notification.Name] = [
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardDidChangeFrameNotification,
        ]
        for name in startNames {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if Self.keyboardOverlaps(note) {
                    self?.startLink()
                } else {
                    self?.stopLink()
                }
                KeyboardAvoidance.pin()
            })
        }
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopLink()
            KeyboardAvoidance.pin()
        })
    }

    deinit {
        stopLink()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        KeyboardAvoidance.pin()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        KeyboardAvoidance.install()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopLink()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        KeyboardAvoidance.pin()
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        KeyboardAvoidance.pin()
    }

    private static func keyboardOverlaps(_ note: Notification) -> Bool {
        guard
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return true }
        let screen = UIScreen.main.bounds
        return frame.minY < screen.maxY - 1
    }
}
