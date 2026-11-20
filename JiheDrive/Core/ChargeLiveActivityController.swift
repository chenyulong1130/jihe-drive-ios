import Foundation
import ActivityKit

#if !WIDGET_EXTENSION
enum ChargeLiveActivityController {
    static func sync(vehicle: Vehicle, battery: BatteryInfo?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let charging = battery?.isCharging ?? vehicle.isCharging
        let soc = min(max(battery?.level ?? vehicle.soc, 0), 100)
        let range = battery?.rangeKm ?? vehicle.rangeKm
        let eta = etaText(battery: battery, charging: charging)
        let state = ChargeActivityAttributes.ContentState(
            soc: soc,
            rangeKm: range,
            charging: charging,
            etaText: eta,
            vehicleName: vehicle.name,
            updatedAt: Date()
        )
        let stale = Date().addingTimeInterval(45 * 60)
        let content = ActivityContent(state: state, staleDate: stale)

        let vin = vehicle.vinNo
        let existing = Activity<ChargeActivityAttributes>.activities.filter { $0.attributes.vin == vin }
        if charging {
            if let activity = existing.first {
                Task { await activity.update(content) }
            } else {
                let attributes = ChargeActivityAttributes(vin: vin)
                _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
            }
        } else {
            for activity in existing {
                Task { await activity.end(content, dismissalPolicy: .immediate) }
            }
        }
    }

    private static func etaText(battery: BatteryInfo?, charging: Bool) -> String {
        guard charging else { return "未充电" }
        if let text = battery?.etaFullText, !text.isEmpty { return text }
        if let text = battery?.chargeTimeString, !text.isEmpty { return text }
        if let text = battery?.fullChargeText, !text.isEmpty { return text }
        if let minutes = battery?.chargeMinutes {
            return "约 \(minutes) 分钟"
        }
        return "充电中"
    }
}
#endif
