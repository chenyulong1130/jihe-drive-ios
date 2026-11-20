import SwiftUI
import UIKit

/// Apple HIG 设计令牌：语义色随浅/深色自动切换，字号走 SF Pro 默认层级。
enum Theme {
    // MARK: - 背景与表面

    /// 分组列表底色（systemGroupedBackground）
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    /// 卡片（secondarySystemGroupedBackground）
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    /// 行内弱填充（tertiarySystemFill）
    static let surfaceAlt = Color(uiColor: .tertiarySystemFill)

    // MARK: - 文字

    static let label = Color(uiColor: .label)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let tertiary = Color(uiColor: .tertiaryLabel)
    static let ink = Color(uiColor: .label)

    // MARK: - 分隔

    static let separator = Color(uiColor: .separator)
    static let opaqueSeparator = Color(uiColor: .opaqueSeparator)

    // MARK: - 强调色（语义）

    static let brand = Color(uiColor: .systemBlue)
    static let green = Color(uiColor: .systemGreen)
    static let orange = Color(uiColor: .systemOrange)
    static let red = Color(uiColor: .systemRed)
    static let teal = Color(uiColor: .systemTeal)
    static let indigo = Color(uiColor: .systemIndigo)
    static let yellow = Color(uiColor: .systemYellow)

    // MARK: - 布局（8pt 网格，4pt 细分）

    static let page: CGFloat = 16
    static let cardRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 10
    static let tap: CGFloat = 44

    // MARK: - 阴影（只用一种极淡的扩散阴影）

    static let cardShadow = Color.black.opacity(0.04)

    // MARK: - 字号（Dynamic Type 默认值）

    static let largeTitle = Font.system(size: 34, weight: .regular)
    static let title2 = Font.system(size: 22, weight: .semibold)
    static let headline = Font.system(size: 17, weight: .semibold)
    static let callout = Font.system(size: 16, weight: .regular)
    static let footnote = Font.system(size: 13, weight: .regular)
    static let caption = Font.system(size: 12, weight: .regular)
    static let captionStrong = Font.system(size: 12, weight: .semibold)
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
