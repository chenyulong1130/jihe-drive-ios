import Combine
import Foundation
import Network
import UIKit
import WidgetKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var vehicles: [Vehicle] = []
    @Published private(set) var batteries: [BatteryInfo] = []
    /// batteries 属于哪台车。充电态是**按车**的，切车瞬间/加载空窗期不能把上一台车的
    /// 电池套到当前车上（否则会出现"所有车都在充电"）。视图与灵动岛都必须先校验这个。
    @Published private(set) var batteriesVin: String?

    /// 当前 batteries 是否确实属于选中车辆
    var batteriesBelongToSelected: Bool {
        guard let batteriesVin, let vin = selectedVehicle?.vinNo else { return false }
        return WidgetSnapshot.sameVin(batteriesVin, vin)
    }

    /// 只属于当前车的电池（充电态展示、灵动岛、充电 UI 的唯一入口）
    var liveBatteryOfSelected: BatteryInfo? {
        guard batteriesBelongToSelected else { return nil }
        return batteries.first { !$0.id.hasPrefix("vehicle-") }
    }
    @Published private(set) var batteryLoading = false
    @Published var batteryError: String?
    @Published private(set) var tire: TireReading?
    @Published private(set) var loading = false
    /// 车辆首页详情（vehicleHomePage）在拉取中：首页各卡片骨架屏用这个兜底，
    /// 切车 / 首次进入时详情没回来前不闪空数据
    @Published private(set) var detailLoading = false
    @Published private(set) var detailVehicle: Vehicle?
    @Published var selectedVin: String? {
        didSet {
            UserDefaults.standard.set(selectedVin, forKey: Self.vinKey)
            WidgetSnapshot.persistSelectedVin(selectedVin)
            guard oldValue != selectedVin else { return }
            seedWidgetSnap(for: selectedVin)
            // 换车后旧电池数据必须清掉，否则详情页会显示上一台车的电压温度/充电态
            batteries = []
            batteriesVin = nil
            batteryError = nil
            tire = nil
            detailVehicle = nil
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    @Published var errorMessage: String?
    /// 最近一次车辆数据成功刷新的时间（轮询/下拉/回前台都会更新）
    @Published private(set) var lastUpdatedAt: Date?

    /// 开关机刚发出时云端锁态会滞后，这段时间内别用列表/详情把乐观状态盖回去
    private var lockHold: (vin: String, locked: Bool, until: Date)?
    /// 充电态防抖：下拉刷新/轮询瞬间云端偶尔回报"未充电"（数据断流/缓存刷新），
    /// 上一刻还在充电就按住旧状态 45 秒，避免主页"充电中"闪丢、过一会才回来
    private var chargeHold: (vin: String, until: Date)?

    private static let vinKey = "jihe.selected.vin"

    private let client: ZeehoClient

    /// 网络可达性监听：国行 iOS「无线数据」权限弹窗期间请求必失败，
    /// 路径变为可用（权限放行/网络恢复）时补拉一次车辆列表，
    /// 否则首页会一直空着，只能退出重登才恢复
    private let pathMonitor = NWPathMonitor()
    private var didLoadOnPathReady = false

    init(client: ZeehoClient = .shared) {
        self.client = client
        self.isLoggedIn = client.isLoggedIn
        let saved = UserDefaults.standard.string(forKey: Self.vinKey)
        self.selectedVin = (saved?.isEmpty == false) ? saved : nil
        WidgetSnapshot.persistSelectedVin(self.selectedVin)
        startPathMonitor()
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                // 只在"还没成功拉到过车辆列表"时补拉，避免正常轮询外多打接口
                if self.isLoggedIn, self.vehicles.isEmpty, !self.loading, !self.didLoadOnPathReady {
                    self.didLoadOnPathReady = true
                    await self.loadVehicles()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "jihe.pathmonitor"))
    }

    var selectedVehicle: Vehicle? {
        let base: Vehicle?
        if let selectedVin, let hit = vehicles.first(where: { WidgetSnapshot.sameVin($0.vinNo, selectedVin) }) {
            base = hit
        } else {
            base = vehicles.first
        }
        guard let base else { return nil }
        guard let detail = detailVehicle, detail.vinNo == base.vinNo else { return base }
        return base.merged(with: detail)
    }

    func bootstrap() async {
        guard isLoggedIn else { return }
        await loadVehicles()
        // 网络权限刚放行时首拉常常直接失败（国行「无线数据」弹窗期间）：
        // 车辆列表仍为空就小步重试几轮，等权限/网络真正就绪
        for _ in 0..<5 {
            guard isLoggedIn, vehicles.isEmpty, !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await loadVehicles()
            if !vehicles.isEmpty { return }
        }
    }

    func loadVehicles() async {
        guard isLoggedIn else { return }
        loading = true
        defer { loading = false }
        do {
            let response = try await client.get("/v1.0/app/cfmotoserverapp/vehicle/list")
            let code = ZeehoClient.codeString(response["code"])
            if !code.isEmpty && code != "10000" {
                errorMessage = ZeehoClient.errorText(response) ?? "车辆列表加载失败"
                return
            }
            vehicles = Vehicle.list(from: response)
            if selectedVin == nil { selectedVin = vehicles.first?.vinNo }
            if (client.userId ?? "").isEmpty, let id = Self.userId(from: response["data"]) {
                client.userId = id
            }
            applyLockHold()
            errorMessage = nil
            didLoadOnPathReady = true
            prefetchModelsInBackground()
        } catch let error as ZeehoError {
            if case .unauthorized = error {
                isLoggedIn = false
            }
            errorMessage = error.localizedDescription
        } catch is CancellationError {
            // 页面刷新打断，忽略
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var prefetchTask: Task<Void, Never>?

    /// 联网时后台预取其他车辆的 3D 模型：切到没缓存过的车（尤其已在
    /// 仪表 Wi-Fi 等无互联网网络时）也有缓存可用，不用现场下载失败。
    func prefetchModelsInBackground() {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            let vins = await MainActor.run { self.vehicles.map(\.vinNo) }
            for vin in vins {
                guard !Task.isCancelled else { return }
                await self.prefetchModelIfNeeded(vin: vin)
            }
        }
    }

    private func prefetchModelIfNeeded(vin: String) async {
        do {
            let response = try await client.get("/v1.0/app/cfmotoserverapp/vehicleHomePage/\(vin)")
            let code = ZeehoClient.codeString(response["code"])
            guard code.isEmpty || code == "10000",
                  var json = Self.detailPayload(response) else { return }
            json["vinNo"] = vin
            if let nested = json["vehicleInfo"] as? [String: Any] {
                json.merge(nested) { current, _ in current }
            }
            guard let parsed = Vehicle(json: json),
                  let url = parsed.model3DURL, parsed.isGLBModel,
                  GLBModelStore.cached(vin: vin, remote: url) == nil else { return }
            _ = try await GLBModelStore.localFile(for: url, vin: vin)
        } catch is CancellationError {
        } catch {
            // 静默失败：联网后重新进入会再预取
        }
    }

    func requestCode(phone: String) async throws {
        let response = try await client.requestAuthCode(phone: phone)
        let code = ZeehoClient.codeString(response["code"])
        guard code == "10000" else {
            throw ZeehoError.server(
                code: code,
                message: ZeehoClient.errorText(response) ?? "验证码发送失败"
            )
        }
    }

    func login(phone: String, code: String) async throws {
        let response = try await client.login(phone: phone, code: code)
        let status = ZeehoClient.codeString(response["code"])
        guard status == "10000" else {
            throw ZeehoError.server(
                code: status,
                message: ZeehoClient.errorText(response) ?? "登录失败"
            )
        }
        guard let token = Self.accessToken(response["data"]) else {
            throw ZeehoError.decoding("登录成功但未返回 token")
        }
        client.token = token
        if let id = Self.userId(from: response["data"]) {
            client.userId = id
        }
        isLoggedIn = true
        await loadVehicles()
    }

    func logout() {
        client.clearSession()
        prefetchTask?.cancel()
        prefetchTask = nil
        vehicles = []
        batteries = []
        selectedVin = nil
        errorMessage = nil
        batteryError = nil
        isLoggedIn = false
    }

    /// 直接粘贴 token 登录：先用车辆列表验证一次，无效就不落库
    func loginWithToken(_ raw: String) async throws {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "bearer ", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else {
            throw ZeehoError.decoding("Token 不完整，检查是否复制全了")
        }

        client.token = trimmed
        do {
            let response = try await client.get("/v1.0/app/cfmotoserverapp/vehicle/list")
            let code = ZeehoClient.codeString(response["code"])
            guard code.isEmpty || code == "10000" else {
                client.clearSession()
                throw ZeehoError.server(
                    code: code,
                    message: ZeehoClient.errorText(response) ?? "Token 无效或已过期"
                )
            }
            vehicles = Vehicle.list(from: response)
            if selectedVin == nil { selectedVin = vehicles.first?.vinNo }
            if (client.userId ?? "").isEmpty, let id = Self.userId(from: response["data"]) {
                client.userId = id
            }
            errorMessage = nil
            isLoggedIn = true
            prefetchModelsInBackground()
        } catch {
            client.clearSession()
            throw error
        }
    }

    func refreshAll() async {
        await loadVehicles()
        if let vin = selectedVehicle?.vinNo {
            async let battery: Void = loadBattery(vin: vin)
            async let detail: Void = loadDetail(vin: vin)
            async let tire: Void = loadTire(vin: vin)
            _ = await (battery, detail, tire)
        }
        WidgetSnapshot.publish(from: self, ride: nil)
        lastUpdatedAt = Date()
    }

    /// 前台轻量轮询：车辆首页 + 电池，不刷胎压/列表
    func refreshQuiet() async {
        guard isLoggedIn, let vin = selectedVehicle?.vinNo else { return }
        async let battery: Void = loadBattery(vin: vin, quiet: true)
        async let detail: Void = loadDetail(vin: vin)
        async let tire: Void = loadTire(vin: vin)
        _ = await (battery, detail, tire)
        WidgetSnapshot.publish(from: self, ride: nil)
        WidgetCenter.shared.reloadAllTimelines()
        lastUpdatedAt = Date()
    }

    /// 下拉刷新等 View 侧路径手动标记更新时间
    func markUpdated() {
        lastUpdatedAt = Date()
    }

    /// 胎压传感器接口，独立于车辆详情，失败不影响主流程
    func loadTire(vin: String) async {
        let reading = await TireService.fetch(vin: vin)
        guard selectedVin == nil || WidgetSnapshot.sameVin(selectedVin, vin) else { return }
        // 接口失败时保留旧读数，避免下拉刷新把胎压刷没
        if let reading {
            tire = reading
            WidgetSnapshot.publish(from: self)
        }
    }

    /// 车辆首页接口：胎压、电压、温度、3D 模型这类细节只有这里带
    func loadDetail(vin: String) async {
        detailLoading = true
        defer { detailLoading = false }
        do {
            let response = try await client.get("/v1.0/app/cfmotoserverapp/vehicleHomePage/\(vin)")
            let code = ZeehoClient.codeString(response["code"])
            if !code.isEmpty && code != "10000" { return }
            guard var json = Self.detailPayload(response) else { return }
            json["vinNo"] = vin
            if let nested = json["vehicleInfo"] as? [String: Any] {
                json.merge(nested) { current, _ in current }
            }
            guard let parsed = Vehicle(json: json) else { return }
            guard selectedVin == nil || WidgetSnapshot.sameVin(selectedVin, vin) else { return }
            detailVehicle = parsed
            applyLockHold()
            WidgetSnapshot.publish(from: self)
        } catch is CancellationError {
            // 切车打断，忽略
        } catch let error as URLError where error.code == .cancelled {
            // 同上
        } catch {
            // 细节接口失败不影响主流程，页面回落到列表字段
        }
    }

    private static func detailPayload(_ response: [String: Any]) -> [String: Any]? {
        let raw = response["data"] ?? response
        if let dict = raw as? [String: Any] { return dict }
        if let first = (raw as? [[String: Any]])?.first { return first }
        return nil
    }

    // MARK: - 电池

    func loadBattery(vin: String, quiet: Bool = false) async {
        if !quiet { batteryLoading = true }
        batteryError = nil
        defer { if !quiet { batteryLoading = false } }

        do {
            // 小程序规则：V2 给充电骨架（功率/充满文案），batteryInfo 覆盖 soc/电压/电流
            async let v2Task = client.get("/v1.0/app/cfmotoserverapp/vehicleHomePageV2/\(vin)")
            async let infoTask = client.get("/v1.0/app/cfmotoserverapp/batteryInfo/\(vin)")
            let v2Res = try? await v2Task
            let infoRes = try? await infoTask
            // 同一份 V2 还带坐垫锁状态，别浪费一次请求
            let seat = v2Res.flatMap { Vehicle.parseSeat(from: $0) }

            var items = BatteryInfo.parse(infoRes ?? [:])
            let skeleton = BatteryInfo.parse(v2Res ?? [:])
            if let live = items.first, let frame = skeleton.first {
                items = [frame.merged(with: live)]
            } else if items.isEmpty {
                items = skeleton
            }

            if let id = items.first?.detailId, !id.isEmpty, !id.hasPrefix("battery-") {
                let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
                if let detail = try? await client.get("/v1.0/app/cfmotoserverapp/batteryInfo/detail/\(encoded)"),
                   let extra = BatteryInfo.parse(detail).first,
                   let base = items.first {
                    items = [base.merged(with: extra)]
                }
            }

            guard selectedVin == nil || WidgetSnapshot.sameVin(selectedVin, vin) else { return }
            items = chargeHeldItems(vin: vin, fresh: items)
            if let seat {
                if detailVehicle?.vinNo == vin {
                    detailVehicle = detailVehicle?.withSeat(seat)
                }
                if let index = vehicles.firstIndex(where: { WidgetSnapshot.sameVin($0.vinNo, vin) }) {
                    vehicles[index] = vehicles[index].withSeat(seat)
                }
            }
            if items.isEmpty, let vehicle = selectedVehicle, WidgetSnapshot.sameVin(vehicle.vinNo, vin) {
                items = [BatteryInfo.fallback(from: vehicle)]
            }
            batteries = items
            batteriesVin = vin
            if let battery = items.first, let current = selectedVehicle, WidgetSnapshot.sameVin(current.vinNo, vin) {
                let patched = current.withBattery(battery)
                if detailVehicle?.vinNo == vin {
                    detailVehicle = (detailVehicle ?? current).withBattery(battery)
                } else {
                    detailVehicle = patched
                }
                if let index = vehicles.firstIndex(where: { WidgetSnapshot.sameVin($0.vinNo, vin) }) {
                    vehicles[index] = vehicles[index].withBattery(battery)
                }
                WidgetSnapshot.publish(from: self)
            }
            if items.isEmpty {
                batteryError = "云端暂未返回电池数据"
                // 没有电池数据也要把刚到的坐垫状态推给小组件
                if seat != nil { WidgetSnapshot.publish(from: self) }
            }
        } catch let error as ZeehoError {
            batteryError = error.localizedDescription
        } catch is CancellationError {
            // 切车时上一个请求被取消，不是错误
        } catch let error as URLError where error.code == .cancelled {
            // 同上
        } catch {
            batteryError = error.localizedDescription
        }
    }

    func clearBattery() {
        batteries = []
        batteriesVin = nil
        batteryError = nil
        chargeHold = nil
    }

    /// 充电态防抖：新读数不是充电中、但上一份是，且没拔出电池——
    /// 45 秒宽限期内沿用上一份充电中数据，不让"充电中"在下拉刷新时闪丢。
    /// 新读数确实是充电中，或电池已拔出，立即清除防抖。
    private func chargeHeldItems(vin: String, fresh items: [BatteryInfo]) -> [BatteryInfo] {
        guard let current = items.first else { return items }
        if current.isLiveCharging || current.isPulledOut {
            chargeHold = nil
            return items
        }
        let previous = batteriesVin == vin ? batteries.first : nil
        guard let previous, previous.isLiveCharging, !previous.isPulledOut else { return items }
        // 只在第一次读到"充电中→未充电"跳变时装一次宽限期，过期后不重 arms，
        // 否则真实停充会被无限按住
        if chargeHold?.vin != vin {
            chargeHold = (vin, Date().addingTimeInterval(45))
        }
        guard let until = chargeHold?.until, until > Date() else {
            chargeHold = nil
            return items
        }
        return [previous]
    }

    // MARK: - Commands

    func toggleLock(_ vehicle: Vehicle) async throws {
        let unlocking = vehicle.isLocked
        let res = try await client.post(
            "/v1.0/app/cfmotoserverapp/vehicleSet/network/unlock",
            body: ["vinNo": vehicle.vinNo, "lockFlag": unlocking ? 1 : 0]
        )
        try ZeehoClient.requireOK(res, fallback: unlocking ? "开机失败" : "关机失败")
        applyOptimisticLock(vin: vehicle.vinNo, locked: !unlocking)
        let vin = vehicle.vinNo
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard selectedVin == nil || WidgetSnapshot.sameVin(selectedVin, vin) else { return }
            await loadDetail(vin: vin)
        }
    }

    private func applyOptimisticLock(vin: String, locked: Bool) {
        lockHold = (vin, locked, Date().addingTimeInterval(12))
        applyLock(vin: vin, locked: locked)
    }

    private func applyLockHold() {
        guard let hold = lockHold else { return }
        if hold.until < Date() {
            lockHold = nil
            return
        }
        applyLock(vin: hold.vin, locked: hold.locked)
    }

    private func applyLock(vin: String, locked: Bool) {
        if let index = vehicles.firstIndex(where: { WidgetSnapshot.sameVin($0.vinNo, vin) }) {
            vehicles[index] = vehicles[index].withLocked(locked)
        }
        if let detail = detailVehicle, WidgetSnapshot.sameVin(detail.vinNo, vin) {
            detailVehicle = detail.withLocked(locked)
        }
    }

    func findVehicle(_ vehicle: Vehicle) async throws {
        let res = try await client.put(
            "/v1.0/app/cfmotoserverapp/vehicleInfo/control/\(vehicle.vinNo)"
        )
        try ZeehoClient.requireOK(res, fallback: "寻车失败")
    }

    /// 高声寻车：鸣笛 + 闪灯（与 Flutter loudFindVehicle 一致）
    func loudFindVehicle(_ vehicle: Vehicle) async throws {
        let res = try await client.post(
            "/v1.0/app/cfmotoserverapp/vehicleInfo/controlV2",
            body: ["param": "4", "vin": vehicle.vinNo]
        )
        try ZeehoClient.requireOK(res, fallback: "寻车失败")
    }

    func openCushion(_ vehicle: Vehicle) async throws {
        let res = try await client.put(
            "/v1.0/app/cfmotoserverapp/vehicleSet/propertyTwo/one",
            body: [
                "commond": "28",
                "commondParam": "1",
                "vcu": vehicle.vinNo,
                "version": "v2",
            ]
        )
        try ZeehoClient.requireOK(res, fallback: "坐垫解锁失败")
    }

    private func seedWidgetSnap(for vin: String?) {
        guard let vin, let vehicle = vehicles.first(where: { WidgetSnapshot.sameVin($0.vinNo, vin) }) else { return }
        let previous = WidgetSnapshot.readVin(vin)
        let account = WidgetSnapshot.read()
        var snap = WidgetSnap()
        snap.loggedIn = true
        if let account {
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
        if let previous {
            snap.todayKm = previous.todayKm
            snap.todayMin = previous.todayMin
            snap.lastKm = previous.lastKm
            snap.lastMin = previous.lastMin
            snap.accel = previous.accel
            snap.brake = previous.brake
            snap.maxSpeed = previous.maxSpeed
            snap.tireText = previous.tireText
            snap.tireBound = previous.tireBound
        }
        snap.vin = vehicle.vinNo
        snap.name = vehicle.name
        snap.soc = vehicle.soc > 0 ? vehicle.soc : (previous?.soc ?? 0)
        snap.rangeKm = vehicle.rangeKm > 0 ? vehicle.rangeKm : (previous?.rangeKm ?? 0)
        snap.charging = vehicle.isCharging
        snap.locked = vehicle.isLocked
        snap.online = vehicle.isOnline
        if let seat = vehicle.seat {
            snap.seatClosed = seat.isClosed ? 1 : 0
            snap.seatAt = seat.sampledAt?.timeIntervalSince1970 ?? 0
        } else if let previous, previous.seatClosed == 0 || previous.seatClosed == 1 {
            snap.seatClosed = previous.seatClosed
            snap.seatAt = previous.seatAt
        }
        snap.imageURL = vehicle.imageURL?.absoluteString ?? previous?.imageURL ?? ""
        snap.imageData = nil
        persistVehicleImage(vehicle)
        snap.updatedAt = Date().timeIntervalSince1970
        WidgetSnapshot.write(snap)
    }

    private func persistVehicleImage(_ vehicle: Vehicle) {
        guard let url = vehicle.imageURL else { return }
        if let image = ResourceCache.cachedImage(url),
           let data = image.pngData() {
            WidgetSnapshot.saveImage(data, vin: vehicle.vinNo)
            return
        }
        if let file = ResourceCache.existingFile(for: url, folder: "images"),
           let data = try? Data(contentsOf: file), !data.isEmpty {
            WidgetSnapshot.saveImage(data, vin: vehicle.vinNo)
        }
    }

    // MARK: - Response helpers

    private static func accessToken(_ data: Any?) -> String? {
        guard let map = data as? [String: Any] else { return nil }
        if let info = map["tokenInfo"] as? [String: Any] {
            for key in ["access_token", "accessToken", "token"] {
                if let value = info[key] as? String, !value.isEmpty { return value }
            }
        }
        for key in ["token", "access_token", "accessToken"] {
            if let value = map[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func userId(from data: Any?) -> String? {
        guard let map = data as? [String: Any] else { return nil }
        for key in ["userId", "uid", "id", "user_id"] {
            if let value = map[key] {
                let text = "\(value)"
                if !text.isEmpty { return text }
            }
        }
        if let info = map["userInfo"] as? [String: Any] {
            return userId(from: info)
        }
        return nil
    }
}
