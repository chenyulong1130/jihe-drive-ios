import Foundation

/// 高德逆地理：经纬度 → 短地址（与小程序 / Flutter 同源）
enum AmapGeocode {
    private static let key = "f4a9d2af73baa386f745df84b4eeb777"
    private static var cache: [String: String] = [:]

    /// 看起来像坐标串（如 `120.1234, 30.5678`）时不当成地址
    static func looksLikeCoordinate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^-?\d{1,3}(\.\d+)?\s*,\s*-?\d{1,3}(\.\d+)?$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    static func readableAddress(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !looksLikeCoordinate(trimmed) else { return nil }
        return trimmed
    }

    static func reverse(longitude: Double, latitude: Double) async -> String? {
        let cacheKey = String(format: "%.5f,%.5f", longitude, latitude)
        if let hit = cache[cacheKey], !hit.isEmpty { return hit }

        var request = URLRequest(
            url: URL(string: "https://dualstack-arestapi.amap.com/v3/geocode/regeo")!
        )
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 6
        request.httpBody = Data(
            "output=json&location=\(longitude),\(latitude)&extensions=base&radius=50&coordsys=autonavi&key=\(key)"
                .utf8
        )

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              "\(json["status"] ?? "")" == "1",
              let regeo = json["regeocode"] as? [String: Any] else {
            return nil
        }

        let short = shortAddress(regeo)
        guard !short.isEmpty else { return nil }
        cache[cacheKey] = short
        return short
    }

    private static func shortAddress(_ regeo: [String: Any]) -> String {
        var out = "\(regeo["formatted_address"] ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return "" }

        let ac = regeo["addressComponent"] as? [String: Any] ?? [:]
        let cityRaw = ac["city"]
        let city: String = {
            if let list = cityRaw as? [Any] {
                return list.map { "\($0)" }.joined()
            }
            return "\(cityRaw ?? "")"
        }()

        for prefix in ["\(ac["province"] ?? "")", city, "\(ac["district"] ?? "")"] {
            let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty, out.hasPrefix(p) {
                out = String(out.dropFirst(p.count))
            } else if !p.isEmpty {
                out = out.replacingOccurrences(of: p, with: "")
            }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "\(regeo["formatted_address"] ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
    }
}
