import Foundation
import WidgetKit

/// 小组件与 App 共用的云端刷新（对齐 Scriptable 闸门）。
/// 常更新：车辆 / 电量 / 骑行 / 胎压 / 积分，写入 App Group。
/// 一天一次：签到、社区；未到盲盒日完全不打盲盒接口。
enum WidgetLiveSync {
    enum Mode {
        case timeline
        case reuse
    }

    struct Existing {
        var vehicle: Vehicle?
        var tire: TireReading?
        var ride: RideTrackService.RideExtra?
        var signedToday: Bool?
        var communityDone: Bool?
        var continueDays: Int?
        var totalSignCount: Int?
        var todayScore: Int?
    }

    @discardableResult
    static func refresh(existing: Existing? = nil, mode: Mode = .timeline) async -> WidgetSnap {
        hydrateSession()
        guard ZeehoClient.shared.isLoggedIn else {
            if let cached = WidgetSnapshot.read(), cached.loggedIn {
                return cached
            }
            let empty = WidgetSnap()
            WidgetSnapshot.write(empty)
            reload()
            return empty
        }

        let cachedSnap = WidgetSnapshot.read()
        let wantedVin = WidgetSnapshot.selectedVin()
            ?? cachedSnap?.vin
            ?? existing?.vehicle?.vinNo
        var snap = cachedSnap ?? WidgetSnap()
        snap.loggedIn = true
        if let wantedVin, !wantedVin.isEmpty, !WidgetSnapshot.sameVin(snap.vin, wantedVin) {
            let sameExisting = WidgetSnapshot.sameVin(existing?.vehicle?.vinNo, wantedVin)
            let stored = WidgetSnapshot.readVin(wantedVin)
            snap.vin = wantedVin
            snap.name = sameExisting ? (existing?.vehicle?.name ?? "") : (stored?.name ?? "")
            snap.soc = sameExisting ? (existing?.vehicle?.soc ?? 0) : (stored?.soc ?? 0)
            snap.rangeKm = sameExisting ? (existing?.vehicle?.rangeKm ?? 0) : (stored?.rangeKm ?? 0)
            snap.charging = sameExisting ? (existing?.vehicle?.isCharging ?? false) : (stored?.charging ?? false)
            snap.locked = sameExisting ? (existing?.vehicle?.isLocked ?? true) : (stored?.locked ?? true)
            snap.online = sameExisting ? (existing?.vehicle?.isOnline ?? false) : (stored?.online ?? false)
            snap.imageURL = sameExisting
                ? (existing?.vehicle?.imageURL?.absoluteString ?? "")
                : (stored?.imageURL ?? "")
            snap.todayKm = stored?.todayKm ?? 0
            snap.todayMin = stored?.todayMin ?? 0
            snap.lastKm = stored?.lastKm ?? 0
            snap.lastMin = stored?.lastMin ?? 0
            snap.accel = stored?.accel ?? 0
            snap.brake = stored?.brake ?? 0
            snap.maxSpeed = stored?.maxSpeed ?? 0
            snap.tireText = stored?.tireText ?? ""
            snap.tireBound = stored?.tireBound ?? false
        }

        var vehicle: Vehicle?
        let tire: TireReading?
        let ride: RideTrackService.RideExtra?
        let battery: (soc: Int, range: Int, charging: Bool)?
        if mode == .reuse, let existingVehicle = existing?.vehicle,
           wantedVin == nil || WidgetSnapshot.sameVin(existingVehicle.vinNo, wantedVin) {
            vehicle = existingVehicle
            tire = existing?.tire
            ride = existing?.ride
            battery = await fetchBattery(vin: existingVehicle.vinNo)
        } else {
            vehicle = await fetchVehicle(hint: existing?.vehicle, wanted: wantedVin)
            if vehicle == nil,
               let hint = existing?.vehicle,
               wantedVin == nil || WidgetSnapshot.sameVin(hint.vinNo, wantedVin) {
                vehicle = hint
            }
            let vin = wantedVin ?? vehicle?.vinNo
            async let tireTask = fetchTire(vin: vin)
            async let rideTask = fetchRide(vin: vin)
            async let batteryTask = fetchBattery(vin: vin)
            tire = await tireTask ?? existing?.tire
            ride = await rideTask ?? existing?.ride
            battery = await batteryTask
        }

        let cachedIsToday = Self.snapIsToday(cachedSnap)
        let uid = ZeehoClient.shared.userId

        var signedToday = existing?.signedToday == true
            || WidgetSnapshot.signedTodayGate()
            || (cachedIsToday && cachedSnap?.signedToday == true)
        var communityDone = existing?.communityDone == true
            || CommunityTask.isDoneToday(userId: uid)
            || (cachedIsToday && cachedSnap?.communityDone == true)
        var continueDays = existing?.continueDays
            ?? (cachedIsToday ? cachedSnap?.continueDays : nil)
            ?? 0
        var totalSignCount = existing?.totalSignCount
            ?? cachedSnap?.totalSignCount
            ?? 0
        var todayScore = existing?.todayScore
            ?? (cachedIsToday ? cachedSnap?.todaySignScore : nil)
            ?? 0

        // 签到：先查今日状态；已签则只记闸门，未签才 POST
        if !signedToday {
            let status = await fetchSigninStatus()
            if status.continueDays > 0 { continueDays = status.continueDays }
            if status.totalSignCount > 0 { totalSignCount = status.totalSignCount }
            if status.todayScore > 0 { todayScore = status.todayScore }
            if status.signed {
                signedToday = true
            } else {
                let sign = await signInIfNeeded()
                if sign.signed { signedToday = true }
                if sign.continueDays > 0 { continueDays = sign.continueDays }
                if sign.todayScore > 0 { todayScore = sign.todayScore }
            }
        }
        if signedToday { WidgetSnapshot.markSignedToday() }

        // 社区只读状态，绝不在小组件/定时刷新里发帖。发帖只走签到页手动按钮。
        if !communityDone, let uid, !uid.isEmpty {
            communityDone = await CommunityTask.resolveDone(userId: uid)
        }

        snap.signedToday = signedToday
        snap.communityDone = communityDone
        snap.continueDays = continueDays
        snap.totalSignCount = totalSignCount
        snap.todaySignScore = todayScore
        snap.lotteryLeft = lotteryLeft(continueDays)

        let lotteryDue = continueDays > 0 && continueDays % 30 == 0
        var lottery = Lottery()
        lottery.left = snap.lotteryLeft
        if lotteryDue, !WidgetSnapshot.lotteryClaimedToday() {
            lottery = await claimLottery()
            if lottery.claimed {
                WidgetSnapshot.markLotteryClaimed()
            }
        } else if lotteryDue, let cached = cachedSnap, cachedIsToday {
            lottery.text = cached.lotteryText.isEmpty ? "盲盒可抽" : cached.lotteryText
            lottery.claimed = cached.lotteryClaimed || WidgetSnapshot.lotteryClaimedToday()
            lottery.score = cached.lotteryScore
            lottery.left = 0
        } else {
            lottery.text = continueDays == 0 ? "盲盒30天" : "盲盒\(snap.lotteryLeft)天"
            if let cached = cachedSnap, cachedIsToday, !cached.lotteryText.isEmpty, !lotteryDue {
                lottery.text = cached.lotteryText
            }
        }
        snap.lotteryText = lottery.text
        snap.lotteryClaimed = lottery.claimed
        snap.lotteryScore = lottery.score
        if lottery.left >= 0 {
            snap.lotteryLeft = lottery.left
        }

        let points = await fetchPoints()
        if points.total > 0 {
            snap.pointsTotal = points.total
            snap.pointsToday = points.today
        } else {
            snap.pointsTotal = cachedSnap?.pointsTotal ?? 0
            snap.pointsToday = cachedSnap?.pointsToday ?? 0
        }

        applyVehicle(&snap, vehicle: vehicle, tire: tire, ride: ride)
        if let battery {
            if battery.soc > 0 { snap.soc = battery.soc }
            if battery.range > 0 { snap.rangeKm = battery.range }
            snap.charging = battery.charging || snap.charging
        }
        if snap.soc <= 0, let cached = cachedSnap, cached.soc > 0,
           WidgetSnapshot.sameVin(cached.vin, snap.vin) {
            snap.soc = cached.soc
            if snap.rangeKm <= 0 { snap.rangeKm = cached.rangeKm }
        }
        if let wantedVin, !wantedVin.isEmpty, snap.vin.isEmpty {
            snap.vin = wantedVin
        }
        _ = await resolveImage(
            vin: wantedVin ?? vehicle?.vinNo ?? snap.vin,
            url: vehicle?.imageURL ?? URL(string: snap.imageURL)
        )
        snap.imageData = nil

        WidgetSnapshot.write(snap)
        reload()
        return snap
    }

