import Foundation

/// 胎压监测读数（单位 bar）
struct TireReading: Equatable {
    var frontBar: Double?
    var rearBar: Double?
    var frontTemp: Double?
    var rearTemp: Double?
    var warning: Int = 0
    var updatedAt: String?

    var hasData: Bool { frontBar != nil || rearBar != nil }

    var isWarning: Bool { warning != 0 }
}

/// 官方胎压传感器接口
enum TireService {

    static func fetch(vin: String) async -> TireReading? {
        guard let response = try? await ZeehoClient.shared.get(
            "/v1.0/app/cfmotoserverapp/app/vehicle/tire/monitoring",
            query: [
                "vinNo": vin,
                "timePeriodType": "1",
                "sensorType": "EXTERNAL"
            ]
        ) else { return nil }

        let code = ZeehoClient.codeString(response["code"])
        guard code.isEmpty || code == "10000" else { return nil }
        guard let data = response["data"] as? [String: Any] else { return nil }
        return parse(data)
    }

    static func parse(_ data: [String: Any]) -> TireReading? {
        var reading = TireReading()
        reading.updatedAt = shortTime(data["updateTime"] as? String)

        if let list = data["realTimeData"] as? [[String: Any]] {
            var unordered: [(bar: Double, temp: Double?)] = []

            for item in list {
                let position = wheelPosition(item["sensorPosition"] ?? item["position"] ?? item["tirePosition"])
                guard let pressure = positiveBar(item["tirePressure"] ?? item["pressure"] ?? item["tyrePressure"]) else { continue }
                let temperature = Vehicle.doubleValue(
                    item["tireTemp"] ?? item["tyreTemp"] ?? item["tireTemperature"]
                        ?? item["temperature"] ?? item["temp"]
                )

                if position == .front {
                    reading.frontBar = pressure
                    reading.frontTemp = temperature
                } else if position == .rear {
                    reading.rearBar = pressure
                    reading.rearTemp = temperature
                } else {
                    // 小程序兜底：非 1/2 位号时按出现顺序填前/后轮
                    unordered.append((pressure, temperature))
                }

                let warning = Vehicle.intValue(item["warningType"])
                if warning > 0 { reading.warning = warning }
            }

            if reading.frontBar == nil, let first = unordered.first {
                reading.frontBar = first.bar
                reading.frontTemp = first.temp
            }
            if reading.rearBar == nil, unordered.count > 1 {
                reading.rearBar = unordered[1].bar
                reading.rearTemp = unordered[1].temp
            } else if reading.rearBar == nil, unordered.count == 1, reading.frontBar != nil {
                // 只剩一个未归位传感器且前轮已有时，不当后轮重复
            }
        }

        // 实时数据没给就用统计里的最后一个采样点
        if !reading.hasData,
           let stats = data["statisticsData"] as? [String: Any],
           let list = stats["data"] as? [[String: Any]] {
            for item in list {
                let position = wheelPosition(item["sensorPosition"] ?? item["position"] ?? item["tirePosition"])
                if let stat = item["tirePressureStat"] as? [String: Any],
                   let points = stat["list"] as? [[String: Any]],
                   let last = points.last,
                   let value = positiveBar(last["value"] ?? last["displayedValue"]) {
                    if position == .front { reading.frontBar = value }
                    if position == .rear { reading.rearBar = value }
                }
                if let stat = item["tireTempStat"] as? [String: Any],
                   let points = stat["list"] as? [[String: Any]],
                   let last = points.last,
                   let temp = Vehicle.doubleValue(last["value"] ?? last["displayedValue"]) {
                    if position == .front { reading.frontTemp = temp }
                    if position == .rear { reading.rearTemp = temp }
                }
            }
        }

        return reading.hasData ? reading : nil
    }

    private enum WheelSlot { case front, rear }

    /// 官方两位传感器：1/前=前轮，2/后=后轮。
    private static func wheelPosition(_ raw: Any?) -> WheelSlot? {
        let text = "\(raw ?? "")".trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.contains("FRONT") || text.contains("前") { return .front }
        if text.contains("REAR") || text.contains("后") { return .rear }
        let number = Vehicle.intValue(raw)
        if number == 1 { return .front }
        if number == 2 { return .rear }
        return nil
    }

    /// 0 / 负值不当作有效胎压（对齐小程序 firstNum）
    private static func positiveBar(_ raw: Any?) -> Double? {
        guard let value = Vehicle.doubleValue(raw), value > 0.3, value < 6 else { return nil }
        return value
    }

    private static func shortTime(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return String(raw.prefix(16))
    }
}

struct TireHistoryPoint: Identifiable {
    var id: Double { time }
    let time: Double
    let value: Double
}

struct TireHistoryWheel: Identifiable {
    var id: String { pos }
    let pos: String
    let points: [TireHistoryPoint]
    let min: Double?
    let max: Double?
    let avg: Double?
}

struct TireHistory {
    let from: Double
    let to: Double
    let wheels: [TireHistoryWheel]
}

enum TireHistoryService {
    static func fetch(vin: String, period: String) async -> TireHistory? {
        var query = H5Client.mineQuery
        query["sensorType"] = "EXTERNAL"
        query["timePeriodType"] = period
        query["vinNo"] = vin
        guard let response = try? await H5Client.get(
            "/cfmotoserverapp/H5/vehicle/tire/statistics",
            query: query
        ) else { return nil }
        let code = ZeehoClient.codeString(response["code"])
        guard code.isEmpty || code == "10000" else { return nil }
        return parse(response["data"])
    }

    static func parse(_ raw: Any?) -> TireHistory? {
        guard let data = raw as? [String: Any] else { return nil }
        let list = (data["data"] as? [[String: Any]]) ?? (data["list"] as? [[String: Any]]) ?? []
        var wheels: [TireHistoryWheel] = []
        for item in list {
            let pos = Vehicle.intValue(item["sensorPosition"]) == 1 ? "front" : "rear"
            guard let stat = item["tirePressureStat"] as? [String: Any] else { continue }
            let pts = ((stat["list"] as? [[String: Any]]) ?? []).compactMap { row -> TireHistoryPoint? in
                guard let t = Vehicle.doubleValue(row["time"]),
                      let v = Vehicle.doubleValue(row["value"]) else { return nil }
                return TireHistoryPoint(time: t * 1000, value: v)
            }.sorted { $0.time < $1.time }
            guard !pts.isEmpty else { continue }
            wheels.append(
                TireHistoryWheel(
                    pos: pos,
                    points: pts,
                    min: Vehicle.doubleValue(stat["min"]),
                    max: Vehicle.doubleValue(stat["max"]),
                    avg: Vehicle.doubleValue(stat["avg"])
                )
            )
        }
        guard !wheels.isEmpty else { return nil }
        return TireHistory(
            from: (Vehicle.doubleValue(data["startTime"]) ?? 0) * 1000,
            to: (Vehicle.doubleValue(data["endTime"]) ?? 0) * 1000,
            wheels: wheels
        )
    }
}
