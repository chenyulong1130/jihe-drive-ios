import Foundation
import SwiftUI

/// CarPlay 预览 / 投屏 BMS 叠画配置（对齐参考 App：开关 · 四角 · 尺寸 · 字段）。
enum BMSOverlayConfig {

    enum Position: String, CaseIterable, Identifiable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var id: String { rawValue }
        var title: String {
            switch self {
            case .topLeading: return "左上"
            case .topTrailing: return "右上"
            case .bottomLeading: return "左下"
            case .bottomTrailing: return "右下"
            }
        }
        var alignment: Alignment {
            switch self {
            case .topLeading: return .topLeading
            case .topTrailing: return .topTrailing
            case .bottomLeading: return .bottomLeading
            case .bottomTrailing: return .bottomTrailing
            }
        }
        /// scaleEffect 锚点用（UnitPoint，Alignment 不能直接转）
        var unitPoint: UnitPoint {
            switch self {
            case .topLeading: return .topLeading
            case .topTrailing: return .topTrailing
            case .bottomLeading: return .bottomLeading
            case .bottomTrailing: return .bottomTrailing
            }
        }
        var icon: String {
            switch self {
            case .topLeading: return "arrow.up.left"
            case .topTrailing: return "arrow.up.right"
            case .bottomLeading: return "arrow.down.left"
            case .bottomTrailing: return "arrow.down.right"
            }
        }
    }

    enum Size: String, CaseIterable, Identifiable {
        case compact, regular, large

        var id: String { rawValue }
        var title: String {
            switch self {
            case .compact: return "紧凑"
            case .regular: return "标准"
            case .large: return "放大"
            }
        }
        /// 叠画卡片相对预览宽度的比例（2026-11-28 调小：投到车机时少挡画面）
        var widthRatio: CGFloat {
            switch self {
            case .compact: return 0.30
            case .regular: return 0.38
            case .large: return 0.46
            }
        }
        var padding: CGFloat {
            switch self {
            case .compact: return 10
            case .regular: return 12
            case .large: return 14
            }
        }
        var titleSize: CGFloat {
            switch self {
            case .compact: return 11
            case .regular: return 13
            case .large: return 15
            }
        }
        var valueSize: CGFloat {
            switch self {
            case .compact: return 16
            case .regular: return 20
            case .large: return 24
            }
        }
        var metricSize: CGFloat {
            switch self {
            case .compact: return 10
            case .regular: return 11
            case .large: return 13
            }
        }
    }

    enum Field: String, CaseIterable, Identifiable {
        case soc, voltage, current, power, cells, temperature

        var id: String { rawValue }
        var title: String {
            switch self {
            case .soc: return "电量"
            case .voltage: return "总压"
            case .current: return "电流"
            case .power: return "功率"
            case .cells: return "单体"
            case .temperature: return "温度"
            }
        }
        var icon: String {
            switch self {
            case .soc: return "battery.100"
            case .voltage: return "bolt.fill"
            case .current: return "wave.3.right"
            case .power: return "flame.fill"
            case .cells: return "square.grid.3x3.fill"
            case .temperature: return "thermometer.medium"
            }
        }
    }

    private static let enabledKey = "mirror.bmsOverlay.enabled"
    private static let positionKey = "mirror.bmsOverlay.position"
    private static let sizeKey = "mirror.bmsOverlay.size"
    private static let fieldsKey = "mirror.bmsOverlay.fields"
    private static let glowModeKey = "mirror.bms.glowMode"
    private static let glowMaxKey = "mirror.bms.glowMax"

    /// 画面周边氛围光：跟随保护板指定参数联动变色（绿→橙→红 随负载升高）
    enum GlowMode: String, CaseIterable, Identifiable {
        case off, power, current

        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "关闭"
            case .power: return "功率联动"
            case .current: return "电流联动"
            }
        }
        /// 满负载映射上限（功率 W / 电流 A）
        var maxValue: Double {
            switch self {
            case .off: return 1
            case .power: return UserDefaults.standard.double(forKey: glowMaxKey) > 0
                ? UserDefaults.standard.double(forKey: glowMaxKey) : 250
            case .current: return UserDefaults.standard.double(forKey: glowMaxKey) > 0
                ? UserDefaults.standard.double(forKey: glowMaxKey) : 40
            }
        }
    }

    static var glowMode: GlowMode {
        get { GlowMode(rawValue: UserDefaults.standard.string(forKey: glowModeKey) ?? "") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: glowModeKey) }
    }

    /// 氛围光满载值（W 或 A，按联动模式）
    static var glowMaxValue: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: glowMaxKey)
            return stored > 0 ? stored : (glowMode == .current ? 40 : 250)
        }
        set { UserDefaults.standard.set(newValue, forKey: glowMaxKey) }
    }

    /// 由实时负载算出氛围色：t = 负载比例（0→绿，0.5→橙，1→红）
    static func glowColor(for realtime: BMSRealtime?, connected: Bool) -> Color? {
        guard connected, let realtime else { return nil }
        switch glowMode {
        case .off:
            return nil
        case .power:
            return heatColor(min(1, max(0, abs(realtime.power) / max(1, glowMaxValue))))
        case .current:
            return heatColor(min(1, max(0, abs(realtime.current) / max(1, glowMaxValue))))
        }
    }

    private static func heatColor(_ t: Double) -> Color {
        Color(hue: 0.33 * (1 - t), saturation: 0.92, brightness: 1)
    }

    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return false }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var position: Position {
        get { Position(rawValue: UserDefaults.standard.string(forKey: positionKey) ?? "") ?? .topLeading }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: positionKey) }
    }

    static var size: Size {
        get { Size(rawValue: UserDefaults.standard.string(forKey: sizeKey) ?? "") ?? .regular }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sizeKey) }
    }

    static var fields: Set<Field> {
        get {
            guard let raw = UserDefaults.standard.array(forKey: fieldsKey) as? [String], !raw.isEmpty else {
                return [.soc, .voltage, .current, .power]
            }
            return Set(raw.compactMap(Field.init(rawValue:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: fieldsKey)
        }
    }

    static func isOn(_ field: Field) -> Bool { fields.contains(field) }

    static func toggle(_ field: Field) {
        var next = fields
        if next.contains(field) {
            guard next.count > 1 else { return }
            next.remove(field)
        } else {
            next.insert(field)
        }
        fields = next
    }
}
