import Foundation
import CoreBluetooth

// MARK: - 设备分类

enum DeviceKind: String, CaseIterable, Identifiable {
    case bms
    case shilanLight
    /// 蚂蚁充电机（新协议引擎帧，历史数据 FUNC=86）
    case charger
    /// 点睛仪表（VTB_EF_ 广播前缀，AB/BA 寄存器协议）
    case dianjingMeter
    /// 速牛灯具（5A A5 TLV 帧，按广播名分 5 种传输通道）
    case lamp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bms: return "保护板"
        case .shilanLight: return "石栏大灯"
        case .charger: return "充电机"
        case .dianjingMeter: return "仪表"
        case .lamp: return "灯具"
        }
    }

    var shortTitle: String {
        switch self {
        case .bms: return "保护板"
        case .shilanLight: return "石栏"
        case .charger: return "充电机"
        case .dianjingMeter: return "仪表"
        case .lamp: return "灯具"
        }
    }

    var detail: String {
        switch self {
        case .bms: return "蚂蚁 / 彦阳 · 电压 / 电流 / 单体 / 保护"
        case .shilanLight: return "石栏协议 · NB- / SL- 大灯高低调节"
        case .charger: return "蚂蚁充电机 · 充电状态 / 历史日志 / 帧调试"
        case .dianjingMeter: return "点睛仪表 · VTB_EF_ · 电压 / 里程 / 零百测速"
        case .lamp: return "速牛灯具 · 亮度 / 色温 / 角度 / RGB 调试"
        }
    }

    var icon: String {
        switch self {
        case .bms: return "battery.100.bolt"
        case .shilanLight: return "headlight.high.beam"
        case .charger: return "powerplug.fill"
        case .dianjingMeter: return "speedometer"
        case .lamp: return "lightbulb.fill"
        }
    }

    /// 设备页主推：保护板 + 石栏 + 充电机 + 仪表 + 灯具
    static let primaryKinds: [DeviceKind] = [.bms, .shilanLight, .charger, .dianjingMeter, .lamp]

    /// 石栏沿用小程序的 8 位开机密码校验，其余设备不需要
    var requiresPowerAuth: Bool {
        switch self {
        case .bms, .charger, .dianjingMeter, .lamp: return false
        case .shilanLight: return true
        }
    }

    /// 广播名 / 服务 UUID 分类；无法识别则返回 nil（扫描时直接丢弃）
    static func classify(name: String, serviceUUIDs: [CBUUID]?) -> DeviceKind? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        // 石栏：NB- / SL-
        if upper.contains("NB-") || upper.contains("SL-") { return .shilanLight }
        // 点睛仪表：VTB_EF_ 广播前缀（小程序 utils/product.js）
        if upper.hasPrefix("VTB_EF_") { return .dianjingMeter }
        // 充电机：广播名带 CHARGER / 充电 字样（须在 BMS 之前判，避免 ANT 前缀抢占）
        if upper.contains("CHARGER") || trimmed.contains("充电") { return .charger }
        // 保护板：蚂蚁 ANT / 彦阳 YY
        if BMSBrand.detect(name: trimmed) != nil { return .bms }
        // 灯具：调试工具的广播名分类规则。识别规则较宽（如 13 位名称→紧凑协议），
        // 为避免把普通外设当灯具，带空格的常见消费设备名不参与灯具自动归类。
        if !trimmed.contains(" "), LampTransport.detect(name: trimmed) != nil { return .lamp }
        return nil
    }
}

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
}

struct BLEDevice: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
    var kind: DeviceKind
    /// 保护板协议品牌；非 BMS 为 nil
    var bmsBrand: BMSBrand? = nil
    /// 灯具传输通道；非灯具为 nil
    var lampTransport: LampTransport? = nil

    var displayName: String { name.isEmpty ? "未命名设备" : name }
}

enum DeviceBLEError: LocalizedError {
    case bluetoothOff
    case timeout
    case notConnected
    case characteristicMissing
    case cancelled
    case invalidFrame(String)
    case invalidHex

    var errorDescription: String? {
        switch self {
        case .bluetoothOff: return "蓝牙未开启，请在系统设置中打开蓝牙"
        case .timeout: return "蓝牙操作超时"
        case .notConnected: return "设备未连接"
        case .characteristicMissing: return "设备服务或特征不匹配"
        case .cancelled: return "操作已取消"
        case .invalidFrame(let text): return "数据帧无效：\(text)"
        case .invalidHex: return "十六进制格式不正确"
        }
    }
}

