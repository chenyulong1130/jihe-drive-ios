import SwiftUI
import UIKit

enum KeyboardAvoidance {
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    static func setLoginMode(_ login: Bool) {
        let raw: UInt = login ? 1 : 3
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.rootViewController != nil {
                if login, window.frame.origin != .zero {
                    window.frame.origin = .zero
                }
                walk(window.rootViewController, raw: raw, resetFrame: login)
            }
        }
    }

    static func recoverLogin() {
        dismiss()
        setLoginMode(true)
    }

    private static func walk(_ vc: UIViewController?, raw: UInt, resetFrame: Bool) {
        guard let vc else { return }
        if vc.additionalSafeAreaInsets.bottom != 0 {
            vc.additionalSafeAreaInsets.bottom = 0
        }
        apply(raw, to: vc)
        if resetFrame, let view = vc.viewIfLoaded {
            if view.transform != .identity {
                view.transform = .identity
            }
            if abs(view.frame.origin.y) > 0.5 {
                view.layer.removeAllAnimations()
                view.frame.origin.y = 0
            }
        }
        vc.children.forEach { walk($0, raw: raw, resetFrame: resetFrame) }
        walk(vc.presentedViewController, raw: raw, resetFrame: resetFrame)
    }

    private static func apply(_ raw: UInt, to vc: UIViewController) {
        let sel = NSSelectorFromString("setSafeAreaRegions:")
        guard vc.responds(to: sel), let imp = vc.method(for: sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(imp, to: Setter.self)(vc, sel, raw)
    }
}

struct KeyboardAvoidanceGate: UIViewControllerRepresentable {
    var loginMode: Bool

    func makeUIViewController(context: Context) -> GateController {
        GateController()
    }

    func updateUIViewController(_ vc: GateController, context: Context) {
        vc.loginMode = loginMode
        vc.apply()
    }
}

final class GateController: UIViewController {
    var loginMode = true
    private var link: CADisplayLink?
    private var observers: [NSObjectProtocol] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIApplication.willResignActiveNotification,
            UIApplication.didBecomeActiveNotification,
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillHideNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.handle(note)
            })
        }
    }

    deinit {
        link?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        apply()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        apply()
        startPinningIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPinning()
    }

    func apply() {
        KeyboardAvoidance.setLoginMode(loginMode)
        if loginMode {
            startPinningIfNeeded()
        } else {
            stopPinning()
        }
    }

    private func handle(_ note: Notification) {
        guard loginMode else { return }
        switch note.name {
        case UIApplication.willResignActiveNotification:
            KeyboardAvoidance.dismiss()
        case UIApplication.didBecomeActiveNotification:
            KeyboardAvoidance.recoverLogin()
        default:
            KeyboardAvoidance.setLoginMode(true)
        }
    }

    private func startPinningIfNeeded() {
        guard loginMode, link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopPinning() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        guard loginMode else { return }
        KeyboardAvoidance.setLoginMode(true)
    }
}

extension View {
    func keyboardAvoidanceLogin(_ login: Bool) -> some View {
        background(KeyboardAvoidanceGate(loginMode: login))
            .ignoresSafeArea(login ? .keyboard : [])
    }
}