    private static func snapIsToday(_ snap: WidgetSnap?) -> Bool {
        guard let snap, snap.updatedAt > 0 else { return false }
        return Calendar.current.isDateInToday(Date(timeIntervalSince1970: snap.updatedAt))
    }

    // MARK: - Session

    static func hydrateSession() {
        if ZeehoClient.shared.token?.isEmpty != false {
            if let token = WidgetSnapshot.sessionToken(), !token.isEmpty {
                ZeehoClient.shared.token = token
            }
        }
        if ZeehoClient.shared.userId?.isEmpty != false {
            if let uid = WidgetSnapshot.sessionUserId(), !uid.isEmpty {
                ZeehoClient.shared.userId = uid
            }
        }
    }

    private static func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.kind)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Vehicle

    private static func fetchBattery(vin: String?) async -> (soc: Int, range: Int, charging: Bool)? {
        guard let vin, !vin.isEmpty else { return nil }
        async let v2Task = ZeehoClient.shared.get("/v1.0/app/cfmotoserverapp/vehicleHomePageV2/\(vin)")
        async let infoTask = ZeehoClient.shared.get("/v1.0/app/cfmotoserverapp/batteryInfo/\(vin)")
        let v2Res = try? await v2Task
        let infoRes = try? await infoTask
        var items = BatteryInfo.parse(infoRes ?? [:])
        let skeleton = BatteryInfo.parse(v2Res ?? [:])
        if let live = items.first, let frame = skeleton.first {
            items = [frame.merged(with: live)]
        } else if items.isEmpty {
            items = skeleton
        }
        guard let battery = items.first else { return nil }
        return (battery.level, battery.rangeKm ?? 0, battery.isCharging)
    }

    private static func fetchVehicle(hint: Vehicle?, wanted: String?) async -> Vehicle? {
        let wanted = wanted ?? WidgetSnapshot.selectedVin() ?? hint?.vinNo
        if wanted == nil || wanted?.isEmpty == true {
            if let hint { return hint }
            if let res = try? await ZeehoClient.shared.get("/v1.0/app/cfmotoserverapp/vehicle/list") {
                return Vehicle.list(from: res).first
            }
            return nil
        }
        guard let vin = wanted, !vin.isEmpty else { return nil }
        var picked: Vehicle? = WidgetSnapshot.sameVin(hint?.vinNo, vin) ? hint : nil
        if let res = try? await ZeehoClient.shared.get("/v1.0/app/cfmotoserverapp/vehicleHomePage/\(vin)") {
            let code = ZeehoClient.codeString(res["code"])
            if code.isEmpty || code == "10000",
               var json = detailPayload(res) {
                json["vinNo"] = vin
                if let nested = json["vehicleInfo"] as? [String: Any] {
                    json.merge(nested) { current, _ in current }
                }
                if let parsed = Vehicle(json: json) {
                    picked = (picked ?? parsed).merged(with: parsed)
                }
            }
        }
        if let picked, WidgetSnapshot.sameVin(picked.vinNo, vin) { return picked }
        if let res = try? await ZeehoClient.shared.get("/v1.0/app/cfmotoserverapp/vehicle/list") {
            let list = Vehicle.list(from: res)
            if let hit = list.first(where: { WidgetSnapshot.sameVin($0.vinNo, vin) }) {
                return (picked ?? hit).merged(with: hit)
            }
        }
        return WidgetSnapshot.sameVin(hint?.vinNo, vin) ? hint : nil
    }

    private static func fetchTire(vin: String?) async -> TireReading? {
        guard let vin, !vin.isEmpty else { return nil }
        return await TireService.fetch(vin: vin)
    }

    private static func fetchRide(vin: String?) async -> RideTrackService.RideExtra? {
        guard let vin, !vin.isEmpty else { return nil }
        return await RideTrackService.rideExtra(vin: vin)
    }

    private static func detailPayload(_ response: [String: Any]) -> [String: Any]? {
        let raw = response["data"] ?? response
        if let dict = raw as? [String: Any] { return dict }
        if let first = (raw as? [[String: Any]])?.first { return first }
        return nil
    }

    private static func applyVehicle(
        _ snap: inout WidgetSnap,
        vehicle: Vehicle?,
        tire: TireReading?,
        ride: RideTrackService.RideExtra?
    ) {
        guard let vehicle else { return }
        if let wanted = WidgetSnapshot.selectedVin(), !wanted.isEmpty,
           !WidgetSnapshot.sameVin(vehicle.vinNo, wanted) {
            return
        }
        snap.name = vehicle.name
        snap.vin = vehicle.vinNo
        snap.soc = vehicle.soc
        snap.rangeKm = vehicle.rangeKm
        snap.charging = vehicle.isCharging
        snap.locked = vehicle.isLocked
        snap.online = vehicle.isOnline
        snap.totalMile = vehicle.totalMileKm
        snap.monthMile = vehicle.monthMileage ?? "--"
        snap.imageURL = vehicle.imageURL?.absoluteString ?? snap.imageURL
        if let km = ride?.todayKm { snap.todayKm = km }
        if let minutes = ride?.todayMin { snap.todayMin = minutes }
        if let km = ride?.lastKm { snap.lastKm = km }
        if let minutes = ride?.lastMin { snap.lastMin = minutes }
        if let accel = ride?.todayAccel { snap.accel = accel }
        if let brake = ride?.todayBrake { snap.brake = brake }
        if let peak = ride?.todayMaxSpeed { snap.maxSpeed = Int(peak.rounded()) }
        let formatted = WidgetSnapshot.tireCaption(tire)
        if formatted.bound {
            snap.tireText = formatted.text
            snap.tireBound = true
        } else if vehicle.hasTirePressure, let kpa = vehicle.tireRearKpa ?? vehicle.tireFrontKpa {
            snap.tireText = String(format: "%.1fbar", kpa / 100)
            snap.tireBound = true
        }
    }

    // MARK: - Sign in / community

    private struct TaskStatus {
        var signed = false
        var community = false
        var continueDays = 0
        var totalSignCount = 0
        var todayScore = 0
    }

    private static func fetchSigninStatus() async -> TaskStatus {
        var status = TaskStatus()
        if let res = try? await H5Client.get("/cfmotoservermine/H5/signin/info") {
            var raw = res
            if ZeehoClient.codeString(raw["code"]) != "10000" {
                raw = (try? await H5Client.get("/cfmotoservermine/H5/signin")) ?? raw
            }
            if ZeehoClient.codeString(raw["code"]) == "10000",
               let info = SigninInfo.parse(raw["data"]) {
                status.continueDays = info.continueDays
                status.todayScore = info.todayRuleScore
                status.signed = info.signedInToday
                if status.totalSignCount == 0 { status.totalSignCount = info.days }
            }
        }
        return status
    }

    private static func signInIfNeeded() async -> (signed: Bool, continueDays: Int, todayScore: Int) {
        guard let res = try? await H5Client.post("/cfmotoservermine/H5/signin") else {
            return (false, 0, 0)
        }
        let code = ZeehoClient.codeString(res["code"])
        let message = "\(res["message"] ?? res["msg"] ?? "")"
        let already = code == "repeatedly_operation"
            || message.contains("已签")
            || message.contains("重复")
        let ok = code == "10000" || already
        let data = res["data"] as? [String: Any]
        let continueDays = Int("\(data?["continueDays"] ?? data?["days"] ?? 0)") ?? 0
        let todayScore = Int("\(data?["integralScore"] ?? data?["integral"] ?? 0)") ?? 0
        return (ok, continueDays, todayScore)
    }

    // MARK: - 30 天盲盒

    private struct Lottery {
        var text = ""
        var claimed = false
        var score = 0
        var left = -1
    }

    private static func lotteryLeft(_ continueDays: Int) -> Int {
        if continueDays <= 0 { return 30 }
        if continueDays % 30 == 0 { return 0 }
        return 30 - (continueDays % 30)
    }

    /// 仅盲盒日且今天还没领过才调用。对齐 Scriptable：lottery → supplementPrize。
    private static func claimLottery() async -> Lottery {
        var result = Lottery()
        result.left = 0
        var lotteryQuery = H5Client.mineQuery
        lotteryQuery["boxType"] = "0"
        lotteryQuery["version"] = "v2"
        if let parsed = parseLottery(
            try? await H5Client.get("/cfmotoservermine/H5/signin/lottery", query: lotteryQuery)
        ) {
            return parsed
        }

        var query = H5Client.mineQuery
        query["supplementDate"] = CommunityTask.todayKey()
        for path in [
            "/cfmotoservermine/H5/signin/supplementPrize",
            "/cfmotoservermine/signin/supplementPrize"
        ] {
            if let parsed = parseLottery(try? await H5Client.get(path, query: query)) {
                return parsed
            }
        }
        result.text = "盲盒可抽"
        return result
    }

    private static func parseLottery(_ res: [String: Any]?) -> Lottery? {
        guard let res else { return nil }
        let code = ZeehoClient.codeString(res["code"])
        let message = "\(res["message"] ?? res["msg"] ?? "")"
        let already = message.contains("已领") || message.contains("已抽") || message.contains("重复")
        let ok = code == "10000" || already
        guard ok else { return nil }
        var result = Lottery()
        result.left = 0
        result.claimed = true
        let data = res["data"] as? [String: Any]
        result.score = Int("\(data?["integral"] ?? data?["integralScore"] ?? data?["score"] ?? 0)") ?? 0
        let name = "\(data?["prizesName"] ?? data?["prizeName"] ?? "")"
        if already {
            result.text = "盲盒已领"
        } else if result.score > 0 {
            result.text = "盲盒+\(result.score)"
        } else if !name.isEmpty {
            result.text = "盲盒 \(name)"
        } else {
            result.text = "盲盒已领"
        }
        return result
    }

    // MARK: - Points

    private static func fetchPoints() async -> (total: Int, today: Int) {
        var total = await fetchIntegralTotal()
        if total == 0 {
            total = await fetchSettingScore()
        }
        guard total > 0 else { return (0, 0) }

        let todayKey = CommunityTask.todayKey()
        let defaults = WidgetSnapshot.suiteDefaults()
        let versionKey = "widget_points_baseline_v2"
        let baselineDate = defaults?.string(forKey: "widget_points_baseline_date") ?? ""
        var baseline = defaults?.integer(forKey: "widget_points_baseline") ?? 0
        let needReset = defaults?.bool(forKey: versionKey) != true || baselineDate != todayKey
        if needReset {
            baseline = total
            defaults?.set(true, forKey: versionKey)
            defaults?.set(todayKey, forKey: "widget_points_baseline_date")
            defaults?.set(baseline, forKey: "widget_points_baseline")
            defaults?.synchronize()
        }
        return (total, max(0, total - baseline))
    }

    private static func fetchIntegralTotal() async -> Int {
        guard let res = try? await ZeehoClient.shared.get("/v1.0/mine/cfmotoservermine/integral/totalIntegral") else {
            return 0
        }
        return parseIntegral(res)
    }

    private static func fetchSettingScore() async -> Int {
        guard let uid = ZeehoClient.shared.userId, !uid.isEmpty else { return 0 }
        let encoded = uid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? uid
        guard let res = try? await ZeehoClient.shared.get("/v1.0/mine/cfmotoservermine/setting/\(encoded)") else {
            return 0
        }
        return parseIntegral(res)
    }

    private static func parseIntegral(_ res: [String: Any]) -> Int {
        let data = res["data"]
        if let number = data as? NSNumber { return number.intValue }
        if let number = data as? Int { return number }
        if let number = data as? Double { return Int(number) }
        if let text = data as? String { return firstInt(text) }
        let map = data as? [String: Any]
        return firstInt(
            map?["score"],
            map?["integralTotal"],
            map?["totalIntegral"],
            map?["integral"],
            map?["point"],
            map?["points"],
            map?["totalScore"],
            map?["userScore"],
            res["score"],
            res["integralTotal"],
            res["totalIntegral"]
        )
    }

    private static func firstInt(_ values: Any?...) -> Int {
        for value in values {
            guard let value, !(value is NSNull) else { continue }
            if let number = value as? NSNumber { return number.intValue }
            if let number = value as? Int { return number }
            let text = "\(value)".trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text == "<null>" { continue }
            if let number = Int(text) { return number }
            if let number = Double(text) { return Int(number) }
        }
        return 0
    }

    private static func resolveImage(vin: String?, url: URL?) async -> Data? {
        if let cached = WidgetSnapshot.loadImage(vin), !cached.isEmpty {
            return cached
        }
        guard let url else { return WidgetSnapshot.loadImage(vin) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              !data.isEmpty else {
            return WidgetSnapshot.loadImage(vin)
        }
        WidgetSnapshot.saveImage(data, vin: vin)
        return WidgetSnapshot.loadImage(vin) ?? data
    }
}
