import Foundation
import WidgetKit

struct WidgetSnap: Equatable {
    var loggedIn = false
    var name = ""
    var vin = ""
    var soc = 0
    var rangeKm = 0
    var charging = false
    var locked = true
    var online = false
    var todayKm = 0.0
    var todayMin = 0
    var accel = 0
    var brake = 0
    var maxSpeed = 0
    var tireText = ""
    var tireBound = false
    var signedToday = false
    var communityDone = false
    var continueDays = 0
    var totalSignCount = 0
    var todaySignScore = 0
    var lotteryLeft = 30
    var lotteryText = ""
    var lotteryClaimed = false
    var lotteryScore = 0
    var pointsTotal = 0
    var pointsToday = 0
    var imageURL = ""
    var imageData: Data?
    var totalMile = 0.0
    var monthMile = "--"
    var updatedAt = Date().timeIntervalSince1970

    var dictionary: [String: Any] {
        [
            "loggedIn": loggedIn,
            "name": name,
            "vin": vin,
            "soc": soc,
            "rangeKm": rangeKm,
            "charging": charging,
            "locked": locked,
            "online": online,
            "todayKm": todayKm,
            "todayMin": todayMin,
            "accel": accel,
            "brake": brake,
            "maxSpeed": maxSpeed,
            "tireText": tireText,
            "tireBound": tireBound,
            "signedToday": signedToday,
            "communityDone": communityDone,
            "continueDays": continueDays,
            "totalSignCount": totalSignCount,
            "todaySignScore": todaySignScore,
            "lotteryLeft": lotteryLeft,
            "lotteryText": lotteryText,
            "lotteryClaimed": lotteryClaimed,
            "lotteryScore": lotteryScore,
            "pointsTotal": pointsTotal,
            "pointsToday": pointsToday,
            "imageURL": imageURL,
            "totalMile": totalMile,
            "monthMile": monthMile,
            "updatedAt": updatedAt
        ]
    }

    static func from(_ raw: [String: Any]) -> WidgetSnap {
        var snap = WidgetSnap()
        snap.loggedIn = bool(raw["loggedIn"])
        snap.name = string(raw["name"])
        snap.vin = string(raw["vin"])
        snap.soc = int(raw["soc"])
        snap.rangeKm = int(raw["rangeKm"])
        snap.charging = bool(raw["charging"])
        snap.locked = bool(raw["locked"], fallback: true)
        snap.online = bool(raw["online"])
        snap.todayKm = double(raw["todayKm"])
        snap.todayMin = int(raw["todayMin"])
        snap.accel = int(raw["accel"])
        snap.brake = int(raw["brake"])
        snap.maxSpeed = int(raw["maxSpeed"])
        snap.tireText = string(raw["tireText"])
        snap.tireBound = bool(raw["tireBound"]) || !snap.tireText.isEmpty
        snap.signedToday = bool(raw["signedToday"])
        snap.communityDone = bool(raw["communityDone"])
        snap.continueDays = int(raw["continueDays"])
        snap.totalSignCount = int(raw["totalSignCount"])
        snap.todaySignScore = int(raw["todaySignScore"])
        snap.lotteryLeft = int(raw["lotteryLeft"], fallback: 30)
        snap.lotteryText = string(raw["lotteryText"])
        snap.lotteryClaimed = bool(raw["lotteryClaimed"])
        snap.lotteryScore = int(raw["lotteryScore"])
        snap.pointsTotal = int(raw["pointsTotal"])
        snap.pointsToday = int(raw["pointsToday"])
        snap.imageURL = string(raw["imageURL"])
        snap.totalMile = double(raw["totalMile"])
        snap.monthMile = {
            let text = string(raw["monthMile"])
            return text.isEmpty ? "--" : text
        }()
        snap.updatedAt = double(raw["updatedAt"])
        snap.imageData = WidgetSnapshot.loadImage()
        return snap
    }

    private static func string(_ raw: Any?) -> String {
        guard let raw else { return "" }
        let text = "\(raw)"
        return text == "<null>" ? "" : text
    }

    private static func int(_ raw: Any?, fallback: Int = 0) -> Int {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        return Int("\(raw ?? "")") ?? fallback
    }

    private static func double(_ raw: Any?) -> Double {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return Double("\(raw ?? "")") ?? 0
    }

    private static func bool(_ raw: Any?, fallback: Bool = false) -> Bool {
        if let value = raw as? Bool { return value }
        if let value = raw as? Int { return value != 0 }
        let text = "\(raw ?? "")".lowercased()
        if text == "1" || text == "true" { return true }
        if text == "0" || text == "false" { return false }
        return fallback
    }
}

/// 主 App → 小组件快照（App Group UserDefaults + 共享文件双写）
enum WidgetSnapshot {
    static let suiteName = "group.com.liruixin.jihedrive"
    static let kind = "JiheDriveWidget"
    private static let fileName = "widget_snapshot.json"
    private static let imageName = "widget_vehicle.png"
    private static let lotteryDayKey = "widget_lottery_checked_day"

    static func suiteDefaults() -> UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func lotteryCheckedToday() -> Bool {
        suiteDefaults()?.string(forKey: lotteryDayKey) == CommunityTask.todayKey()
    }

