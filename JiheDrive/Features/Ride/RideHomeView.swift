import SwiftUI

/// 骑行数据：对齐 Flutter RideMileagePage / 小程序 ride.vue
/// 月度柱状图（rideMonthInfo）→ 选中日汇总 + 按次行程（ridetrack_v2）
struct RideHomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// 从车辆页以弹层方式打开时显示关闭按钮
    var showsClose: Bool = false

    @State private var monthAnchor = Date()
    @State private var monthDays: [RideTrackService.MonthDay] = []
    @State private var selectedIndex = 0
    @State private var daySummary: RideTrackService.DaySummary?
    @State private var tracks: [RideTrack] = []
    @State private var loadingMonth = false
    @State private var loadingDay = false
    @State private var errorText: String?
    @State private var selected: RideTrack?

    private var selectedDay: RideTrackService.MonthDay? {
        guard monthDays.indices.contains(selectedIndex) else { return nil }
        return monthDays[selectedIndex]
    }

    private var monthMileage: Double {
        monthDays.reduce(0) { $0 + $1.mileage }
    }

    private var activeDayCount: Int {
        monthDays.filter { $0.mileage > 0 }.count
    }

    private var maxBar: Double {
        max(monthDays.map(\.mileage).max() ?? 1, 1)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                header

                if model.selectedVehicle != nil {
                    summaryCard
                    monthChartCard
                    daySection
                } else {
                    Text("先在车辆页登录并选择一台车")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, showsClose ? 10 : 4)
            .padding(.bottom, 120)
        }
        .background(Theme.groupedBackground)
        .refreshable { await loadMonth() }
        .task(id: model.selectedVehicle?.vinNo) { await loadMonth() }
        .fullScreenCover(item: $selected) { track in
            if let vehicle = model.selectedVehicle {
                RideReplayView(vehicle: vehicle, track: track)
            }
        }
    }

    private var header: some View {
        Group {
            if showsClose {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("骑行数据")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.label)
                        Text(model.selectedVehicle?.name ?? "尚未选择车辆")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
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
                .padding(.bottom, 6)
            } else {
                LargeTitle("骑行", subtitle: model.selectedVehicle?.name ?? "尚未选择车辆")
            }
        }
    }

    // MARK: - 概览

    private var summaryCard: some View {
        AppleCard {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                    Text("里程概览")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    Text(monthTitle)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiary)
                }

                HStack(spacing: 10) {
                    MetricChip(
                        title: "本月",
                        value: model.selectedVehicle?.monthMileage
                            ?? (monthDays.isEmpty ? "--" : String(format: "%.1f", monthMileage)),
                        unit: "km",
                        icon: "calendar"
                    )
                    MetricChip(
                        title: "有效骑行",
                        value: "\(activeDayCount)",
                        unit: "天",
                        icon: "figure.outdoor.cycle"
                    )
                    MetricChip(
                        title: "总里程",
                        value: String(format: "%.0f", model.selectedVehicle?.totalMileKm ?? 0),
                        unit: "km",
                        icon: "speedometer"
                    )
                }
            }
        }
    }

    // MARK: - 月柱图

    private var monthChartCard: some View {
        AppleCard {
            VStack(spacing: 12) {
                HStack {
                    Button {
                        shiftMonth(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.label)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.surfaceAlt))
                    }
                    .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))

                    Spacer()
                    VStack(spacing: 2) {
                        Text(monthTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.label)
                        Text(loadingMonth ? "加载中…" : "\(monthDays.count) 天记录")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                    }
                    Spacer()

                    Button {
                        shiftMonth(1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(canGoNextMonth ? Theme.label : Theme.tertiary.opacity(0.4))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.surfaceAlt))
                    }
                    .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
                    .disabled(!canGoNextMonth)
                }

                if let errorText {
                    SoftBanner(text: errorText, icon: "exclamationmark.triangle.fill", tone: Theme.orange)
                }

                if loadingMonth && monthDays.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                } else if monthDays.isEmpty {
                    Text("本月暂无骑行数据")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .bottom, spacing: 6) {
                                ForEach(Array(monthDays.enumerated()), id: \.element.id) { index, day in
                                    dayBar(day, index: index)
                                        .id(index)
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.top, 8)
                            .frame(minHeight: 188, alignment: .bottom)
                        }
                        .onChange(of: selectedIndex) { _, idx in
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                        .onAppear {
                            proxy.scrollTo(selectedIndex, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(.top, 10)
    }

    private func dayBar(_ day: RideTrackService.MonthDay, index: Int) -> some View {
        let selected = index == selectedIndex
        let ratio = CGFloat(day.mileage / maxBar)
        let height = max(6, 128 * ratio)
        let hasRide = day.mileage > 0

        return Button {
            guard selectedIndex != index else { return }
            selectedIndex = index
            Task { await loadSelectedDay() }
        } label: {
            VStack(spacing: 6) {
                Text(hasRide ? String(format: "%.0f", day.mileage) : " ")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(selected ? Theme.brand : Theme.tertiary)
                    .monospacedDigit()
                    .frame(height: 12)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Theme.brand : (hasRide ? Theme.brand.opacity(0.45) : Theme.surfaceAlt))
                    .frame(width: 18, height: height)

                Text(dayLabel(day.date))
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.label : Theme.tertiary)
            }
            .frame(width: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 选中日

    private var daySection: some View {
        VStack(spacing: 10) {
            SectionHeader(selectedDay.map { "\($0.date) 行程" } ?? "当日行程")

            if let day = selectedDay, day.mileage > 0 || (daySummary?.mileage ?? 0) > 0 {
                daySummaryCard
            }

            if loadingDay && tracks.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("正在读取当日行程")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if tracks.isEmpty {
                Text((selectedDay?.mileage ?? 0) > 0 ? "当日暂无按次轨迹，可看上方汇总" : "选中有骑行的日期查看行程")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(tracks) { track in
                    Button {
                        selected = track
                    } label: {
                        trackRow(track)
                    }
                    .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
                }
            }
        }
        .padding(.top, 8)
    }

    private var daySummaryCard: some View {
        let mile = daySummary?.mileage ?? selectedDay?.mileage ?? 0
        let mins = daySummary?.minutes ?? selectedDay?.minutes ?? 0
        let speed = daySummary?.maxSpeed ?? 0
        let accel = daySummary?.accelTimes ?? 0
        let brake = daySummary?.brakeTimes ?? 0
        let bend = daySummary?.bendTimes ?? 0

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                MetricChip(title: "里程", value: String(format: "%.1f", mile), unit: "km", icon: "road.lanes")
                MetricChip(title: "时长", value: "\(mins)", unit: "min", icon: "clock")
                MetricChip(
                    title: "极速",
                    value: speed > 0 ? String(format: "%.0f", speed) : "--",
                    unit: "km/h",
                    icon: "speedometer"
                )
            }
            HStack(spacing: 10) {
                MetricChip(title: "急加速", value: accel > 0 ? "\(accel)" : "--", unit: "次", icon: "arrow.up.right")
                MetricChip(title: "急刹车", value: brake > 0 ? "\(brake)" : "--", unit: "次", icon: "arrow.down.right")
                MetricChip(title: "弯道", value: bend > 0 ? "\(bend)" : "--", unit: "次", icon: "arrow.turn.up.right")
            }
        }
    }

    private func trackRow(_ track: RideTrack) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RouteThumbnail(points: track.points)
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(track.startTime ?? "未命名行程")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)

                if let from = track.startAddress, !from.isEmpty {
                    Text(from)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let to = track.endAddress, !to.isEmpty {
                        Text(to)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 12) {
                    label(icon: "point.topleft.down.curvedto.point.bottomright.up", text: String(format: "%.1f km", track.mileage))
                    label(icon: "clock", text: "\(track.durationMinutes) 分钟")
                    if let speed = track.maxSpeed, speed > 0 {
                        label(icon: "speedometer", text: String(format: "%.0f km/h", speed))
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "play.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.brand)
                .padding(.top, 4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.surface)
        )
        .shadow(color: Theme.cardShadow, radius: 20, x: 0, y: 4)
    }

    private func label(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5))
        }
        .foregroundStyle(Theme.secondary)
    }

    // MARK: - 数据

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
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
        Task { await loadMonth() }
    }

    private func loadMonth() async {
        guard let vehicle = model.selectedVehicle else { return }
        loadingMonth = true
        errorText = nil
        defer { loadingMonth = false }

        let days = await RideTrackService.monthInfo(vin: vehicle.vinNo, month: monthAnchor)
        monthDays = days

        if days.isEmpty {
            selectedIndex = 0
            daySummary = nil
            tracks = []
            errorText = nil
            return
        }

        // 默认：今天（有骑行）→ 否则本月最后一个有骑行的日子
        let todayKey = Self.dottedDay.string(from: Date())
        if let todayIdx = days.firstIndex(where: { $0.date == todayKey && $0.mileage > 0 }) {
            selectedIndex = todayIdx
        } else if let last = days.lastIndex(where: { $0.mileage > 0 }) {
            selectedIndex = last
        } else {
            selectedIndex = days.count - 1
        }

        await loadSelectedDay()
    }

    private func loadSelectedDay() async {
        guard let vehicle = model.selectedVehicle, let day = selectedDay else {
            daySummary = nil
            tracks = []
            return
        }

        loadingDay = true
        defer { loadingDay = false }

        guard let date = Self.parseDotted(day.date) else {
            daySummary = nil
            tracks = []
            return
        }

        async let summaryTask = RideTrackService.daySummary(vin: vehicle.vinNo, date: date)
        async let tracksTask = RideTrackService.tracks(vin: vehicle.vinNo, from: date, to: date)
        daySummary = await summaryTask
        tracks = await tracksTask ?? []
    }

    private func dayLabel(_ date: String) -> String {
        let parts = date.split(separator: ".")
        guard parts.count >= 3 else { return date }
        return String(parts[2])
    }

    private static let dottedDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()

    private static func parseDotted(_ text: String) -> Date? {
        dottedDay.date(from: text)
            ?? {
                let alt = DateFormatter()
                alt.locale = Locale(identifier: "en_US_POSIX")
                alt.dateFormat = "yyyy-MM-dd"
                return alt.date(from: text.replacingOccurrences(of: ".", with: "-"))
            }()
    }
}

/// 用轨迹点画的缩略图
struct RouteThumbnail: View {
    let points: [Coordinate]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x0E1B2E), Color(hex: 0x17324F)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Canvas { context, size in
                guard points.count > 1 else { return }
                let lats = points.map { $0.latitude }
                let lngs = points.map { $0.longitude }
                guard let minLat = lats.min(), let maxLat = lats.max(),
                      let minLng = lngs.min(), let maxLng = lngs.max() else { return }

                let spanLat = max(0.000001, maxLat - minLat)
                let spanLng = max(0.000001, maxLng - minLng)
                let inset: CGFloat = 9
                let width = size.width - inset * 2
                let height = size.height - inset * 2

                var path = Path()
                for (index, point) in points.enumerated() {
                    let x = inset + width * CGFloat((point.longitude - minLng) / spanLng)
                    let y = inset + height * CGFloat(1 - (point.latitude - minLat) / spanLat)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                context.stroke(
                    path,
                    with: .color(Color(hex: 0x4D9BFF)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }
            .padding(2)
        }
    }
}
