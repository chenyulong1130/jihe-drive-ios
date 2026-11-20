import Foundation
import WidgetKit

/// 小组件与 App 共用的云端刷新。
/// timeline：拉车辆 + 任务状态 + 盲盒（15 分钟一次）。
/// reuse：App 已拉过车辆，只补任务/盲盒/积分并写快照。
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
            let empty = WidgetSnap()
            WidgetSnapshot.write(empty)
            reload()
            return empty
        }

        var snap = WidgetSnap()
        snap.loggedIn = true

        let vehicle: Vehicle?
        let tire: TireReading?
        let ride: RideTrackService.RideExtra?
        if mode == .reuse, existing?.vehicle != nil {
            vehicle = existing?.vehicle
            tire = existing?.tire
            ride = existing?.ride
        } else {
            vehicle = await fetchVehicle(hint: existing?.vehicle) ?? existing?.vehicle
            async let tireTask = fetchTire(vin: vehicle?.vinNo)
            async let rideTask = fetchRide(vin: vehicle?.vinNo)
            tire = await tireTask ?? existing?.tire
            ride = await rideTask ?? existing?.ride
        }

        let cachedSnap = WidgetSnapshot.read()
        let cachedIsToday = Self.snapIsToday(cachedSnap)
        let localCommunityDone: Bool = {
            if existing?.communityDone == true { return true }
            if cachedIsToday, cachedSnap?.communityDone == true { return true }
            if let uid = ZeehoClient.shared.userId {
                return CommunityTask.isDoneToday(userId: uid)
            }
            return false
        }()
        let knownSigned = existing?.signedToday == true
            || (cachedIsToday && cachedSnap?.signedToday == true)
        let canReuseStatus = knownSigned && localCommunityDone

        var status = TaskStatus()
        if canReuseStatus {
            status.signed = true
            status.community = true
            status.continueDays = existing?.continueDays ?? cachedSnap?.continueDays ?? 0
            status.totalSignCount = existing?.totalSignCount ?? cachedSnap?.totalSignCount ?? 0
            status.todayScore = existing?.todayScore ?? cachedSnap?.todaySignScore ?? 0
        } else {
            status = await fetchTaskStatus()
        }

        let signedAlready = status.signed || knownSigned
        let communityAlready = status.community || localCommunityDone

        // 今天任务都做完：不再签到、不再跑社区
        if signedAlready && communityAlready {
            snap.signedToday = true
            snap.communityDone = true
        } else {
            if !signedAlready {
                await signInIfNeeded()
            }
            if !communityAlready, let uid = ZeehoClient.shared.userId, !uid.isEmpty {
                let result = await CommunityTask.run(userId: uid)
                snap.communityDone = result.success || CommunityTask.isDoneToday(userId: uid)
            } else {
                snap.communityDone = communityAlready
            }
            status = await fetchTaskStatus()
            snap.signedToday = status.signed || signedAlready
            snap.communityDone = snap.communityDone || status.community || communityAlready
        }

        snap.continueDays = status.continueDays > 0 ? status.continueDays : (existing?.continueDays ?? 0)
        snap.totalSignCount = status.totalSignCount > 0 ? status.totalSignCount : (existing?.totalSignCount ?? 0)
        snap.todaySignScore = status.todayScore
        if snap.continueDays == 0, let existingDays = existing?.continueDays {
            snap.continueDays = existingDays
        }
        snap.lotteryLeft = lotteryLeft(snap.continueDays)

        let lotteryDue = snap.continueDays > 0 && snap.continueDays % 30 == 0
        let shouldLottery = mode == .timeline || lotteryDue || !WidgetSnapshot.lotteryCheckedToday()
        var lottery = Lottery()
        lottery.left = snap.lotteryLeft
        if shouldLottery {
            lottery = await runLottery(continueDays: snap.continueDays, signCount: snap.totalSignCount)
            WidgetSnapshot.markLotteryChecked()
        } else if let cached = cachedSnap {
            lottery.text = cached.lotteryText
            lottery.claimed = cached.lotteryClaimed
            lottery.score = cached.lotteryScore
            lottery.left = cached.lotteryLeft
        }
        snap.lotteryText = lottery.text
        snap.lotteryClaimed = lottery.claimed
        snap.lotteryScore = lottery.score
        if lottery.left >= 0 {
            snap.lotteryLeft = lottery.left
        }

        if mode == .timeline || cachedSnap == nil || (cachedSnap?.pointsTotal ?? 0) == 0 || lottery.score > 0 {
            let points = await fetchPoints(
                claimedExtra: lottery.score + (snap.signedToday ? status.todayScore : 0) + (snap.communityDone ? 3 : 0)
            )
            snap.pointsTotal = points.total
            snap.pointsToday = points.today
        } else {
            snap.pointsTotal = cachedSnap?.pointsTotal ?? 0
            snap.pointsToday = cachedSnap?.pointsToday ?? 0
        }

        applyVehicle(&snap, vehicle: vehicle, tire: tire, ride: ride)
        if mode == .timeline, let url = vehicle?.imageURL {
            snap.imageData = await downloadImage(url)
            if let data = snap.imageData {
                WidgetSnapshot.saveImage(data)
            }
        } else {
            snap.imageData = WidgetSnapshot.loadImage()
        }

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

    private static func fetchVehicle(hint: Vehicle?) async -> Vehicle? {
        let selectedVin = WidgetSnapshot.selectedVin() ?? hint?.vinNo
        var list: [Vehicle] = []
        if let res = try? await ZeehoClient.shared.get("/v1.0/app/cfmotoserverapp/vehicle/list") {
            let code = ZeehoClient.codeString(res["code"])
            if code.isEmpty || code == "10000" {
                list = Vehicle.list(from: res)
            }
        }
        if list.isEmpty { return hint }
        var picked = list.first(where: { $0.vinNo == selectedVin }) ?? list.first
        guard let vin = picked?.vinNo else { return hint }
        if let res = try? await ZeehoClient.shared.get("/v1.0/app/cfmotoserverapp/vehicleHomePage/\(vin)") {
            let code = ZeehoClient.codeString(res["code"])
            if code.isEmpty || code == "10000",
               var json = detailPayload(res) {
                json["vinNo"] = vin
                if let nested = json["vehicleInfo"] as? [String: Any] {
                    json.merge(nested) { current, _ in current }
                }
                if let parsed = Vehicle(json: json), let current = picked {
                    picked = current.merged(with: parsed)
                }
            }
        }
        return picked ?? hint
    }

    private static func fetchTire(vin: String?) async -> TireReading? {
        guard let vin, !vin.isEmpty else { return nil }
        return await TireService.fetch(vin: vin)
    }

    private static func fetchRide(vin: String?) async -> RideTrackService.RideExtra? {
        guard let vin, !vin.isEmpty else { return nil }
        guard let day = await RideTrackService.daySummary(vin: vin) else { return nil }
        var extra = RideTrackService.RideExtra()
        extra.todayKm = day.mileage
        extra.todayMin = day.minutes
        extra.todayMaxSpeed = day.maxSpeed
        extra.todayAccel = day.accelTimes
        extra.todayBrake = day.brakeTimes
        extra.todayBend = day.bendTimes
        return extra
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
        snap.name = vehicle.name
        snap.vin = vehicle.vinNo
        snap.soc = vehicle.soc
        snap.rangeKm = vehicle.rangeKm
        snap.charging = vehicle.isCharging
        snap.locked = vehicle.isLocked
        snap.online = vehicle.isOnline
        snap.totalMile = vehicle.totalMileKm
        snap.monthMile = vehicle.monthMileage ?? "--"
        snap.imageURL = vehicle.imageURL?.absoluteString ?? ""
        snap.todayKm = ride?.todayKm ?? 0
        snap.todayMin = ride?.todayMin ?? 0
        snap.accel = ride?.todayAccel ?? 0
        snap.brake = ride?.todayBrake ?? 0
        snap.maxSpeed = Int((ride?.todayMaxSpeed ?? 0).rounded())
        let reading = tire
        if let bar = reading?.rearBar ?? reading?.frontBar {
            let temp = reading?.rearTemp ?? reading?.frontTemp
            if let temp {
                snap.tireText = String(format: "%.1fbar %.0f°C", bar, temp)
            } else {
                snap.tireText = String(format: "%.1fbar", bar)
            }
            snap.tireBound = true
        } else if vehicle.hasTirePressure, let kpa = vehicle.tireRearKpa ?? vehicle.tireFrontKpa {
            snap.tireText = String(format: "%.1fbar", kpa / 100)
            snap.tireBound = true
        } else {
            snap.tireText = ""
            snap.tireBound = false
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

    private static func fetchTaskStatus() async -> TaskStatus {
        var status = TaskStatus()
        if let uid = ZeehoClient.shared.userId, !uid.isEmpty {
            status.community = await CommunityTask.resolveDone(userId: uid)
        }

        if let res = try? await H5Client.get("/cfmotoservermine/H5/signin/info") {
            var raw = res
            if ZeehoClient.codeString(raw["code"]) != "10000" {
                raw = (try? await H5Client.get("/cfmotoservermine/H5/signin")) ?? raw
            }
            if ZeehoClient.codeString(raw["code"]) == "10000",
               let info = SigninInfo.parse(raw["data"]) {
                status.continueDays = info.continueDays
                status.todayScore = info.todayRuleScore
                if info.signedInToday { status.signed = true }
                if status.totalSignCount == 0 { status.totalSignCount = info.days }
            }
        }

        if let res = try? await ZeehoClient.shared.get("/v1.0/mine/cfmotoservermine/signin/count"),
           ZeehoClient.codeString(res["code"]) == "10000",
           let data = res["data"] as? [String: Any] {
            if "\(data["signStatus"] ?? "")" == "1" { status.signed = true }
            let count = Int("\(data["count"] ?? "")") ?? 0
            if count > 0 { status.totalSignCount = count }
        }
        return status
    }

    private static func signInIfNeeded() async {
        _ = try? await H5Client.post("/cfmotoservermine/H5/signin")
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

    private static func runLottery(continueDays: Int, signCount: Int) async -> Lottery {
        var result = Lottery()
        result.left = lotteryLeft(continueDays)
        var cycleCount = signCount
        let month = String(CommunityTask.todayKey().prefix(7))
        var monthQuery = H5Client.mineQuery
        monthQuery["month"] = month
        if let res = try? await H5Client.get("/cfmotoservermine/signin/info", query: monthQuery),
           ZeehoClient.codeString(res["code"]) == "10000",
           let data = res["data"] as? [String: Any] {
            let count = Int("\(data["signCount"] ?? "")") ?? 0
            if count > 0 { cycleCount = count }
        }
        let due = (continueDays > 0 && continueDays % 30 == 0)
            || (cycleCount >= 30 && continueDays > 0 && continueDays % 30 == 0)

        if due {
            let today = CommunityTask.todayKey()
            var query = H5Client.mineQuery
            query["supplementDate"] = today
            var claimed = false
            var score = 0
            var name = ""
            for path in [
                "/cfmotoservermine/signin/supplementPrize",
                "/cfmotoservermine/H5/signin/supplementPrize"
            ] {
                guard let res = try? await H5Client.get(path, query: query) else { continue }
                if ZeehoClient.codeString(res["code"]) == "10000" {
                    claimed = true
                    let data = res["data"] as? [String: Any]
                    score = Int("\(data?["integral"] ?? data?["integralScore"] ?? 0)") ?? 0
                    name = "\(data?["prizesName"] ?? data?["prizeName"] ?? "")"
                    break
                }
            }
            result.claimed = claimed
            result.score = score
            if claimed {
                result.text = score > 0 ? "盲盒+\(score)" : (name.isEmpty ? "盲盒已领" : "盲盒 \(name)")
                result.left = 0
            } else {
                result.text = "盲盒可领"
                result.left = 0
            }
        } else {
            result.text = result.left == 30 && continueDays == 0 ? "盲盒30天" : "盲盒\(result.left)天"
        }

        var prizeQuery = H5Client.mineQuery
        prizeQuery["page"] = "1"
        prizeQuery["pageSize"] = "10"
        _ = try? await H5Client.get("/cfmotoservermine/H5/signin/prizesDetail", query: prizeQuery)
        return result
    }

    // MARK: - Points

    private static func fetchPoints(claimedExtra: Int) async -> (total: Int, today: Int) {
        var total = 0
        if let res = try? await ZeehoClient.shared.get("/v1.0/mine/cfmotoservermine/integral/totalIntegral") {
            if let number = res["data"] as? NSNumber {
                total = number.intValue
            } else if let data = res["data"] as? [String: Any] {
                total = firstInt(data["integralTotal"], data["totalIntegral"], data["integral"], data["score"])
            } else {
                total = firstInt(res["integralTotal"], res["totalIntegral"], res["data"])
            }
        }
        let todayKey = CommunityTask.todayKey()
        let defaults = WidgetSnapshot.suiteDefaults()
        let baselineDate = defaults?.string(forKey: "widget_points_baseline_date") ?? ""
        var baseline = defaults?.integer(forKey: "widget_points_baseline") ?? 0
        if baselineDate != todayKey {
            baseline = max(0, total - claimedExtra)
            defaults?.set(todayKey, forKey: "widget_points_baseline_date")
            defaults?.set(baseline, forKey: "widget_points_baseline")
            defaults?.synchronize()
        }
        let today = max(0, total - baseline)
        return (total, today)
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

    private static func downloadImage(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              !data.isEmpty else {
            return WidgetSnapshot.loadImage()
        }
        return data
    }
}
