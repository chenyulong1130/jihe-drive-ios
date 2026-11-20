import Foundation

/// 高德逆地理：经纬度 → 短地址（POI / 街道优先，不要坐标串）
enum AmapGeocode {
    private static let key = "f4a9d2af73baa386f745df84b4eeb777"
    private static var cache: [String: String] = [:]

    /// 看起来像坐标串（如 `120.1234, 30.5678`）时不当成地址
    static func looksLikeCoordinate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^-?\d{1,3}(\.\d+)?\s*,\s*-?\d{1,3}(\.\d+)?$"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"^-?\d{1,3}\.\d{3,}"#, options: .regularExpression) != nil,
           trimmed.range(of: #"-?\d{1,2}\.\d{3,}"#, options: .regularExpression) != nil {
            return true
        }
        return false
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
            "output=json&location=\(longitude),\(latitude)&extensions=all&radius=80&coordsys=autonavi&key=\(key)"
                .utf8
        )

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              "\(json["status"] ?? "")" == "1",
              let regeo = json["regeocode"] as? [String: Any] else {
            return nil
        }

        let short = shortAddress(regeo)
        guard !short.isEmpty, !looksLikeCoordinate(short) else { return nil }
        cache[cacheKey] = short
        return short
    }

    private static func shortAddress(_ regeo: [String: Any]) -> String {
        let ac = regeo["addressComponent"] as? [String: Any] ?? [:]
        let streetNo = ac["streetNumber"] as? [String: Any] ?? [:]

        if let pois = regeo["pois"] as? [[String: Any]] {
            for poi in pois.prefix(3) {
                let name = text(poi["name"])
                if !name.isEmpty { return name }
            }
        }

        let neighborhood = text((ac["neighborhood"] as? [String: Any])?["name"])
        if !neighborhood.isEmpty { return neighborhood }

        let building = text((ac["building"] as? [String: Any])?["name"])
        if !building.isEmpty { return building }

        let street = text(streetNo["street"]) + text(streetNo["number"])
        if !street.isEmpty { return street }

        let township = text(ac["township"])
        if !township.isEmpty { return township }

        var out = text(regeo["formatted_address"] ?? regeo["formattedAddress"])
        guard !out.isEmpty else { return "" }

        let cityRaw = ac["city"]
        let city: String = {
            if let list = cityRaw as? [Any] { return list.map { "\($0)" }.joined() }
            return text(cityRaw)
        }()
        for prefix in [text(ac["province"]), city, text(ac["district"])] {
            if !prefix.isEmpty, out.hasPrefix(prefix) {
                out = String(out.dropFirst(prefix.count))
            } else if !prefix.isEmpty {
                out = out.replacingOccurrences(of: prefix, with: "")
            }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text(regeo["formatted_address"]) : trimmed
    }

    private static func text(_ raw: Any?) -> String {
        if raw == nil || raw is NSNull { return "" }
        if let list = raw as? [Any] {
            return list.map { text($0) }.filter { !$0.isEmpty }.joined()
        }
        if let map = raw as? [String: Any] {
            return text(map["name"] ?? map["street"])
        }
        let value = "\(raw!)".trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "[]" || value == "<null>" { return "" }
        return value
    }
}
