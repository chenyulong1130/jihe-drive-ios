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
    /// 位置文字（接口给就去掉经纬度兜底）
    let address: String?
    let imageURL: URL?
    let monthMileage: String?
    /// 胎压，统一换算成 kPa 存，展示时除 100 得到 bar
    let tireFrontKpa: Double?
    let tireRearKpa: Double?
    /// 车辆接口里带的电池读数，电池详情接口失败时兜底
    let voltage: Double?
    let temperature: Double?
    let cycleCount: Int?
    /// 官方 3D 模型地址（部分车型才有）
    let model3DURL: URL?

    var id: String { vinNo }

    var hasTirePressure: Bool { tireFrontKpa != nil || tireRearKpa != nil }

    /// 接口给的是 glb/gltf 时用 model-viewer 渲染
    var isGLBModel: Bool {
        guard let url = model3DURL else { return false }
        let ext = url.pathExtension.lowercased()
        return ext == "glb" || ext == "gltf"
    }

    var coordinate: Coordinate? {
        guard let latitude, let longitude, latitude != 0, longitude != 0 else {
            return nil
        }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    /// 车辆列表只有概要，首页接口返回的细节补进来（胎压、电压、3D 模型等）
    func merged(with detail: Vehicle) -> Vehicle {
        Vehicle(
            vinNo: vinNo,
            name: detail.name == "我的车辆" ? name : detail.name,
            soc: detail.soc > 0 ? detail.soc : soc,
            rangeKm: detail.rangeKm > 0 ? detail.rangeKm : rangeKm,
            totalMileKm: detail.totalMileKm > 0 ? detail.totalMileKm : totalMileKm,
            isOnline: isOnline,
            isLocked: isLocked,
            isCharging: detail.isCharging || isCharging,
            signalLevel: detail.signalLevel > 0 ? detail.signalLevel : signalLevel,
            latitude: detail.latitude ?? latitude,
            longitude: detail.longitude ?? longitude,
            locationTime: detail.locationTime ?? locationTime,
            address: detail.address ?? address,
            imageURL: detail.imageURL ?? imageURL,
            monthMileage: detail.monthMileage ?? monthMileage,
            tireFrontKpa: detail.tireFrontKpa ?? tireFrontKpa,
            tireRearKpa: detail.tireRearKpa ?? tireRearKpa,
            voltage: detail.voltage ?? voltage,
            temperature: detail.temperature ?? temperature,
            cycleCount: detail.cycleCount ?? cycleCount,
            model3DURL: detail.model3DURL ?? model3DURL
        )
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
        self.address = Self.firstString(json, keys: [
            "address", "locationAddress", "positionAddress", "lastAddress",
            "locationDesc", "formattedAddress"
        ]) ?? location?["address"] as? String
        self.imageURL = Self.firstString(json, keys: ["customImage", "vehicleScalePicUrl", "vehiclePicUrl", "vehicleBackPicUrl", "pic", "imageUrl"]).flatMap(URL.init(string:))
        self.monthMileage = Self.dashValue(json["rideMileageMonth"])
        let fields = Self.merge(json, iot)
        self.tireFrontKpa = Self.pressure(json, iot, keys: [
            "frontTirePressure", "frontTyrePressure", "tirePressureFront",
            "FrontTirePressure", "frontTirePress", "tireFrontPressure"
        ]) ?? Self.sniffPressure(fields, front: true)
        self.tireRearKpa = Self.pressure(json, iot, keys: [
            "rearTirePressure", "rearTyrePressure", "tirePressureRear",
            "RearTirePressure", "rearTirePress", "tireRearPressure"
        ]) ?? Self.sniffPressure(fields, front: false)

        let voltage = Self.doubleValue(
            json["batteryVoltage"] ?? json["voltage"] ?? iot["BatteryVoltage"] ?? iot["Voltage"]
        )
        self.voltage = (voltage ?? 0) > 0 ? voltage : nil

        let temperature = Self.doubleValue(
            json["batteryTemp"] ?? json["batteryTemperature"] ?? iot["BatteryTemp"] ?? iot["Temperature"] ?? iot["temp"]
        )
        self.temperature = (temperature ?? 0) != 0 ? temperature : nil

        let cycle = Self.intValue(
            json["cycleCount"] ?? json["batteryCycleCount"] ?? iot["CycleCount"] ?? iot["BatteryCycleCount"]
        )
        self.cycleCount = cycle > 0 ? cycle : nil

        // 先按已知字段取，取不到就递归扫整份 JSON，找任何指向模型文件的地址
        let explicitModel = Self.firstString(json, keys: [
            // 与安卓版一致的优先顺序
            "vehiclePic3dUrl", "vehiclePic3d", "vehicle3dUrl", "vehiclePic3DUrl",
            "model3dUrl", "model3DUrl", "modelUrl", "model3durl", "threeDModelUrl",
            "arModelUrl", "vehicleModel", "model3d", "3dModelUrl", "threeDUrl",
            "sceneUrl", "modelPath", "modelAddress", "carModelUrl", "gltfUrl"
        ]).flatMap(URL.init(string:))
        self.model3DURL = explicitModel ?? Self.findModelURL(in: json)
    }

    /// 在整份响应里递归找模型文件地址（不同车型字段名不统一）
    private static func findModelURL(in value: Any) -> URL? {
        if let text = value as? String {
            let lower = text.lowercased()
            guard lower.hasPrefix("http") || lower.hasPrefix("/") else { return nil }
            let extensions = [".glb", ".gltf", ".usdz", ".usd", ".obj", ".dae", ".ply", ".scn"]
            guard extensions.contains(where: { lower.contains($0) }) else { return nil }
            return URL(string: text)
        }
        if let dict = value as? [String: Any] {
            for child in dict.values {
                if let hit = findModelURL(in: child) { return hit }
            }
            return nil
        }
        if let array = value as? [Any] {
            for child in array {
                if let hit = findModelURL(in: child) { return hit }
            }
            return nil
        }
        return nil
    }

    /// 顶层字段 + iot 字段合并，便于按关键字模糊匹配
    private static func merge(_ json: [String: Any], _ iot: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in iot { out[key.lowercased()] = value }
        for (key, value) in json where !(value is [String: Any]) && !(value is [Any]) {
            out[key.lowercased()] = value
        }
        return out
    }

    /// 车型差异太大，按关键字兜底找胎压：键名同时含 tire/tyre 与 press/kpa/bar
    private static func sniffPressure(_ fields: [String: Any], front: Bool) -> Double? {
        for (key, value) in fields {
            let k = key.lowercased()
            guard k.contains("tire") || k.contains("tyre") else { continue }
            guard k.contains("press") || k.contains("kpa") || k.contains("bar") else { continue }

            let isFront = k.contains("front") || k.contains("qf") || k.contains("frt")
            let isRear = k.contains("rear") || k.contains("back") || k.contains("hb") || k.contains("rr")
            guard front ? isFront : isRear else { continue }

            if let value = doubleValue(value), value > 0 {
                return value <= 10 ? value * 100 : value
            }
        }
        return nil
    }

    /// 胎压原始值可能是 bar（2.4）或 kPa（240），统一成 kPa
    private static func pressure(_ json: [String: Any], _ iot: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let raw = json[key] ?? iot[key],
                  let value = doubleValue(raw),
                  value > 0 else { continue }
            return value <= 10 ? value * 100 : value
        }
        return nil
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
    var endTime: String? = nil
    var maxSpeed: Double? = nil
    var startAddress: String? = nil
    var endAddress: String? = nil

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
