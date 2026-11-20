import Foundation

struct Vehicle: Identifiable, Hashable {
    let vinNo: String
    let name: String
    /// 车型名（vehicleTypeName / modelName）
    let modelName: String?
    let soc: Int
    let rangeKm: Int
    let totalMileKm: Double
    let isOnline: Bool
    /// 接口是否明确给了在线状态（无则 merge 时不覆盖列表）
    let onlineKnown: Bool
    let isLocked: Bool
    let isCharging: Bool
    /// 信号格 0–5（gsmRxLevel），不是 dBm
    let signalLevel: Int
    let signalText: String?
    let latitude: Double?
    let longitude: Double?
    let locationTime: String?
    /// 位置文字（接口给就去掉经纬度兜底）
    let address: String?
    let imageURL: URL?
    let monthMileage: String?
    /// 本月骑行时长（分钟文案）
    let monthRideMinutes: String?
    /// 胎压，统一换算成 kPa 存，展示时除 100 得到 bar
    let tireFrontKpa: Double?
    let tireRearKpa: Double?
    /// 车辆接口里带的电池读数，电池详情接口失败时兜底
    let voltage: Double?
    let temperature: Double?
    let cycleCount: Int?
    /// 官方 3D 模型地址（部分车型才有）
    let model3DURL: URL?
    /// 仪表壁纸轮廓（subjectWallpaperConfig）
    let wallpaperOutlines: WallpaperOutlines?
    /// 是否车主（carMaster != "0"）
    let isCarMaster: Bool
    let shareNickName: String?

    var id: String { vinNo }

    /// 分享车辆（非车主）
    var isShared: Bool { !isCarMaster }

    var hasTirePressure: Bool { tireFrontKpa != nil || tireRearKpa != nil }

    func withLocked(_ locked: Bool) -> Vehicle {
        Vehicle(
            vinNo: vinNo,
            name: name,
            modelName: modelName,
            soc: soc,
            rangeKm: rangeKm,
            totalMileKm: totalMileKm,
            isOnline: isOnline,
            onlineKnown: onlineKnown,
            isLocked: locked,
            isCharging: isCharging,
            signalLevel: signalLevel,
            signalText: signalText,
            latitude: latitude,
            longitude: longitude,
            locationTime: locationTime,
            address: address,
            imageURL: imageURL,
            monthMileage: monthMileage,
            monthRideMinutes: monthRideMinutes,
            tireFrontKpa: tireFrontKpa,
            tireRearKpa: tireRearKpa,
            voltage: voltage,
            temperature: temperature,
            cycleCount: cycleCount,
            model3DURL: model3DURL,
            wallpaperOutlines: wallpaperOutlines,
            isCarMaster: isCarMaster,
            shareNickName: shareNickName
        )
    }

#if !WIDGET_EXTENSION
    /// 用 V2 / batteryInfo 覆盖电量、续航、充电态（对齐小程序双源合并）
    func withBattery(_ battery: BatteryInfo) -> Vehicle {
        Vehicle(
            vinNo: vinNo,
            name: name,
            modelName: modelName,
            soc: battery.level > 0 ? battery.level : soc,
            rangeKm: battery.rangeKm ?? rangeKm,
            totalMileKm: totalMileKm,
            isOnline: isOnline,
            onlineKnown: onlineKnown,
            isLocked: isLocked,
            isCharging: battery.isCharging || isCharging,
            signalLevel: signalLevel,
            signalText: signalText,
            latitude: latitude,
            longitude: longitude,
            locationTime: locationTime,
            address: address,
            imageURL: imageURL,
            monthMileage: monthMileage,
            monthRideMinutes: monthRideMinutes,
            tireFrontKpa: tireFrontKpa,
            tireRearKpa: tireRearKpa,
            voltage: battery.voltage > 0 ? battery.voltage : voltage,
            temperature: battery.temperature != 0 ? battery.temperature : temperature,
            cycleCount: battery.cycleCount ?? cycleCount,
            model3DURL: model3DURL,
            wallpaperOutlines: wallpaperOutlines,
            isCarMaster: isCarMaster,
            shareNickName: shareNickName
        )
    }
#endif

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
            modelName: detail.modelName ?? modelName,
            soc: detail.soc > 0 ? detail.soc : soc,
            rangeKm: detail.rangeKm > 0 ? detail.rangeKm : rangeKm,
            totalMileKm: detail.totalMileKm > 0 ? detail.totalMileKm : totalMileKm,
            // 在线：详情明确给出才覆盖；锁态：详情 headLockState / lockStatus 为准
            isOnline: detail.onlineKnown ? detail.isOnline : isOnline,
            onlineKnown: detail.onlineKnown || onlineKnown,
            isLocked: detail.isLocked,
            isCharging: detail.isCharging || isCharging,
            signalLevel: detail.signalLevel > 0 ? detail.signalLevel : signalLevel,
            signalText: detail.signalText ?? signalText,
            latitude: detail.latitude ?? latitude,
            longitude: detail.longitude ?? longitude,
            locationTime: detail.locationTime ?? locationTime,
            address: detail.address ?? address,
            imageURL: detail.imageURL ?? imageURL,
            monthMileage: detail.monthMileage ?? monthMileage,
            monthRideMinutes: detail.monthRideMinutes ?? monthRideMinutes,
            tireFrontKpa: detail.tireFrontKpa ?? tireFrontKpa,
            tireRearKpa: detail.tireRearKpa ?? tireRearKpa,
            voltage: detail.voltage ?? voltage,
            temperature: detail.temperature ?? temperature,
            cycleCount: detail.cycleCount ?? cycleCount,
            model3DURL: detail.model3DURL ?? model3DURL,
            wallpaperOutlines: detail.wallpaperOutlines ?? wallpaperOutlines,
            isCarMaster: isCarMaster && detail.isCarMaster,
            shareNickName: detail.shareNickName ?? shareNickName
        )
    }
}

