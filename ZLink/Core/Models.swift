import Foundation

struct Vehicle: Identifiable, Hashable {
    let vinNo: String
    let name: String
    let soc: Int
    let rangeKm: Int
    let totalMileKm: Double
    let isOnline: Bool
    let isLocked: Bool
    let isCharging: Bool
    let signalLevel: Int
    let latitude: Double?
    let longitude: Double?
    let locationTime: String?
    let imageURL: URL?
    let monthMileage: String?

    var id: String { vinNo }

    var coordinate: Coordinate? {
        guard let latitude, let longitude, latitude != 0, longitude != 0 else {
            return nil
        }
        return Coordinate(latitude: latitude, longitude: longitude)
    }
}

struct Coordinate: Hashable {
    let latitude: Double
    let longitude: Double
}

extension Vehicle {
    init?(json: [String: Any]) {
        let vin = Self.firstString(json, keys: ["vinNo", "frameNo", "vin"]) ?? ""
        guard !vin.isEmpty else { return nil }

        let iot = Self.iotProperties(json["iotProperties"])
        let location = json["location"] as? [String: Any]

        self.vinNo = vin
        self.name = Self.firstString(json, keys: ["vehicleName", "vehicleTypeName", "modelName", "deviceName", "name"]) ?? "我的车辆"
        self.soc = Self.intValue(json["bmssoc"] ?? iot["BMSSOC"] ?? iot["bmssoc"])
        self.rangeKm = Self.intValue(json["hmiRidableMile"] ?? iot["HMIRidableMile"] ?? iot["hmiRidableMile"])
        self.totalMileKm = Self.doubleValue(json["totalRideMile"] ?? iot["TotalRideMile"]) ?? 0
        self.isOnline = Self.onlineHint(json) ?? false
        self.isLocked = Self.lockState(json, iot)
        self.isCharging = Self.chargingState(json, iot)
        self.signalLevel = Self.intValue(json["gsmRxLev"] ?? iot["GSMRxLev"])
        let latitude = location.flatMap { Self.doubleValue($0["latitude"]) }
        let longitude = location.flatMap { Self.doubleValue($0["longitude"]) }
        self.latitude = (latitude ?? 0) == 0 ? nil : latitude
        self.longitude = (longitude ?? 0) == 0 ? nil : longitude
        self.locationTime = location?["locationTime"] as? String
        self.imageURL = Self.firstString(json, keys: ["customImage", "vehicleScalePicUrl", "vehiclePicUrl", "vehicleBackPicUrl", "pic", "imageUrl"]).flatMap(URL.init(string:))
        self.monthMileage = Self.dashValue(json["rideMileageMonth"])
    }

    static func list(from response: [String: Any]) -> [Vehicle] {
        flatten(response["data"]).compactMap(Vehicle.init(json:))
    }

    private static func flatten(_ raw: Any?) -> [[String: Any]] {
        if let array = raw as? [[String: Any]] { return array }
        if let dict = raw as? [String: Any] {
            for key in ["vehicles", "vehicleList", "list", "records", "rows", "items"] {
                if let nested = dict[key] {
                    let items = flatten(nested)
                    if !items.isEmpty { return items }
                }
            }
            if dict["vinNo"] != nil || dict["vehicleName"] != nil || dict["deviceName"] != nil {
                return [dict]
            }
        }
        return []
    }

    /// iotProperties 可能是 [{identify, value}] 或 {key: {value}}
    static func iotProperties(_ raw: Any?) -> [String: Any] {
        if let array = raw as? [[String: Any]] {
            var out: [String: Any] = [:]
            for item in array {
                if let key = item["identify"] as? String {
                    out[key] = item["value"]
                }
            }
            return out
        }
        if let dict = raw as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict {
                if let inner = value as? [String: Any], let nested = inner["value"] {
                    out[key] = nested
                } else {
                    out[key] = value
                }
            }
            return out
        }
        return [:]
    }

    private static func firstString(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    static func intValue(_ raw: Any?) -> Int {
        if let number = raw as? Int { return number }
        if let number = raw as? Double { return Int(number) }
        if let string = raw as? String, let number = Double(string) { return Int(number) }
        return 0
    }

    static func doubleValue(_ raw: Any?) -> Double? {
        if let number = raw as? Double { return number }
        if let number = raw as? Int { return Double(number) }
        if let string = raw as? String { return Double(string) }
        return nil
    }

    private static func dashValue(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "--" || trimmed == "null" { return nil }
        return trimmed
    }

    private static func onlineHint(_ json: [String: Any]) -> Bool? {
        if let status = (json["onlineStatus"] as? String)?.uppercased() {
            if status == "ONLINE" { return true }
            if status == "OFFLINE" { return false }
        }
        if let ride = json["rideState"] as? String {
            if ride.contains("在线") { return true }
            if !ride.isEmpty { return false }
        }
        return nil
    }

    private static func lockState(_ json: [String: Any], _ iot: [String: Any]) -> Bool {
        if let raw = json["lockStatus"] ?? iot["LockStatus"] ?? iot["lockStatus"] {
            let text = "\(raw)".lowercased()
            if text == "0" { return true }
            if text == "1" { return false }
            return text.contains("lock") && !text.contains("unlock")
        }
        if let head = json["headLockState"] ?? iot["HeadLockState"] {
            return "\(head)" == "1"
        }
        return true
    }

    private static func chargingState(_ json: [String: Any], _ iot: [String: Any]) -> Bool {
        for key in ["chargeState", "whetherChargeState", "ChargeState", "BMSChargeState"] {
            if let raw = json[key] ?? iot[key], "\(raw)" == "1" { return true }
        }
        if let status = json["chargeStatus"] as? String {
            return status == "1" || status.lowercased().contains("charg")
        }
        return false
    }
}

struct RideTrack: Identifiable, Hashable {
    let id: String
    let startTime: String?
    let mileage: Double
    let durationMinutes: Int
    let points: [Coordinate]

    static func parse(_ response: [String: Any]) -> [RideTrack] {
        guard let data = response["data"] else { return [] }
        let items: [[String: Any]]
        if let array = data as? [[String: Any]] {
            items = array
        } else if let dict = data as? [String: Any],
                  let array = (dict["list"] ?? dict["records"] ?? dict["tracks"]) as? [[String: Any]] {
            items = array
        } else {
            items = []
        }
        return items.enumerated().compactMap { index, item in
            let points = Self.points(item["trackPointList"] ?? item["points"] ?? item["trackPoints"])
            guard !points.isEmpty || item["startTime"] != nil else { return nil }
            return RideTrack(
                id: (item["id"] ?? item["trackId"]).map { "\($0)" } ?? "track-\(index)",
                startTime: item["startTime"] as? String ?? item["startTimeStr"] as? String,
                mileage: Vehicle.doubleValue(item["mileage"] ?? item["rideMileage"]) ?? 0,
                durationMinutes: Vehicle.intValue(item["ridingTime"] ?? item["duration"]),
                points: points
            )
        }
    }

    static func points(_ raw: Any?) -> [Coordinate] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { point in
            guard let lat = Vehicle.doubleValue(point["latitude"] ?? point["lat"]),
                  let lng = Vehicle.doubleValue(point["longitude"] ?? point["lng"] ?? point["lon"]),
                  lat != 0, lng != 0 else { return nil }
            return Coordinate(latitude: lat, longitude: lng)
        }
    }
}
