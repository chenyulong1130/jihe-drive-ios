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
    @State private var selecting = false
    @State private var picked: Set<String> = []
    @State private var replayBundle: RideReplayBundle?

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    monthChip
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    if !groups.isEmpty {
                        monthHero
                            .padding(.bottom, 8)
                    }

                    if model.selectedVehicle == nil {
                        Text("先在车辆页登录并选择一台车")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                            .padding(.top, 32)
                    } else if loading && groups.isEmpty {
                        RideListSkeleton()
                            .padding(.top, 4)
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
                .padding(.top, showsClose ? 10 : 8)
                .padding(.bottom, selecting ? 168 : 120)
            }
            .background(Theme.groupedBackground)
            .refreshable { await loadMonth() }

            if selecting {
                selectBar
            }
        }
        .task(id: "\(model.selectedVehicle?.vinNo ?? "")-\(monthKey)-\(shouldLoadRides)") {
            guard shouldLoadRides else { return }
            await loadMonth()
        }
        .fullScreenCover(item: $selected) { track in
            if let vehicle = model.selectedVehicle {
                RideReplayView(vehicle: vehicle, tracks: [track])
            }
        }
        .fullScreenCover(item: $replayBundle) { bundle in
            if let vehicle = model.selectedVehicle {
                RideReplayView(vehicle: vehicle, tracks: bundle.tracks)
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

            if !groups.isEmpty {
                Button {
                    withAnimation(Motion.quick) {
                        selecting.toggle()
                        if !selecting { picked.removeAll() }
                    }
                } label: {
                    Text(selecting ? "取消" : "多选")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                }
                .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
            }

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

    private var selectBar: some View {
        HStack(spacing: 12) {
            Text("已选 \(picked.count) 条")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.label)
            Spacer(minLength: 0)
            Button {
                let tracks = groups.flatMap(\.tracks).filter { picked.contains($0.id) }
                guard !tracks.isEmpty else { return }
                replayBundle = RideReplayBundle(tracks: tracks)
            } label: {
                Text(picked.count > 1 ? "合并回放" : "回放")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(picked.isEmpty ? Theme.tertiary : Theme.brand))
            }
            .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
            .disabled(picked.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .padding(.bottom, 8)
        .background(.regularMaterial)
        .shadow(color: Color.black.opacity(0.08), radius: 16, y: -4)
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

    private var monthHero: some View {
        let km = groups.reduce(0.0) { $0 + $1.totalKm }
        let days = groups.filter { !$0.tracks.isEmpty }.count
        let peak = groups.map(\.totalKm).max() ?? 0
        let avg = days > 0 ? km / Double(days) : 0
        return VStack(alignment: .leading, spacing: 12) {
            Text("本月里程")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatKm(km))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                Text("km")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 0) {
                monthStat("\(days)", "天", "骑行天数")
                monthStat(formatKm(avg), "km", "日均里程")
                monthStat(formatKm(peak), "km", "单日最长")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface)
        )
        .shadow(color: Theme.cardShadow, radius: 12, y: 3)
    }

    private func monthStat(_ value: String, _ unit: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Day

    private func daySection(_ group: RideDayGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Spacer(minLength: 8)
                Text("\(group.tracks.count)次 · \(formatKm(group.totalKm))km")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .monospacedDigit()
            }
            .padding(.top, 8)

            VStack(spacing: 0) {
                ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        if selecting {
                            if picked.contains(track.id) {
                                picked.remove(track.id)
                            } else {
                                picked.insert(track.id)
                            }
                        } else {
                            selected = track
                        }
                    } label: {
                        rideRow(track, checked: picked.contains(track.id))
                    }
                    .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
                    if index < group.tracks.count - 1 {
                        HairLine(inset: 12)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
            )
            .shadow(color: Theme.cardShadow, radius: 10, y: 2)
        }
        .padding(.bottom, 8)
    }

    private func rideRow(_ track: RideTrack, checked: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if selecting {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(checked ? Theme.brand : Theme.tertiary)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(timeRange(track))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                thumb(track)
                    .frame(width: 72, height: 72)
            }
            .frame(width: 86, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Spacer(minLength: 0)
                    Text(formatKm(track.mileage))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.brand)
                        .monospacedDigit()
                    Text("km")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    if !selecting {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.leading, 2)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    placeLine(title: "起点", text: startText(track), tint: Color(hex: 0x22C55E))
                    placeLine(title: "终点", text: endText(track), tint: Color(hex: 0xF97316))
                }

                HStack(spacing: 0) {
                    rideMetric(RideTrackService.durationText(track.durationMinutes), "耗时")
                    rideMetric(speedText(avgSpeed(track)), "均速")
                    rideMetric(speedText(peakSpeed(track)), "极速")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func placeLine(title: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.label)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rideMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .semibold))
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

    private func thumb(_ track: RideTrack) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: 0xF2F4F7))
            RouteThumbnail(points: track.points)
            if let url = track.thumbnailURL {
                CachedRemoteImage(url: url, contentMode: .fill)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        let tracksResult = await RideTrackService.monthTracks(vin: vehicle.vinNo, month: monthAnchor)
        let days = await daysTask ?? []
        if Task.isCancelled { return }

        var tracks = tracksResult ?? []
        let known = Set(tracks.compactMap(\.dayKey))
        let missing = days.filter { $0.mileage > 0 && !known.contains($0.date) }
        if !missing.isEmpty {
            let extra = await Self.tracksForDays(vin: vehicle.vinNo, days: missing)
            var seen = Set(tracks.map(\.id))
            for track in extra where seen.insert(track.id).inserted {
                tracks.append(track)
            }
        }
        if Task.isCancelled { return }
        if tracks.isEmpty {
            if days.contains(where: { $0.mileage > 0 }) {
                errorText = "行程明细加载失败，下拉刷新"
            }
            groups = []
            return
        }
        groups = Self.buildGroups(days: days, tracks: tracks)
    }

    private static func tracksForDays(vin: String, days: [RideTrackService.MonthDay]) async -> [RideTrack] {
        let ridden = days.filter { $0.mileage > 0 }.prefix(31)
        guard !ridden.isEmpty else { return [] }
        return await withTaskGroup(of: [RideTrack].self, returning: [RideTrack].self) { group in
            for day in ridden {
                guard let date = dotted.date(from: day.date) else { continue }
                group.addTask {
                    await RideTrackService.tracks(vin: vin, from: date, to: date, pageSize: 20) ?? []
                }
            }
            var collected: [RideTrack] = []
            for await batch in group {
                collected.append(contentsOf: batch)
            }
            return collected
        }
    }

    private static func buildGroups(days: [RideTrackService.MonthDay], tracks: [RideTrack]) -> [RideDayGroup] {
        let today = dotted.string(from: Date())
        var bucket: [String: [RideTrack]] = [:]
        for track in tracks {
            let key = track.dayKey ?? today
            bucket[key, default: []].append(track)
        }

        let keys = bucket.keys.sorted(by: >)
        return keys.compactMap { key in
            let list = (bucket[key] ?? []).sorted { ($0.startTime ?? "") > ($1.startTime ?? "") }
            guard !list.isEmpty else { return nil }
            let day = days.first(where: { $0.date == key })
            let km = day?.mileage ?? list.reduce(0) { $0 + $1.mileage }
            let minutes = day?.minutes ?? list.reduce(0) { $0 + $1.durationMinutes }
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

    private func startText(_ track: RideTrack) -> String {
        AmapGeocode.compact(track.startAddress, limit: 18) ?? "未记录起点"
    }

    private func endText(_ track: RideTrack) -> String {
        AmapGeocode.compact(track.endAddress, limit: 18) ?? "未记录终点"
    }

    private func avgSpeed(_ track: RideTrack) -> Double? {
        let hours = Double(track.durationMinutes) / 60.0
        if hours > 0.02, track.mileage > 0 {
            return track.mileage / hours
        }
        let samples = track.speedSamples.filter { $0 > 0.5 }
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    private func peakSpeed(_ track: RideTrack) -> Double? {
        if let max = track.maxSpeed, max > 0 { return max }
        if let peak = track.speedSamples.max(), peak > 0 { return peak }
        return nil
    }

    private func speedText(_ value: Double?) -> String {
        guard let value, value > 0 else { return "--" }
        return String(format: "%.0f km/h", value)
    }

    private func timeRange(_ track: RideTrack) -> String {
        let start = track.startTime ?? "--:--"
        if let end = track.endTime, !end.isEmpty, end != start {
            return "\(start)-\(end)"
        }
        return start
    }

    private func formatKm(_ km: Double) -> String {
        if km >= 100 { return String(format: "%.0f", km) }
        return String(format: "%.1f", km)
    }

    private static let dotted: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
}

private struct RideReplayBundle: Identifiable {
    let id: String
    let tracks: [RideTrack]

    init(tracks: [RideTrack]) {
        self.tracks = tracks
        self.id = tracks.map(\.id).joined(separator: "|")
    }
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
