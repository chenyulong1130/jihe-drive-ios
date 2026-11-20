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
                        Label(context.state.charging ? "充电中" : "待机", systemImage: "bolt.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.green)
                        Text(context.state.batteryName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
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
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("\(context.state.rangeKm) km")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                        if let amps = context.state.currentAmps {
                            Text(String(format: "%.1f A", abs(amps)))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.green.opacity(0.9))
                                .monospacedDigit()
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        chargingBar(progress: Double(context.state.soc) / 100)
                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                            Text(context.state.etaText)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let amps = context.state.currentAmps {
                                Text(String(format: "电流 %.1fA", abs(amps)))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .monospacedDigit()
                            }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.etaText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                    if let amps = state.currentAmps {
                        Text(String(format: "电流 %.1f A", abs(amps)))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.green.opacity(0.9))
                            .monospacedDigit()
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
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.green.opacity(0.75 + 0.2 * pulse), Color.green],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * CGFloat(min(max(progress, 0), 1))))
                }
            }
        }
        .frame(height: 7)
    }
}
