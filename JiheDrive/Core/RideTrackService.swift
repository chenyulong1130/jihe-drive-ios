import Foundation

/// 官方骑行轨迹接口（分享页同款合并轨迹）
/// GET /cfmotoserverapp/share/merge/ridetrack?vinNo=&startTimeFrom=&startTimeTo=
/// 返回 trajectory = "lng,lat,speed&lng,lat,speed&..."
enum RideTrackService {

    private static let dashed: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let dotted: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd HH:mm:ss"
        return formatter
    }()

    static func track(vin: String, day: Date) async -> RideTrack? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) else {
            return nil
        }

        for formatter in [dashed, dotted] {
            let query = [
                "vinNo": vin,
                "startTimeFrom": formatter.string(from: start),
                "startTimeTo": formatter.string(from: end)
            ]
            guard let response = try? await ZeehoClient.shared.get(
                "/v1.0/app/cfmotoserverapp/share/merge/ridetrack",
                query: query
            ) else { continue }

            let code = ZeehoClient.codeString(response["code"])
            guard code.isEmpty || code == "10000" else { continue }
            guard let data = response["data"] as? [String: Any] else { continue }
            if let track = parse(data, fallbackID: formatter.string(from: start)) {
                return track
            }
        }
        return nil
    }

    static func parse(_ data: [String: Any], fallbackID: String) -> RideTrack? {
        let points = points(from: data["trajectory"])
        guard points.count > 1 else { return nil }

        let mileage = Vehicle.doubleValue(data["rideMileage"]) ?? 0
        let minutes = Int(Vehicle.doubleValue(data["ridingTimeUnitMinute"]) ?? 0)

        return RideTrack(
            id: (data["trackId"] ?? data["id"]).map { "\($0)" } ?? fallbackID,
            startTime: display(data["startTime"] as? String),
            mileage: mileage,
            durationMinutes: max(minutes, 1),
            points: points,
            endTime: display(data["endTime"] as? String),
            maxSpeed: Vehicle.doubleValue(data["maxSpeed"]),
            startAddress: address(from: data["startAddr"]),
            endAddress: address(from: data["endAddr"])
        )
    }

    private static func points(from raw: Any?) -> [Coordinate] {
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

    private static func address(from raw: Any?) -> String? {
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

    /// "2026.11.20 08:12:33" → "11.20 08:12"
    private static func display(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let segments = raw.replacingOccurrences(of: "-", with: ".").split(separator: " ")
        guard let datePart = segments.first else { return raw }
        let timePart = segments.count > 1 ? String(segments[1].prefix(5)) : ""
        let comps = datePart.split(separator: ".")
        let shortDate = comps.count >= 3 ? "\(comps[1]).\(comps[2])" : String(datePart)
        return timePart.isEmpty ? shortDate : "\(shortDate) \(timePart)"
    }
}
