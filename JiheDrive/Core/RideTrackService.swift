import Foundation

/// 骑行数据接口（与小程序 / 安卓版一致，均已在真机验证）
/// - 按次明细：GET /ridetrack_v2?vinNo=&startDateTime=yyyy-MM-dd&endDateTime=yyyy-MM-dd&startTime=yyyy-MM&endTime=yyyy-MM&page=&pageSize=
///   ⚠️ 日期与月份必须横线分隔
/// - 单日汇总：GET /rideDayInfo?vinNo=&date=yyyy.MM.dd
///   ⚠️ 这里是点分隔，横线会返回 40000
enum RideTrackService {

    private static let dashedDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dashedMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private static let dottedDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()

    // MARK: - 按次明细

    static func tracks(
        vin: String,
        days: Int = 30,
        page: Int = 1,
        pageSize: Int = 50
    ) async -> [RideTrack]? {
        let calendar = Calendar.current
        let today = Date()
        guard let from = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) else {
            return nil
        }
        return await tracks(vin: vin, from: from, to: today, page: page, pageSize: pageSize)
    }

    /// 按日期区间拉按次行程（日期/月份均横线，对齐 miniapp fetchTripTrack）
    static func tracks(
        vin: String,
        from: Date,
        to: Date,
        page: Int = 1,
        pageSize: Int = 50
    ) async -> [RideTrack]? {
        let query = [
            "vinNo": vin,
            "startDateTime": dashedDay.string(from: from),
            "endDateTime": dashedDay.string(from: to),
            "startTime": dashedMonth.string(from: from),
            "endTime": dashedMonth.string(from: to),
            "page": "\(page)",
            "pageSize": "\(pageSize)"
        ]

        let response: [String: Any]
        do {
            response = try await ZeehoClient.shared.get(
                "/v1.0/app/cfmotoserverapp/ridetrack_v2",
                query: query
            )
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }

        let code = ZeehoClient.codeString(response["code"])
        guard code.isEmpty || code == "10000" else { return nil }
        return parse(response["data"])
    }

    /// data 可能是 [{ dayTime, historyList: [...] }]，也可能直接是行程数组
    static func parse(_ data: Any?) -> [RideTrack] {
        let groups: [[String: Any]] = {
            if let array = data as? [[String: Any]] { return array }
            if let dict = data as? [String: Any], let list = dict["list"] as? [[String: Any]] {
                return list
            }
            return []
        }()

        var items: [[String: Any]] = []
        for group in groups {
            let history = (group["historyList"]
                ?? group["rideRocordList"]
                ?? group["rideList"]
                ?? group["recordList"]) as? [[String: Any]]
            if let history {
                items.append(contentsOf: history)
            } else if group["rideId"] != nil || group["trajectory"] != nil {
                items.append(group)
            }
        }

        let pairs = items.enumerated().compactMap { index, item -> (String, RideTrack)? in
            let samples = trajectory(item["trajectory"])
            let points = samples.map { $0.coordinate }
            let mileage = Vehicle.doubleValue(item["rideMileage"] ?? item["mileage"] ?? item["distance"]) ?? 0
            let minutes = Int(Vehicle.doubleValue(item["ridingTimeUnitMinute"] ?? item["ridingTimeDayUnitMinute"]) ?? 0)
            // 列表可无轨迹（只显示里程/时长）；回放页再筛 points.count > 1
            guard points.count > 1 || mileage > 0 || minutes > 0 else { return nil }

            let start = text(item["startTime"] ?? item["beginTime"] ?? item["rideBeginTime"])
            let end = text(item["endTime"] ?? item["finishTime"] ?? item["rideEndTime"])
            let track = RideTrack(
                id: text(item["rideId"] ?? item["id"]) ?? "ride-\(index)",
                startTime: display(start),
                mileage: mileage,
                durationMinutes: max(minutes, points.count > 1 ? 1 : 0),
                points: points,
                endTime: display(end),
                maxSpeed: Vehicle.doubleValue(item["maxSpeed"]),
                startAddress: address(item["startAddr"] ?? item["startAddress"]),
                endAddress: address(item["endAddr"] ?? item["endAddress"]),
                speedSamples: samples.map { $0.speed },
                accelTimes: Int(Vehicle.doubleValue(
                    item["accelerationTimes"] ?? item["accelerationTimesDay"]
                ) ?? 0),
                brakeTimes: Int(Vehicle.doubleValue(
                    item["brakesTimes"] ?? item["brakesTimesDay"] ?? item["brakeTimes"]
                ) ?? 0),
                bendTimes: Int(Vehicle.doubleValue(
                    item["bendingTimes"] ?? item["bendingTimesDay"] ?? item["bendTimes"]
                ) ?? 0),
                thumbnailURL: remoteURL(
                    item["trackThumbnails"]
                        ?? item["trackThumbnail"]
                        ?? item["thumbnail"]
                        ?? item["thumbUrl"]
                        ?? item["rideThumbnail"]
                )
            )
            return (start ?? "", track)
        }

        return pairs.sorted { $0.0 > $1.0 }.map { $0.1 }
    }

    // MARK: - 单日汇总

    struct DaySummary {
        var mileage: Double
        var minutes: Int
        var maxSpeed: Double
        var accelTimes: Int
        var brakeTimes: Int
        var bendTimes: Int
    }

    /// 车辆页双卡：最近骑行 + 今日（对齐 Flutter homeRideInfo + rideDayInfo）
    struct RideExtra {
        var lastKm: Double?
        var lastMin: Int?
        var todayKm: Double?
        var todayMin: Int?
        var todayMaxSpeed: Double?
        var todayAccel: Int?
        var todayBrake: Int?
        var todayBend: Int?
    }

    static func daySummary(vin: String, date: Date = Date()) async -> DaySummary? {
        let query = [
            "vinNo": vin,
            "date": dottedDay.string(from: date)
        ]
        let response: [String: Any]
        do {
            response = try await ZeehoClient.shared.get(
                "/v1.0/app/cfmotoserverapp/rideDayInfo",
                query: query
            )
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }

        let code = ZeehoClient.codeString(response["code"])
        guard code.isEmpty || code == "10000" else { return nil }
        guard let data = unwrapMap(response["data"]) else { return nil }

        let maxSpeed = Vehicle.doubleValue(data["maxSpeed"])
            ?? Vehicle.doubleValue(data["maxSpeedDay"])
            ?? Vehicle.doubleValue(data["highestSpeed"])
            ?? Vehicle.doubleValue(data["rideMaxSpeed"])
            ?? 0
        return DaySummary(
            mileage: Vehicle.doubleValue(data["rideMileageDay"] ?? data["rideMileage"]) ?? 0,
            minutes: Int(Vehicle.doubleValue(
                data["ridingTimeDayUnitMinute"] ?? data["ridingTimeUnitMinute"]
            ) ?? 0),
            maxSpeed: maxSpeed,
            accelTimes: Int(Vehicle.doubleValue(
                data["accelerationTimesDay"] ?? data["accelerationTimes"]
            ) ?? 0),
            brakeTimes: Int(Vehicle.doubleValue(
                data["brakesTimesDay"] ?? data["brakesTimes"] ?? data["brakeTimes"]
            ) ?? 0),
            bendTimes: Int(Vehicle.doubleValue(
                data["bendingTimesDay"] ?? data["bendingTimes"] ?? data["bendTimes"]
            ) ?? 0)
        )
    }

    /// 月里程：对齐 Flutter / 小程序 rideMonthInfo（month 用 yyyy.MM）
    struct MonthDay: Identifiable {
        var id: String { date }
        let date: String
        let mileage: Double
        let minutes: Int
    }

    /// 失败/取消返回 nil，调用方应保留旧数据；空月返回 []
    static func monthInfo(vin: String, month: Date = Date()) async -> [MonthDay]? {
        let query = [
            "vinNo": vin,
            "month": dottedMonth.string(from: month)
        ]
        let response: [String: Any]
        do {
            response = try await ZeehoClient.shared.get(
                "/v1.0/app/cfmotoserverapp/rideMonthInfo",
                query: query
            )
        } catch is CancellationError {
            return nil
        } catch {
            return await monthFromTracks(vin: vin, month: month)
        }
        let code = ZeehoClient.codeString(response["code"])
        guard code.isEmpty || code == "10000" else {
            return await monthFromTracks(vin: vin, month: month)
        }

        let raw = response["data"]
        let list: [[String: Any]]
        if let array = raw as? [[String: Any]] {
            list = array
        } else if let dict = raw as? [String: Any] {
            list = (dict["list"] as? [[String: Any]])
                ?? (dict["records"] as? [[String: Any]])
                ?? (dict["dayList"] as? [[String: Any]])
                ?? []
        } else {
            list = []
        }

        let parsed = list.compactMap { item -> MonthDay? in
            let rawDate = text(item["date"] ?? item["dayTime"] ?? item["rideDate"]) ?? ""
            let date = rawDate.replacingOccurrences(of: "-", with: ".")
            let mileage = Vehicle.doubleValue(item["rideMileage"] ?? item["rideMileageDay"] ?? item["mileage"]) ?? 0
            let minutes = Int(Vehicle.doubleValue(item["ridingTimeUnitMinute"] ?? item["ridingTimeDayUnitMinute"]) ?? 0)
            guard !date.isEmpty else { return nil }
            return MonthDay(date: date, mileage: mileage, minutes: minutes)
        }
        if !parsed.isEmpty { return parsed }
        // 共享车月汇总常为空，改用当月 ridetrack_v2 按天汇总（Z-Link 同样走轨迹）
        return await monthFromTracks(vin: vin, month: month)
    }

    private static func monthFromTracks(vin: String, month: Date) async -> [MonthDay]? {
        let calendar = Calendar.current
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) else {
            return []
        }
        let end = min(monthEnd, Date())
        guard let tracks = await tracks(vin: vin, from: start, to: end, pageSize: 80) else {
            return Task.isCancelled ? nil : []
        }

        var buckets: [String: (km: Double, min: Int)] = [:]
        let display = DateFormatter()
        display.locale = Locale(identifier: "en_US_POSIX")
        display.dateFormat = "yyyy.MM.dd"
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let year = calendar.component(.year, from: month)
        for track in tracks {
            let raw = track.startTime ?? ""
            let day: String
            if let date = parse.date(from: raw) ?? parse.date(from: String(raw.prefix(19))) {
                day = display.string(from: date)
            } else {
                let head = raw.split(separator: " ").first.map(String.init) ?? raw
                let bits = head.split(separator: ".").map(String.init)
                if bits.count >= 3, bits[0].count == 4 {
                    day = bits.prefix(3).joined(separator: ".")
                } else if bits.count >= 2, let monthNum = Int(bits[0]), let dayNum = Int(bits[1]) {
                    day = String(format: "%04d.%02d.%02d", year, monthNum, dayNum)
                } else {
                    continue
                }
            }
            var bucket = buckets[day] ?? (0, 0)
            bucket.km += track.mileage
            bucket.min += track.durationMinutes
            buckets[day] = bucket
        }
        return buckets.map { MonthDay(date: $0.key, mileage: $0.value.km, minutes: $0.value.min) }
            .sorted { $0.date < $1.date }
    }

    private static let dottedMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM"
        return formatter
    }()

    /// 面板骑行卡权威数据源：homeRideInfo（最近）+ rideDayInfo（今日时长/极速/行为）
    /// 取消时返回 nil，调用方不要覆盖旧数据
    static func rideExtra(vin: String) async -> RideExtra? {
        if Task.isCancelled { return nil }
        var extra = RideExtra()

        do {
            let response = try await ZeehoClient.shared.get(
                "/v1.0/app/cfmotoserverapp/homeRideInfo",
                query: ["vinNo": vin]
            )
            let code = ZeehoClient.codeString(response["code"])
            if code.isEmpty || code == "10000",
               let data = unwrapMap(response["data"]) {
                let mileages = (data["mileages"] as? [Any])?
                    .compactMap { Vehicle.doubleValue($0) }
                    .filter { $0 > 0 } ?? []
                let times = (data["ridingTimes"] as? [Any])?
                    .compactMap { Vehicle.doubleValue($0).map { Int($0) } }
                    .filter { $0 > 0 } ?? []

                extra.lastKm = positive(Vehicle.doubleValue(data["lastRideMileage"]))
                    ?? mileages.last
                extra.lastMin = positiveInt(
                    Vehicle.doubleValue(data["lastRidingTimeUnitMinute"])
                        ?? Vehicle.doubleValue(data["lastRidingTime"])
                ) ?? times.last
                extra.todayKm = positive(Vehicle.doubleValue(data["rideMileageDay"]))
                extra.todayMaxSpeed = positive(
                    Vehicle.doubleValue(data["maxSpeed"])
                        ?? Vehicle.doubleValue(data["maxSpeedDay"])
                        ?? Vehicle.doubleValue(data["highestSpeed"])
                )
            }
        } catch is CancellationError {
            return nil
        } catch {
            // 主接口失败仍继续拉当日汇总
        }

        if Task.isCancelled { return nil }
        if let day = await daySummary(vin: vin) {
            if day.mileage > 0 { extra.todayKm = day.mileage }
            extra.todayMin = day.minutes > 0 ? day.minutes : extra.todayMin
            extra.todayMaxSpeed = day.maxSpeed > 0 ? day.maxSpeed : extra.todayMaxSpeed
            extra.todayAccel = day.accelTimes
            extra.todayBrake = day.brakeTimes
            extra.todayBend = day.bendTimes
        } else if Task.isCancelled {
            return nil
        }

        if extra.todayMaxSpeed == nil
            || extra.todayAccel == nil
            || (extra.todayAccel ?? 0) == 0 {
            if let dayTracks = await tracks(vin: vin, days: 1), !dayTracks.isEmpty {
                if extra.todayMaxSpeed == nil {
                    let peak = dayTracks.compactMap { track -> Double? in
                        if let max = track.maxSpeed, max > 0 { return max }
                        return track.speedSamples.max()
                    }.max() ?? 0
                    if peak > 0 { extra.todayMaxSpeed = peak }
                }
                let accel = dayTracks.reduce(0) { $0 + $1.accelTimes }
                let brake = dayTracks.reduce(0) { $0 + $1.brakeTimes }
                let bend = dayTracks.reduce(0) { $0 + $1.bendTimes }
                if accel > 0 { extra.todayAccel = accel }
                if brake > 0 { extra.todayBrake = brake }
                if bend > 0 { extra.todayBend = bend }
            } else if Task.isCancelled {
                return nil
            }
        }

        return extra
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func positiveInt(_ value: Double?) -> Int? {
        guard let value, value > 0 else { return nil }
        return Int(value)
    }

    // MARK: - 解析工具

    /// trajectory = "lng,lat,speed,ts,x" 用 & 连接
    private struct Sample {
        let coordinate: Coordinate
        let speed: Double
    }

    private static func trajectory(_ raw: Any?) -> [Sample] {
        guard let text = raw as? String, !text.isEmpty else { return [] }
        return text.split(separator: "&").compactMap { segment in
            let parts = segment.split(separator: ",")
            guard parts.count >= 2,
                  let lng = Double(String(parts[0]).trimmingCharacters(in: .whitespaces)),
                  let lat = Double(String(parts[1]).trimmingCharacters(in: .whitespaces)),
                  abs(lat) > 0.0001,
                  abs(lng) > 0.0001 else { return nil }
            let speed = parts.count >= 3
                ? (Double(String(parts[2]).trimmingCharacters(in: .whitespaces)) ?? 0)
                : 0
            return Sample(
                coordinate: Coordinate(latitude: lat, longitude: lng),
                speed: speed
            )
        }
    }

    private static func unwrapMap(_ raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] {
            if let nested = dict["rideDayInfo"] as? [String: Any] { return nested }
            if let nested = dict["day"] as? [String: Any] { return nested }
            if let nested = dict["data"] as? [String: Any] { return nested }
            return dict
        }
        if let list = raw as? [[String: Any]] { return list.first }
        return nil
    }

    private static func text(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber { return number.stringValue }
        let value = "\(raw)".trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "<null>" ? nil : value
    }

    /// startAddr 是 JSON 串（{"name":"..."}）或纯文本
    private static func address(_ raw: Any?) -> String? {
        if let text = raw as? String {
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String,
               !name.isEmpty {
                return name
            }
            return text.isEmpty ? nil : text
        }
        if let dict = raw as? [String: Any],
           let name = dict["name"] as? String,
           !name.isEmpty {
            return name
        }
        return nil
    }

    /// "2026.11.13 08:12:33" / ISO8601 → "08:12"（列表按日分组，条目不再重复日期）
    private static func display(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return raw }
        if let match = raw.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) {
            let hm = String(raw[match]).split(separator: ":")
            if hm.count == 2, let hour = Int(hm[0]) {
                return String(format: "%02d:%@", hour, String(hm[1]))
            }
            return String(raw[match])
        }
        let segments = raw.replacingOccurrences(of: "-", with: ".").split(separator: " ")
        if segments.count > 1 {
            return String(segments[1].prefix(5))
        }
        return nil
    }

    private static func remoteURL(_ raw: Any?) -> URL? {
        if let url = raw as? URL { return url }
        if let dict = raw as? [String: Any] {
            return remoteURL(dict["url"] ?? dict["thumbUrl"] ?? dict["thumbnail"] ?? dict["ossUrl"])
        }
        if let list = raw as? [Any] {
            return remoteURL(list.first)
        }
        guard var text = text(raw), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "\\/", with: "/")
        if let url = URL(string: text) { return url }
        return text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
            .flatMap(URL.init(string:))
    }
}
