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
            query: ["vinNo": vin, "timePeriodType": "1"]
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
            for item in list {
                let position = Vehicle.intValue(item["sensorPosition"])
                let pressure = Vehicle.doubleValue(item["tirePressure"])
                let temperature = Vehicle.doubleValue(item["tireTemp"])
                if position == 1 {
                    reading.frontBar = pressure
                    reading.frontTemp = temperature
                } else if position == 2 {
                    reading.rearBar = pressure
                    reading.rearTemp = temperature
                }
                let warning = Vehicle.intValue(item["warningType"])
                if warning > 0 { reading.warning = warning }
            }
        }

        // 实时数据没给就用统计里的最后一个采样点
        if !reading.hasData,
           let stats = data["statisticsData"] as? [String: Any],
           let list = stats["data"] as? [[String: Any]] {
            for item in list {
                let position = Vehicle.intValue(item["sensorPosition"])
                guard let stat = item["tirePressureStat"] as? [String: Any],
                      let points = stat["list"] as? [[String: Any]],
                      let last = points.last,
                      let value = Vehicle.doubleValue(last["value"]) else { continue }
                if position == 1 { reading.frontBar = value }
                if position == 2 { reading.rearBar = value }
            }
        }

        return reading.hasData ? reading : nil
    }

    private static func shortTime(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return String(raw.prefix(16))
    }
}
