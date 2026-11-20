import SwiftUI

/// 全部行程：按日分组列表，对齐官方「全部行程」页
struct RideHomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.activeMainTab) private var activeMainTab

    var showsClose: Bool = false

    @State private var monthAnchor = Date()
    @State private var groups: [RideDayGroup] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var selected: RideTrack?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                monthChip
                    .padding(.top, 8)
                    .padding(.bottom, 18)

                if model.selectedVehicle == nil {
                    Text("先在车辆页登录并选择一台车")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 32)
                } else if loading && groups.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else if let errorText, groups.isEmpty {
                    SoftBanner(text: errorText, icon: "exclamationmark.triangle.fill", tone: Theme.orange)
                        .padding(.top, 12)
                } else if groups.isEmpty {
                    Text("本月暂无骑行记录")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else {
                    ForEach(groups) { group in
                        daySection(group)
                    }
                }
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, showsClose ? 10 : 4)
            .padding(.bottom, 120)
        }
        .background(Theme.groupedBackground)
        .refreshable { await loadMonth() }
        .task(id: "\(model.selectedVehicle?.vinNo ?? "")-\(monthKey)-\(shouldLoadRides)") {
            guard shouldLoadRides else { return }
            await loadMonth()
        }
        .fullScreenCover(item: $selected) { track in
            if let vehicle = model.selectedVehicle {
                RideReplayView(vehicle: vehicle, track: track)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if showsClose {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
            }

            Text("全部行程")
                .font(.system(size: showsClose ? 18 : 28, weight: .semibold))
                .foregroundStyle(Theme.label)

            Spacer(minLength: 0)

            if showsClose {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.surfaceAlt))
                }
                .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
            }
        }
    }

    private var monthChip: some View {
        HStack(spacing: 10) {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))

            HStack(spacing: 6) {
                Text(monthTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.surface))
            .shadow(color: Theme.cardShadow, radius: 8, y: 2)

            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canGoNextMonth ? Theme.secondary : Theme.tertiary.opacity(0.35))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
            .disabled(!canGoNextMonth)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Day

    private func daySection(_ group: RideDayGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Spacer(minLength: 8)
                Text("\(formatKm(group.totalKm))km  \(durationLabel(group.totalMin))")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiary)
                    .monospacedDigit()
            }
            .padding(.top, 6)

            ForEach(group.tracks) { track in
                Button {
                    selected = track
                } label: {
                    rideCard(track)
                }
                .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
            }
        }
        .padding(.bottom, 10)
    }

    private func rideCard(_ track: RideTrack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(timeRange(track))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }

            HStack(alignment: .center, spacing: 14) {
                thumb(track)
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(formatKm(track.mileage))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.label)
                            .monospacedDigit()
                        Text("km")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                    }

                    HStack(spacing: 0) {
                        metric(socText(track), "耗电量")
                        metric("\(track.durationMinutes)min", "耗时")
                        metric(avgEnergyText(track), "平均能耗")
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
        )
        .shadow(color: Theme.cardShadow, radius: 14, y: 3)
    }

    private func thumb(_ track: RideTrack) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: 0xF2F4F7))
            RouteThumbnail(points: track.points)
            if let url = track.thumbnailURL {
                CachedRemoteImage(url: url, contentMode: .fill)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.label)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    /// 底栏切到骑行页，或从车辆页全屏打开行程列表时才拉月数据。
    private var shouldLoadRides: Bool {
        showsClose || activeMainTab == .ride
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/MM"
        return formatter.string(from: monthAnchor)
    }

    private var monthKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM"
        return formatter.string(from: monthAnchor)
    }

    private var canGoNextMonth: Bool {
        let cal = Calendar.current
        let now = Date()
        return cal.component(.year, from: monthAnchor) < cal.component(.year, from: now)
            || (cal.component(.year, from: monthAnchor) == cal.component(.year, from: now)
                && cal.component(.month, from: monthAnchor) < cal.component(.month, from: now))
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        if delta > 0, !canGoNextMonth { return }
        monthAnchor = next
    }

    private func loadMonth() async {
        guard let vehicle = model.selectedVehicle else { return }
        loading = true
        errorText = nil
        defer { loading = false }

        async let daysTask = RideTrackService.monthInfo(vin: vehicle.vinNo, month: monthAnchor)
        async let tracksTask = RideTrackService.monthTracks(vin: vehicle.vinNo, month: monthAnchor)
        let days = await daysTask
        let tracks = await tracksTask

        if Task.isCancelled { return }
        if tracks == nil, days == nil {
            errorText = "骑行数据加载失败"
            return
        }
        groups = Self.buildGroups(days: days ?? [], tracks: tracks ?? [])
    }

    private static func buildGroups(days: [RideTrackService.MonthDay], tracks: [RideTrack]) -> [RideDayGroup] {
        let today = dotted.string(from: Date())
        var bucket: [String: [RideTrack]] = [:]
        for track in tracks {
            let key = track.dayKey ?? today
            bucket[key, default: []].append(track)
        }
        for day in days where day.mileage > 0 && bucket[day.date] == nil {
            bucket[day.date] = []
        }

        let keys = bucket.keys.sorted(by: >)
        return keys.compactMap { key in
            let list = (bucket[key] ?? []).sorted { ($0.startTime ?? "") > ($1.startTime ?? "") }
            let day = days.first(where: { $0.date == key })
            let km = day?.mileage ?? list.reduce(0) { $0 + $1.mileage }
            let minutes = day?.minutes ?? list.reduce(0) { $0 + $1.durationMinutes }
            guard km > 0 || minutes > 0 || !list.isEmpty else { return nil }
            return RideDayGroup(
                id: key,
                title: dayTitle(key, today: today),
                totalKm: km,
                totalMin: minutes,
                tracks: list
            )
        }
    }

    private static func dayTitle(_ key: String, today: String) -> String {
        if key == today { return "今天" }
        let parts = key.split(separator: ".")
        guard parts.count >= 3, let month = Int(parts[1]), let day = Int(parts[2]) else {
            return key
        }
        return "\(month)月\(String(format: "%02d", day))日"
    }

    private func timeRange(_ track: RideTrack) -> String {
        let start = track.startTime ?? "--:--"
        if let end = track.endTime, !end.isEmpty, end != start {
            return "\(start)-\(end)"
        }
        return start
    }

    private func socText(_ track: RideTrack) -> String {
        if let soc = track.socUsed, soc > 0 {
            return String(format: soc >= 10 ? "%.0f%%" : "%.1f%%", soc)
        }
        return "--"
    }

    private func avgEnergyText(_ track: RideTrack) -> String {
        guard let soc = track.socUsed, soc > 0, track.mileage > 0.05 else { return "--" }
        return String(format: "%.1f%%/km", soc / track.mileage)
    }

    private func formatKm(_ km: Double) -> String {
        if km >= 100 { return String(format: "%.0f", km) }
        return String(format: "%.1f", km)
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes >= 60 {
            let hours = Double(minutes) / 60.0
            return String(format: hours >= 10 ? "%.0fh" : "%.1fh", hours)
        }
        return "\(minutes)min"
    }

    private static let dotted: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
}

