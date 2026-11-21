import AppIntents
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
        completion(.from(matchingSelected(WidgetSnapshot.read() ?? WidgetSnap())))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let disk = matchingSelected(WidgetSnapshot.read() ?? WidgetSnap())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [.from(disk)], policy: .after(next)))
        Task {
            _ = await WidgetLiveSync.refresh()
        }
    }

    private func matchingSelected(_ snap: WidgetSnap) -> WidgetSnap {
        var copy = snap
        copy.imageData = nil
        guard let wanted = WidgetSnapshot.selectedVin(), !wanted.isEmpty else { return copy }
        if copy.vin.isEmpty {
            copy.vin = wanted
        }
        return copy
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

    // MARK: - Medium：对齐参考图，左骑行电量行为，右积分车图胎压

    private var medium: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("今日骑行")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(hex: 0x0F172A))
                    Text("\(fmtKm(snap.todayKm)) km · \(snap.todayMin) min")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(hex: 0x94A3B8))
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                pointsCorner
            }

            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(snap.soc)%")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color(hex: 0x0F172A))
                            .monospacedDigit()
                        Text("\(snap.rangeKm) km")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(hex: 0x64748B))
                            .monospacedDigit()
                    }
                    progress
                        .frame(maxWidth: 128)
                    Text(snap.charging ? "充电中" : "未充电")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(hex: 0x94A3B8))
                    Spacer(minLength: 4)
                    controlBar
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 4) {
                    vehicleImage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !tireLabel.isEmpty {
                        Text(tireLabel)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(hex: 0x94A3B8))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(width: 168)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerRow(titleSize: 12, compact: true)
            Text(todayRideLine)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(hex: 0x6B7280))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(snap.soc)")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x9AA4B2))
                Text("\(snap.rangeKm) km")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x6B7280))
            }
            progress
            controlBar
                .padding(.top, 6)
            Spacer(minLength: 0)
            HStack {
                Text(snap.pointsTotal > 0 ? "\(snap.pointsTotal) 分" : "-- 分")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x0F172A))
                Spacer(minLength: 0)
                Text(lotteryPillText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xB45309))
            }
        }
        .padding(12)
    }

    // MARK: - Large

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow(titleSize: 15)

            HStack(alignment: .firstTextBaseline) {
                Text(todayRideLine)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x0F172A))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                pointsInline
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(snap.soc)")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text("%")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x9AA4B2))
                        Text("\(snap.rangeKm) km")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0x6B7280))
                    }
                    progress
                    Text(snap.charging ? "充电中" : "未充电")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: 0x94A3B8))
                    controlBar
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 4) {
                    vehicleImage
                        .frame(maxWidth: .infinity, maxHeight: 120)
                    if !tireLabel.isEmpty {
                        Text("胎压 \(tireLabel)")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hex: 0x9AA4B2))
                    }
                }
                .frame(width: 168)
            }
            .frame(maxHeight: .infinity)

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
        if snap.todayKm > 0.01 || snap.todayMin > 0 || snap.maxSpeed > 0 {
            return "今日骑行 \(todayRideData)"
        }
        return "今日暂无骑行"
    }

    private var todayRideData: String {
        if snap.todayKm > 0.01 || snap.todayMin > 0 || snap.maxSpeed > 0 {
            return "\(fmtKm(snap.todayKm)) km · \(durationLabel(snap.todayMin)) · \(snap.maxSpeed) km/h"
        }
        return "暂无骑行"
    }

    private func fmtKm(_ value: Double) -> String {
        if value >= 100 { return String(Int(value.rounded())) }
        return String(format: "%.1f", value)
    }

    /// 右上角两行：社区/签到/时间，下面积分数据
    private var pointsCorner: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 5) {
                pill(
                    snap.communityDone ? "社区已做" : "社区未做",
                    bg: snap.communityDone ? Color(hex: 0xDCFCE7) : Color(hex: 0xFFEDD5),
                    fg: snap.communityDone ? Color(hex: 0x166534) : Color(hex: 0xC2410C)
                )
                signPill
                Text(timeText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(hex: 0x94A3B8))
                    .monospacedDigit()
            }
            HStack(spacing: 0) {
                Text("积分 \(snap.pointsTotal > 0 ? "\(snap.pointsTotal)" : "--")")
                    .foregroundStyle(Color(hex: 0x0F172A))
                Text("  今日 +\(snap.pointsToday)")
                    .foregroundStyle(Color(hex: 0x22C55E))
                Text("  连签 \(snap.continueDays) 天")
                    .foregroundStyle(Color(hex: 0x3B82F6))
            }
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
    }

    private var signPill: some View {
        Text(snap.signedToday ? "已签" : "未签")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(snap.signedToday ? Color(hex: 0x166534) : Color(hex: 0xE11D48))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(snap.signedToday ? Color(hex: 0xDCFCE7) : Color(hex: 0xFFE4E6))
            )
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
        }
        return "\(minutes) min"
    }

    private func headerRow(titleSize: CGFloat, compact: Bool = false) -> some View {
        HStack(spacing: compact ? 4 : 5) {
            Text("极核")
                .font(.system(size: titleSize, weight: .heavy))
                .foregroundStyle(Color(hex: 0x0F172A))
            Spacer(minLength: 0)
            if !compact {
                pill(
                    snap.communityDone ? "社区已做" : "社区未做",
                    bg: snap.communityDone ? Color(hex: 0xDCFCE7) : Color(hex: 0xFFEDD5),
                    fg: snap.communityDone ? Color(hex: 0x166534) : Color(hex: 0xC2410C)
                )
            }
            pill(
                lotteryPillText,
                bg: Color(hex: 0xFEF3C7),
                fg: Color(hex: 0xB45309)
            )
            pill(
                snap.signedToday ? "已签" : "未签",
                bg: snap.signedToday ? Color(hex: 0xDCFCE7) : Color(hex: 0xFEE2E2),
                fg: snap.signedToday ? Color(hex: 0x166534) : Color(hex: 0x991B1B)
            )
            if !compact {
                Text(timeText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(hex: 0x9AA4B2))
                    .monospacedDigit()
            }
        }
        .minimumScaleFactor(0.75)
    }

    private var pointsInline: some View {
        HStack(spacing: 0) {
            Text("总积分 \(snap.pointsTotal > 0 ? "\(snap.pointsTotal)" : "--")")
                .foregroundStyle(Color(hex: 0x0F172A))
            Text(" · 今日 +\(snap.pointsToday)")
                .foregroundStyle(Color(hex: 0x10B981))
            Text(" · 连签 \(snap.continueDays)天")
                .foregroundStyle(Color(hex: 0x3B82F6))
        }
        .font(.system(size: 9, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var tireLabel: String {
        if snap.tireBound, !snap.tireText.isEmpty { return snap.tireText }
        return ""
    }

    private var lotteryPillText: String {
        if snap.lotteryLeft == 0 || snap.lotteryClaimed {
            if snap.lotteryText.contains("盲盒") { return snap.lotteryText }
            return snap.lotteryClaimed ? "盲盒已领" : "盲盒可抽"
        }
        if !snap.lotteryText.isEmpty { return snap.lotteryText }
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

    private var controlBar: some View {
        HStack(spacing: 8) {
            controlButton(
                intent: WidgetLockIntent(),
                symbol: snap.locked ? "lock.open.fill" : "lock.fill",
                tint: snap.locked ? Color(hex: 0x16A34A) : Color(hex: 0xEA580C),
                label: snap.locked ? "开机" : "关机"
            )
            controlButton(
                intent: WidgetCushionIntent(),
                symbol: "rectangle.portrait.bottomhalf.filled",
                tint: Color(hex: 0x475569),
                label: "坐垫"
            )
            controlButton(
                intent: WidgetFindIntent(),
                symbol: "speaker.wave.2.fill",
                tint: Color(hex: 0x2563EB),
                label: "寻车"
            )
        }
    }

    private func controlButton<I: AppIntent>(
        intent: I,
        symbol: String,
        tint: Color,
        label: String
    ) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.95)))
                .overlay(Circle().strokeBorder(Color(hex: 0xE2E8F0), lineWidth: 0.8))
                .contentShape(Circle())
                .accessibilityLabel(label)
        }
        .buttonStyle(.plain)
    }

    private var vehicleImage: some View {
        Group {
            if let image = WidgetSnapshot.displayImage(vin: snap.vin) {
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
        ChargeLiveActivity()
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
