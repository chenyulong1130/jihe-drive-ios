import Foundation

// MARK: - Schema

struct VehicleSettingOption: Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

enum VehicleSettingKind {
    case toggle
    case select([VehicleSettingOption])
    case action
}

struct VehicleSettingItem: Identifiable {
    let key: String
    let title: String
    let desc: String?
    let cmd: String
    var version: String = "v2"
    let kind: VehicleSettingKind
    let readKeys: [String]

    var id: String { key }
}

struct VehicleSettingGroup: Identifiable {
    let title: String
    let items: [VehicleSettingItem]
    var id: String { title }
}

enum VehicleSettingError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

// MARK: - 服务

/// 车辆设置：读 vehicleSetInfo，写 propertyOne/one（与安卓版一致）
enum VehicleSettingsService {

    static let groups: [VehicleSettingGroup] = [
        VehicleSettingGroup(title: "骑行", items: [
            VehicleSettingItem(
                key: "kineticEnergyRecovery",
                title: "动能回收",
                desc: "回收减速能量，湿滑路面慎用",
                cmd: "62",
                kind: .select([
                    VehicleSettingOption(value: "0", label: "关闭"),
                    VehicleSettingOption(value: "1", label: "标准"),
                    VehicleSettingOption(value: "2", label: "增强")
                ]),
                readKeys: ["kineticEnergyRecovery"]
            ),
            VehicleSettingItem(
                key: "cruiseControlHold",
                title: "动态定速巡航",
                desc: "加速后松开转把，恢复巡航速度",
                cmd: "64",
                kind: .toggle,
                readKeys: ["cruiseControlFunction", "cruiseMode"]
            ),
            VehicleSettingItem(
                key: "etcsTractionControl",
                title: "eTCS 牵引力控制",
                desc: "控制动力输出，减少湿滑路面打滑",
                cmd: "59",
                kind: .toggle,
                readKeys: ["tcsTractionControl", "etcsTractionControl"]
            ),
            VehicleSettingItem(
                key: "precisionEndurance",
                title: "精准续航",
                desc: "按骑行习惯估算续航里程",
                cmd: "55",
                version: "",
                kind: .toggle,
                readKeys: ["precisionEndurance"]
            ),
            VehicleSettingItem(
                key: "barkePower",
                title: "电子制动",
                desc: "刹车时切断动力输出",
                cmd: "57",
                kind: .toggle,
                readKeys: ["barkePower"]
            ),
            VehicleSettingItem(
                key: "extendedRange",
                title: "增程模式",
                desc: "低电量时优先保障续航，动力受限",
                cmd: "72",
                version: "",
                kind: .toggle,
                readKeys: ["extendedRange"]
            ),
            VehicleSettingItem(
                key: "automaticParking",
                title: "自动驻车",
                desc: "长捏刹车后保持车辆静止",
                cmd: "51",
                kind: .toggle,
                readKeys: ["automaticParking"]
            )
        ]),
        VehicleSettingGroup(title: "解锁", items: [
            VehicleSettingItem(
                key: "inductiveDistance",
                title: "感应解锁距离",
                desc: "手机靠近车辆多远自动解锁",
                cmd: "54",
                kind: .select([
                    VehicleSettingOption(value: "1", label: "更近"),
                    VehicleSettingOption(value: "3", label: "默认"),
                    VehicleSettingOption(value: "5", label: "更远")
                ]),
                readKeys: ["inductiveDistance"]
            ),
            VehicleSettingItem(
                key: "passwordUnlocking",
                title: "密码解锁",
                desc: "输入密码即可解锁车辆",
                cmd: "74",
                kind: .toggle,
                readKeys: ["passwordUnlocking"]
            ),
            VehicleSettingItem(
                key: "originNfc",
                title: "NFC 卡片钥匙",
                desc: "用 NFC 卡片贴近仪表解锁",
                cmd: "90",
                kind: .toggle,
                readKeys: ["originNfc"]
            ),
            VehicleSettingItem(
                key: "openCushion",
                title: "远程解锁坐垫",
                desc: "座桶弹开后 5 秒内可打开",
                cmd: "28",
                kind: .action,
                readKeys: []
            )
        ])
    ]

