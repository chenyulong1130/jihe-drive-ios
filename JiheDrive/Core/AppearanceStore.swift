import SwiftUI
import UIKit
import CoreFoundation

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
        resolvedScheme = Self.scheme(for: saved, fallback: .light)
        observeSystem()
        applyToWindows(setStyle: true)
    }

    func refreshResolved() {
        let next = Self.scheme(for: mode, fallback: resolvedScheme)
        if resolvedScheme != next {
            resolvedScheme = next
        }
        applyToWindows(setStyle: true)
    }

    /// 回前台只涂窗口底色。再写 overrideUserInterfaceStyle 会触发整页重建，看起来就是白屏。
    func applyToWindows(setStyle: Bool = false) {
        let dark = resolvedScheme == .dark
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        let canvas = dark ? Self.darkCanvas : Self.lightCanvas
        UIView.performWithoutAnimation {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows where Self.shouldPaint(window) {
                    Self.paint(window, style: style, canvas: canvas, setStyle: setStyle)
                }
            }
        }
    }

    /// 键盘弹起会新建 TextEffects 窗口。给它涂不透明底色会把登录页整页盖住。
    private static func shouldPaint(_ window: UIWindow) -> Bool {
        if KeyboardAvoidance.isSystemOverlayWindow(window) { return false }
        return window.rootViewController != nil
    }

    private static func paint(
        _ window: UIWindow,
        style: UIUserInterfaceStyle,
        canvas: UIColor,
        setStyle: Bool
    ) {
        if setStyle, window.overrideUserInterfaceStyle != style {
            window.overrideUserInterfaceStyle = style
        }
        window.backgroundColor = canvas
        window.layer.backgroundColor = canvas.cgColor
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // 后台期间系统可能切了深浅色，跟随模式下重新解析
                if self.mode == .system {
                    self.refreshResolved()
                } else {
                    self.applyToWindows(setStyle: false)
                }
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // 控制中心切深浅色不触发 willEnterForeground，这里再兜一次
                if self.mode == .system {
                    self.refreshResolved()
                } else {
                    self.applyToWindows(setStyle: false)
                }
            }
        })
        // iOS 的系统深浅色切换是 Darwin 通知，NotificationCenter.default 收不到，
        // 必须经 CFNotificationCenter 注册，再转成内部 NS 通知给主线程消费。
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotificationCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                NotificationCenter.default.post(
                    name: Notification.Name("jihe.systemAppearanceChanged"),
                    object: nil
                )
            },
            "AppleInterfaceThemeChangedNotification" as CFString,
            nil,
            .deliverImmediately
        )
        observers.append(center.addObserver(
            forName: Notification.Name("jihe.systemAppearanceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mode == .system else { return }
                // 录屏 / 控制中心会把 trait 变成 unspecified，不能当成浅色
                if Self.currentInterfaceStyle() == .unspecified {
                    self.applyToWindows(setStyle: false)
                    return
                }
                self.refreshResolved()
            }
        })
        observers.append(center.addObserver(
            forName: UIWindow.didBecomeVisibleNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let window = note.object as? UIWindow else {
                    self?.applyToWindows(setStyle: false)
                    return
                }
                guard Self.shouldPaint(window) else { return }
                let dark = self?.resolvedScheme == .dark
                Self.paint(
                    window,
                    style: dark ? .dark : .light,
                    canvas: dark ? Self.darkCanvas : Self.lightCanvas,
                    setStyle: false
                )
            }
        })
        observers.append(center.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // 开始/结束录屏不要切 ColorScheme，只保证窗口不是系统白
                self?.applyToWindows(setStyle: false)
            }
        })
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotificationCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private static func scheme(for mode: AppAppearance, fallback: ColorScheme) -> ColorScheme {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .system:
            switch currentInterfaceStyle() {
            case .dark: return .dark
            case .light: return .light
            default: return fallback
            }
        }
    }

    /// 录屏、控制中心弹出时 UIScreen.main 经常是 unspecified，优先读前台 scene。
    private static func currentInterfaceStyle() -> UIUserInterfaceStyle {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
            let style = active.traitCollection.userInterfaceStyle
            if style != .unspecified { return style }
        }
        for scene in scenes {
            let style = scene.traitCollection.userInterfaceStyle
            if style != .unspecified { return style }
        }
        return UIScreen.main.traitCollection.userInterfaceStyle
    }
}
