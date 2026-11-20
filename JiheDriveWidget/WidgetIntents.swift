import AppIntents
import Foundation
import WidgetKit

/// 小组件远程指令：开关锁 / 坐垫 / 寻车（不打开 App）
enum WidgetVehicleActions {
    static func lock() async {
        hydrate()
        guard let vin = currentVin() else { return }
        var snap = WidgetSnapshot.read() ?? WidgetSnap()
        let unlocking = snap.locked
        guard let res = try? await ZeehoClient.shared.post(
            "/v1.0/app/cfmotoserverapp/vehicleSet/network/unlock",
            body: ["vinNo": vin, "lockFlag": unlocking ? 1 : 0]
        ), ok(res) else { return }
        snap.locked = !unlocking
        snap.updatedAt = Date().timeIntervalSince1970
        WidgetSnapshot.write(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func cushion() async {
        hydrate()
        guard let vin = currentVin() else { return }
        _ = try? await ZeehoClient.shared.put(
            "/v1.0/app/cfmotoserverapp/vehicleSet/propertyTwo/one",
            body: [
                "commond": "28",
                "commondParam": "1",
                "vcu": vin,
                "version": "v2"
            ]
        )
    }

    static func find() async {
        hydrate()
        guard let vin = currentVin() else { return }
        if let res = try? await ZeehoClient.shared.put(
            "/v1.0/app/cfmotoserverapp/vehicleInfo/control/\(vin)"
        ), ok(res) {
            return
        }
        _ = try? await ZeehoClient.shared.post(
            "/v1.0/app/cfmotoserverapp/vehicleInfo/controlV2",
            body: ["param": "4", "vin": vin]
        )
    }

    private static func currentVin() -> String? {
        if let vin = WidgetSnapshot.selectedVin(), !vin.isEmpty { return vin }
        if let vin = WidgetSnapshot.read()?.vin, !vin.isEmpty { return vin }
        return nil
    }

    private static func hydrate() {
        WidgetLiveSync.hydrateSession()
    }

    private static func ok(_ res: [String: Any]) -> Bool {
        let code = "\(res["code"] ?? "")"
        return code == "10000" || code == "0"
    }
}

struct WidgetLockIntent: AppIntent {
    static var title: LocalizedStringResource = "开关锁"
    static var description: IntentDescription = "远程开锁或关锁"
    static var openAppWhenRun = false
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await WidgetVehicleActions.lock()
        return .result()
    }
}

struct WidgetCushionIntent: AppIntent {
    static var title: LocalizedStringResource = "打开坐垫"
    static var description: IntentDescription = "远程打开坐垫"
    static var openAppWhenRun = false
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await WidgetVehicleActions.cushion()
        return .result()
    }
}

struct WidgetFindIntent: AppIntent {
    static var title: LocalizedStringResource = "寻车"
    static var description: IntentDescription = "鸣笛闪灯寻车"
    static var openAppWhenRun = false
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await WidgetVehicleActions.find()
        return .result()
    }
}
