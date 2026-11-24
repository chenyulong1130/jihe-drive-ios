import Foundation

/// 坐垫状态：来自 vehicleHomePageV2 的 seatLockState + refreshTime。
/// 云端是轮询快照，不是实时推送，超过 10 分钟（接口 refreshRate）不再当真。
struct SeatState: Hashable {
    /// true=锁止/关闭，false=已打开（与 headLockState 1=已锁同编码）
    let isClosed: Bool
    /// 云端采样时刻；nil 表示接口没给时间，只能按拉取时刻算新鲜度
    let sampledAt: Date?

    func isOpen(maxAgeSeconds: TimeInterval = 600) -> Bool? {
        if let sampledAt, Date().timeIntervalSince(sampledAt) > maxAgeSeconds {
            return nil
        }
        return !isClosed
    }
}

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
    /// 真实坐垫状态（可变，便于 V2 轮询到位后原地补丁）
    var seat: SeatState?

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
            shareNickName: shareNickName,
            seat: seat
        )
    }

    /// V2 轮询结果到位后只补坐垫字段，不动电量/锁车等其他状态
    func withSeat(_ seat: SeatState?) -> Vehicle {
        var copy = self
        copy.seat = seat
        return copy
    }

#if !WIDGET_EXTENSION
    /// 用 V2 / batteryInfo 覆盖电量、续航、充电态（对齐小程序双源合并）
    func withBattery(_ battery: BatteryInfo) -> Vehicle {
        Vehicle(
            vinNo: vinNo,
            name: name,
            modelName: modelName,
            soc: battery.level > 0 ? battery.level : soc,
            rangeKm: (battery.rangeKm ?? 0) > 0 ? (battery.rangeKm ?? rangeKm) : rangeKm,
            totalMileKm: totalMileKm,
            isOnline: isOnline,
            onlineKnown: onlineKnown,
            isLocked: isLocked,
            isCharging: battery.isLiveCharging,
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
            shareNickName: shareNickName,
            seat: seat
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
            isCharging: detail.isCharging,
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
            shareNickName: detail.shareNickName ?? shareNickName,
            seat: Self.preferSeat(detail.seat, seat)
        )
    }

    /// 列表/详情/V2 三个来源取采样时间更新的那份，避免旧值盖掉新值
    private static func preferSeat(_ lhs: SeatState?, _ rhs: SeatState?) -> SeatState? {
        if let lhs, let rhs {
            return (lhs.sampledAt ?? .distantPast) >= (rhs.sampledAt ?? .distantPast) ? lhs : rhs
        }
        return lhs ?? rhs
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
        self.rangeKm = Self.intValue(
            json["hmiRidableMile"]
                ?? iot["HMIRidableMile"]
                ?? iot["hmiRidableMile"]
                ?? json["ridableMile"]
                ?? json["remainMileage"]
                ?? json["remainMile"]
                ?? json["rangeKm"]
                ?? json["hmiRideableMile"]
        )
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
        self.model3DURL = explicitModel ?? Self.pickModelURL(from: json, modelName: self.modelName)
        self.wallpaperOutlines = WallpaperOutlines.parse(
            json["subjectWallpaperConfig"] ?? json["wallpaperConfig"]
        )
        self.seat = Self.seatState(json, iot)
    }

    /// 从 V2 响应直接取坐垫状态，不依赖完整的 Vin 模型解析
    static func parseSeat(from response: [String: Any]) -> SeatState? {
        let data = (response["data"] as? [String: Any]) ?? response
        return seatState(data, iotProperties(data["iotProperties"]))
    }

    private static func seatState(_ json: [String: Any], _ iot: [String: Any]) -> SeatState? {
        guard let raw = json["seatLockState"] ?? iot["SeatLockState"] ?? iot["seatLockState"] else {
            return nil
        }
        let text = "\(raw)".trimmingCharacters(in: .whitespacesAndNewlines)
        let isClosed: Bool
        if text == "1" {
            isClosed = true
        } else if text == "0" {
            isClosed = false
        } else {
            return nil
        }
        let time = json["refreshTime"] ?? json["seatStateUpdateTime"] ?? iot["SeatStateTime"]
        return SeatState(isClosed: isClosed, sampledAt: seatTimestamp(time))
    }

    private static func seatTimestamp(_ raw: Any?) -> Date? {
        guard let raw, !(raw is NSNull) else { return nil }
        let text = "\(raw)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "<null>" else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // 接口给的是北京时间，别按设备时区解读，否则新鲜度会差几小时
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: text) { return date }
        if let number = Double(text), number > 1_000_000_000 {
            return Date(timeIntervalSince1970: number > 1_000_000_000_000 ? number / 1000 : number)
        }
        return ISO8601DateFormatter().date(from: text)
    }

    /// 在整份响应里递归收集模型文件地址（不同车型字段名不统一）。
    /// 旧版"取第一个命中"的缺陷：响应里若带共享的车型模型列表（多台车/多个
    /// 车型的 glb 都在），每台车都会解析成数组第一个元素——表现为
    /// "切车后 3D 还是第一台车的模型"。现在收集全部候选：
    /// 唯一地址直接用；多个地址时按车型名（字母数字段）归属本车的；
    /// 归属不上才退回第一个（兼容单模型列表的老接口）。
    private static func pickModelURL(from value: Any, modelName: String?) -> URL? {
        var raw: [String] = []
        collectModelURLs(in: value, into: &raw)
        var candidates: [String] = []
        for u in raw where !candidates.contains(u) { candidates.append(u) }
        guard !candidates.isEmpty else { return nil }
        guard candidates.count > 1 else { return URL(string: candidates[0]) }

        // 从车型名里拆出字母数字段（如 "极核AE4-MAX2plus" → ["ae4", "max2plus"]），
        // 任一段在 URL 里出现即认为该地址属于本车
        let nameNorm = (modelName ?? "").lowercased()
        let tokens = nameNorm.split(whereSeparator: { !$0.isNumber && !($0.isLetter && $0.isASCII) })
            .map { String($0) }
            .filter { $0.count >= 2 }
        if let hit = candidates.first(where: { url in
            let u = url.lowercased()
            return tokens.contains { u.contains($0) }
        }) {
            return URL(string: hit)
        }
        return URL(string: candidates[0])
    }

    private static func collectModelURLs(in value: Any, into urls: inout [String]) {
        if let text = value as? String {
            let lower = text.lowercased()
            guard lower.hasPrefix("http") || lower.hasPrefix("/") else { return }
            let extensions = [".glb", ".gltf", ".usdz", ".usd", ".obj", ".dae", ".ply", ".scn"]
            guard extensions.contains(where: { lower.contains($0) }) else { return }
            urls.append(text)
            return
        }
        if let dict = value as? [String: Any] {
            for child in dict.values {
                collectModelURLs(in: child, into: &urls)
            }
            return
        }
        if let array = value as? [Any] {
            for child in array {
                collectModelURLs(in: child, into: &urls)
            }
            return
        }
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
    /// 与 points 对齐的采样 Unix 秒；0 表示该点没有时间
    var timestamps: [TimeInterval] = []
    /// 与 points 对齐的**真实**采样 Unix 秒（多段合并时 timestamps 会压缩跨段空档，
    /// 墙钟显示仍按真实时刻走；单段行程留空，回退到 startedAt 推算）
    var realTimestamps: [TimeInterval] = []
    /// 行程开始（Unix 秒），来自 startTime 原文
    var startedAt: TimeInterval? = nil
    /// 行程结束（Unix 秒），来自 endTime 原文
    var endedAt: TimeInterval? = nil

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

    /// 合并多段轨迹回放。
    /// 关键点：两段骑行之间的空档（同日几小时 / 跨天几天）不参与回放时间轴——
    /// 压缩成 20 秒的过渡，否则回放大部分时间都在"横穿城市/日历"，
    /// 光标跨城乱飞、时间轴被空档占满（多选回放"乱了"的根因）。
    /// 真实时间戳另存 realTimestamps，供墙钟时间显示。
    static func merged(_ tracks: [RideTrack]) -> RideTrack {
        let sorted = tracks.sorted { ($0.startTime ?? "") < ($1.startTime ?? "") }
        guard let first = sorted.first else {
            return RideTrack(id: "empty", startTime: nil, mileage: 0, durationMinutes: 0, points: [])
        }
        if sorted.count == 1 { return first }

        var points: [Coordinate] = []
        var speeds: [Double] = []
        var stamps: [TimeInterval] = []
        var realStamps: [TimeInterval] = []
        /// 跨段压缩的累计偏移；段与段之间超过 3 分钟的空档压成 20 秒
        var shift: TimeInterval = 0
        var lastReal: TimeInterval = 0
        for item in sorted {
            let n = item.points.count
            let itemStamps = item.timestamps.count == n ? item.timestamps : Array(repeating: TimeInterval(0), count: n)
            var firstKnownInTrack = true
            for raw in itemStamps {
                if raw > 1_000_000_000 {
                    if firstKnownInTrack, lastReal > 1_000_000_000 {
                        let gap = raw - lastReal
                        if gap > 180 { shift += gap - 20 }
                    }
                    lastReal = raw
                    firstKnownInTrack = false
                    stamps.append(raw - shift)
                } else {
                    stamps.append(0)
                }
            }
            realStamps.append(contentsOf: itemStamps)
            points.append(contentsOf: item.points)
            if item.speedSamples.count == item.points.count {
                speeds.append(contentsOf: item.speedSamples)
            } else {
                speeds.append(contentsOf: Array(repeating: 0, count: item.points.count))
            }
        }
        return RideTrack(
            id: sorted.map(\.id).joined(separator: "+"),
            startTime: first.startTime,
            mileage: sorted.reduce(0) { $0 + $1.mileage },
            durationMinutes: sorted.reduce(0) { $0 + $1.durationMinutes },
            points: points,
            endTime: sorted.last?.endTime,
            maxSpeed: sorted.compactMap(\.maxSpeed).max() ?? speeds.max(),
            startAddress: first.startAddress,
            endAddress: sorted.last?.endAddress,
            speedSamples: speeds,
            accelTimes: sorted.reduce(0) { $0 + $1.accelTimes },
            brakeTimes: sorted.reduce(0) { $0 + $1.brakeTimes },
            bendTimes: sorted.reduce(0) { $0 + $1.bendTimes },
            thumbnailURL: first.thumbnailURL,
            dayKey: first.dayKey,
            timestamps: stamps,
            realTimestamps: realStamps,
            startedAt: first.startedAt,
            endedAt: sorted.last?.endedAt
        )
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

/// 把回放进度映射到真实行程时间：停车时段标记停在原地，而不是按点序号匀速跳。
enum ReplayClock {
    static func make(_ track: RideTrack) -> (times: [TimeInterval], duration: TimeInterval) {
        let count = track.points.count
        let apiDuration = TimeInterval(max(track.durationMinutes, 0) * 60)
        guard count > 0 else {
            return ([], max(apiDuration, 1))
        }

        var unix = track.timestamps
        if unix.count != count {
            unix = Array(repeating: 0, count: count)
        }

        let firstKnown = unix.first(where: isUnix)
        let lastKnown = unix.last(where: isUnix)
        let start = track.startedAt ?? firstKnown ?? 0
        var end = track.endedAt ?? lastKnown ?? 0
        if isUnix(start), apiDuration > 0 {
            end = max(end, start + apiDuration)
        }
        if end <= start {
            end = start + max(apiDuration, TimeInterval(max(count - 1, 1) * 10))
        }

        let originHint = isUnix(start) ? start : (firstKnown ?? 0)
        let filled = fill(unix, start: originHint, end: end)
        let origin = isUnix(start) ? min(start, filled.first ?? start) : (filled.first ?? 0)
        let finish = max(filled.last ?? origin, isUnix(end) ? end : origin, origin + 1)
        let duration = max(finish - origin, 1)
        let relative = filled.map { max(0, min(duration, $0 - origin)) }
        return (relative, duration)
    }

    static func sample(_ track: RideTrack, progress: Double) -> (point: Coordinate, speed: Double) {
        let clock = make(track)
        return interpolate(
            points: track.points,
            speeds: track.speedSamples,
            times: clock.times,
            duration: clock.duration,
            progress: progress
        )
    }

    /// 进度对应的墙钟；有开始时间就按真实时刻走。
    /// 多段合并（timestamps 压缩过跨段空档）时按 realTimestamps 取样，
    /// 保证显示的时刻仍是每段骑行的真实时刻。
    static func wallDate(track: RideTrack, progress: Double) -> Date? {
        let clock = make(track)
        let elapsed = clock.duration * min(max(progress, 0), 1)
        if track.realTimestamps.count == track.points.count,
           track.realTimestamps.contains(where: isUnix) {
            let sample = sampleValue(
                track.realTimestamps.map(Double.init),
                times: clock.times,
                duration: clock.duration,
                progress: progress
            )
            if sample > 1_000_000_000 {
                return Date(timeIntervalSince1970: sample)
            }
        }
        if let start = track.startedAt, start > 1_000_000_000 {
            return Date(timeIntervalSince1970: start + elapsed)
        }
        if let first = track.timestamps.first(where: { $0 > 1_000_000_000 }) {
            let origin = clock.times.first ?? 0
            return Date(timeIntervalSince1970: first - origin + elapsed)
        }
        return nil
    }

    /// 折线 / 进度条共用：progress 是时间比例，不是点序号。
    static func sampleValue(
        _ values: [Double],
        times: [TimeInterval],
        duration: TimeInterval,
        progress: Double
    ) -> Double {
        guard !values.isEmpty else { return 0 }
        let dummy = values.map { _ in Coordinate(latitude: 0, longitude: 0) }
        return interpolate(
            points: dummy,
            speeds: values,
            times: times,
            duration: duration,
            progress: progress
        ).speed
    }

    static func interpolate(
        points: [Coordinate],
        speeds: [Double],
        times: [TimeInterval],
        duration: TimeInterval,
        progress: Double
    ) -> (point: Coordinate, speed: Double) {
        let clamped = min(max(progress, 0), 1)
        guard let first = points.first else {
            return (Coordinate(latitude: 0, longitude: 0), 0)
        }
        guard points.count > 1 else {
            return (first, speeds.first ?? 0)
        }

        let lastTime = times.last ?? 0
        let firstTime = times.first ?? 0
        let useTime = times.count == points.count && duration > 0 && lastTime > firstTime
        let index: Int
        let fraction: Double
        if useTime {
            (index, fraction) = bracket(times, t: clamped * duration)
        } else {
            let raw = clamped * Double(points.count - 1)
            index = min(points.count - 2, max(0, Int(raw)))
            fraction = raw - Double(index)
        }

        let a = points[index]
        let b = points[min(index + 1, points.count - 1)]
        let point = Coordinate(
            latitude: a.latitude + (b.latitude - a.latitude) * fraction,
            longitude: a.longitude + (b.longitude - a.longitude) * fraction
        )
        let sa = speeds.indices.contains(index) ? speeds[index] : 0
        let sb = speeds.indices.contains(index + 1) ? speeds[index + 1] : sa
        return (point, sa + (sb - sa) * fraction)
    }

    private static func isUnix(_ value: TimeInterval) -> Bool {
        value > 1_000_000_000
    }

    private static func fill(_ raw: [TimeInterval], start: TimeInterval, end: TimeInterval) -> [TimeInterval] {
        let n = raw.count
        guard n > 0 else { return [] }
        var out = raw
        let known = (0..<n).filter { isUnix(out[$0]) }
        if known.isEmpty {
            guard n > 1 else { return [start] }
            let span = max(end - start, 1)
            return (0..<n).map { start + span * Double($0) / Double(n - 1) }
        }

        let firstIdx = known[0]
        let firstT = out[firstIdx]
        let head = isUnix(start) ? min(start, firstT) : firstT
        if firstIdx > 0 {
            for i in 0..<firstIdx {
                out[i] = head + (firstT - head) * Double(i) / Double(firstIdx)
            }
        }
        for k in 0..<(known.count - 1) {
            let a = known[k]
            let b = known[k + 1]
            let ta = out[a]
            let tb = out[b]
            let gap = b - a
            guard gap > 1 else { continue }
            for i in (a + 1)..<b {
                out[i] = ta + (tb - ta) * Double(i - a) / Double(gap)
            }
        }
        let lastIdx = known.last!
        let lastT = out[lastIdx]
        let tail = end > lastT ? end : lastT
        if lastIdx < n - 1 {
            let gap = (n - 1) - lastIdx
            for i in (lastIdx + 1)..<n {
                out[i] = lastT + (tail - lastT) * Double(i - lastIdx) / Double(gap)
            }
        }
        for i in 1..<n where out[i] < out[i - 1] {
            out[i] = out[i - 1]
        }
        return out
    }

    private static func bracket(_ times: [TimeInterval], t: TimeInterval) -> (Int, Double) {
        let n = times.count
        guard n > 1 else { return (0, 0) }
        if t <= times[0] { return (0, 0) }
        if t >= times[n - 1] { return (n - 2, 1) }
        var lo = 0
        var hi = n - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid } else { hi = mid }
        }
        let span = times[hi] - times[lo]
        if span <= 0.001 { return (lo, 0) }
        return (lo, min(1, max(0, (t - times[lo]) / span)))
    }
}
