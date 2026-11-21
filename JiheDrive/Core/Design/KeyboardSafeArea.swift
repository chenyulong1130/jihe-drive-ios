import SwiftUI
import UIKit
import ObjectiveC

extension View {
    /// 登录页关掉系统键盘避让，避免输入框被整页顶出屏幕。
    func ignoringKeyboardSafeArea() -> some View {
        background(KeyboardSafeAreaStripper())
    }
}

private struct KeyboardSafeAreaStripper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> KeyboardSafeAreaController {
        KeyboardSafeAreaController()
    }

    func updateUIViewController(_ uiViewController: KeyboardSafeAreaController, context: Context) {}
}

final class KeyboardSafeAreaController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        apply(strip: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        apply(strip: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        apply(strip: false)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        apply(strip: true)
    }

    private func apply(strip: Bool) {
        var current: UIViewController? = parent
        while let vc = current {
            vc.additionalSafeAreaInsets.bottom = 0
            Self.setKeyboardRegion(vc, enabled: !strip)
            current = vc.parent
        }
        if strip, let window = viewIfLoaded?.window {
            window.frame.origin.y = 0
        }
    }

    private static func setKeyboardRegion(_ vc: UIViewController, enabled: Bool) {
        let sel = NSSelectorFromString("setSafeAreaRegions:")
        guard vc.responds(to: sel),
              let method = class_getInstanceMethod(object_getClass(vc), sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        let setter = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        let container: UInt = 1
        let keyboard: UInt = 2
        setter(vc, sel, enabled ? container | keyboard : container)
    }
}
