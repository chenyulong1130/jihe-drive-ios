import Foundation

/// 电池信息。云端字段名在不同版本里不一致，解析时按候选键递归查找。
struct BatteryInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let level: Int
    let voltage: Double
    let temperature: Double
    let type: String
    let stateText: String
    let isCharging: Bool
    let isPulledOut: Bool
    let abnormal: String?
    let chargeMinutes: Int?
    let fullChargeText: String?
    let cycleCount: Int?
    let capacity: Double?

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

    private static func make(_ json: [String: Any], index: Int) -> BatteryInfo? {
        let level = intValue(JSONDig.first(json, keys: ["batteryLevel", "bmssoc", "batterySoc", "soc"]))
        let voltage = doubleValue(JSONDig.first(json, keys: ["batteryVoltage", "voltage", "totalVoltage"]))
        let temp = doubleValue(JSONDig.first(json, keys: ["batteryTemp", "temperature", "temp"]))
        let type = stringValue(JSONDig.first(json, keys: ["batteryType", "type"]))
        let rawState = JSONDig.first(json, keys: ["batteryState", "batteryStateStr", "state"])
        let powerState = JSONDig.first(json, keys: ["batteryPowerState", "chargeState", "whetherChargeState"])
        let pulled = stringValue(JSONDig.first(json, keys: ["batteryPullOutFlag", "pullOutFlag"]))
        let abnormal = stringValue(JSONDig.first(json, keys: ["batteryAbnormalType", "abnormalType"]))
        let chargeSeconds = intValue(JSONDig.first(json, keys: ["chargeDuration", "chargeDurationSecond"]))
        let fullCharge = stringValue(JSONDig.first(json, keys: ["fullChargeTime", "chargeTimeString", "fullChargeTimeSecond"]))
        let cycle = intValue(JSONDig.first(json, keys: ["cycleCount", "batteryCycleCount", "cycle"]))
        let capacity = doubleValue(JSONDig.first(json, keys: ["batteryCapacity", "capacity", "remainCapacity"]))
        let name = stringValue(JSONDig.first(json, keys: ["batteryName", "bmsUniqueId", "batteryNo", "name"]))

        let parsedState = stateText(rawState, powerState: powerState)
        let charging = parsedState.contains("充")

        let typeName = type ?? ""
        let batteryName = name ?? ""
        let pulledFlag = pulled ?? ""

        if level == 0 && voltage == 0 && temp == 0 && typeName.isEmpty && batteryName.isEmpty {
            return nil
        }

        return BatteryInfo(
            id: batteryName.isEmpty ? "battery-\(index)" : "\(batteryName)-\(index)",
            name: batteryName.isEmpty ? "电池 \(index + 1)" : batteryName,
            level: max(0, min(100, level)),
            voltage: voltage,
            temperature: temp,
            type: typeName.isEmpty ? "锂电池" : typeName,
            stateText: parsedState,
            isCharging: charging,
            isPulledOut: pulledFlag == "1" || pulledFlag.lowercased() == "true",
            abnormal: (abnormal?.isEmpty ?? true) || abnormal == "0" ? nil : abnormal,
            chargeMinutes: chargeSeconds > 0 ? chargeSeconds / 60 : nil,
            fullChargeText: fullCharge?.isEmpty == true ? nil : fullCharge,
            cycleCount: cycle > 0 ? cycle : nil,
            capacity: (capacity ?? 0) > 0 ? capacity : nil
        )
    }

    private static func stateText(_ raw: Any?, powerState: Any?) -> String {
        if let text = stringValue(raw), !text.isEmpty {
            switch text {
            case "0": break
            case "1": return "充电中"
            case "2": return "放电中"
            case "3": return "待机"
            default: return text
            }
        }
        if let text = stringValue(powerState), !text.isEmpty {
            if text == "1" || text.lowercased().contains("charg") { return "充电中" }
        }
        return "待机"
    }

    /// 在 data 里找电池数组（列表可能包在 list / batteryInfoList / batteryInfos 里）
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
        if let number = raw as? Double { return number }
        if let number = raw as? Int { return Double(number) }
        if let text = raw as? String, let number = Double(text) { return number }
        if let number = raw as? NSNumber { return number.doubleValue }
        return 0
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
