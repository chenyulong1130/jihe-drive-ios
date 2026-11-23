import Foundation

/// 电池信息。合并 vehicleHomePageV2（充电骨架）+ batteryInfo（实时电压电流）。
struct BatteryInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let level: Int
    let voltage: Double
    let temperature: Double
    let current: Double?
    let power: Double?
    let type: String
    let stateText: String
    let isCharging: Bool
    let isPulledOut: Bool
    let abnormal: String?
    let chargeMinutes: Int?
    let fullChargeText: String?
    let chargeTimeString: String?
    let etaFullText: String?
    let cycleCount: Int?
    let capacity: Double?
    let soh: Double?
    let score: String?
    let rangeKm: Int?
    let refreshTime: String?
    let powerUseToday: Double?
    let powerUseMonth: Double?
    let powerChargeMonth: Double?
    let chargeCount: Int?
    /// V2 `onlineStatus == ONLINE`
    let isOnline: Bool?
    /// 接口单独给的电池等级，和 SOC 不是同一个字段
    let batteryLevel: Int?
    /// 调 batteryInfo/detail/{id} 用
    let detailId: String?

    var hasLiveElectrical: Bool { voltage > 0 || current != nil || power != nil }

    /// 以电池接口实时状态为准：有实测电流/功率就是充电中；
    /// 只有"充"状态文案而没有实时电气数据（电池服务过期、数据断流）不算
    var isLiveCharging: Bool {
        if isPulledOut { return false }
        if stateText.contains("放电") { return false }
        if let current, abs(current) > 0.3 { return true }
        if let power, power > 10 { return true }
        guard stateText.contains("充") else { return false }
        return current != nil || power != nil
    }

    var hasChargeInfo: Bool {
        isCharging
            || !(chargeTimeString ?? "").isEmpty
            || !(etaFullText ?? "").isEmpty
            || chargeMinutes != nil
    }

    var hasUsage: Bool {
        powerUseToday != nil || powerUseMonth != nil || powerChargeMonth != nil || chargeCount != nil
    }

    func merged(with other: BatteryInfo) -> BatteryInfo {
        BatteryInfo(
            id: other.detailId != nil ? other.id : (detailId != nil ? id : other.id),
            name: Self.pickName(other.name, name),
            level: other.level > 0 ? other.level : level,
            voltage: other.voltage > 0 ? other.voltage : voltage,
            temperature: other.temperature != 0 ? other.temperature : temperature,
            current: other.current ?? current,
            power: other.power ?? power,
            type: other.type == "锂电池" ? (type.isEmpty ? other.type : type) : other.type,
            stateText: other.stateText.isEmpty ? stateText : other.stateText,
            isCharging: other.isCharging,
            isPulledOut: isPulledOut || other.isPulledOut,
            abnormal: other.abnormal ?? abnormal,
            chargeMinutes: other.chargeMinutes ?? chargeMinutes,
            fullChargeText: other.fullChargeText ?? fullChargeText,
            chargeTimeString: Self.nonempty(other.chargeTimeString) ?? chargeTimeString,
            etaFullText: Self.nonempty(other.etaFullText) ?? etaFullText,
            cycleCount: other.cycleCount ?? cycleCount,
            capacity: other.capacity ?? capacity,
            soh: other.soh ?? soh,
            score: Self.nonempty(other.score) ?? score,
            rangeKm: other.rangeKm ?? rangeKm,
            refreshTime: other.refreshTime ?? refreshTime,
            powerUseToday: other.powerUseToday ?? powerUseToday,
            powerUseMonth: other.powerUseMonth ?? powerUseMonth,
            powerChargeMonth: other.powerChargeMonth ?? powerChargeMonth,
            chargeCount: other.chargeCount ?? chargeCount,
            isOnline: other.isOnline ?? isOnline,
            batteryLevel: other.batteryLevel ?? batteryLevel,
            detailId: other.detailId ?? detailId
        )
    }

    static func parse(_ response: [String: Any]) -> [BatteryInfo] {
        let data = response["data"] ?? response

        if let items = array(in: data) {
            let parsed = items.enumerated().compactMap { index, item -> BatteryInfo? in
                make(item, index: index)
            }
            if !parsed.isEmpty { return parsed }
        }
        if let single = data as? [String: Any], let one = make(single, index: 0) {
            return [one]
        }
        return []
    }

    static func fallback(from vehicle: Vehicle) -> BatteryInfo {
        BatteryInfo(
            id: "vehicle-\(vehicle.vinNo)",
            name: "动力电池",
            level: vehicle.soc,
            voltage: scaledVolts(vehicle.voltage ?? 0),
            temperature: vehicle.temperature ?? 0,
            current: nil,
            power: nil,
            type: "锂电池",
            stateText: vehicle.isCharging ? "充电中" : "待机",
            isCharging: vehicle.isCharging,
            isPulledOut: false,
            abnormal: nil,
            chargeMinutes: nil,
            fullChargeText: nil,
            chargeTimeString: nil,
            etaFullText: nil,
            cycleCount: vehicle.cycleCount,
            capacity: nil,
            soh: nil,
            score: nil,
            rangeKm: vehicle.rangeKm > 0 ? vehicle.rangeKm : nil,
            refreshTime: nil,
            powerUseToday: nil,
            powerUseMonth: nil,
            powerChargeMonth: nil,
            chargeCount: nil,
            isOnline: vehicle.isOnline,
            batteryLevel: nil,
            detailId: nil
        )
    }

    private static func make(_ json: [String: Any], index: Int) -> BatteryInfo? {
        let level = intValue(JSONDig.first(json, keys: [
            "bmssoc", "batterySoc", "soc", "BmsSoc"
        ]))
        let grade = intValue(JSONDig.first(json, keys: ["batteryLevel"]))
        let voltage = scaledVolts(doubleValue(JSONDig.first(json, keys: [
            "bmsVoltage", "batteryVoltage", "voltage", "totalVoltage", "packVoltage"
        ])))
        let temp = doubleValue(JSONDig.first(json, keys: [
            "batteryTemp", "temperature", "temp", "bmsTemp"
        ]))
        let currentRaw = JSONDig.first(json, keys: ["current", "bmsCurrent", "chargeCurrent", "dischargeCurrent"])
        let current = optionalDouble(currentRaw)
        let powerRaw = JSONDig.first(json, keys: ["batteryPower", "power", "chargePower"])
        let power = optionalDouble(powerRaw)
        let type = stringValue(JSONDig.first(json, keys: ["batteryType", "type"]))
        // 键序即优先级：chargeState/chargeStateStr 是真实充电状态（实测充电中 "1"/"充电中"）。
        // batteryState/batteryPowerState 是恒为 "0" 的无关字段，绝不能排在前面——
        // 旧键序让它们永远遮蔽真实状态，导致任何版本都显示不出"充电中"。
        let rawState = JSONDig.first(json, keys: ["chargeStateStr", "batteryStateStr", "chargeState", "batteryState", "state"])
        let powerState = JSONDig.first(json, keys: [
            "chargeState", "whetherChargeState", "batteryPowerState"
        ])
        let pulled = stringValue(JSONDig.first(json, keys: ["batteryPullOutFlag", "pullOutFlag"]))
        let abnormal = stringValue(JSONDig.first(json, keys: ["batteryAbnormalType", "abnormalType"]))
        let chargeSeconds = intValue(JSONDig.first(json, keys: [
            "chargeDuration", "chargeDurationSecond", "fullChargeTimeSecond"
        ]))
        let fullMin = intValue(JSONDig.first(json, keys: ["fullChargeTime"]))
        let fullCharge = stringValue(JSONDig.first(json, keys: [
            "fullChargeTime", "chargeTimeString", "fullChargeTimeSecond"
        ]))
        let cycle = intValue(JSONDig.first(json, keys: ["cycleCount", "batteryCycleCount", "cycle"]))
        let capacity = doubleValue(JSONDig.first(json, keys: [
            "batteryCapacity", "capacity", "remainCapacity", "remainAh"
        ]))
        let name = stringValue(JSONDig.first(json, keys: [
            "batteryName", "bmsUniqueId", "batteryNo", "name", "deviceId"
        ]))
        let detailId = stringValue(JSONDig.first(json, keys: [
            "bmsUniqueId", "batteryNo", "deviceId", "batteryId", "id"
        ]))
        let soh = optionalDouble(JSONDig.first(json, keys: ["soh", "batterySoh", "health"]))
        let score = stringValue(JSONDig.first(json, keys: ["score", "batteryScore"]))
        let range = intValue(JSONDig.first(json, keys: [
            "hmiRidableMile", "HMIRidableMile", "ridableMile", "remainMileage",
            "remainMile", "rangeKm", "hmiRideableMile"
        ]))
        let refresh = stringValue(JSONDig.first(json, keys: ["refreshTime", "updateTime", "ts"]))
        let chargeTimeString = stringValue(JSONDig.first(json, keys: ["chargeTimeString"]))
        let eta = stringValue(JSONDig.first(json, keys: [
            "expectFullTimeDescribe", "etaFullText", "expectFullTime"
        ]))

        let parsedState = stateText(rawState, powerState: powerState)
        // 不能用 contains("充")："未充电"也含"充"字，会误判成充电中
        let charging = parsedState == "充电中" || boolCharge(powerState)
        let online = optionalOnline(JSONDig.first(json, keys: ["onlineStatus", "isOnline", "online"]))
        let soc = level > 0 ? level : grade

        let typeName = type ?? ""
        let batteryName = name ?? ""
        let pulledFlag = pulled ?? ""

        if soc == 0 && voltage == 0 && temp == 0 && current == nil && power == nil
            && typeName.isEmpty && batteryName.isEmpty && !charging && online == nil {
            return nil
        }

        let chargeMin: Int? = {
            if fullMin > 0, fullMin < 24 * 60 { return fullMin }
            if chargeSeconds > 60 { return chargeSeconds / 60 }
            if chargeSeconds > 0 { return chargeSeconds }
            return nil
        }()

        return BatteryInfo(
            id: batteryName.isEmpty ? "battery-\(index)" : "\(batteryName)-\(index)",
            name: batteryName.isEmpty ? "动力电池" : batteryName,
            level: max(0, min(100, soc)),
            voltage: voltage,
            temperature: temp,
            current: current,
            power: power,
            type: typeName.isEmpty ? "锂电池" : typeName,
            stateText: parsedState,
            isCharging: charging,
            isPulledOut: pulledFlag == "1" || pulledFlag.lowercased() == "true",
            abnormal: (abnormal?.isEmpty ?? true) || abnormal == "0" ? nil : abnormal,
            chargeMinutes: chargeMin,
            fullChargeText: fullCharge?.isEmpty == true ? nil : fullCharge,
            chargeTimeString: chargeTimeString,
            etaFullText: eta,
            cycleCount: cycle > 0 ? cycle : nil,
            capacity: capacity > 0 ? capacity : nil,
            soh: soh.flatMap { $0 > 0 ? $0 : nil },
            score: score,
            rangeKm: range > 0 ? range : nil,
            refreshTime: refresh,
            powerUseToday: optionalDouble(JSONDig.first(json, keys: ["powerUseToday", "todayPower"])),
            powerUseMonth: optionalDouble(JSONDig.first(json, keys: ["powerUseMonth", "monthPower"])),
            powerChargeMonth: optionalDouble(JSONDig.first(json, keys: ["powerChargeMonth"])),
            chargeCount: {
                let n = intValue(JSONDig.first(json, keys: ["chargeCount", "monthChargeCount"]))
                return n > 0 ? n : nil
            }(),
            isOnline: online,
            batteryLevel: grade > 0 ? grade : nil,
            detailId: detailId
        )
    }

    /// >300 视为 0.1V 刻度（724 → 72.4V），对齐小程序 voltScale
    private static func scaledVolts(_ raw: Double) -> Double {
        guard raw > 0 else { return 0 }
        return raw > 300 ? (raw / 10) : raw
    }

    private static func optionalOnline(_ raw: Any?) -> Bool? {
        if let flag = raw as? Bool { return flag }
        guard let text = stringValue(raw)?.uppercased(), !text.isEmpty else { return nil }
        if text == "ONLINE" || text == "1" || text == "TRUE" { return true }
        if text == "OFFLINE" || text == "0" || text == "FALSE" { return false }
        return nil
    }

    private static func boolCharge(_ raw: Any?) -> Bool {
        if let flag = raw as? Bool { return flag }
        let text = stringValue(raw)?.lowercased() ?? ""
        return text == "1" || text == "true" || text.contains("charg")
    }

    private static func stateText(_ raw: Any?, powerState: Any?) -> String {
        if let text = stringValue(raw), !text.isEmpty {
            switch text {
            case "0": break
            case "1": return "充电中"
            case "2": return "放电中"
            case "3": return "待机"
            default:
                if text != "0" { return text }
            }
        }
        if boolCharge(powerState) { return "充电中" }
        return "待机"
    }

    private static func array(in data: Any) -> [[String: Any]]? {
        if let array = data as? [[String: Any]] { return array }
        guard let dict = data as? [String: Any] else { return nil }
        for key in ["batteryInfoList", "batteryInfos", "list", "records", "rows", "items"] {
            if let nested = dict[key] {
                if let array = nested as? [[String: Any]] { return array }
                if let inner = nested as? [String: Any],
                   let array = inner["list"] as? [[String: Any]] {
                    return array
                }
            }
        }
        return nil
    }

    private static func pickName(_ a: String, _ b: String) -> String {
        if a == "动力电池" || a.hasPrefix("battery-") { return b.isEmpty ? a : b }
        return a.isEmpty ? b : a
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let number = raw as? Int { return number }
        if let number = raw as? Double { return Int(number) }
        if let text = raw as? String, let number = Double(text) { return Int(number) }
        if let number = raw as? NSNumber { return number.intValue }
        return 0
    }

    private static func doubleValue(_ raw: Any?) -> Double {
        optionalDouble(raw) ?? 0
    }

    private static func optionalDouble(_ raw: Any?) -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.doubleValue
        }
        if let number = raw as? Double { return number }
        if let number = raw as? Int { return Double(number) }
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            return Double(trimmed)
        }
        return nil
    }
}

/// 在任意深度的 JSON 里按候选键取第一个非空值
enum JSONDig {
    static func first(_ root: Any, keys: [String]) -> Any? {
        var queue: [Any] = [root]
        var guardCount = 0

        while !queue.isEmpty && guardCount < 4000 {
            guardCount += 1
            let node = queue.removeFirst()

            if let dict = node as? [String: Any] {
                for key in keys {
                    if let value = dict[key], !isBlank(value) {
                        return value
                    }
                }
                for (_, value) in dict {
                    if value is [String: Any] || value is [Any] {
                        queue.append(value)
                    }
                }
            } else if let array = node as? [Any] {
                for value in array where value is [String: Any] || value is [Any] {
                    queue.append(value)
                }
            }
        }
        return nil
    }

    private static func isBlank(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespaces).isEmpty }
        return false
    }
}
