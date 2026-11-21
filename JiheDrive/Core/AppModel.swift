import Combine
import Foundation
import UIKit
import WidgetKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var vehicles: [Vehicle] = []
    @Published private(set) var batteries: [BatteryInfo] = []
    @Published private(set) var batteryLoading = false
    @Published var batteryError: String?
    @Published private(set) var tire: TireReading?
    @Published private(set) var loading = false
    @Published private(set) var detailVehicle: Vehicle?
    @Published var selectedVin: String? {
        didSet {
            UserDefaults.standard.set(selectedVin, forKey: Self.vinKey)
            WidgetSnapshot.persistSelectedVin(selectedVin)
            guard oldValue != selectedVin else { return }
            seedWidgetSnap(for: selectedVin)
            // 换车后旧电池数据必须清掉，否则详情页会显示上一台车的电压温度
            batteries = []
            batteryError = nil
            tire = nil
            detailVehicle = nil
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    @Published var errorMessage: String?

    /// 开关机刚发出时云端锁态会滞后，这段时间内别用列表/详情把乐观状态盖回去
    private var lockHold: (vin: String, locked: Bool, until: Date)?

    private static let vinKey = "jihe.selected.vin"

    private let client: ZeehoClient

    init(client: ZeehoClient = .shared) {
        self.client = client
        self.isLoggedIn = client.isLoggedIn
        let saved = UserDefaults.standard.string(forKey: Self.vinKey)
        self.selectedVin = (saved?.isEmpty == false) ? saved : nil
        WidgetSnapshot.persistSelectedVin(self.selectedVin)
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
            if items.isEmpty, let vehicle = selectedVehicle, WidgetSnapshot.sameVin(vehicle.vinNo, vin) {
                items = [BatteryInfo.fallback(from: vehicle)]
            }
            batteries = items
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
        batteryError = nil
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
        var snap = WidgetSnapshot.read() ?? WidgetSnap()
        if !WidgetSnapshot.sameVin(snap.vin, vehicle.vinNo) {
            snap.todayKm = 0
            snap.todayMin = 0
            snap.lastKm = 0
            snap.lastMin = 0
            snap.accel = 0
            snap.brake = 0
            snap.maxSpeed = 0
            snap.tireText = ""
            snap.tireBound = false
        }
        snap.vin = vehicle.vinNo
        snap.name = vehicle.name
        if vehicle.soc > 0 { snap.soc = vehicle.soc }
        if vehicle.rangeKm > 0 { snap.rangeKm = vehicle.rangeKm }
        snap.charging = vehicle.isCharging
        snap.locked = vehicle.isLocked
        snap.online = vehicle.isOnline
        snap.imageURL = vehicle.imageURL?.absoluteString ?? snap.imageURL
        snap.imageData = nil
        persistVehicleImage(vehicle)
        snap.updatedAt = Date().timeIntervalSince1970
        WidgetSnapshot.write(snap)
    }

    private func persistVehicleImage(_ vehicle: Vehicle) {
        if WidgetSnapshot.loadImage(vehicle.vinNo) != nil { return }
        guard let url = vehicle.imageURL else { return }
        if let image = ResourceCache.cachedImage(url),
           let data = image.jpegData(compressionQuality: 0.86) {
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