private struct RideDayGroup: Identifiable {
    let id: String
    let title: String
    let totalKm: Double
    let totalMin: Int
    let tracks: [RideTrack]
}

/// 浅底轨迹缩略图：青点起点、红点终点
struct RouteThumbnail: View {
    let points: [Coordinate]

    var body: some View {
        Canvas { context, size in
            let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12)
            context.fill(bg, with: .color(Color(hex: 0xF3F5F8)))

            guard points.count > 1 else { return }
            let lats = points.map(\.latitude)
            let lngs = points.map(\.longitude)
            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLng = lngs.min(), let maxLng = lngs.max() else { return }

            let spanLat = max(0.000001, maxLat - minLat)
            let spanLng = max(0.000001, maxLng - minLng)
            let inset: CGFloat = 10
            let width = size.width - inset * 2
            let height = size.height - inset * 2

            func point(at coordinate: Coordinate) -> CGPoint {
                CGPoint(
                    x: inset + width * CGFloat((coordinate.longitude - minLng) / spanLng),
                    y: inset + height * CGFloat(1 - (coordinate.latitude - minLat) / spanLat)
                )
            }

            var path = Path()
            for (index, item) in points.enumerated() {
                let p = point(at: item)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            context.stroke(
                path,
                with: .color(Color(hex: 0x3B9BFF)),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            )

            if let first = points.first {
                let start = point(at: first)
                let dot = Path(ellipseIn: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8))
                context.fill(dot, with: .color(Color(hex: 0x2DD4BF)))
            }
            if let last = points.last {
                let end = point(at: last)
                let dot = Path(ellipseIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8))
                context.fill(dot, with: .color(Color(hex: 0xFF5A5A)))
            }
        }
    }
}
