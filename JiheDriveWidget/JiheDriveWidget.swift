import SwiftUI
import WidgetKit

struct WidgetEntry: TimelineEntry {
    let date: Date
    let loggedIn: Bool
    let name: String
    let soc: Int
    let rangeKm: Int
    let locked: Bool
    let online: Bool
    let charging: Bool
    let tireText: String
    let signedToday: Bool
    let continueDays: Int
    let lotteryLeft: Int
    let monthMile: String
    let totalMile: Double
}

struct SnapshotProvider: TimelineProvider {
    private let suite = "group.com.liruixin.jihedrive"

    func placeholder(in context: Context) -> WidgetEntry {
        sample
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(load() ?? sample)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let entry = load() ?? sample
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private var sample: WidgetEntry {
        WidgetEntry(
            date: Date(),
            loggedIn: true,
            name: "极核 AE8",
            soc: 72,
            rangeKm: 68,
            locked: true,
            online: true,
            charging: false,
            tireText: "前2.4 · 后2.5 bar",
            signedToday: true,
            continueDays: 12,
            lotteryLeft: 18,
            monthMile: "86.2",
            totalMile: 3204
        )
    }

    private func load() -> WidgetEntry? {
        let payload = readPayload()
        guard !payload.isEmpty else { return nil }
        let loggedIn = bool(payload["loggedIn"])
        let name = string(payload["name"])
        // 已登录且有车名，或至少有电量数据，都当有效快照
        guard loggedIn || !name.isEmpty || int(payload["soc"]) > 0 else { return nil }
        return WidgetEntry(
            date: Date(timeIntervalSince1970: double(payload["updatedAt"])),
            loggedIn: loggedIn || !name.isEmpty,
            name: name.isEmpty ? "我的车辆" : name,
            soc: int(payload["soc"]),
            rangeKm: int(payload["rangeKm"]),
            locked: bool(payload["locked"], fallback: true),
            online: bool(payload["online"]),
            charging: bool(payload["charging"]),
            tireText: string(payload["tireText"]),
            signedToday: bool(payload["signedToday"]),
            continueDays: int(payload["continueDays"]),
            lotteryLeft: int(payload["lotteryLeft"]),
            monthMile: {
                let text = string(payload["monthMile"])
                return text.isEmpty ? "--" : text
            }(),
            totalMile: double(payload["totalMile"])
        )
    }

    private func readPayload() -> [String: Any] {
        if let defaults = UserDefaults(suiteName: suite),
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
                "updatedAt": defaults.double(forKey: "updatedAt")
            ]
        }
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suite)?
            .appendingPathComponent("widget_snapshot.json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        return [:]
    }

    private func string(_ raw: Any?) -> String {
        guard let raw else { return "" }
        return "\(raw)"
    }

    private func int(_ raw: Any?) -> Int {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        return Int("\(raw ?? "")") ?? 0
    }

    private func double(_ raw: Any?) -> Double {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return Double("\(raw ?? "")") ?? 0
    }

    private func bool(_ raw: Any?, fallback: Bool = false) -> Bool {
        if let value = raw as? Bool { return value }
        if let value = raw as? Int { return value != 0 }
        let text = "\(raw ?? "")"
        return text == "1" || text.lowercased() == "true" ? true : fallback
    }
}

struct JiheDriveWidgetEntryView: View {
    var entry: WidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if !entry.loggedIn || entry.name.isEmpty {
            loggedOut
        } else {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
    }

    private var loggedOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("极核智行")
                .font(.system(size: 15, weight: .bold))
            Text("打开 App 登录并同步车辆")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .containerBackground(for: .widget) { widgetBackground }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.name)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(entry.signedToday ? "已签" : "未签")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(entry.signedToday ? Color(hex: 0x166534) : Color(hex: 0xB45309))
            }
            Text("\(entry.soc)%")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("续航 \(entry.rangeKm) km")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            progress
            Spacer(minLength: 0)
            Text(entry.locked ? "已关锁" : "未关锁")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(entry.locked ? Color(hex: 0x166534) : Color(hex: 0xB45309))
        }
        .padding(14)
        .containerBackground(for: .widget) { widgetBackground }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                pill(entry.signedToday ? "已签" : "未签",
                     bg: entry.signedToday ? Color(hex: 0xDCFCE7) : Color(hex: 0xFEF3C7),
                     fg: entry.signedToday ? Color(hex: 0x166534) : Color(hex: 0xB45309))
                Text(timeText)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0x94A3B8))
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(entry.soc)")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("%")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if entry.charging {
                            Text("充电中")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(hex: 0x166534))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(hex: 0xDCFCE7)))
                        }
                    }
                    Text("续航 \(entry.rangeKm) km")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    progress
                    HStack {
                        metric("本月", entry.monthMile)
                        metric("总里程", String(format: "%.0f", entry.totalMile))
                        metric("连签", "\(entry.continueDays)")
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Image(systemName: "bolt.car.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color(hex: 0x0E6B6B).opacity(0.85))
                    if !entry.tireText.isEmpty {
                        Text(entry.tireText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    Text(entry.locked ? "已关锁" : "未关锁")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(entry.locked ? Color(hex: 0x166534) : Color(hex: 0xB45309))
                }
            }
        }
        .padding(14)
        .containerBackground(for: .widget) { widgetBackground }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(entry.name)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                pill(entry.signedToday ? "已签" : "未签",
                     bg: entry.signedToday ? Color(hex: 0xDCFCE7) : Color(hex: 0xFEF3C7),
                     fg: entry.signedToday ? Color(hex: 0x166534) : Color(hex: 0xB45309))
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(entry.soc)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("续航 \(entry.rangeKm) km")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            progress

            HStack {
                bigMetric("本月", "\(entry.monthMile) km")
                bigMetric("总里程", String(format: "%.0f km", entry.totalMile))
                bigMetric("连签", "\(entry.continueDays) 天")
                bigMetric("盲盒", "\(entry.lotteryLeft) 天")
            }

            HStack {
                Text(entry.locked ? "已关锁" : "未关锁")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(entry.locked ? Color(hex: 0x166534) : Color(hex: 0xB45309))
                if !entry.tireText.isEmpty {
                    Text("· \(entry.tireText)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(entry.online ? "在线" : "离线")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("打开 App 可寻车 / 开关锁 / 签到")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .containerBackground(for: .widget) { widgetBackground }
    }

    private var progress: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0xE2E8F0))
                Capsule()
                    .fill(Color(hex: 0x22C55E))
                    .frame(width: max(4, geo.size.width * CGFloat(min(100, max(0, entry.soc))) / 100))
            }
        }
        .frame(height: 6)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(Color(hex: 0x94A3B8))
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bigMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.55))
        )
    }

    private func pill(_ text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
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
        .description("电量、续航、锁态与签到一览")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
