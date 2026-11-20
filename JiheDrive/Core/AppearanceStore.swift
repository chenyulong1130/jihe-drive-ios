import SwiftUI
import UIKit

/// 外观模式：跟随系统 / 始终浅色 / 始终深色
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

@MainActor
final class AppearanceStore: ObservableObject {
    @Published var mode: AppAppearance {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            refreshResolved()
        }
    }

    /// 实际套到界面上的浅/深，永远不是 nil。
    /// 「跟随系统」也解析成当前系统浅或深，避免 preferredColorScheme(nil) 在浅色下整页变白。
    @Published private(set) var resolvedScheme: ColorScheme

    private var observers: [NSObjectProtocol] = []
    private static let key = "jihe.appearance.mode"

    private static let lightCanvas = UIColor(red: 0.933, green: 0.945, blue: 0.961, alpha: 1)
    private static let darkCanvas = UIColor(red: 0.067, green: 0.094, blue: 0.145, alpha: 1)

    init() {
        let saved: AppAppearance
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let value = AppAppearance(rawValue: raw) {
            saved = value
        } else {
            saved = .system
        }
        mode = saved
        resolvedScheme = Self.scheme(for: saved)
        observeSystem()
        applyToWindows()
    }

    func refreshResolved() {
        let next = Self.scheme(for: mode)
        if resolvedScheme != next {
            resolvedScheme = next
        }
        applyToWindows()
    }

    func applyToWindows() {
        let dark = resolvedScheme == .dark
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        let canvas = dark ? Self.darkCanvas : Self.lightCanvas
        UIView.performWithoutAnimation {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows {
                    window.overrideUserInterfaceStyle = style
                    window.backgroundColor = canvas
                    window.layer.backgroundColor = canvas.cgColor
                }
            }
        }
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.refreshResolved()
            }
        }
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main,
            using: handler
        ))
        observers.append(center.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main,
            using: handler
        ))
    }

    private static func scheme(for mode: AppAppearance) -> ColorScheme {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .system:
            return UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
    }
}
