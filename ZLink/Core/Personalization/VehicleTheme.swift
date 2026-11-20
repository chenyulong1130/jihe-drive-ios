import SwiftUI

/// 车辆主视觉主题：优先用本地渐变色（离线可用），也可换成云端封面图
struct VehicleTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let desc: String
    let colors: [Color]
    let posterURL: URL?

    var isDefault: Bool { id.isEmpty }

    static func == (lhs: VehicleTheme, rhs: VehicleTheme) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum VehicleThemeCatalog {
    static let all: [VehicleTheme] = [
        VehicleTheme(id: "", name: "极核蓝", desc: "默认 · 深海渐变", colors: [Color(hex: 0x07203D), Color(hex: 0x0A4A8A), Color(hex: 0x0B6BCB)], posterURL: nil),
        VehicleTheme(id: "g-mint", name: "氧气", desc: "青蓝 · 清爽", colors: [Color(hex: 0x062B2A), Color(hex: 0x0C6E63), Color(hex: 0x14A38B)], posterURL: nil),
        VehicleTheme(id: "g-violet", name: "暮光", desc: "靛紫 · 夜行", colors: [Color(hex: 0x191033), Color(hex: 0x3B2A7A), Color(hex: 0x6A4BD6)], posterURL: nil),
        VehicleTheme(id: "g-ember", name: "熔岩", desc: "橙红 · 热血", colors: [Color(hex: 0x2A0E0A), Color(hex: 0x8A2B12), Color(hex: 0xD9571F)], posterURL: nil),
        VehicleTheme(id: "g-steel", name: "钢灰", desc: "石墨 · 冷静", colors: [Color(hex: 0x14181D), Color(hex: 0x333B45), Color(hex: 0x5A6673)], posterURL: nil),
        VehicleTheme(
            id: "19910204705690688",
            name: "梦幻眼眸",
            desc: "特写 · 蓝瞳",
            colors: [Color(hex: 0x0B2A4A), Color(hex: 0x1B5A8A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_10_25_file/19910199397471296_s240q80.webp")
        ),
        VehicleTheme(
            id: "19027185103557504",
            name: "湖水",
            desc: "治愈 · 静水",
            colors: [Color(hex: 0x0A3A3A), Color(hex: 0x1C7A72)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_05_22_file/19027183998751616_s240q80.webp")
        ),
        VehicleTheme(
            id: "19933035341960256",
            name: "冰系剑光",
            desc: "蓝发 · 雪花",
            colors: [Color(hex: 0x0A2540), Color(hex: 0x2F6FA8)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_10_29_file/19933034239317056_s240q80.webp")
        ),
        VehicleTheme(
            id: "19929546270070336",
            name: "夜鲸",
            desc: "夜景 · 梦幻",
            colors: [Color(hex: 0x101A3A), Color(hex: 0x3A2A7A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_10_29_file/19929530689082944_s240q80.webp")
        ),
        VehicleTheme(
            id: "20003130825004608",
            name: "精灵教堂",
            desc: "丁达尔光 · 蓝白",
            colors: [Color(hex: 0x132A3A), Color(hex: 0x4A7A9A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_11_11_file/20003127123596864_s240q80.webp")
        ),
        VehicleTheme(
            id: "17792047438220672",
            name: "山野田野",
            desc: "蓝天 · 草地",
            colors: [Color(hex: 0x143A2A), Color(hex: 0x2E7A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_10_16_file/17791927566847360_s240q80.webp")
        )
    ]

    static func theme(id: String) -> VehicleTheme {
        all.first(where: { $0.id == id }) ?? all[0]
    }
}

/// 当前主题（UserDefaults 持久化）
/// 命名空间：video / photo / a-xxx（动态）/ 空或主题 id（静态）
@MainActor
final class ThemeStore: ObservableObject {
    static let videoID = "video"
    static let photoID = "photo"

    @Published var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: Self.key) }
    }

    private static let key = "zlink.vehicle.theme"

    init() {
        selectedID = UserDefaults.standard.string(forKey: Self.key) ?? ""
    }

    var current: VehicleTheme { VehicleThemeCatalog.theme(id: selectedID) }

    var selection: BackdropSelection {
        switch selectedID {
        case Self.videoID: return .video
        case Self.photoID: return .photo
        default:
            if let kind = AnimatedBackdropKind(rawValue: selectedID) {
                return .animated(kind)
            }
            return .theme(VehicleThemeCatalog.theme(id: selectedID))
        }
    }

    func select(_ id: String) {
        selectedID = id
    }
}
