import Foundation
import UIKit
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
    var lastKm = 0.0
    var lastMin = 0
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
            "lastKm": lastKm,
            "lastMin": lastMin,
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
        snap.lastKm = double(raw["lastKm"])
        snap.lastMin = int(raw["lastMin"])
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
        // 车图走 App Group 文件，不塞进时间线，避免 WidgetKit 丢掉整份快照后只剩占位车标
        snap.imageData = nil
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
    private static let lastSignDateKey = "widget_last_sign_date"
    private static let lastBlindBoxDateKey = "widget_last_blindbox_date"

    static func suiteDefaults() -> UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func signedTodayGate() -> Bool {
        suiteDefaults()?.string(forKey: lastSignDateKey) == CommunityTask.todayKey()
    }

    static func markSignedToday() {
        suiteDefaults()?.set(CommunityTask.todayKey(), forKey: lastSignDateKey)
        suiteDefaults()?.synchronize()
    }

    static func lotteryClaimedToday() -> Bool {
        suiteDefaults()?.string(forKey: lastBlindBoxDateKey) == CommunityTask.todayKey()
    }

    static func markLotteryClaimed() {
        suiteDefaults()?.set(CommunityTask.todayKey(), forKey: lastBlindBoxDateKey)
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
            snap.imageData = nil
        }
        if let ride {
            snap.todayKm = ride.todayKm ?? snap.todayKm
            snap.todayMin = ride.todayMin ?? snap.todayMin
            snap.lastKm = ride.lastKm ?? snap.lastKm
            snap.lastMin = ride.lastMin ?? snap.lastMin
            snap.accel = ride.todayAccel ?? snap.accel
            snap.brake = ride.todayBrake ?? snap.brake
            snap.maxSpeed = ride.todayMaxSpeed.map { Int($0.rounded()) } ?? snap.maxSpeed
        }
        if let tire = model.tire {
            let formatted = WidgetSnapshot.tireCaption(tire)
            snap.tireText = formatted.text
            snap.tireBound = formatted.bound
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
        let wanted = selectedVin()
        payload["selectedVin"] = wanted ?? snap.vin
        if let wanted, !wanted.isEmpty, !sameVin(snap.vin, wanted) {
            // 过期刷新还在写上一台车，不能覆盖当前选中车辆
            return
        }

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
            saveImage(data, vin: snap.vin)
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
            return WidgetSnap.from(map)
        }
        if let url = snapshotURL(),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return WidgetSnap.from(json)
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

    static func persistSelectedVin(_ vin: String?) {
        let value = vin ?? ""
        suiteDefaults()?.set(value, forKey: "selectedVin")
        suiteDefaults()?.synchronize()
        UserDefaults.standard.set(value, forKey: "jihe.selected.vin")
        UserDefaults.standard.set(value, forKey: "widget_selectedVin")
        UserDefaults.standard.set(value, forKey: "selectedVin")
        UserDefaults.standard.synchronize()
        if let url = selectedVinFileURL() {
            try? value.data(using: .utf8)?.write(to: url, options: [.atomic])
        }
        if let url = snapshotURL(),
           var json = (try? Data(contentsOf: url)).flatMap({
               try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
           }) {
            json["selectedVin"] = value
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                try? data.write(to: url, options: [.atomic])
            }
        }
    }

    static func selectedVin() -> String? {
        let candidates: [String?] = [
            selectedVinFile(),
            suiteDefaults()?.string(forKey: "selectedVin"),
            snapshotSelectedVin(),
            UserDefaults.standard.string(forKey: "widget_selectedVin"),
            UserDefaults.standard.string(forKey: "jihe.selected.vin"),
            UserDefaults.standard.string(forKey: "selectedVin")
        ]
        return candidates.compactMap { vin -> String? in
            let trimmed = vin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    private static func selectedVinFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent("selected_vin.txt")
    }

    private static func selectedVinFile() -> String? {
        guard let url = selectedVinFileURL(),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func sameVin(_ lhs: String?, _ rhs: String?) -> Bool {
        let a = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        let b = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return !a.isEmpty && a == b
    }

    private static func snapshotSelectedVin() -> String? {
        guard let url = snapshotURL(),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let vin = "\(json["selectedVin"] ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
        return vin.isEmpty ? nil : vin
    }

    static func tireCaption(_ reading: TireReading?) -> (text: String, bound: Bool) {
        let front = reading?.frontBar
        let rear = reading?.rearBar
        let hasFront = (front ?? 0) > 0.3
        let hasRear = (rear ?? 0) > 0.3
        if !hasFront && !hasRear { return ("", false) }
        func one(_ bar: Double?, _ temp: Double?) -> String {
            guard let bar, bar > 0.3 else { return "未绑定" }
            if let temp {
                return String(format: "%.1fbar %.0f°", bar, temp)
            }
            return String(format: "%.1fbar", bar)
        }
        return ("\(one(front, reading?.frontTemp)) / \(one(rear, reading?.rearTemp))", true)
    }

    static func snapshotURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent(fileName)
    }

    static func imageFileURL(_ vin: String? = nil) -> URL? {
        let name: String
        if let key = imageKey(vin) {
            name = "widget_vehicle_\(key).png"
        } else {
            name = imageName
        }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent(name)
    }

    /// 文件名统一大写，避免切车后大小写不一致读到别的车图
    private static func imageKey(_ vin: String?) -> String? {
        let trimmed = vin?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: "/", with: "_")
    }

    static func saveImage(_ data: Data, vin: String? = nil) {
        let targetVin = vin ?? selectedVin()
        guard imageKey(targetVin) != nil, let url = imageFileURL(targetVin) else { return }
        let payload = prepareImage(data) ?? data
        try? payload.write(to: url, options: [.atomic])
        // 当前选中车再写一份通用文件，只给预览占位，读图必须带 VIN
        if sameVin(targetVin, selectedVin()), let generic = imageFileURL() {
            try? payload.write(to: generic, options: [.atomic])
        }
    }

    static func loadImage(_ vin: String? = nil) -> Data? {
        let targetVin = vin ?? selectedVin()
        guard imageKey(targetVin) != nil, let url = imageFileURL(targetVin) else { return nil }
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }
        return nil
    }

    static func displayImage(vin: String? = nil) -> UIImage? {
        let target = vin.flatMap { $0.isEmpty ? nil : $0 } ?? selectedVin()
        guard let data = loadImage(target) else { return nil }
        return UIImage(data: data)
    }

    /// 压到小组件够用的尺寸，避免把原图塞进时间线后被系统丢掉
    private static func prepareImage(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxPixel: CGFloat = 420
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxPixel ? maxPixel / longest : 1
        let size = CGSize(
            width: max(1, (image.size.width * scale).rounded()),
            height: max(1, (image.size.height * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.86)
    }
}
