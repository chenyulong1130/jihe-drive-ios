import Foundation

/// CarPlay 画面参数：配件识别（0x1D01）时声明给 iOS 的屏幕规格。
/// iOS 按此分辨率/帧率编码 CarPlay 画面，触控坐标映射同步使用。
/// 修改后需重新启动 CarPlay 会话生效。
enum CPDisplayConfig {
    enum Resolution: String, CaseIterable, Identifiable {
        case standard = "1024×480 · 30fps"
        case hd720 = "1280×720 · 60fps"

        var id: String { rawValue }
        var width: Int { self == .hd720 ? 1280 : 1024 }
        var height: Int { self == .hd720 ? 720 : 480 }
        var fps: Int { self == .hd720 ? 60 : 30 }
    }

    private static let key = "carplay.resolution"

    /// 当前画面参数（持久化；默认标准档）
    static var current: Resolution {
        get { Resolution(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    static var width: Int { current.width }
    static var height: Int { current.height }
    static var fps: Int { current.fps }
}
