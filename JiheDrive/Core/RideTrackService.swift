import Foundation

/// 骑行数据接口（与小程序 / 安卓版一致，均已在真机验证）
/// - 按次明细：GET /ridetrack_v2?vinNo=&startDateTime=yyyy-MM-dd&endDateTime=yyyy-MM-dd&startTime=yyyy-MM&endTime=yyyy-MM&page=&pageSize=
///   ⚠️ 日期与月份必须横线分隔
/// - 单日汇总：GET /rideDayInfo?vinNo=&date=yyyy.MM.dd
///   ⚠️ 这里是点分隔，横线会返回 40000
enum RideTrackService {

    private static let dashedDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dashedMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private static let dottedDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()

    // MARK: - 按次明细

    static func tracks(
        vin: String,
        days: Int = 7,
        page: Int = 1,
        pageSize: Int = 20
    ) async -> [RideTrack]? {
        let calendar = Calendar.current
        let today = Date()
        guard let from = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) else {
            return nil
        }

        let query = [
            "vinNo": vin,
            "startDateTime": dashedDay.string(from: from),
            "endDateTime": dashedDay.string(from: today),
            "startTime": dashedMonth.string(from: from),
            "endTime": dashedMonth.string(from: today),
            "page": "\(page)",
            "pageSize": "\(pageSize)"
        ]

        guard let response = try? await ZeehoClient.shared.get(
            "/v1.0/app/cfmotoserverapp/ridetrack_v2",
            query: query
        ) else { return nil }

        let code = ZeehoClient.codeString(response["code"])
        guard code.isEmpty || code == "10000" else { return nil }
        return parse(response["data"])
    }

    /// data 可能是 [{ dayTime, historyList: [...] }]，也可能直接是行程数组
    static func parse(_ data: Any?) -> [RideTrack] {
        let groups: [[String: Any]] = {
            if let array = data as? [[String: Any]] { return array }
            if let dict = data as? [String: Any], let list = dict["list"] as? [[String: Any]] {
                return list
            }
            return []
        }()

        var items: [[String: Any]] = []
        for group in groups {
            let history = (group["historyList"]
                ?? group["rideRocordList"]
                ?? group["rideList"]
                ?? group["recordList"]) as? [[String: Any]]
            if let history {
                items.append(contentsOf: history)
            } else if group["rideId"] != nil || group["trajectory"] != nil {
                items.append(group)
            }
        }

        let pairs = items.enumerated().compactMap { index, item -> (String, RideTrack)? in
            let points = trajectory(item["trajectory"])
            guard points.count > 1 else { return nil }

            let start = text(item["startTime"] ?? item["beginTime"] ?? item["rideBeginTime"])
            let end = text(item["endTime"] ?? item["finishTime"] ?? item["rideEndTime"])
            let track = RideTrack(
                id: text(item["rideId"] ?? item["id"]) ?? "ride-\(index)",
                startTime: display(start),
                mileage: Vehicle.doubleValue(item["rideMileage"] ?? item["mileage"] ?? item["distance"]) ?? 0,
                durationMinutes: max(Int(Vehicle.doubleValue(item["ridingTimeUnitMinute"]) ?? 0), 1),
                points: points,
                endTime: display(end),
                maxSpeed: Vehicle.doubleValue(item["maxSpeed"]),
                startAddress: address(item["startAddr"] ?? item["startAddress"]),
                endAddress: address(item["endAddr"] ?? item["endAddress"])
            )
            return (start ?? "", track)
        }

        return pairs.sorted { $0.0 > $1.0 }.map { $0.1 }
    }

    // MARK: - 单日汇总

    struct DaySummary {
        var mileage: Double
        var minutes: Int
        var maxSpeed: Double
    }

    static func daySummary(vin: String, date: Date = Date()) async -> DaySummary? {
        let query = [
            "vinNo": vin,
            "date": dottedDay.string(from: date)
        ]
        guard let response = try? await ZeehoClient.shared.get(
            "/v1.0/app/cfmotoserverapp/rideDayInfo",
            query: query
        ) else { return nil }

        let code = ZeehoClient.codeString(response["code"])
        guard code.isEmpty || code == "10000" else { return nil }
        guard let data = response["data"] as? [String: Any] else { return nil }

        return DaySummary(
            mileage: Vehicle.doubleValue(data["rideMileageDay"]) ?? 0,
            minutes: Int(Vehicle.doubleValue(data["ridingTimeDayUnitMinute"]) ?? 0),
            maxSpeed: Vehicle.doubleValue(data["maxSpeed"]) ?? 0
        )
    }

    // MARK: - 解析工具

    /// trajectory = "lng,lat,speed,ts,x" 用 & 连接
    private static func trajectory(_ raw: Any?) -> [Coordinate] {
        guard let text = raw as? String, !text.isEmpty else { return [] }
        return text.split(separator: "&").compactMap { segment in
            let parts = segment.split(separator: ",")
            guard parts.count >= 2,
                  let lng = Double(String(parts[0]).trimmingCharacters(in: .whitespaces)),
                  let lat = Double(String(parts[1]).trimmingCharacters(in: .whitespaces)),
                  abs(lat) > 0.0001,
                  abs(lng) > 0.0001 else { return nil }
            return Coordinate(latitude: lat, longitude: lng)
        }
    }

    private static func text(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber { return number.stringValue }
        let value = "\(raw)".trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "<null>" ? nil : value
    }

    /// startAddr 是 JSON 串（{"name":"..."}）或纯文本
    private static func address(_ raw: Any?) -> String? {
        if let text = raw as? String {
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String,
               !name.isEmpty {
                return name
            }
            return text.isEmpty ? nil : text
        }
        if let dict = raw as? [String: Any],
           let name = dict["name"] as? String,
           !name.isEmpty {
            return name
        }
        return nil
    }

    /// "2026.11.13 08:12:33" → "11.13 08:12"
    private static func display(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return raw }
        let normalized = raw.replacingOccurrences(of: "-", with: ".")
        let segments = normalized.split(separator: " ")
        guard let datePart = segments.first else { return raw }
        let timePart = segments.count > 1 ? String(segments[1].prefix(5)) : ""
        let comps = datePart.split(separator: ".")
        let shortDate = comps.count >= 3 ? "\(comps[1]).\(comps[2])" : String(datePart)
        return timePart.isEmpty ? shortDate : "\(shortDate) \(timePart)"
    }
}
