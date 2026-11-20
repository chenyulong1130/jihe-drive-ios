import ActivityKit
import SwiftUI
import WidgetKit

struct ChargeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeActivityAttributes.self) { context in
            lockBanner(context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("充电中", systemImage: "bolt.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.green)
                        Text(context.state.vehicleName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(context.state.soc)%")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("\(context.state.rangeKm) km")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        chargingBar(progress: Double(context.state.soc) / 100)
                        HStack {
                            Text(context.state.etaText)
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("模拟充电")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(state.charging ? "车辆充电中" : "充电结束", systemImage: "bolt.car.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                Spacer()
                Text(state.vehicleName)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(state.soc)%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(state.etaText)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("\(state.rangeKm) km")
                    .font(.system(size: 15, weight: .semibold))
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
