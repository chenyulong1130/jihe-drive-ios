import SwiftUI
import UIKit

/// 临时诊断：独立 UIWindow（层级高于键盘）显示窗口/宿主/内容的真实坐标。
/// 页面整块被挪走也不会消失；键盘收起后仍保留「弹起瞬间」的快照。
/// 定位完成后整份文件删除。
final class ProbeWindow {
    static let shared = ProbeWindow()

    private var window: UIWindow?
    private let label = UILabel()
    private var observers: [NSObjectProtocol] = []
    private var captured: [String] = []
    private var timer: Timer?

    func start() {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }

        let win = UIWindow(windowScene: scene)
        win.windowLevel = .alert + 1
        win.backgroundColor = .clear

        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 8, weight: .bold)
        label.textColor = .black
        label.backgroundColor = .yellow
        label.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: vc.view.trailingAnchor, constant: -6)
        ])
        win.rootViewController = vc
        win.isHidden = false
        window = win

        observeKeyboard()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        captured.removeAll()
        window?.isHidden = true
        window = nil
    }

    private func observeKeyboard() {
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidShowNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let kb = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
                self.capture("UP kbY\(Int(kb.minY))/\(Int(kb.height)) " + Self.snapshot())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.capture("UP2 " + Self.snapshot())
                }
            })
        }
    }

    private func capture(_ line: String) {
        captured.append(line)
        if captured.count > 3 { captured.removeFirst() }
        refresh()
    }

    private func refresh() {
        var lines = captured
        lines.append("NOW " + Self.snapshot())
        label.text = lines.joined(separator: "\n")
        label.sizeToFit()
    }

    /// W=窗口 y/h，H=宿主 y/h/底部安全区/顶部安全区，S=子视图数，C=最大子视图 y/h
    static func snapshot() -> String {
        var out: [String] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows {
                let cls = String(describing: type(of: w))
                if cls.contains("TextEffects") || cls.contains("Keyboard") { continue }
                guard let root = w.rootViewController else { continue }
                let host = root.view!
                let big = host.subviews.max { $0.frame.height < $1.frame.height }
                out.append("W\(Int(w.frame.minY))/\(Int(w.frame.height))")
                out.append("H\(Int(host.frame.minY))/\(Int(host.frame.height))/\(Int(host.safeAreaInsets.bottom))/\(Int(host.safeAreaInsets.top))")
                out.append("S\(host.subviews.count)")
                if let big {
                    out.append("C[\(String(describing: type(of: big)).prefix(12)) \(Int(big.frame.minY))/\(Int(big.frame.height))]")
                }
            }
        }
        return out.joined(separator: " ")
    }
}

/// 登录页挂这个视图即启用诊断窗口。
struct LoginProbe: View {
    var body: some View {
        Color.clear
            .onAppear { ProbeWindow.shared.start() }
            .onDisappear { ProbeWindow.shared.stop() }
    }
}
