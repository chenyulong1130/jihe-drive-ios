import SwiftUI

/// 车辆主视觉主题：默认透明 + 动态视频目录（与 Flutter vehicle_bg_theme 同源）
struct VehicleTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let desc: String
    let colors: [Color]
    let posterURL: URL?
    /// 云端动态主题视频；有值时英雄区循环播放，而不是只贴封面
    let videoURL: URL?

    var isDefault: Bool { id.isEmpty }
    var hasVideo: Bool { videoURL != nil }

    init(
        id: String,
        name: String,
        desc: String,
        colors: [Color],
        posterURL: URL? = nil,
        videoURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.desc = desc
        self.colors = colors
        self.posterURL = posterURL
        self.videoURL = videoURL
    }

    static func == (lhs: VehicleTheme, rhs: VehicleTheme) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum VehicleThemeCatalog {
    static let all: [VehicleTheme] = [
        VehicleTheme(
            id: "",
            name: "默认",
            desc: "纯净背景",
            colors: [Color(hex: 0x07203D), Color(hex: 0x0A4A8A), Color(hex: 0x0B6BCB)]
        ),
        VehicleTheme(
            id: "g-mint",
            name: "氧气",
            desc: "青蓝 · 清爽",
            colors: [Color(hex: 0x062B2A), Color(hex: 0x0C6E63), Color(hex: 0x14A38B)]
        ),
        VehicleTheme(
            id: "g-violet",
            name: "暮光",
            desc: "靛紫 · 夜行",
            colors: [Color(hex: 0x191033), Color(hex: 0x3B2A7A), Color(hex: 0x6A4BD6)]
        ),
        VehicleTheme(
            id: "g-ember",
            name: "熔岩",
            desc: "橙红 · 热血",
            colors: [Color(hex: 0x2A0E0A), Color(hex: 0x8A2B12), Color(hex: 0xD9571F)]
        ),
        VehicleTheme(
            id: "g-steel",
            name: "钢灰",
            desc: "石墨 · 冷静",
            colors: [Color(hex: 0x14181D), Color(hex: 0x333B45), Color(hex: 0x5A6673)]
        ),
        VehicleTheme(
            id: "19910204705690688",
            name: "梦幻眼眸",
            desc: "特写 · 蓝瞳",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_10_25_file/19910199397471296_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_10_25_file/19910199397471296.mp4")
        ),
        VehicleTheme(
            id: "19027185103557504",
            name: "自嘲熊",
            desc: "湖水 · 治愈",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_05_22_file/19027183998751616_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_05_22_file/19027183998751616.mp4")
        ),
        VehicleTheme(
            id: "17815999759895936",
            name: "五条悟",
            desc: "咒术回战 · 蓝眼",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_10_20_file/17815907003452800_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_10_20_file/17815907003452800.mp4")
        ),
        VehicleTheme(
            id: "19932199181571136",
            name: "02 · Darling",
            desc: "发光文字 · 漫画墙",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_10_29_file/19932194811892800_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_10_29_file/19932194811892800.mp4")
        ),
        VehicleTheme(
            id: "19933035341960256",
            name: "冰系剑光",
            desc: "蓝发少女 · 雪花",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_10_29_file/19933034239317056_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_10_29_file/19933034239317056.mp4")
        ),
        VehicleTheme(
            id: "19011384588225920",
            name: "黑发少女",
            desc: "暗黑 · 紫瞳",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_05_19_file/19011374796426624_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_05_19_file/19011374796426624.mp4")
        ),
        VehicleTheme(
            id: "19311107908391808",
            name: "轻松熊",
            desc: "水面 · 治愈",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_07_11_file/19311104283923328_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_07_11_file/19311104283923328.mp4")
        ),
        VehicleTheme(
            id: "19929546270070336",
            name: "DeepSeek鲸鱼娘",
            desc: "夜景 · 梦幻",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_10_29_file/19929530689082944_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_10_29_file/19929530689082944.mp4")
        ),
        VehicleTheme(
            id: "17587336854097280",
            name: "红瞳眨眼",
            desc: "特写 · 黑发",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_09_10_file/17587334530977152_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_09_10_file/17587334530977152.mp4")
        ),
        VehicleTheme(
            id: "19275700262818688",
            name: "女剑客",
            desc: "寒光 · 长剑",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_07_05_file/19275656733938560_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_07_05_file/19275656733938560.mp4")
        ),
        VehicleTheme(
            id: "19724934231577472",
            name: "绫波丽",
            desc: "EVA · 红瞳",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_09_22_file/19724921082172288_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_09_22_file/19724921082172288.mp4")
        ),
        VehicleTheme(
            id: "18907507980946816",
            name: "若叶睦",
            desc: "BanG Dream · 黑白",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_05_01_file/18907462026579328_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_05_01_file/18907462026579328.mp4")
        ),
        VehicleTheme(
            id: "19694820209611648",
            name: "猫咪侧脸",
            desc: "清冷 · 黑长直",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_09_17_file/19694818000393088_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_09_17_file/19694818000393088.mp4")
        ),
        VehicleTheme(
            id: "19977684595267136",
            name: "猫耳少女",
            desc: "居家 · 软萌",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_11_06_file/19977569594267200_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_11_06_file/19977569594267200.mp4")
        ),
        VehicleTheme(
            id: "17440900285189504",
            name: "白发红瞳",
            desc: "眨眼 · 灵眸",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_08_15_file/17440897608437120_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_08_15_file/17440897608437120.mp4")
        ),
        VehicleTheme(
            id: "17468477806202240",
            name: "懒羊羊",
            desc: "卧室 · 雨天",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_08_20_file/17468467847024000_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_08_20_file/17468467847024000.mp4")
        ),
        VehicleTheme(
            id: "17469705038777728",
            name: "紫眸少女",
            desc: "暗紫 · 黑长直",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_08_20_file/17469703159139712_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_08_20_file/17469703159139712.mp4")
        ),
        VehicleTheme(
            id: "17429951965482368",
            name: "雪景少女",
            desc: "蓝色围巾 · 冬季",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_08_13_file/17429942183382400_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_08_13_file/17429942183382400.mp4")
        ),
        VehicleTheme(
            id: "20003130825004608",
            name: "精灵教堂",
            desc: "丁达尔光 · 蓝白",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_11_11_file/20003127123596864_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_11_11_file/20003127123596864.mp4")
        ),
        VehicleTheme(
            id: "17731785862139264",
            name: "赤瞳",
            desc: "斩赤红之瞳 · 红眼",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_10_05_file/17731782620990848_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_10_05_file/17731782620990848.mp4")
        ),
        VehicleTheme(
            id: "18012877372968320",
            name: "蜡笔小新",
            desc: "风间彻 · 小伙伴",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_11_24_file/18012839448333696_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_11_24_file/18012839448333696.mp4")
        ),
        VehicleTheme(
            id: "17900783299841408",
            name: "海绵宝宝",
            desc: "月下 · 篝火野营",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_11_04_file/17900700706917760_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_11_04_file/17900700706917760.mp4")
        ),
        VehicleTheme(
            id: "17437385162280320",
            name: "吉伊卡哇",
            desc: "夏季泳池 · 气泡",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_08_14_file/17437380057156992_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_08_14_file/17437380057156992.mp4")
        ),
        VehicleTheme(
            id: "17562640137178496",
            name: "水中02",
            desc: "国家队 · 粉发",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_09_06_file/17562632008355200_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_09_06_file/17562632008355200.mp4")
        ),
        VehicleTheme(
            id: "17683913501166976",
            name: "雨天帽衫",
            desc: "红瞳 · 蓝色帽衫",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_09_27_file/17683817619574144_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_09_27_file/17683817619574144.mp4")
        ),
        VehicleTheme(
            id: "17565398639496576",
            name: "利威尔兵长",
            desc: "进击的巨人 · 绿瞳",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_09_06_file/17565330613128576_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_09_06_file/17565330613128576.mp4")
        ),
        VehicleTheme(
            id: "18793775318551936",
            name: "风铃公主",
            desc: "鬼刀 · 国漫",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_04_11_file/18793670881955200_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_04_11_file/18793670881955200.mp4")
        ),
        VehicleTheme(
            id: "18086586563677568",
            name: "罗峰",
            desc: "吞噬星空 · 机甲",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_12_07_file/18086582063779200_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_12_07_file/18086582063779200.mp4")
        ),
        VehicleTheme(
            id: "17900783298792832",
            name: "红眼光效",
            desc: "暗黑 · 霓虹",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_11_04_file/17900694833909120_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_11_04_file/17900694833909120.mp4")
        ),
        VehicleTheme(
            id: "18851589117365632",
            name: "萧炎",
            desc: "斗破苍穹 · 异火",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_04_21_file/18851585676135808_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_04_21_file/18851585676135808.mp4")
        ),
        VehicleTheme(
            id: "20027266056868928",
            name: "搞怪金发",
            desc: "呆毛 · 广场",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_11_15_file/20027259216090176_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_11_15_file/20027259216090176.mp4")
        ),
        VehicleTheme(
            id: "17792047438220672",
            name: "山野田野",
            desc: "蓝天 · 草地",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_10_16_file/17791927566847360_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_10_16_file/17791927566847360.mp4")
        ),
        VehicleTheme(
            id: "19275700269241216",
            name: "大树下",
            desc: "夏日绿荫 · 晴天",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_07_05_file/19275695366493056_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_07_05_file/19275695366493056.mp4")
        ),
        VehicleTheme(
            id: "18850213490445696",
            name: "蒙面武士",
            desc: "刺客 · 黑白",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2026_04_21_file/18850209382780288_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2026_04_21_file/18850209382780288.mp4")
        ),
        VehicleTheme(
            id: "17603706208308608",
            name: "蜡笔小新",
            desc: "荷塘 · 夏日",
            colors: [Color(hex: 0x0B1A16), Color(hex: 0x1E3A4A)],
            posterURL: URL(string: "https://img.haowallpaper.com/cache_file/2025_09_13_file/17603628614929792_s240q80.webp"),
            videoURL: URL(string: "https://img.haowallpaper.com/pre_cache_file/2025_09_13_file/17603628614929792.mp4")
        ),

    ]

    /// 仅动态视频主题（主题商城）
    static var videoThemes: [VehicleTheme] {
        all.filter { $0.hasVideo }
    }

    static func theme(id: String) -> VehicleTheme {
        all.first(where: { $0.id == id }) ?? all[0]
    }
}

/// 当前主题（UserDefaults 持久化）
/// 命名空间：video / photo / a-xxx（动态）/ 空或主题 id（静态 / 云端视频）
@MainActor
final class ThemeStore: ObservableObject {
    static let videoID = "video"
    static let photoID = "photo"

    @Published var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: Self.key) }
    }

    private static let key = "jihe.vehicle.backdrop"

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
            if let wallpaper = WallpaperCatalog.item(id: selectedID) {
                return .builtin(wallpaper)
            }
            return .theme(VehicleThemeCatalog.theme(id: selectedID))
        }
    }

    /// 英雄区实际播放的视频：本地「我的视频」或云端主题 mp4
    func resolvedVideoURL(local: URL?) -> URL? {
        switch selection {
        case .video: return local
        case .theme(let theme): return theme.videoURL
        default: return nil
        }
    }

    var displayName: String {
        switch selection {
        case .video: return "我的视频"
        case .photo: return "我的照片"
        case .animated(let kind): return kind.name
        case .builtin(let wallpaper): return wallpaper.name
        case .theme(let theme): return theme.name
        }
    }

    func select(_ id: String) {
        selectedID = id
    }
}