/// 蚂蚁 BMS 的三组通信通道，与小程序 bleChannelDiagnostics.js 一致
enum BMSChannel: String, CaseIterable, Identifiable {
    case ffe1
    case fff3fff4
    case fff5fff6

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ffe1: return "默认通道 FFE1"
        case .fff3fff4: return "备用通道 A（FFF3/FFF4）"
        case .fff5fff6: return "备用通道 B（FFF5/FFF6）"
        }
    }

    var writeID: String {
        switch self {
        case .ffe1: return "FFE1"
        case .fff3fff4: return "FFF3"
        case .fff5fff6: return "FFF5"
        }
    }

    var notifyID: String {
        switch self {
        case .ffe1: return "FFE1"
        case .fff3fff4: return "FFF4"
        case .fff5fff6: return "FFF6"
        }
    }
}

// MARK: - 本地鉴权（沿用小程序密码，仅作本地门锁，不上传）

enum DeviceAuth {
    /// 石栏/控制器出厂默认 8 位开机密码
    static let defaultPowerOnCode = "22222222"
    static let serviceCode = "0241"

    private static let powerKey = "device.auth.poweron.v1"
    private static let expireKey = "device.auth.poweron.expire"
    /// 「我的」页面保存的自定义开机密码；未保存时回落出厂默认
    private static let customCodeKey = "device.auth.poweron.custom"

    /// 开机密码：优先「我的」里存的，没有才用默认值
    static var powerOnCode: String {
        let stored = UserDefaults.standard.string(forKey: customCodeKey) ?? ""
        return stored.isEmpty ? defaultPowerOnCode : stored
    }

    static func hasCustomPowerCode() -> Bool {
        !(UserDefaults.standard.string(forKey: customCodeKey) ?? "").isEmpty
    }

    /// 保存自定义开机密码；传空串/不足 8 位即清除，回落默认
    static func setPowerOnCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 8 {
            UserDefaults.standard.set(trimmed, forKey: customCodeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: customCodeKey)
        }
    }

    static func isVerified() -> Bool {
        let expire = UserDefaults.standard.double(forKey: expireKey)
        guard expire > 0 else { return false }
        if Date().timeIntervalSince1970 >= expire {
            clearVerified()
            return false
        }
        return UserDefaults.standard.bool(forKey: powerKey)
    }

    static func markVerified(days: Int = 7) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: powerKey)
        defaults.set(Date().timeIntervalSince1970 + Double(days) * 86_400, forKey: expireKey)
    }

    static func clearVerified() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: powerKey)
        defaults.removeObject(forKey: expireKey)
    }
}

/// 石栏大灯记忆：用户调好高度后命名保存（本地持久化），列表与详情页共用
struct HeadlightMemoryItem: Codable, Equatable, Identifiable {
    var name: String
    var percent: Int
    var id: String { "\(name)-\(percent)" }
}

enum HeadlightMemory {
    static let key = "device.headlight.memory.items"

    static func load() -> [HeadlightMemoryItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([HeadlightMemoryItem].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [HeadlightMemoryItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 添加/按名覆盖（同名更新高度），按高度排序
    static func add(name: String, percent: Int) -> [HeadlightMemoryItem] {
        var items = load()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = clean.isEmpty ? "记忆 \(items.count + 1)" : clean
        let clamped = min(100, max(0, percent))
        items.removeAll { $0.name == finalName }
        items.append(HeadlightMemoryItem(name: finalName, percent: clamped))
        items.sort { $0.percent < $1.percent }
        save(items)
        return items
    }

    static func remove(_ item: HeadlightMemoryItem) -> [HeadlightMemoryItem] {
        var items = load()
        items.removeAll { $0 == item }
        save(items)
        return items
    }
}

/// 维修密码（4 位）的一次性校验会话，控制器与灯具共用
@MainActor
final class DeviceSession: ObservableObject {
    static let shared = DeviceSession()

    @Published var showServicePassword = false
    @Published var serviceError = ""
    @Published private(set) var serviceVerified = false

    private var pending: ((Bool) -> Void)?

    func requestServiceAuth(_ completion: @escaping (Bool) -> Void) {
        pending = completion
        serviceError = ""
        showServicePassword = true
    }

    func submit(_ code: String) {
        guard code == DeviceAuth.serviceCode else {
            serviceError = "密码错误，请重新输入"
            return
        }
        serviceVerified = true
        showServicePassword = false
        pending?(true)
        pending = nil
    }

    func cancel() {
        pending?(false)
        pending = nil
        showServicePassword = false
    }

    func resetServiceAuth() {
        serviceVerified = false
    }
}
