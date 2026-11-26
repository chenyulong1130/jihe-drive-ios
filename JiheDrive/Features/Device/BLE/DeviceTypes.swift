import Foundation
import CoreBluetooth

// MARK: - 设备分类

enum DeviceKind: String, CaseIterable, Identifiable {
    case bms
    case shilanLight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bms: return "保护板"
        case .shilanLight: return "石栏大灯"
        }
    }

    var shortTitle: String {
        switch self {
        case .bms: return "保护板"
        case .shilanLight: return "石栏"
        }
    }

    var detail: String {
        switch self {
        case .bms: return "蚂蚁 / 彦阳 · 电压 / 电流 / 单体 / 保护"
        case .shilanLight: return "石栏协议 · NB- / SL- 大灯高低调节"
        }
    }

    var icon: String {
        switch self {
        case .bms: return "battery.100.bolt"
        case .shilanLight: return "headlight.high.beam"
        }
    }

    /// 设备页主推：保护板 + 石栏
    static let primaryKinds: [DeviceKind] = [.bms, .shilanLight]

    /// 石栏沿用小程序的 8 位开机密码校验，BMS 不需要
    var requiresPowerAuth: Bool {
        switch self {
        case .bms: return false
        case .shilanLight: return true
        }
    }

    /// 广播名 / 服务 UUID 分类；无法识别则返回 nil（扫描时直接丢弃）
    static func classify(name: String, serviceUUIDs: [CBUUID]?) -> DeviceKind? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        // 石栏：NB- / SL-
        if upper.contains("NB-") || upper.contains("SL-") { return .shilanLight }
        // 保护板：蚂蚁 ANT / 彦阳 YY（先接这两家）
        if BMSBrand.detect(name: trimmed) != nil { return .bms }
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

/// 石栏大灯记忆位置：本地持久化（用户调好高度后选择保存），设备列表与详情页共用
enum HeadlightMemory {
    static let key = "device.headlight.memory.percents"

    static func load() -> [Int] {
        UserDefaults.standard.array(forKey: key) as? [Int] ?? []
    }

    static func save(_ list: [Int]) {
        UserDefaults.standard.set(list, forKey: key)
    }

    /// 添加记忆（去重排序），返回最新列表
    static func add(_ percent: Int) -> [Int] {
        var list = load()
        if !list.contains(percent) {
            list.append(min(100, max(0, percent)))
            list.sort()
        }
        save(list)
        return list
    }

    static func remove(_ percent: Int) -> [Int] {
        var list = load()
        list.removeAll { $0 == percent }
        save(list)
        return list
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
