import Combine
import Foundation

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
            guard oldValue != selectedVin else { return }
            // 换车后旧电池数据必须清掉，否则详情页会显示上一台车的电压温度
            batteries = []
            batteryError = nil
            tire = nil
            detailVehicle = nil
        }
    }
    @Published var errorMessage: String?

    private static let vinKey = "jihe.selected.vin"

    private let client: ZeehoClient

    init(client: ZeehoClient = .shared) {
        self.client = client
        self.isLoggedIn = client.isLoggedIn
        let saved = UserDefaults.standard.string(forKey: Self.vinKey)
        self.selectedVin = (saved?.isEmpty == false) ? saved : nil
    }

    var selectedVehicle: Vehicle? {
        let base: Vehicle?
        if let selectedVin, let hit = vehicles.first(where: { $0.vinNo == selectedVin }) {
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
            await loadBattery(vin: vin)
            await loadDetail(vin: vin)
            await loadTire(vin: vin)
        }
    }

    /// 胎压传感器接口，独立于车辆详情，失败不影响主流程
    func loadTire(vin: String) async {
        let reading = await TireService.fetch(vin: vin)
        guard selectedVin == nil || selectedVin == vin else { return }
        tire = reading
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
            guard selectedVin == nil || selectedVin == vin else { return }
            detailVehicle = parsed
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

    func loadBattery(vin: String) async {
        batteryLoading = true
        batteryError = nil
        defer { batteryLoading = false }

        do {
            var response = try await client.get("/v1.0/app/cfmotoserverapp/batteryInfo/\(vin)")
            var items = BatteryInfo.parse(response)

            // 老车型 batteryInfo 为空，退回首页接口取同一批字段
            if items.isEmpty {
                response = try await client.get("/v1.0/app/cfmotoserverapp/vehicleHomePage/\(vin)")
                items = BatteryInfo.parse(response)
            }

            // 请求期间用户可能已经切车，晚到的响应不能写进当前车辆
            guard selectedVin == nil || selectedVin == vin else { return }
            batteries = items
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
        _ = try await client.post(
            "/v1.0/app/cfmotoserverapp/vehicleSet/network/unlock",
            body: ["vinNo": vehicle.vinNo, "lockFlag": unlocking ? 1 : 0]
        )
        // 乐观翻转：列表/详情刷新前先改本地锁态，避免按钮卡住
        applyOptimisticLock(vin: vehicle.vinNo, locked: !unlocking)
        await loadVehicles()
        if let vin = selectedVin {
            await loadDetail(vin: vin)
        }
    }

    private func applyOptimisticLock(vin: String, locked: Bool) {
        if let index = vehicles.firstIndex(where: { $0.vinNo == vin }) {
            let old = vehicles[index]
            vehicles[index] = Vehicle(
                vinNo: old.vinNo,
                name: old.name,
                soc: old.soc,
                rangeKm: old.rangeKm,
                totalMileKm: old.totalMileKm,
                isOnline: old.isOnline,
                onlineKnown: old.onlineKnown,
                isLocked: locked,
                isCharging: old.isCharging,
                signalLevel: old.signalLevel,
                signalText: old.signalText,
                latitude: old.latitude,
                longitude: old.longitude,
                locationTime: old.locationTime,
                address: old.address,
                imageURL: old.imageURL,
                monthMileage: old.monthMileage,
                tireFrontKpa: old.tireFrontKpa,
                tireRearKpa: old.tireRearKpa,
                voltage: old.voltage,
                temperature: old.temperature,
                cycleCount: old.cycleCount,
                model3DURL: old.model3DURL,
                wallpaperOutlines: old.wallpaperOutlines
            )
        }
        if let detail = detailVehicle, detail.vinNo == vin {
            detailVehicle = Vehicle(
                vinNo: detail.vinNo,
                name: detail.name,
                soc: detail.soc,
                rangeKm: detail.rangeKm,
                totalMileKm: detail.totalMileKm,
                isOnline: detail.isOnline,
                onlineKnown: detail.onlineKnown,
                isLocked: locked,
                isCharging: detail.isCharging,
                signalLevel: detail.signalLevel,
                signalText: detail.signalText,
                latitude: detail.latitude,
                longitude: detail.longitude,
                locationTime: detail.locationTime,
                address: detail.address,
                imageURL: detail.imageURL,
                monthMileage: detail.monthMileage,
                tireFrontKpa: detail.tireFrontKpa,
                tireRearKpa: detail.tireRearKpa,
                voltage: detail.voltage,
                temperature: detail.temperature,
                cycleCount: detail.cycleCount,
                model3DURL: detail.model3DURL,
                wallpaperOutlines: detail.wallpaperOutlines
            )
        }
    }

    func findVehicle(_ vehicle: Vehicle) async throws {
        _ = try await client.put(
            "/v1.0/app/cfmotoserverapp/vehicleInfo/control/\(vehicle.vinNo)"
        )
    }

    /// 高声寻车：鸣笛 + 闪灯（与 Flutter loudFindVehicle 一致）
    func loudFindVehicle(_ vehicle: Vehicle) async throws {
        _ = try await client.post(
            "/v1.0/app/cfmotoserverapp/vehicleInfo/controlV2",
            body: ["param": "4", "vin": vehicle.vinNo]
        )
    }

    func openCushion(_ vehicle: Vehicle) async throws {
        _ = try await client.put(
            "/v1.0/app/cfmotoserverapp/vehicleSet/propertyTwo/one",
            body: [
                "commond": "28",
                "commondParam": "1",
                "vcu": vehicle.vinNo,
                "version": "v2",
            ]
        )
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