/// 仪表壁纸轮廓 PNG（type 2=主页, type 1=速度卡），对齐 Flutter VehicleWallpaperOutlines
struct WallpaperOutlines: Hashable {
    var homeOutlineURL: URL?
    var speedOutlineURL: URL?
    var speedSubjectURL: URL?

    static let fallback = WallpaperOutlines(
        homeOutlineURL: URL(string: "https://oss-cfmoto.zeehoev.com/uploads/zeeho-client-pc/media/1783574792892.png"),
        speedOutlineURL: URL(string: "https://oss-cfmoto.zeehoev.com/uploads/zeeho-client-pc/media/1783574803780.png"),
        speedSubjectURL: URL(string: "https://oss-cfmoto.zeehoev.com/uploads/zeeho-client-pc/media/1783574799347.png")
    )

    static func parse(_ raw: Any?) -> WallpaperOutlines? {
        let array: [[String: Any]]
        if let list = raw as? [[String: Any]] {
            array = list
        } else if let text = raw as? String,
                  let data = text.data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            array = list
        } else {
            return nil
        }

        var home: URL?
        var speed: URL?
        var subject: URL?
        for item in array {
            let type = "\(item["type"] ?? "")"
            let url = (item["url"] as? String).flatMap(URL.init(string:))
            if type == "2", home == nil { home = url }
            if type == "1" {
                if speed == nil { speed = url }
                if subject == nil {
                    subject = (item["subjectUrl"] as? String).flatMap(URL.init(string:))
                }
            }
        }
        guard home != nil || speed != nil else { return nil }
        return WallpaperOutlines(homeOutlineURL: home, speedOutlineURL: speed, speedSubjectURL: subject)
    }

    func withFallback() -> WallpaperOutlines {
        WallpaperOutlines(
            homeOutlineURL: homeOutlineURL ?? Self.fallback.homeOutlineURL,
            speedOutlineURL: speedOutlineURL ?? Self.fallback.speedOutlineURL,
            speedSubjectURL: speedSubjectURL ?? Self.fallback.speedSubjectURL
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
        self.name = Self.firstString(json, keys: ["vehicleName", "deviceName", "name"]) ?? "我的车辆"
        self.modelName = Self.firstString(json, keys: ["vehicleTypeName", "modelName", "vehicleType"])
        self.soc = Self.intValue(json["bmssoc"] ?? iot["BMSSOC"] ?? iot["bmssoc"])
        self.rangeKm = Self.intValue(json["hmiRidableMile"] ?? iot["HMIRidableMile"] ?? iot["hmiRidableMile"])
        self.totalMileKm = Self.doubleValue(json["totalRideMile"] ?? iot["TotalRideMile"]) ?? 0
        let online = Self.onlineHint(json)
        self.isOnline = online ?? false
        self.onlineKnown = online != nil
        self.isLocked = Self.lockState(json, iot)
        self.isCharging = Self.chargingState(json, iot)
        // carMaster "0" = 被分享；sharedFlag "1" + 昵称也当分享车
        let master = Self.firstString(json, keys: ["carMaster"]) ?? "1"
        let sharedFlag = Self.firstString(json, keys: ["sharedFlag"])
        let nick = Self.firstString(json, keys: ["shareNickName"])
        self.shareNickName = nick
        self.isCarMaster = master != "0" && !(sharedFlag == "1" && (nick?.isEmpty == false))
        // 格数用 gsmRxLevel；gsmRxLev 是 dBm（常为负），不能当格数
        self.signalLevel = Self.signalBars(
            json["gsmRxLevel"] ?? iot["GSMRxLevel"] ?? json["gsmRxLevValue"]
        )
        self.signalText = Self.firstString(json, keys: ["gsmRxLevValue", "signalText"])
            ?? Self.firstString(iot, keys: ["GSMRxLevValue", "gsmRxLevValue"])
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
        self.monthRideMinutes = Self.dashValue(json["ridingTimeMonthUnitMinute"])
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
        self.wallpaperOutlines = WallpaperOutlines.parse(
            json["subjectWallpaperConfig"] ?? json["wallpaperConfig"]
        )
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
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return 0 }
            return number.intValue
        }
        if let number = raw as? Int { return number }
        if let number = raw as? Double { return Int(number) }
        if let string = raw as? String, let number = Double(string) { return Int(number) }
        return 0
    }

    static func doubleValue(_ raw: Any?) -> Double? {
        if raw == nil || raw is NSNull { return nil }
        // JSON 整数是 NSNumber，as? Double 会失败，必须先走 NSNumber
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.doubleValue
        }
        if let number = raw as? Double { return number }
        if let number = raw as? Int { return Double(number) }
        if let string = raw as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func dashValue(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "--" || trimmed == "null" { return nil }
        return trimmed
    }

    private static func onlineHint(_ json: [String: Any]) -> Bool? {
        if let raw = json["onlineStatus"] {
            let status = "\(raw)".trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if status == "ONLINE" || status == "1" || status == "TRUE" { return true }
            if status == "OFFLINE" || status == "0" || status == "FALSE" { return false }
        }
        if let ride = json["rideState"] as? String {
            let text = ride.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("在线") { return true }
            if text.contains("离线") { return false }
            // 非空但不含在线/离线时不当作定论（避免误判）
        }
        return nil
    }

    /// 信号格 0–5；拒绝把负 dBm 当格数
    private static func signalBars(_ raw: Any?) -> Int {
        guard let value = doubleValue(raw) else { return 0 }
        if value < 0 { return 0 }
        return min(5, max(0, Int(value)))
    }

    /// 对齐 Flutter / 小程序：lockStatus 0=锁 1=开 → headLockState → 缺省已锁
    private static func lockState(_ json: [String: Any], _ iot: [String: Any]) -> Bool {
        if let raw = json["lockStatus"] ?? iot["LockStatus"] ?? iot["lockStatus"] {
            let text = "\(raw)".trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if text == "0" { return true }
            if text == "1" { return false }
        }
        if let head = json["headLockState"] ?? iot["HeadLockState"] {
            let text = "\(head)".trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "1" { return true }
            if text == "0" { return false }
        }
        if let raw = json["lockStatus"] ?? iot["LockStatus"] ?? iot["lockStatus"] {
            let text = "\(raw)".lowercased()
            return text.contains("lock") && !text.contains("unlock")
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
    /// 与 points 对齐的速度采样（km/h），回放按速度着色
    var speedSamples: [Double] = []
    var accelTimes: Int = 0
    var brakeTimes: Int = 0
    var bendTimes: Int = 0
    var thumbnailURL: URL? = nil
    /// 分组用，yyyy.MM.dd
    var dayKey: String? = nil
    /// 本次耗电 SOC%
    var socUsed: Double? = nil
    /// 本次能耗 Wh（接口给大数时）
    var energyWh: Double? = nil

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
