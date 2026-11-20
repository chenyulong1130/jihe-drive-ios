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

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var uiUserInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class AppearanceStore: ObservableObject {
    @Published var mode: AppAppearance {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            applyToWindows()
        }
    }

    private static let key = "jihe.appearance.mode"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let saved = AppAppearance(rawValue: raw) {
            mode = saved
        } else {
            mode = .system
        }
        applyToWindows()
    }

    func applyToWindows() {
        let style = mode.uiUserInterfaceStyle
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = style
                window.backgroundColor = .systemGroupedBackground
            }
        }
    }
}
