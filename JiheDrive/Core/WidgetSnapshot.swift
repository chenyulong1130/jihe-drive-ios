import Foundation
import WidgetKit

/// 主 App → 小组件快照（App Group UserDefaults + 共享文件双写）
enum WidgetSnapshot {
    static let suiteName = "group.com.liruixin.jihedrive"
    static let kind = "JiheDriveWidget"
    private static let fileName = "widget_snapshot.json"

    @MainActor
    static func publish(from model: AppModel, signin: SigninStore? = nil) {
        let vehicle = model.selectedVehicle
        var payload: [String: Any] = [
            "loggedIn": ZeehoClient.shared.isLoggedIn,
            "name": vehicle?.name ?? "",
            "soc": vehicle?.soc ?? 0,
            "rangeKm": vehicle?.rangeKm ?? 0,
            "locked": vehicle?.isLocked ?? true,
            "online": vehicle?.isOnline ?? false,
            "charging": vehicle?.isCharging ?? false,
            "totalMile": vehicle?.totalMileKm ?? 0,
            "monthMile": vehicle?.monthMileage ?? "--",
            "imageURL": vehicle?.imageURL?.absoluteString ?? "",
            "updatedAt": Date().timeIntervalSince1970
        ]

        if let tire = model.tire {
            let front = tire.frontBar.map { String(format: "%.1f", $0) } ?? "--"
            let rear = tire.rearBar.map { String(format: "%.1f", $0) } ?? "--"
            payload["tireText"] = "前\(front) · 后\(rear) bar"
        } else {
            payload["tireText"] = ""
        }

        if let signin {
            payload["signedToday"] = signin.signedToday
            payload["continueDays"] = signin.info?.continueDays ?? 0
            payload["lotteryLeft"] = signin.info?.daysUntilLottery ?? 0
            payload["totalSignCount"] = signin.totalSignCount ?? 0
        }

        write(payload)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func read() -> [String: Any]? {
        if let defaults = UserDefaults(suiteName: suiteName),
           defaults.object(forKey: "updatedAt") != nil {
            return [
                "loggedIn": defaults.bool(forKey: "loggedIn"),
                "name": defaults.string(forKey: "name") ?? "",
                "soc": defaults.integer(forKey: "soc"),
                "rangeKm": defaults.integer(forKey: "rangeKm"),
                "locked": defaults.bool(forKey: "locked"),
                "online": defaults.bool(forKey: "online"),
                "charging": defaults.bool(forKey: "charging"),
                "totalMile": defaults.double(forKey: "totalMile"),
                "monthMile": defaults.string(forKey: "monthMile") ?? "--",
                "tireText": defaults.string(forKey: "tireText") ?? "",
                "signedToday": defaults.bool(forKey: "signedToday"),
                "continueDays": defaults.integer(forKey: "continueDays"),
                "lotteryLeft": defaults.integer(forKey: "lotteryLeft"),
                "totalSignCount": defaults.integer(forKey: "totalSignCount"),
                "updatedAt": defaults.double(forKey: "updatedAt")
            ]
        }
        if let url = snapshotURL(),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        return nil
    }

    private static func write(_ payload: [String: Any]) {
        if let defaults = UserDefaults(suiteName: suiteName) {
            for (key, value) in payload {
                defaults.set(value, forKey: key)
            }
            defaults.synchronize()
        }
        // 标准库也写一份，方便主 App 自检
        let standard = UserDefaults.standard
        for (key, value) in payload {
            standard.set(value, forKey: "widget_\(key)")
        }
        standard.synchronize()

        if let url = snapshotURL(),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private static func snapshotURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent(fileName)
    }
}
