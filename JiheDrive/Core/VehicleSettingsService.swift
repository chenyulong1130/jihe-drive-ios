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

enum VehicleSettingEndpoint {
    case property
    /// 与 AppModel.openCushion 一致的通路（cmd 28 坐垫实测可用）
    case propertyTwo
    case soundSize
    case lowPower
    case motoPlay
}

struct VehicleSettingItem: Identifiable {
    let key: String
    let title: String
    let desc: String?
    let cmd: String
    var version: String = "v2"
    let kind: VehicleSettingKind
    let readKeys: [String]
    var endpoint: VehicleSettingEndpoint = .property

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
                readKeys: [],
                endpoint: .propertyTwo
            )
        ]),
        VehicleSettingGroup(title: "快捷键", items: [
            VehicleSettingItem(
                key: "customButtonSingle",
                title: "自定义按键（单击）",
                desc: "按下车上自定义键时执行的功能",
                cmd: "142",
                kind: .select([
                    VehicleSettingOption(value: "7", label: "切换信息组"),
                    VehicleSettingOption(value: "1", label: "Hello 音效"),
                    VehicleSettingOption(value: "3", label: "解锁坐垫"),
                    VehicleSettingOption(value: "10", label: "静音切换"),
                    VehicleSettingOption(value: "19", label: "陡坡缓降"),
                    VehicleSettingOption(value: "20", label: "音量增减"),
                    VehicleSettingOption(value: "31", label: "无操作")
                ]),
                readKeys: ["customButtonSingle", "customButton"]
            )
        ]),
        VehicleSettingGroup(title: "安防", items: [
            VehicleSettingItem(
                key: "inducedVibration",
                title: "震动防盗报警",
                desc: "调整震动报警灵敏度",
                cmd: "61",
                kind: .select([
                    VehicleSettingOption(value: "0", label: "微弱"),
                    VehicleSettingOption(value: "1", label: "标准"),
                    VehicleSettingOption(value: "2", label: "灵敏"),
                    VehicleSettingOption(value: "3", label: "关闭")
                ]),
                readKeys: ["inducedVibration"]
            ),
            VehicleSettingItem(
                key: "automaticShutdownSwitch",
                title: "超时关机保护",
                desc: "长时间停放自动关机，防止电池耗尽",
                cmd: "103",
                kind: .toggle,
                readKeys: ["automaticShutdownSwitch"]
            ),
            VehicleSettingItem(
                key: "automaticShutdownTimeout",
                title: "超时关机时间",
                desc: "触发自动关机的等待时长（分钟）",
                cmd: "108",
                kind: .select([
                    VehicleSettingOption(value: "5", label: "5 分钟"),
                    VehicleSettingOption(value: "10", label: "10 分钟"),
                    VehicleSettingOption(value: "20", label: "20 分钟"),
                    VehicleSettingOption(value: "30", label: "30 分钟"),
                    VehicleSettingOption(value: "60", label: "60 分钟")
                ]),
                readKeys: ["automaticShutdownTimeout"]
            ),
            VehicleSettingItem(
                key: "automaticShutdown",
                title: "离车关机",
                desc: "离开车辆后自动关机",
                cmd: "32",
                kind: .toggle,
                readKeys: ["automaticShutdown"]
            ),
            VehicleSettingItem(
                key: "leaveOffTime",
                title: "离车关机时长",
                desc: "离开后等待多久关机（秒）",
                cmd: "33",
                kind: .select([
                    VehicleSettingOption(value: "3", label: "3 秒"),
                    VehicleSettingOption(value: "5", label: "5 秒"),
                    VehicleSettingOption(value: "10", label: "10 秒"),
                    VehicleSettingOption(value: "30", label: "30 秒"),
                    VehicleSettingOption(value: "60", label: "60 秒"),
                    VehicleSettingOption(value: "120", label: "120 秒")
                ]),
                readKeys: ["leaveOffTime"]
            ),
            VehicleSettingItem(
                key: "emergencyBrakeFlash",
                title: "急刹双闪",
                desc: "急刹时灯光快速闪烁提醒后车",
                cmd: "107",
                kind: .toggle,
                readKeys: ["emergencyBrakeFlash"]
            )
        ]),
        VehicleSettingGroup(title: "感应", items: [
            VehicleSettingItem(
                key: "cushionSensor",
                title: "座垫感应",
                desc: "坐垫受压后才可进入骑行状态",
                cmd: "66",
                kind: .toggle,
                readKeys: ["cushionSensor", "ecushionSensor"]
            ),
            VehicleSettingItem(
                key: "edgeSupportSensing",
                title: "边撑感应",
                desc: "检测边撑是否收起，未收起不可骑行",
                cmd: "73",
                kind: .toggle,
                readKeys: ["edgeSupportSensing"]
            )
        ]),
        VehicleSettingGroup(title: "灯光", items: [
            VehicleSettingItem(
                key: "comeHomeWithYou",
                title: "伴我回家",
                desc: "关机后大灯延时熄灭",
                cmd: "56",
                kind: .toggle,
                readKeys: ["comeHomeWithYou"]
            ),
            VehicleSettingItem(
                key: "comeHomeWithYouTime",
                title: "延时关灯",
                desc: "大灯延时关闭时间（秒）",
                cmd: "58",
                kind: .select([
                    VehicleSettingOption(value: "3", label: "3 秒"),
                    VehicleSettingOption(value: "10", label: "10 秒"),
                    VehicleSettingOption(value: "30", label: "30 秒"),
                    VehicleSettingOption(value: "60", label: "60 秒"),
                    VehicleSettingOption(value: "120", label: "120 秒")
                ]),
                readKeys: ["comeHomeWithYouTime"]
            )
        ]),
        VehicleSettingGroup(title: "仪表", items: [
            VehicleSettingItem(
                key: "mileageUnit",
                title: "里程单位",
                desc: nil,
                cmd: "2",
                kind: .select([
                    VehicleSettingOption(value: "1", label: "公制 km"),
                    VehicleSettingOption(value: "2", label: "英制 mile")
                ]),
                readKeys: ["mileageUnit"]
            ),
            VehicleSettingItem(
                key: "temperatureUnit",
                title: "温度单位",
                desc: nil,
                cmd: "3",
                kind: .select([
                    VehicleSettingOption(value: "1", label: "摄氏度 ℃"),
                    VehicleSettingOption(value: "2", label: "华氏度 ℉")
                ]),
                readKeys: ["temperatureUnit"]
            ),
            VehicleSettingItem(
                key: "timeFormat",
                title: "时间格式",
                desc: nil,
                cmd: "5",
                kind: .select([
                    VehicleSettingOption(value: "1", label: "12 小时制"),
                    VehicleSettingOption(value: "2", label: "24 小时制")
                ]),
                readKeys: ["timeFormat"]
            )
        ]),
        VehicleSettingGroup(title: "音效", items: [
            VehicleSettingItem(
                key: "soundEffectSetting.soundSize",
                title: "音量",
                desc: "提示音音量大小",
                cmd: "",
                kind: .select([
                    VehicleSettingOption(value: "0", label: "静音"),
                    VehicleSettingOption(value: "20", label: "20"),
                    VehicleSettingOption(value: "40", label: "40"),
                    VehicleSettingOption(value: "60", label: "60"),
                    VehicleSettingOption(value: "80", label: "80"),
                    VehicleSettingOption(value: "100", label: "100")
                ]),
                readKeys: ["soundEffectSetting.soundSize", "soundSize"],
                endpoint: .soundSize
            )
        ]),
        VehicleSettingGroup(title: "电池", items: [
            VehicleSettingItem(
                key: "lowPower",
                title: "低电量提醒",
                desc: "电量低于该阈值时车辆提醒",
                cmd: "",
                kind: .select([
                    VehicleSettingOption(value: "10", label: "10%"),
                    VehicleSettingOption(value: "15", label: "15%"),
                    VehicleSettingOption(value: "20", label: "20%"),
                    VehicleSettingOption(value: "25", label: "25%"),
                    VehicleSettingOption(value: "30", label: "30%")
                ]),
                readKeys: ["lowPower"],
                endpoint: .lowPower
            ),
            VehicleSettingItem(
                key: "motoPlay",
                title: "投屏开关",
                desc: "仪表画面联动到 App 端展示",
                cmd: "",
                kind: .toggle,
                readKeys: ["motoPlay"],
                endpoint: .motoPlay
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
        let response: [String: Any]
        switch item.endpoint {
        case .soundSize:
            let size = min(100, max(0, Int(value) ?? 0))
            response = try await ZeehoClient.shared.put(
                "/v1.0/app/cfmotoserverapp/vehicleSet/soundSize",
                body: ["size": size, "vcu": vin]
            )
        case .lowPower:
            response = try await ZeehoClient.shared.put(
                "/v1.0/app/cfmotoserverapp/vehicleSet/lowPowerRule/one",
                body: ["ruleId": "", "value": value, "vcu": vin]
            )
        case .motoPlay:
            response = try await ZeehoClient.shared.put(
                "/v1.0/app/cfmotoserverapp/vehicleSet/motoPlay/one",
                body: ["vinNo": vin, "motoPlay": value == "1" ? 1 : 0]
            )
        case .propertyTwo:
            // 与车辆页坐垫按钮完全一致（cmd 28 实测走 propertyTwo）
            response = try await ZeehoClient.shared.put(
                "/v1.0/app/cfmotoserverapp/vehicleSet/propertyTwo/one",
                body: [
                    "commond": item.cmd,
                    "commondParam": value,
                    "vcu": vin,
                    "version": item.version
                ]
            )
        case .property:
            response = try await ZeehoClient.shared.put(
                "/v1.0/app/cfmotoserverapp/vehicleSet/propertyOne/one",
                body: [
                    "commond": item.cmd,
                    "commondParam": value,
                    "relatedFunctions": NSNull(),
                    "vcu": vin,
                    "version": item.version
                ]
            )
        }
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

    fileprivate static func rawValue(in raw: [String: Any], path: String) -> Any? {
        // 顶层精确命中优先（快路径，且避免同名嵌套键误伤）
        if path.contains(".") {
            let parts = path.split(separator: ".")
            if let first = parts.first, let sub = raw[String(first)] as? [String: Any] {
                let rest = parts.dropFirst().joined(separator: ".")
                if let direct = sub[rest] { return direct }
            }
        } else if let direct = raw[path] {
            return direct
        }
        // 兜底：vehicleSetInfo 的载荷结构可能有包层（data.property 之类），
        // 顶层找不到就 BFS 递归搜同名键（复用电池解析的 JSONDig）
        return JSONDig.first(raw, keys: [path])
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

    /// 排查用：vehicleSetInfo 原始载荷的格式化文本
    var rawJSON: String {
        guard !raw.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "(空)"
        }
        return text
    }

    @discardableResult
    func toggle(item: VehicleSettingItem) async -> Bool {
        let current = value(for: item)
        let next = current == "1" ? "0" : "1"
        return await send(item: item, value: next)
    }

    @discardableResult
    func select(item: VehicleSettingItem, newValue: String) async -> Bool {
        guard newValue != value(for: item) else { return true }
        return await send(item: item, value: newValue)
    }

    @discardableResult
    func runAction(item: VehicleSettingItem) async -> Bool {
        await send(item: item, value: "1")
    }

    @discardableResult
    private func send(item: VehicleSettingItem, value: String) async -> Bool {
        guard !vin.isEmpty, busyKey == nil else { return false }
        busyKey = item.key
        error = nil
        let previous = raw
        applyOptimistic(item: item, value: value)

        do {
            try await VehicleSettingsService.write(vin: vin, item: item, value: value)
            busyKey = nil
            return true
        } catch let failure {
            raw = previous
            self.error = failure.localizedDescription
            busyKey = nil
            return false
        }
    }

    private func applyOptimistic(item: VehicleSettingItem, value: String) {
        // 别名键全部同步：vehicleSetInfo 里同一设置可能落在任意一个别名键上
        // （如 cruiseControlFunction / cruiseMode），只写第一个会造成
        // 「界面切了、服务器刷新后弹回去」的显示不一致
        let keys = item.readKeys.isEmpty ? [item.key] : item.readKeys
        var touched = false
        for key in keys {
            if VehicleSettingsService.rawValue(in: raw, path: key) != nil {
                setRawValue(path: key, value: value)
                touched = true
            }
        }
        if !touched, let first = keys.first {
            setRawValue(path: first, value: value)
        }
    }

    private func setRawValue(path: String, value: String) {
        if path.contains(".") {
            let parts = path.split(separator: ".").map(String.init)
            guard parts.count >= 2 else {
                raw[path] = value
                return
            }
            var nested = raw[parts[0]] as? [String: Any] ?? [:]
            nested[parts.dropFirst().joined(separator: ".")] = value
            raw[parts[0]] = nested
        } else {
            raw[path] = value
        }
    }
}
