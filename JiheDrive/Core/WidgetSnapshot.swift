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

    /// 今日积分：接口差值、签到分、社区分取最大，避免基线重置后显示 0
    var displayTodayPoints: Int {
        max(pointsToday, todaySignScore + (communityDone ? 3 : 0))
    }

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
        let vehicle = model.selectedVehicle
        let previous = vehicle.flatMap { readVin($0.vinNo) }
        var snap = previous ?? WidgetSnap()
        if previous == nil, let account = readIgnoringVin() {
            snap.pointsTotal = account.pointsTotal
            snap.pointsToday = account.pointsToday
            snap.signedToday = account.signedToday
            snap.communityDone = account.communityDone
            snap.continueDays = account.continueDays
            snap.totalSignCount = account.totalSignCount
            snap.todaySignScore = account.todaySignScore
            snap.lotteryLeft = account.lotteryLeft
            snap.lotteryText = account.lotteryText
            snap.lotteryClaimed = account.lotteryClaimed
            snap.lotteryScore = account.lotteryScore
        }
        snap.loggedIn = ZeehoClient.shared.isLoggedIn
        if let vehicle {
            snap.name = vehicle.name
            snap.vin = vehicle.vinNo
            snap.soc = vehicle.soc
            snap.rangeKm = vehicle.rangeKm
            snap.locked = vehicle.isLocked
            snap.online = vehicle.isOnline
            snap.charging = vehicle.isCharging
            snap.totalMile = vehicle.totalMileKm
            snap.monthMile = vehicle.monthMileage ?? "--"
            snap.imageURL = vehicle.imageURL?.absoluteString ?? ""
            snap.imageData = nil
            if let url = vehicle.imageURL,
               let image = ResourceCache.cachedImage(url),
               let data = image.pngData() {
                saveImage(data, vin: vehicle.vinNo)
            }
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
            let earned = (signin.info?.todayEarnedScore ?? 0) + (signin.communityDone ? 3 : 0)
            if earned > 0 {
                snap.pointsToday = max(snap.pointsToday, earned)
            }
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
        var snap = snap
        if snap.vin.isEmpty, let wanted = selectedVin(), !wanted.isEmpty {
            snap.vin = wanted
        }
        let old = (snap.vin.isEmpty ? nil : readVin(snap.vin))
            ?? {
                let fallback = readKeychain() ?? readIgnoringVin()
                return sameVin(snap.vin, fallback?.vin) ? fallback : nil
            }()
        if snap.loggedIn, let old, sameVin(snap.vin, old.vin) {
            fillMissingVehicle(&snap, from: old)
        }
        var payload = snap.dictionary
        payload["sessionToken"] = ZeehoClient.shared.token ?? ""
        payload["sessionUserId"] = ZeehoClient.shared.userId ?? ""
        let wanted = selectedVin()
        payload["selectedVin"] = wanted ?? snap.vin
        payload["userSelectedVin"] = wanted ?? snap.vin
        writeVinFile(snap, payload: payload)
        if wanted == nil || wanted?.isEmpty == true || sameVin(snap.vin, wanted) {
            writeKeychain(snap, payload: payload)
        }
        if let wanted, !wanted.isEmpty, !sameVin(snap.vin, wanted) {
            return
        }

        if let defaults = suiteDefaults() {
            for (key, value) in payload where key != "userSelectedVin" {
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
        let wanted = selectedVin()
        if let wanted, let per = readVin(wanted), hasVehicleData(per) {
            return per
        }
        let candidates = [readKeychain(), readSuite(), readFile(), readStandard()].compactMap { $0 }
        if let wanted, !wanted.isEmpty {
            if let hit = candidates.first(where: { sameVin($0.vin, wanted) && hasVehicleData($0) }) {
                return hit
            }
            if let acc = newest(candidates) {
                if sameVin(acc.vin, wanted), hasVehicleData(acc) {
                    return acc
                }
                return accountStub(from: acc, vin: wanted)
            }
            return nil
        }
        return newest(candidates)
    }

    static func hasVehicleData(_ snap: WidgetSnap) -> Bool {
        snap.soc > 0 || snap.rangeKm > 0 || !snap.name.isEmpty
    }

    static func fillMissingVehicle(_ snap: inout WidgetSnap, from old: WidgetSnap) {
        guard sameVin(snap.vin, old.vin) else { return }
        if !hasVehicleData(snap), hasVehicleData(old) {
            snap.name = old.name
            if snap.vin.isEmpty { snap.vin = old.vin }
            snap.soc = old.soc
            snap.rangeKm = old.rangeKm
            snap.charging = old.charging
            snap.locked = old.locked
            snap.online = old.online
            snap.imageURL = old.imageURL
            snap.todayKm = old.todayKm
            snap.todayMin = old.todayMin
            snap.tireText = old.tireText
            snap.tireBound = old.tireBound
            snap.totalMile = old.totalMile
            snap.monthMile = old.monthMile
            return
        }
        if snap.soc <= 0, old.soc > 0 { snap.soc = old.soc }
        if snap.rangeKm <= 0, old.rangeKm > 0 { snap.rangeKm = old.rangeKm }
        if snap.vin.isEmpty { snap.vin = old.vin }
        if snap.name.isEmpty { snap.name = old.name }
        if snap.imageURL.isEmpty { snap.imageURL = old.imageURL }
        if snap.todayKm == 0, old.todayKm > 0 { snap.todayKm = old.todayKm }
        if snap.todayMin == 0, old.todayMin > 0 { snap.todayMin = old.todayMin }
        if snap.tireText.isEmpty, !old.tireText.isEmpty {
            snap.tireText = old.tireText
            snap.tireBound = old.tireBound
        }
        if snap.totalMile == 0, old.totalMile > 0 { snap.totalMile = old.totalMile }
        if snap.monthMile == "--", old.monthMile != "--" { snap.monthMile = old.monthMile }
    }

    static func readIgnoringVin() -> WidgetSnap? {
        newest([readKeychain(), readSuite(), readFile(), readStandard()].compactMap { $0 })
    }

    private static func writeKeychain(_ snap: WidgetSnap, payload: [String: Any]) {
        if hasVehicleData(snap),
           let data = try? JSONSerialization.data(withJSONObject: payload) {
            KeychainStore.shared.setData(data, for: .widgetSnap)
        }
        if !snap.vin.isEmpty {
            KeychainStore.shared.set(snap.vin, for: .selectedVin)
        }
    }

    private static func readKeychain() -> WidgetSnap? {
        guard let data = KeychainStore.shared.data(for: .widgetSnap),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return WidgetSnap.from(json)
    }

    private static func accountStub(from acc: WidgetSnap, vin: String) -> WidgetSnap {
        var stub = WidgetSnap()
        stub.loggedIn = acc.loggedIn
        stub.vin = vin
        stub.pointsTotal = acc.pointsTotal
        stub.pointsToday = acc.pointsToday
        stub.signedToday = acc.signedToday
        stub.communityDone = acc.communityDone
        stub.continueDays = acc.continueDays
        stub.totalSignCount = acc.totalSignCount
        stub.todaySignScore = acc.todaySignScore
        stub.lotteryLeft = acc.lotteryLeft
        stub.lotteryText = acc.lotteryText
        stub.lotteryClaimed = acc.lotteryClaimed
        stub.lotteryScore = acc.lotteryScore
        return stub
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
        KeychainStore.shared.set(value.isEmpty ? nil : value, for: .selectedVin)
        suiteDefaults()?.set(value, forKey: "userSelectedVin")
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
            json["userSelectedVin"] = value
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                try? data.write(to: url, options: [.atomic])
            }
        }
    }

    static func selectedVin() -> String? {
        let candidates: [String?] = [
            KeychainStore.shared.value(for: .selectedVin),
            suiteDefaults()?.string(forKey: "userSelectedVin"),
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
        let vin = "\(json["userSelectedVin"] ?? json["selectedVin"] ?? "")"
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        sharedDir()?.appendingPathComponent(fileName)
    }

    static func readVin(_ vin: String?) -> WidgetSnap? {
        guard let url = vinSnapshotURL(vin),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return WidgetSnap.from(json)
    }

    private static func vinSnapshotURL(_ vin: String?) -> URL? {
        guard let key = imageKey(vin) else { return nil }
        return sharedDir()?.appendingPathComponent("widget_snapshot_\(key).json")
    }

    private static func writeVinFile(_ snap: WidgetSnap, payload: [String: Any]) {
        guard let url = vinSnapshotURL(snap.vin),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func sharedDir() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }

    private static func readSuite() -> WidgetSnap? {
        guard let defaults = suiteDefaults(),
              defaults.object(forKey: "updatedAt") != nil else { return nil }
        var map: [String: Any] = [:]
        for key in defaults.dictionaryRepresentation().keys {
            if let value = defaults.object(forKey: key) {
                map[key] = value
            }
        }
        return WidgetSnap.from(map)
    }

    private static func readFile() -> WidgetSnap? {
        guard let url = snapshotURL(),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return WidgetSnap.from(json)
    }

    private static func readStandard() -> WidgetSnap? {
        let standard = UserDefaults.standard
        var map: [String: Any] = [:]
        for (key, value) in standard.dictionaryRepresentation() where key.hasPrefix("widget_") {
            map[String(key.dropFirst("widget_".count))] = value
        }
        guard map["updatedAt"] != nil else { return nil }
        return WidgetSnap.from(map)
    }

    private static func newest(_ snaps: [WidgetSnap]) -> WidgetSnap? {
        snaps.max { $0.updatedAt < $1.updatedAt }
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
        guard let key = imageKey(targetVin) else { return }
        let payload = prepareImage(data) ?? data
        if let url = imageFileURL(targetVin) {
            try? payload.write(to: url, options: [.atomic])
        }
        suiteDefaults()?.set(payload, forKey: "widget_image_\(key)")
        suiteDefaults()?.synchronize()
        if sameVin(targetVin, selectedVin()) {
            KeychainStore.shared.setData(payload, for: .widgetImage)
            if let generic = imageFileURL() {
                try? payload.write(to: generic, options: [.atomic])
            }
        }
    }

    static func loadImage(_ vin: String? = nil) -> Data? {
        let targetVin = vin ?? selectedVin()
        if let key = imageKey(targetVin) {
            if let url = imageFileURL(targetVin),
               let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
            if let data = suiteDefaults()?.data(forKey: "widget_image_\(key)"), !data.isEmpty {
                return data
            }
            if sameVin(targetVin, selectedVin()),
               let data = KeychainStore.shared.data(for: .widgetImage), !data.isEmpty {
                return data
            }
        }
        if let generic = imageFileURL(), let data = try? Data(contentsOf: generic), !data.isEmpty {
            return data
        }
        if let data = KeychainStore.shared.data(for: .widgetImage), !data.isEmpty {
            return data
        }
        return nil
    }

    static func displayImage(vin: String? = nil) -> UIImage? {
        let target = vin.flatMap { $0.isEmpty ? nil : $0 } ?? selectedVin()
        if let data = loadImage(target) ?? loadImage(selectedVin()) ?? loadImage() {
            return UIImage(data: data)
        }
        return nil
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
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return knockOutBackdrop(rendered).pngData()
    }

    /// 去掉四周白底，保留车身（包括白车）
    private static func knockOutBackdrop(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let width = cg.width
        let height = cg.height
        guard width > 2, height > 2 else { return image }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        let mid = ((height / 2) * width + (width / 2)) * 4
        let centerBright = Int(pixels[mid]) > 188
            && Int(pixels[mid + 1]) > 188
            && Int(pixels[mid + 2]) > 188
        if centerBright { return image }

        func isBackdrop(_ i: Int) -> Bool {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2]), a = Int(pixels[i + 3])
            if a < 16 { return true }
            let maxc = max(r, g, b)
            let minc = min(r, g, b)
            return maxc >= 236 && (maxc - minc) <= 18
        }

        var visited = [Bool](repeating: false, count: width * height)
        var queue: [Int] = []
        func enqueue(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let idx = y * width + x
            if visited[idx] { return }
            visited[idx] = true
            if isBackdrop(idx * 4) { queue.append(idx) }
        }
        for x in 0..<width {
            enqueue(x, 0)
            enqueue(x, height - 1)
        }
        for y in 0..<height {
            enqueue(0, y)
            enqueue(width - 1, y)
        }
        var head = 0
        while head < queue.count {
            let idx = queue[head]
            head += 1
            let i = idx * 4
            pixels[i] = 0
            pixels[i + 1] = 0
            pixels[i + 2] = 0
            pixels[i + 3] = 0
            let x = idx % width
            let y = idx / width
            enqueue(x - 1, y)
            enqueue(x + 1, y)
            enqueue(x, y - 1)
            enqueue(x, y + 1)
        }
        guard let out = ctx.makeImage() else { return image }
        return UIImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
    }
}