    static func markLotteryChecked() {
        suiteDefaults()?.set(CommunityTask.todayKey(), forKey: lotteryDayKey)
        suiteDefaults()?.synchronize()
    }

#if !WIDGET_EXTENSION
    @MainActor
    static func publish(
        from model: AppModel,
        signin: SigninStore? = nil,
        ride: RideTrackService.RideExtra? = nil
    ) {
        var snap = read() ?? WidgetSnap()
        snap.loggedIn = ZeehoClient.shared.isLoggedIn
        if let vehicle = model.selectedVehicle {
            snap.name = vehicle.name
            snap.vin = vehicle.vinNo
            snap.soc = vehicle.soc
            snap.rangeKm = vehicle.rangeKm
            snap.locked = vehicle.isLocked
            snap.online = vehicle.isOnline
            snap.charging = vehicle.isCharging
            snap.totalMile = vehicle.totalMileKm
            snap.monthMile = vehicle.monthMileage ?? snap.monthMile
            snap.imageURL = vehicle.imageURL?.absoluteString ?? snap.imageURL
        }
        if let ride {
            snap.todayKm = ride.todayKm ?? snap.todayKm
            snap.todayMin = ride.todayMin ?? snap.todayMin
            snap.accel = ride.todayAccel ?? snap.accel
            snap.brake = ride.todayBrake ?? snap.brake
            snap.maxSpeed = ride.todayMaxSpeed.map { Int($0.rounded()) } ?? snap.maxSpeed
        }
        if let tire = model.tire {
            if let bar = tire.rearBar ?? tire.frontBar {
                let temp = tire.rearTemp ?? tire.frontTemp
                if let temp {
                    snap.tireText = String(format: "%.1fbar %.0f°C", bar, temp)
                } else {
                    snap.tireText = String(format: "%.1fbar", bar)
                }
                snap.tireBound = true
            }
        }
        if let signin {
            snap.signedToday = signin.signedToday
            snap.communityDone = signin.communityDone
            snap.continueDays = signin.info?.continueDays ?? snap.continueDays
            snap.totalSignCount = signin.totalSignCount ?? snap.totalSignCount
            snap.todaySignScore = signin.info?.todayRuleScore ?? snap.todaySignScore
            let left = signin.info?.daysUntilLottery ?? snap.lotteryLeft
            snap.lotteryLeft = left
            if snap.lotteryText.isEmpty {
                snap.lotteryText = left == 0 ? "盲盒可领" : "盲盒\(left)天"
            }
        }
        snap.updatedAt = Date().timeIntervalSince1970
        write(snap)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        WidgetCenter.shared.reloadAllTimelines()
    }
#endif

    static func write(_ snap: WidgetSnap) {
        var payload = snap.dictionary
        payload["sessionToken"] = ZeehoClient.shared.token ?? ""
        payload["sessionUserId"] = ZeehoClient.shared.userId ?? ""
        payload["selectedVin"] = snap.vin

        if let defaults = suiteDefaults() {
            for (key, value) in payload {
                defaults.set(value, forKey: key)
            }
            defaults.synchronize()
        }
        let standard = UserDefaults.standard
        for (key, value) in payload where key != "sessionToken" {
            standard.set(value, forKey: "widget_\(key)")
        }
        standard.synchronize()

        if let url = snapshotURL(),
           let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: url, options: [.atomic])
        }
        if let data = snap.imageData {
            saveImage(data)
        }
    }

    static func read() -> WidgetSnap? {
        if let defaults = suiteDefaults(),
           defaults.object(forKey: "updatedAt") != nil {
            var map: [String: Any] = [:]
            for key in defaults.dictionaryRepresentation().keys {
                if let value = defaults.object(forKey: key) {
                    map[key] = value
                }
            }
            var snap = WidgetSnap.from(map)
            snap.imageData = loadImage()
            return snap
        }
        if let url = snapshotURL(),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var snap = WidgetSnap.from(json)
            snap.imageData = loadImage()
            return snap
        }
        return nil
    }

    static func sessionToken() -> String? {
        if let token = suiteDefaults()?.string(forKey: "sessionToken"), !token.isEmpty {
            return token
        }
        if let url = snapshotURL(),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = json["sessionToken"] as? String,
           !token.isEmpty {
            return token
        }
        return nil
    }

    static func sessionUserId() -> String? {
        if let uid = suiteDefaults()?.string(forKey: "sessionUserId"), !uid.isEmpty {
            return uid
        }
        if let url = snapshotURL(),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let uid = "\(json["sessionUserId"] ?? "")"
            return uid.isEmpty ? nil : uid
        }
        return nil
    }

    static func selectedVin() -> String? {
        let vin = suiteDefaults()?.string(forKey: "selectedVin") ?? suiteDefaults()?.string(forKey: "vin")
        return (vin?.isEmpty == false) ? vin : nil
    }

    static func snapshotURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent(fileName)
    }

    static func imageFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent(imageName)
    }

    static func saveImage(_ data: Data) {
        if let url = imageFileURL() {
            try? data.write(to: url, options: [.atomic])
            return
        }
        let fallback = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(imageName)
        if let fallback {
            try? data.write(to: fallback, options: [.atomic])
        }
    }

    static func loadImage() -> Data? {
        if let url = imageFileURL(), let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }
        let fallback = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(imageName)
        if let fallback, let data = try? Data(contentsOf: fallback), !data.isEmpty {
            return data
        }
        return nil
    }
}
