import Foundation
import ActivityKit

#if !WIDGET_EXTENSION
enum ChargeLiveActivityController {
    static func sync(vehicle: Vehicle, battery: BatteryInfo?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let liveBattery = battery.flatMap { $0.id.hasPrefix("vehicle-") ? nil : $0 }
        let charging = liveBattery?.isLiveCharging == true
        let soc = min(max(liveBattery?.level ?? 0, 0), 100)
        let range = liveBattery?.rangeKm ?? vehicle.rangeKm
        let eta = etaText(battery: charging ? liveBattery : nil, charging: charging)
        let batteryName = {
            let name = liveBattery?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "动力电池" : name
        }()
        let powerWatts = liveBattery?.power ?? {
            guard let amps = liveBattery?.current, let volts = liveBattery?.voltage, volts > 0 else { return nil }
            return abs(amps) * volts
        }()
        let state = ChargeActivityAttributes.ContentState(
            soc: soc,
            rangeKm: range,
            charging: charging,
            etaText: eta,
            vehicleName: vehicle.name,
            batteryName: batteryName,
            currentAmps: liveBattery?.current,
            powerWatts: powerWatts,
            updatedAt: Date()
        )
        let stale = Date().addingTimeInterval(45 * 60)
        let content = ActivityContent(state: state, staleDate: stale)

        let vin = vehicle.vinNo
        for leftover in Activity<ChargeActivityAttributes>.activities where leftover.attributes.vin != vin {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
        let existing = Activity<ChargeActivityAttributes>.activities.filter { $0.attributes.vin == vin }
        if charging {
            if let activity = existing.first {
                Task { await activity.update(content) }
            } else {
                let attributes = ChargeActivityAttributes(vin: vin)
                _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
            }
        } else {
            for activity in Activity<ChargeActivityAttributes>.activities {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
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
