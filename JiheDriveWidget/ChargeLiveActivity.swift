import ActivityKit
import SwiftUI
import WidgetKit

struct ChargeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeActivityAttributes.self) { context in
            lockBanner(context.state)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("充电中", systemImage: "bolt.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.green)
                        Text(context.state.vehicleName)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(context.state.soc)%")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(context.state.etaText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green.opacity(0.9))
                            .lineLimit(1)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        chargingBar(progress: Double(context.state.soc) / 100)
                        HStack(spacing: 14) {
                            if let text = powerText(context.state.powerWatts) {
                                stat("功率", text)
                            }
                            if let amps = context.state.currentAmps {
                                stat("电流", String(format: "%.1f A", abs(amps)))
                            }
                            Spacer(minLength: 8)
                            Text("\(context.state.rangeKm) km")
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.green)
            } compactTrailing: {
                Text("\(context.state.soc)%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.green)
            } minimal: {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.green.opacity(0.92))
        }
    }

    private func powerText(_ watts: Double?) -> String? {
        guard let w = watts, w > 0 else { return nil }
        return w >= 1000 ? String(format: "%.2f kW", w / 1000) : String(format: "%.0f W", w)
    }

    private func lockBanner(_ state: ChargeActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(state.charging ? "车辆充电中" : "充电结束", systemImage: "bolt.car.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.batteryName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text(state.vehicleName)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(state.soc)%")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.etaText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        if let text = powerText(state.powerWatts) {
                            Text(text)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.green.opacity(0.9))
                                .monospacedDigit()
                        }
                        if let amps = state.currentAmps {
                            Text(String(format: "电流 %.1f A", abs(amps)))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.green.opacity(0.9))
                                .monospacedDigit()
                        }
                    }
                }
                Spacer(minLength: 8)
                Text("\(state.rangeKm) km")
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
            }

            chargingBar(progress: Double(state.soc) / 100)
        }
        .foregroundStyle(.white)
    }

    private func chargingBar(progress: Double) -> some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 0.8)) { timeline in
                let pulse = abs(sin(timeline.date.timeIntervalSince1970 * 2.2))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    if progress > 0 {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.green.opacity(0.75 + 0.2 * pulse), Color.green],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)))
                    }
                }
            }
        }
        .frame(height: 7)
    }
}
