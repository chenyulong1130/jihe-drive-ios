import Foundation
import WidgetKit

/// 主 App → 小组件快照（App Group UserDefaults）
enum WidgetSnapshot {
    static let suiteName = "group.com.liruixin.jihedrive"
    static let kind = "JiheDriveWidget"

    @MainActor
    static func publish(from model: AppModel, signin: SigninStore) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        let vehicle = model.selectedVehicle

        defaults.set(ZeehoClient.shared.isLoggedIn, forKey: "loggedIn")
        defaults.set(vehicle?.name ?? "", forKey: "name")
        defaults.set(vehicle?.soc ?? 0, forKey: "soc")
        defaults.set(vehicle?.rangeKm ?? 0, forKey: "rangeKm")
        defaults.set(vehicle?.isLocked ?? true, forKey: "locked")
        defaults.set(vehicle?.isOnline ?? false, forKey: "online")
        defaults.set(vehicle?.isCharging ?? false, forKey: "charging")
        defaults.set(vehicle?.totalMileKm ?? 0, forKey: "totalMile")
        defaults.set(vehicle?.monthMileage ?? "--", forKey: "monthMile")
        defaults.set(vehicle?.imageURL?.absoluteString ?? "", forKey: "imageURL")

        if let tire = model.tire {
            let front = tire.frontBar.map { String(format: "%.1f", $0) } ?? "--"
            let rear = tire.rearBar.map { String(format: "%.1f", $0) } ?? "--"
            defaults.set("前\(front) · 后\(rear) bar", forKey: "tireText")
        } else {
            defaults.set("", forKey: "tireText")
        }

        defaults.set(signin.signedToday, forKey: "signedToday")
        defaults.set(signin.info?.continueDays ?? 0, forKey: "continueDays")
        defaults.set(signin.info?.daysUntilLottery ?? 0, forKey: "lotteryLeft")
        defaults.set(signin.totalSignCount ?? 0, forKey: "totalSignCount")
        defaults.set(Date().timeIntervalSince1970, forKey: "updatedAt")

        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}