    static func fetch(vin: String) async throws -> [String: Any] {
        let response = try await ZeehoClient.shared.get(
            "/v1.0/app/cfmotoserverapp/vehicleSet/vehicleSetInfo/\(vin)"
        )
        let code = ZeehoClient.codeString(response["code"])
        if !code.isEmpty, code != "10000" {
            throw VehicleSettingError.message(
                (response["message"] as? String) ?? "车辆设置读取失败（\(code)）"
            )
        }
        return response["data"] as? [String: Any] ?? [:]
    }

    static func write(vin: String, item: VehicleSettingItem, value: String) async throws {
        let body: [String: Any] = [
            "commond": item.cmd,
            "commondParam": value,
            "relatedFunctions": NSNull(),
            "vcu": vin,
            "version": item.version
        ]
        let response = try await ZeehoClient.shared.put(
            "/v1.0/app/cfmotoserverapp/vehicleSet/propertyOne/one",
            body: body
        )
        let code = ZeehoClient.codeString(response["code"])
        if !code.isEmpty, code != "10000" {
            throw VehicleSettingError.message(
                (response["message"] as? String) ?? "下发失败（\(code)）"
            )
        }
    }

    /// 从 raw 里按候选键读当前值，支持 a.b 嵌套
    static func currentValue(in raw: [String: Any], for item: VehicleSettingItem) -> String {
        let keys = item.readKeys.isEmpty ? [item.key] : item.readKeys
        for key in keys {
            if let value = rawValue(in: raw, path: key) {
                return normalize(value)
            }
        }
        return ""
    }

    private static func rawValue(in raw: [String: Any], path: String) -> Any? {
        if path.contains(".") {
            let parts = path.split(separator: ".")
            guard let first = parts.first, let sub = raw[String(first)] as? [String: Any] else {
                return nil
            }
            return sub[parts.dropFirst().joined(separator: ".")]
        }
        return raw[path]
    }

    private static func normalize(_ value: Any) -> String {
        if let bool = value as? Bool { return bool ? "1" : "0" }
        if let number = value as? NSNumber { return number.stringValue }
        if let text = value as? String {
            if text == "true" { return "1" }
            if text == "false" { return "0" }
            return text
        }
        return "\(value)"
    }
}

// MARK: - 状态

@MainActor
final class VehicleSettingsStore: ObservableObject {
    @Published private(set) var raw: [String: Any] = [:]
    @Published private(set) var loading = false
    @Published private(set) var busyKey: String?
    @Published var error: String?

    private var vin: String = ""

    func load(vin: String) async {
        self.vin = vin
        loading = true
        error = nil
        defer { loading = false }
        do {
            raw = try await VehicleSettingsService.fetch(vin: vin)
        } catch VehicleSettingError.message(let text) {
            error = text
        } catch let failure {
            error = failure.localizedDescription
        }
    }

    func value(for item: VehicleSettingItem) -> String {
        VehicleSettingsService.currentValue(in: raw, for: item)
    }

    func toggle(item: VehicleSettingItem) async {
        let current = value(for: item)
        let next = current == "1" ? "0" : "1"
        await send(item: item, value: next)
    }

    func select(item: VehicleSettingItem, newValue: String) async {
        guard newValue != value(for: item) else { return }
        await send(item: item, value: newValue)
    }

    func runAction(item: VehicleSettingItem) async {
        await send(item: item, value: "1")
    }

    private func send(item: VehicleSettingItem, value: String) async {
        guard !vin.isEmpty, busyKey == nil else { return }
        busyKey = item.key
        let previous = raw
        let key = item.readKeys.first ?? item.key
        raw[key] = value

        do {
            try await VehicleSettingsService.write(vin: vin, item: item, value: value)
        } catch let failure {
            raw = previous
            self.error = failure.localizedDescription
        }
        busyKey = nil
    }
}
