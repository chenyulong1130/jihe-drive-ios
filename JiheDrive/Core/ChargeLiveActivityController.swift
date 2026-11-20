import Foundation
import ActivityKit

#if !WIDGET_EXTENSION
enum ChargeLiveActivityController {
    static func sync(vehicle: Vehicle, battery: BatteryInfo?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let charging = battery?.isCharging ?? vehicle.isCharging
        let soc = battery?.level ?? vehicle.soc
        let range = battery?.rangeKm ?? vehicle.rangeKm
        let eta = battery?.etaFullText
            ?? battery?.chargeTimeString
            ?? battery?.fullChargeText
            ?? (battery?.chargeMinutes).map { "约 \($0) 分钟" }
            ?? ""
        let state = ChargeActivityAttributes.ContentState(
            soc: min(max(soc, 0), 100),
            rangeKm: range,
            charging: charging,
            etaText: charging ? (eta.isEmpty ? "充电中" : eta) : "未充电",
            vehicleName: vehicle.name,
            updatedAt: Date()
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(45 * 60))

        let existing = Activity<ChargeActivityAttributes>.activities.filter { $0.attributes.vin == vehicle.vinNo }
        if charging {
            if let activity = existing.first {
                Task { await activity.update(content) }
            } else {
                let attributes = ChargeActivityAttributes(vin: vehicle.vinNo)
                _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
            }
        } else {
            for activity in existing {
                Task { await activity.end(content, dismissalPolicy: .immediate) }
            }
        }
    }
}
#endif
