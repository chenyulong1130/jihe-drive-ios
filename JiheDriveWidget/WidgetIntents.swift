import AppIntents
import Foundation
import WidgetKit

/// 小组件远程指令：开关锁 / 坐垫 / 寻车（不打开 App）
enum WidgetVehicleActions {
    @discardableResult
    static func lock() async -> String {
        hydrate()
        guard let vin = currentVin() else { return "未选择车辆" }
        var snap = WidgetSnapshot.read() ?? WidgetSnap()
        let unlocking = snap.locked
        do {
            let res = try await ZeehoClient.shared.post(
                "/v1.0/app/cfmotoserverapp/vehicleSet/network/unlock",
                body: ["vinNo": vin, "lockFlag": unlocking ? 1 : 0]
            )
            try ZeehoClient.requireOK(res, fallback: unlocking ? "开锁失败" : "关锁失败")
            snap.locked = !unlocking
            snap.updatedAt = Date().timeIntervalSince1970
            WidgetSnapshot.write(snap)
            WidgetCenter.shared.reloadAllTimelines()
            return unlocking ? "开锁成功" : "关锁成功"
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    static func cushion() async -> String {
        hydrate()
        guard let vin = currentVin() else { return "未选择车辆" }
        do {
            let res = try await ZeehoClient.shared.put(
                "/v1.0/app/cfmotoserverapp/vehicleSet/propertyTwo/one",
                body: [
                    "commond": "28",
                    "commondParam": "1",
                    "vcu": vin,
                    "version": "v2"
                ]
            )
            try ZeehoClient.requireOK(res, fallback: "坐垫解锁失败")
            return "坐垫解锁成功"
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    static func find() async -> String {
        hydrate()
        guard let vin = currentVin() else { return "未选择车辆" }
        do {
            let res = try await ZeehoClient.shared.put(
                "/v1.0/app/cfmotoserverapp/vehicleInfo/control/\(vin)"
            )
            if (try? ZeehoClient.requireOK(res, fallback: "寻车失败")) == nil {
                let fallback = try await ZeehoClient.shared.post(
                    "/v1.0/app/cfmotoserverapp/vehicleInfo/controlV2",
                    body: ["param": "4", "vin": vin]
                )
                try ZeehoClient.requireOK(fallback, fallback: "寻车失败")
            }
            return "寻车指令已发送"
        } catch {
            return error.localizedDescription
        }
    }

    private static func currentVin() -> String? {
        if let vin = WidgetSnapshot.selectedVin(), !vin.isEmpty { return vin }
        if let vin = WidgetSnapshot.read()?.vin, !vin.isEmpty { return vin }
        return nil
    }

    private static func hydrate() {
        WidgetLiveSync.hydrateSession()
    }
}

struct WidgetLockIntent: AppIntent {
    static var title: LocalizedStringResource = "开关锁"
    static var description: IntentDescription = "远程开锁或关锁"
    static var openAppWhenRun = false
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await WidgetVehicleActions.lock()
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct WidgetCushionIntent: AppIntent {
    static var title: LocalizedStringResource = "打开坐垫"
    static var description: IntentDescription = "远程打开坐垫"
    static var openAppWhenRun = false
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await WidgetVehicleActions.cushion()
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct WidgetFindIntent: AppIntent {
    static var title: LocalizedStringResource = "寻车"
    static var description: IntentDescription = "鸣笛闪灯寻车"
    static var openAppWhenRun = false
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await WidgetVehicleActions.find()
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}
