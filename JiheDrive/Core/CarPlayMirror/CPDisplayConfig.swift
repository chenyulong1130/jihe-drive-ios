import Foundation

/// CarPlay 画面参数：配件识别（0x1D01）时声明给 iOS 的屏幕规格。
/// iOS 按此分辨率/帧率编码 CarPlay 画面，触控坐标映射同步使用。
/// 修改后需重新启动 CarPlay 会话生效。
/// 档位与校验规则对齐 CarWithin ReceiverConfiguration：
/// 边长 320…3840 偶数、面积 ≤ 4K、帧率 30–60 步进 5、物理宽 100–400mm。
enum CPDisplayConfig {

    enum Resolution: String, CaseIterable, Identifiable {
        case p480 = "480P"
        case p720 = "720P"
        case p1080 = "1080P"

        var id: String { rawValue }
        var width: Int {
            switch self {
            case .p480: return 800
            case .p720: return 1280
            case .p1080: return 1920
            }
        }
        var height: Int {
            switch self {
            case .p480: return 480
            case .p720: return 720
            case .p1080: return 1080
            }
        }
    }

    enum FPS: Int, CaseIterable, Identifiable {
        case fps30 = 30
        case fps60 = 60

        var id: Int { rawValue }
        var title: String { "\(rawValue) FPS" }
    }

    /// CarPlay 白天/夜间外观（对齐 CarWithin Appearance）：
    /// 跟随系统 = 识别信息里声明自动模式；白天/夜间 = 会话就绪后发 setNightMode 命令
    enum Appearance: Int, CaseIterable, Identifiable {
        case system = 0
        case light = 1
        case dark = 2

        var id: Int { rawValue }
        var title: String { ["跟随系统", "白天", "夜间"][rawValue] }
    }

    /// CarPlay 主屏图标大小 = 声明的屏幕物理宽度（mm 越大图标越小）
    enum IconSize: Int, CaseIterable, Identifiable {
        case large = 125
        case normal = 200
        case small = 250
        case tiny = 300

        var id: Int { rawValue }
        var title: String { ["大", "默认", "较小", "最小"][rawValue] }
    }

    private static func string(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }
    private static func setString(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // MARK: 分辨率 / 帧率

    private static let resolutionKey = "carplay.resolution"
    private static let fpsKey = "carplay.fps"

    static var resolution: Resolution {
        get { Resolution(rawValue: string(resolutionKey) ?? "") ?? .p720 }
        set { setString(resolutionKey, newValue.rawValue) }
    }
    static var fps: FPS {
        get { FPS(rawValue: UserDefaults.standard.integer(forKey: fpsKey)) ?? .fps30 }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: fpsKey) }
    }

    static var width: Int { resolution.width }
    static var height: Int { resolution.height }
    /// 帧率规整（CarPlay 要求 30–60 步进 5，四舍五入）
    static var sanitizedFPS: Int {
        let clamped = min(60, max(30, fps.rawValue))
        return ((clamped - 30) + 2) / 5 * 5 + 30
    }

    // MARK: 外观

    private static let appearanceKey = "carplay.appearance"
    static var appearance: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.integer(forKey: appearanceKey)) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: appearanceKey) }
    }

    // MARK: 图标大小（屏幕物理宽度 mm）

    private static let iconSizeKey = "carplay.iconSizeMM"
    static var iconSize: IconSize {
        get { IconSize(rawValue: UserDefaults.standard.integer(forKey: iconSizeKey)) ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: iconSizeKey) }
    }
    static var widthPhysicalMM: Int { iconSize.rawValue }

    // MARK: 极核仪表投屏参数（对齐 CarWithin Zeeho 枚举）

    enum ZeehoFPS: Int, CaseIterable, Identifiable {
        case fps25 = 25
        case fps30 = 30

        var id: Int { rawValue }
        var title: String { "\(rawValue) FPS" }
        /// 自动码率 = 2.5Mbps × fps/25（对齐 CarWithin ZeehoFrameRate.bitrate）
        var autoBitrate: Int { 2_500_000 * rawValue / 25 }
    }

    enum ZeehoBitrate: Int, CaseIterable, Identifiable {
        case auto = 0
        case m12 = 12
        case m15 = 15
        case m18 = 18
        case m24 = 24
        case m30 = 30

        var id: Int { rawValue }
        var title: String { self == .auto ? "自动（随帧率）" : "\(rawValue) Mbit/s" }
        var bitsPerSecond: Int? { self == .auto ? nil : rawValue * 1_000_000 }
    }

    enum ZeehoProfile: Int, CaseIterable, Identifiable {
        case baseline = 0
        case main = 1

        var id: Int { rawValue }
        var title: String { self == .baseline ? "Baseline（兼容）" : "Main（更清晰）" }
    }

    private static let zeehoFPSKey = "zeeho.fps"
    private static let zeehoBitrateKey = "zeeho.bitrate"
    private static let zeehoProfileKey = "zeeho.encodeProfile"

    static var zeehoFPS: ZeehoFPS {
        get { ZeehoFPS(rawValue: UserDefaults.standard.integer(forKey: zeehoFPSKey)) ?? .fps25 }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: zeehoFPSKey) }
    }
    static var zeehoBitrate: ZeehoBitrate {
        get { ZeehoBitrate(rawValue: UserDefaults.standard.integer(forKey: zeehoBitrateKey)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: zeehoBitrateKey) }
    }
    static var zeehoProfile: ZeehoProfile {
        get { ZeehoProfile(rawValue: UserDefaults.standard.integer(forKey: zeehoProfileKey)) ?? .baseline }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: zeehoProfileKey) }
    }

    /// 极核转码器实际使用的码率（bit/s）：固定档优先，否则随帧率自动
    static var zeehoEffectiveBitrate: Int {
        zeehoBitrate.bitsPerSecond ?? zeehoFPS.autoBitrate
    }
}
