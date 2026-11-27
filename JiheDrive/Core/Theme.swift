import SwiftUI
import UIKit

/// Apple HIG 设计令牌：语义色随浅/深色自动切换，字号走 SF Pro 默认层级。
enum Theme {
    // MARK: - 背景与表面（对齐 Flutter / 小程序冷灰蓝，避免系统白过刺）

    /// 页面底：#EEF1F5 / 深色 #111825
    static let groupedBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.067, green: 0.094, blue: 0.145, alpha: 1) // #111825
            : UIColor(red: 0.933, green: 0.945, blue: 0.961, alpha: 1) // #EEF1F5
    })
    /// 卡片：白 / 深色 #1C2534
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.110, green: 0.145, blue: 0.204, alpha: 1) // #1C2534
            : UIColor.white
    })
    /// 行内弱填充
    static let surfaceAlt = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor(red: 0.47, green: 0.52, blue: 0.59, alpha: 0.12)
    })
    /// 抬升一层
    static let elevated = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.106, green: 0.141, blue: 0.196, alpha: 1)
            : UIColor(red: 0.969, green: 0.976, blue: 0.988, alpha: 1) // #F7F9FC
    })
    /// 顶部氛围（小程序 canvas-top #E4EEF8）
    static let canvasTop = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.078, green: 0.110, blue: 0.165, alpha: 1) // #141C2A
            : UIColor(red: 0.894, green: 0.933, blue: 0.973, alpha: 1) // #E4EEF8
    })

    // MARK: - 文字

    static let label = Color(uiColor: .label)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let tertiary = Color(uiColor: .tertiaryLabel)
    static let ink = Color(uiColor: .label)

    // MARK: - 分隔

    static let separator = Color(uiColor: .separator)
    static let opaqueSeparator = Color(uiColor: .opaqueSeparator)

    // MARK: - 强调色（语义，系统会随深浅微调）

    static let brand = Color(uiColor: .systemBlue)
    static let green = Color(uiColor: .systemGreen)
    static let orange = Color(uiColor: .systemOrange)
    static let red = Color(uiColor: .systemRed)
    static let teal = Color(uiColor: .systemTeal)
    static let indigo = Color(uiColor: .systemIndigo)
    static let yellow = Color(uiColor: .systemYellow)

    /// 寻车强调色
    static let find = Color(uiColor: .systemOrange)
    /// 解锁主按钮（锁车态）
    static let unlock = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.62, blue: 0.22, alpha: 1)
            : UIColor(red: 1.0, green: 0.48, blue: 0.10, alpha: 1)
    })
    /// 关锁主按钮（已解锁态）
    static let lock = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 1)
            : UIColor(red: 0.10, green: 0.45, blue: 0.92, alpha: 1)
    })

    // MARK: - 布局（8pt 网格，4pt 细分）

    static let page: CGFloat = 16
    static let cardRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 10
    static let tap: CGFloat = 44

    // MARK: - 阴影（深色略加强，浅色保持极淡）

    static let cardShadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.45)
            : UIColor.black.withAlphaComponent(0.06)
    })

    static let softShadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.55)
            : UIColor.black.withAlphaComponent(0.10)
    })

    // MARK: - 字号（Dynamic Type 默认值）

    static let largeTitle = Font.system(size: 34, weight: .regular)
    static let title2 = Font.system(size: 22, weight: .semibold)
    static let headline = Font.system(size: 17, weight: .semibold)
    static let callout = Font.system(size: 16, weight: .regular)
    static let footnote = Font.system(size: 13, weight: .regular)
    static let caption = Font.system(size: 12, weight: .regular)
    static let captionStrong = Font.system(size: 12, weight: .semibold)
}

/// 状态栏高度：GeometryReader 在 ignoresSafeArea 后 insets.top 经常是 0
enum ScreenMetrics {
    static var statusBarHeight: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let height = scenes.first?.statusBarManager?.statusBarFrame.height, height > 20 {
            return height
        }
        return 47
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// 「RRGGBB」十六进制字符串转色（设备快照/云端色值用）
    init(hexString: String) {
        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)
        self.init(hex: UInt32(truncatingIfNeeded: value))
    }

    func mixed(with other: Color, amount: CGFloat) -> Color {
        let a = UIColor(self)
        let b = UIColor(other)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return Color(
            .sRGB,
            red: Double(ar + (br - ar) * amount),
            green: Double(ag + (bg - ag) * amount),
            blue: Double(ab + (bb - ab) * amount),
            opacity: Double(aa + (ba - aa) * amount)
        )
    }
}
