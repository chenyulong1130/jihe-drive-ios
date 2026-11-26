import Foundation
import CoreBluetooth

// MARK: - 设备分类

enum DeviceKind: String, CaseIterable, Identifiable {
    case bms
    case controller
    case shilanLight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bms: return "BMS 保护板"
        case .controller: return "电机控制器"
        case .shilanLight: return "石栏大灯调节"
        }
    }

    var shortTitle: String {
        switch self {
        case .bms: return "BMS"
        case .controller: return "控制器"
        case .shilanLight: return "石栏大灯"
        }
    }

    var detail: String {
        switch self {
        case .bms: return "实时电压 / 电流 / 单体 / 保护状态 / 通道诊断"
        case .controller: return "电机位置 / 限位 / 速度 / 自检 / 车型预设"
        case .shilanLight: return "SL- 前缀：调节大灯高低 / 8 位开机密码校验"
        }
    }

    var icon: String {
        switch self {
        case .bms: return "battery.100.bolt"
        case .controller: return "gearshape.2"
        case .shilanLight: return "headlight.beam"
        }
    }

    /// 石栏与控制器共用 5A A5 电机帧，进入前需要 8 位开机密码校验
    var requiresPowerAuth: Bool {
        switch self {
        case .bms: return false
        case .controller, .shilanLight: return true
        }
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
    static let powerOnCode = "22222222"
    static let serviceCode = "0241"

    private static let powerKey = "device.auth.poweron.v1"
    private static let expireKey = "device.auth.poweron.expire"

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
