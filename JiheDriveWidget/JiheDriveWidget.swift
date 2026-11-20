import SwiftUI
import WidgetKit
import UIKit

struct WidgetEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnap

    static func from(_ snap: WidgetSnap) -> WidgetEntry {
        let stamp = snap.updatedAt > 0 ? Date(timeIntervalSince1970: snap.updatedAt) : Date()
        return WidgetEntry(date: stamp, snap: snap)
    }
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        .from(sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        if context.isPreview {
            completion(.from(sample))
            return
        }
        if let snap = WidgetSnapshot.read(), snap.loggedIn || snap.soc > 0 || !snap.name.isEmpty {
            completion(.from(snap))
            return
        }
        completion(.from(WidgetSnapshot.read() ?? WidgetSnap()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        Task {
            let snap = await WidgetLiveSync.refresh()
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            completion(Timeline(entries: [.from(snap)], policy: .after(next)))
        }
    }

    /// 预览用，对齐 Scriptable 参考图
    private var sample: WidgetSnap {
        var snap = WidgetSnap()
        snap.loggedIn = true
        snap.name = "未绑定"
        snap.soc = 57
        snap.rangeKm = 62
        snap.charging = false
        snap.todayKm = 0
        snap.todayMin = 0
        snap.accel = 0
        snap.brake = 0
        snap.maxSpeed = 0
        snap.pointsTotal = 7102
        snap.pointsToday = 1
        snap.continueDays = 8
        snap.signedToday = false
        snap.communityDone = false
        snap.lotteryLeft = 22
        snap.lotteryText = "盲盒22天"
        snap.tireText = "2.0bar 6°C"
        snap.tireBound = true
        snap.updatedAt = Date().timeIntervalSince1970
        return snap
    }
}

struct JiheDriveWidgetEntryView: View {
    var entry: WidgetEntry
    @Environment(\.widgetFamily) private var family

    private var snap: WidgetSnap { entry.snap }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
        .containerBackground(for: .widget) { widgetBackground }
    }

    // MARK: - Medium（对齐 Scriptable 截图）

    private var medium: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("今日骑行")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: 0x0F172A))
                Text(todayRideLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x94A3B8))

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(snap.soc)%")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x0F172A))
                        .monospacedDigit()
                    Text("\(snap.rangeKm) km")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: 0x6B7280))
                }
                .padding(.top, 4)

                progress
                    .padding(.top, 2)

                Text(snap.charging ? "充电中" : "未充电")
                    .font(.system(size: 10))
                    .foregroundStyle(snap.charging ? Color(hex: 0x0369A1) : Color(hex: 0x94A3B8))
                    .padding(.top, 1)

                HStack(spacing: 0) {
                    behavior(snap.accel, "加速")
                    behavior(snap.brake, "急刹")
                    behavior(snap.maxSpeed, "极速")
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    pill(
                        snap.communityDone ? "社区已做" : "社区未做",
                        bg: snap.communityDone ? Color(hex: 0xDCFCE7) : Color(hex: 0xFFEDD5),
                        fg: snap.communityDone ? Color(hex: 0x166534) : Color(hex: 0xC2410C)
                    )
                    pill(
                        lotteryPillText,
                        bg: Color(hex: 0xFEF3C7),
                        fg: Color(hex: 0xB45309)
                    )
                    pill(
                        snap.signedToday ? "已签" : "未签",
                        bg: snap.signedToday ? Color(hex: 0xDCFCE7) : Color(hex: 0xFFEDD5),
                        fg: snap.signedToday ? Color(hex: 0x166534) : Color(hex: 0xEA580C)
                    )
                    Text(timeText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(hex: 0x94A3B8))
                        .monospacedDigit()
                }
                .minimumScaleFactor(0.75)

                HStack(spacing: 6) {
                    Text("积分 \(snap.pointsTotal)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: 0x0F172A))
                    Text("今日 +\(snap.pointsToday)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x10B981))
                    Text("连签 \(snap.continueDays) 天")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x3B82F6))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                vehicleImage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(alignment: .bottom) {
                    if !tireLabel.isEmpty {
                        Spacer(minLength: 0)
                        Text(tireLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hex: 0x64748B))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("今日骑行")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: 0x0F172A))
                Spacer(minLength: 0)
                Text(snap.signedToday ? "已签" : "未签")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(snap.signedToday ? Color(hex: 0x166534) : Color(hex: 0xEA580C))
            }
            Text(todayRideLine)
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0x94A3B8))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(snap.soc)%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("\(snap.rangeKm) km")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x6B7280))
            }
            progress
            Spacer(minLength: 0)
            HStack {
                Text(snap.communityDone ? "社区已做" : "社区未做")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(snap.communityDone ? Color(hex: 0x166534) : Color(hex: 0xC2410C))
                Spacer(minLength: 0)
                Text(lotteryPillText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xB45309))
            }
        }
        .padding(14)
    }

    // MARK: - Large

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Text("今日骑行")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(hex: 0x0F172A))
                    .lineLimit(1)
                Spacer(minLength: 0)
                pill(
                    snap.communityDone ? "社区已做" : "社区未做",
                    bg: snap.communityDone ? Color(hex: 0xDCFCE7) : Color(hex: 0xFFEDD5),
                    fg: snap.communityDone ? Color(hex: 0x166534) : Color(hex: 0xC2410C)
                )
                pill(
                    lotteryPillText,
                    bg: Color(hex: 0xFEF3C7),
                    fg: Color(hex: 0xB45309)
                )
                pill(
                    snap.signedToday ? "已签" : "未签",
                    bg: snap.signedToday ? Color(hex: 0xDCFCE7) : Color(hex: 0xFFEDD5),
                    fg: snap.signedToday ? Color(hex: 0x166534) : Color(hex: 0xEA580C)
                )
                Text(timeText)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0x94A3B8))
                    .monospacedDigit()
            }

            Text(todayRideLine)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0x0F172A))

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(snap.soc)%")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("\(snap.rangeKm) km")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0x6B7280))
                    }
                    progress
                    Text(snap.charging ? "充电中" : "未充电")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: 0x94A3B8))
                    HStack(spacing: 0) {
                        behavior(snap.accel, "加速")
                        behavior(snap.brake, "急刹")
                        behavior(snap.maxSpeed, "极速")
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("积分 \(snap.pointsTotal)")
                            .font(.system(size: 13, weight: .bold))
                        Text("今日 +\(snap.pointsToday)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x10B981))
                        Text("连签 \(snap.continueDays) 天")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x3B82F6))
                    }
                    vehicleImage
                        .frame(maxWidth: .infinity, maxHeight: 120)
                    if !tireLabel.isEmpty {
                        HStack {
                            Spacer()
                            Text(tireLabel)
                                .font(.system(size: 11))
                                .foregroundStyle(Color(hex: 0x64748B))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HStack {
                Text(snap.locked ? "已关锁" : "未关锁")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(snap.locked ? Color(hex: 0x166534) : Color(hex: 0xB45309))
                Spacer()
                Text(snap.online ? "在线" : "离线")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x94A3B8))
            }
        }
        .padding(16)
    }

    // MARK: - Pieces

    private var todayRideLine: String {
        if snap.todayKm > 0.01 || snap.todayMin > 0 {
            return String(format: "%.1f km · %@", snap.todayKm, durationLabel(snap.todayMin))
        }
        if snap.lastKm > 0.01 {
            return String(format: "最近 %.1f km · %@", snap.lastKm, durationLabel(snap.lastMin))
        }
        return "今日暂无骑行"
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)min"
        }
        return "\(minutes) min"
    }

    private var tireLabel: String {
        if snap.tireBound, !snap.tireText.isEmpty { return snap.tireText }
        return ""
    }

    private var lotteryPillText: String {
        if !snap.lotteryText.isEmpty { return snap.lotteryText }
        if snap.lotteryLeft == 0 { return "盲盒可领" }
        return "盲盒\(snap.lotteryLeft)天"
    }

    private var progress: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0xE5E7EB))
                Capsule()
                    .fill(Color(hex: 0x22C55E))
                    .frame(width: max(4, geo.size.width * CGFloat(min(100, max(0, snap.soc))) / 100))
            }
        }
        .frame(height: 7)
    }

    private func behavior(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0x0F172A))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0x94A3B8))
        }
        .frame(maxWidth: .infinity)
    }

    private var vehicleImage: some View {
        Group {
            if let data = snap.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "scooter")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Color(hex: 0x94A3B8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func pill(_ text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
            .lineLimit(1)
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let stamp = entry.date.timeIntervalSince1970 > 0 ? entry.date : Date()
        return formatter.string(from: stamp)
    }

    private var widgetBackground: some View {
        LinearGradient(
            colors: [Color(hex: 0xEAF2FF), Color.white],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

@main
struct JiheDriveWidgetBundle: WidgetBundle {
    var body: some Widget {
        JiheDriveHomeWidget()
    }
}

struct JiheDriveHomeWidget: Widget {
    let kind = "JiheDriveWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            JiheDriveWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("极核智行")
        .description("今日骑行、电量、积分、签到与社区")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
