import SwiftUI
import UIKit

/// 全部行程：按日分组列表，对齐官方「全部行程」页
struct RideHomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var showsClose: Bool = false

    @State private var monthAnchor = Date()
    @State private var groups: [RideDayGroup] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var selected: RideTrack?
    @State private var selecting = false
    @State private var picked: Set<String> = []
    @State private var replayBundle: RideReplayBundle?
    @State private var loadedKey: String?
    /// 边缘滑动返回：手指拖动时整页跟手位移
    @State private var backDrag: CGFloat = 0
    @State private var backDragging = false
    /// 多选回放最多同时选几段：合并回放的时间轴、点位规模和可读性都在 5 段内最稳
    @State private var pickHint: String?
    /// 上拉加载更多：当月行程接口按天分页（ridetrack_v2 page/pageSize），
    /// 首屏只拉第一页，滚到底部再拉下一页追加，不再一次拼齐整月
    @State private var loadingMore = false
    @State private var noMorePages = false
    @State private var nextPage = 2
    /// 已加载的当月行程明细；monthInfo 的日里程兜底用在翻完页之后
    @State private var loadedDays: [RideTrackService.MonthDay] = []
    @State private var loadedTracks: [RideTrack] = []
    /// 月份选择面板：点日期胶囊弹出年/月双轮
    @State private var showMonthPicker = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                // 顶部栏与日期固定：只有下面的列表滚动
                header
                    .padding(.horizontal, Theme.page)
                    .padding(.top, showsClose ? 10 : 8)
                monthChip
                    .padding(.horizontal, Theme.page)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
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
                            loadMoreFooter
                        }
                    }
                    .padding(.horizontal, Theme.page)
                    .padding(.bottom, listBottomPadding)
                }
                .background(Theme.groupedBackground)
                .refreshable { await loadMonth(force: true) }
            }

            if selecting {
                selectBar
            }
        }
        .offset(x: backDrag)
        .animation(backDragging ? nil : Motion.quick, value: backDrag)
        .overlay(alignment: .leading) {
            // 左边缘滑动返回（与系统返回手势同向）：全屏 cover 没有自带手势。
            // 顶部留出 header + 月份选择条的高度，别把返回按钮和月份切换挡住
            Color.clear
                .frame(width: 32)
                .padding(.top, 118)
                .contentShape(Rectangle())
                .gesture(edgeBackGesture)
        }
        .onAppear {
            // 全屏 cover 不会重置全局状态栏样式，进来改成默认（深浅色自适应），
            // 否则沿用车辆页的 lightContent，浅色底上状态栏一片白看不清
            UIApplication.shared.statusBarStyle = .default
        }
        .onDisappear {
            // 返回车辆页恢复深色主视觉的白字状态栏
            UIApplication.shared.statusBarStyle = .lightContent
        }
        .task(id: "\(model.selectedVehicle?.vinNo ?? "")-\(monthKey)-\(shouldLoadRides)") {
            guard shouldLoadRides else { return }
            let key = "\(model.selectedVehicle?.vinNo ?? "")-\(monthKey)"
            if loadedKey != key { loading = true }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, shouldLoadRides else { return }
            await loadMonth(force: false)
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
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerSheet(anchor: $monthAnchor)
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

            VStack(alignment: .leading, spacing: 3) {
                Text("全部行程")
                    .font(.system(size: showsClose ? 18 : 28, weight: .semibold))
                    .foregroundStyle(Theme.label)
                if !groups.isEmpty {
                    Text("本月 \(loadedTracks.count) 次骑行记录")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .monospacedDigit()
                }
            }

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

    /// 底栏胶囊大约 70pt + 安全区；全屏打开时没有 Tab，少留一点
    private var listBottomPadding: CGFloat {
        if selecting {
            return showsClose ? 120 : 210
        }
        return showsClose ? 40 : 120
    }

    /// 左边缘滑动返回：向右拖超过阈值或速度够快就关闭，否则弹回
    private var edgeBackGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard value.translation.width > 0 else { return }
                backDragging = true
                backDrag = value.translation.width
            }
            .onEnded { value in
                let dx = value.translation.width
                let shouldDismiss = dx > 120 || value.predictedEndTranslation.width > 260
                if shouldDismiss {
                    dismiss()
                }
                backDragging = false
                backDrag = 0
            }
    }

    private var selectBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(picked.count) 条")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.label)
                if let pickHint {
                    Text(pickHint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.orange)
                }
            }
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
        .padding(.top, 12)
        .padding(.bottom, showsClose ? 10 : 96)
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

            Button {
                showMonthPicker = true
            } label: {
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
            }
            .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))

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
        let minutes = groups.reduce(0) { $0 + $1.totalMin }
        let peak = groups.map(\.totalKm).max() ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "bicycle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.brand.opacity(0.12)))
                Text("本月总览")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                Text(monthTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .monospacedDigit()
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(formatKm(km))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                Text("km")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.brand)
            }

            HStack(spacing: 0) {
                monthStat("\(days)", "天", "骑行天数")
                heroDivider
                monthStat(RideTrackService.durationText(minutes), "", "累计时长")
                heroDivider
                monthStat(formatKm(peak), "km", "单日最长")
            }

            heroBars
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.brand.opacity(0.14), Theme.brand.opacity(0.04), Theme.surface.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.brand.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Theme.cardShadow, radius: 12, y: 3)
    }

    private var heroDivider: some View {
        Rectangle()
            .fill(Theme.tertiary.opacity(0.2))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 6)
    }

    /// 当月每日里程迷你柱状图（月历接口的日里程），今天高亮；只有一天数据时不画
    @ViewBuilder
    private var heroBars: some View {
        let ridden = loadedDays
            .filter { $0.mileage > 0 }
            .sorted { $0.date < $1.date }
        let peakKm = ridden.map(\.mileage).max() ?? 0
        let today = Self.dotted.string(from: Date())
        if ridden.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(ridden, id: \.date) { day in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(day.date == today ? Theme.brand : Theme.brand.opacity(0.28))
                            .frame(height: max(4, 40 * CGFloat(day.mileage / max(peakKm, 0.01))))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 40)

                HStack(spacing: 3) {
                    if let firstDay = ridden.first {
                        Text(Self.monthDayLabel(firstDay.date))
                            .foregroundStyle(Theme.tertiary)
                    }
                    Spacer(minLength: 0)
                    if let todayKm = loadedDays.first(where: { $0.date == today }), todayKm.mileage > 0 {
                        Text("今日 \(formatKm(todayKm.mileage)) km")
                            .foregroundStyle(Theme.brand)
                    } else if let lastDay = ridden.last {
                        Text(Self.monthDayLabel(lastDay.date))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
            }
        }
    }

    private static func monthDayLabel(_ key: String) -> String {
        let parts = key.split(separator: ".")
        guard parts.count >= 3 else { return key }
        return "\(parts[1])/\(parts[2])"
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
                                pickHint = nil
                            } else if picked.count >= maxPickedTracks {
                                showPickHint("合并回放最多选 \(maxPickedTracks) 段")
                            } else {
                                picked.insert(track.id)
                                pickHint = nil
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
        HStack(alignment: .top, spacing: 12) {
            if selecting {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(checked ? Theme.brand : Theme.tertiary)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(timeRange(track))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                thumb(track)
                    .frame(width: 68, height: 68)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Spacer(minLength: 0)
                    Text(formatKm(track.mileage))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.brand)
                        .monospacedDigit()
                    Text("km")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    if !selecting {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    placeLine(text: startText(track), tint: Color(hex: 0x22C55E))
                    placeLine(text: endText(track), tint: Color(hex: 0xF97316))
                }

                HStack(spacing: 0) {
                    rideMetric(RideTrackService.durationText(track.durationMinutes), "耗时")
                    rideMetric(speedText(avgSpeed(track)), "均速")
                    rideMetric(speedText(peakSpeed(track)), "极速")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func placeLine(text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rideMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
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

    /// 合并回放一次最多几段：太多会把不同日期的空档压进同一条时间轴，
    /// 光标跨城乱飞、地图连线成网，5 段以内节奏和可读性都最好
    private let maxPickedTracks = 5

    private func showPickHint(_ text: String) {
        pickHint = text
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if pickHint == text { pickHint = nil }
        }
    }

    /// 骑行 Tab 已移除：RideHomeView 只从车辆页全屏打开（showsClose=true）。
    private var shouldLoadRides: Bool {
        showsClose
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
        // 切月立即清缓存标记并进入加载态，绕过 loadedKey 缓存，避免「点了没反应」
        loadedKey = ""
        loading = true
    }

    /// 上拉加载尾部：加载中转圈、没有更多给提示、否则放透明哨兵（出现即触发追加）
    @ViewBuilder
    private var loadMoreFooter: some View {
        if loadingMore {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("加载更多骑行")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
        } else if noMorePages {
            Text("没有更多骑行记录了")
                .font(Theme.footnote)
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
        } else {
            // LazyVStack 下哨兵滚进视口才创建，onAppear 触发拉下一页
            Color.clear
                .frame(height: 1)
                .onAppear { Task { await loadMore() } }
        }
    }

    /// 滚到底部拉当月下一页行程（接口按天分组翻页），有新数据就追加进列表；
    /// 翻到空页/没有新数据时收口，并把「有日里程但没明细」的日子兜底补齐
    private func loadMore() async {
        guard !loadingMore, !noMorePages else { return }
        guard let vehicle = model.selectedVehicle else { return }
        loadingMore = true
        defer { loadingMore = false }

        guard let bounds = Self.monthBounds(for: monthAnchor) else {
            noMorePages = true
            return
        }
        let batch = await RideTrackService.tracks(
            vin: vehicle.vinNo, from: bounds.start, to: bounds.end,
            page: nextPage, pageSize: 10
        ) ?? []
        if Task.isCancelled { return }

        var fresh: [RideTrack] = []
        var seen = Set(loadedTracks.map(\.id))
        for track in batch where seen.insert(track.id).inserted {
            fresh.append(track)
        }
        guard !fresh.isEmpty else {
            noMorePages = true
            await reconcileMissingDays(vehicle: vehicle)
            return
        }
        nextPage += 1
        loadedTracks.append(contentsOf: fresh)
        groups = Self.buildGroups(days: loadedDays, tracks: loadedTracks)
    }

    /// 翻完页后兜底：月历接口说某天有里程，但分页明细里没有——按天单独拉
    private func reconcileMissingDays(vehicle: Vehicle) async {
        let known = Set(loadedTracks.compactMap(\.dayKey))
        let missing = loadedDays.filter { $0.mileage > 0 && !known.contains($0.date) }
        guard !missing.isEmpty else { return }
        let extra = await Self.tracksForDays(vin: vehicle.vinNo, days: missing)
        var seen = Set(loadedTracks.map(\.id))
        var added = false
        for track in extra where seen.insert(track.id).inserted {
            loadedTracks.append(track)
            added = true
        }
        if added, !Task.isCancelled {
            groups = Self.buildGroups(days: loadedDays, tracks: loadedTracks)
        }
    }

    /// 当月起止日期（最后一天不越过今天）
    private static func monthBounds(for date: Date) -> (start: Date, end: Date)? {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month], from: date)
        components.day = 1
        guard let start = calendar.date(from: components),
              let next = calendar.date(byAdding: .month, value: 1, to: start),
              let last = calendar.date(byAdding: .day, value: -1, to: next) else {
            return nil
        }
        return (start, min(last, Date()))
    }

    /// 首屏拉当月第一页 + 最近一周明细（接口按天升序翻页，最新行程在最后几页）；
    /// 更早的记录交给 loadMore 上拉追加
    private func loadMonth(force: Bool = true) async {
        guard let vehicle = model.selectedVehicle else { return }
        let key = "\(vehicle.vinNo)-\(monthKey)"
        if !force, loadedKey == key, !groups.isEmpty { return }
        loading = true
        errorText = nil
        defer { loading = false }

        guard let bounds = Self.monthBounds(for: monthAnchor) else { return }
        async let daysTask = RideTrackService.monthInfo(vin: vehicle.vinNo, month: monthAnchor)
        // 整月第一页（接口按天升序，拿到的是月初最旧的几天）
        let first = await RideTrackService.tracks(
            vin: vehicle.vinNo, from: bounds.start, to: bounds.end, page: 1, pageSize: 10
        ) ?? []
        let days = await daysTask ?? []
        if Task.isCancelled { return }

        loadedDays = days
        var merged: [RideTrack] = []
        var seen = Set<String>()
        for track in first where seen.insert(track.id).inserted {
            merged.append(track)
        }
        // 最近一周改为「按天拉」：范围请求按天升序分页，第一页只会拿到最旧的一天，
        // 导致首屏只出现一周前的记录；按天逐日拉保证最新骑行首屏可见
        let recentStart = max(bounds.start, Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? bounds.start)
        let recentStartKey = Self.dotted.string(from: recentStart)
        let recentDays = days.filter { $0.date >= recentStartKey && $0.mileage > 0 }
        if !recentDays.isEmpty {
            let recent = await Self.tracksForDays(vin: vehicle.vinNo, days: Array(recentDays))
            for track in recent where seen.insert(track.id).inserted {
                merged.append(track)
            }
        }
        nextPage = 2
        noMorePages = first.isEmpty
        groups = Self.buildGroups(days: days, tracks: merged)

        if merged.isEmpty, days.contains(where: { $0.mileage > 0 }) {
            // 月历有里程但分页明细空：先按天兜底补一轮，仍为空才报错
            await reconcileMissingDays(vehicle: vehicle)
            if groups.isEmpty {
                errorText = "行程明细加载失败，下拉刷新"
            }
        }
        loadedKey = key
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
        AmapGeocode.placeShort(track.startAddress, limit: 11) ?? "未记录起点"
    }

    private func endText(_ track: RideTrack) -> String {
        AmapGeocode.placeShort(track.endAddress, limit: 11) ?? "未记录终点"
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

/// 月份选择面板：年/月双轮，范围 2020-01 到当前月
private struct MonthPickerSheet: View {
    @Binding var anchor: Date
    @Environment(\.dismiss) private var dismiss

    private let calendar = Calendar.current
    @State private var year: Int
    @State private var month: Int

    init(anchor: Binding<Date>) {
        _anchor = anchor
        let cal = Calendar.current
        _year = State(initialValue: cal.component(.year, from: anchor.wrappedValue))
        _month = State(initialValue: cal.component(.month, from: anchor.wrappedValue))
    }

    private var currentYear: Int { calendar.component(.year, from: Date()) }
    private var currentMonth: Int { calendar.component(.month, from: Date()) }
    private var years: [Int] { Array(2020...max(2020, currentYear)) }
    private var months: [Int] { year >= currentYear ? Array(1...currentMonth) : Array(1...12) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("选择月份")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Spacer(minLength: 0)
                Button {
                    apply(year: currentYear, month: currentMonth)
                } label: {
                    Text("回到本月")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                }
                .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            HStack(spacing: 0) {
                Picker("年", selection: $year) {
                    ForEach(years, id: \.self) { value in
                        Text("\(value)年").tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker("月", selection: $month) {
                    ForEach(months, id: \.self) { value in
                        Text("\(value)月").tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }
            .frame(height: 160)
            .onChange(of: year) { _, newValue in
                // 切到当前年时把月份收敛到不超过本月
                if newValue >= currentYear, month > currentMonth {
                    month = currentMonth
                }
            }

            Button {
                apply()
            } label: {
                Text("确定")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.brand))
            }
            .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .sheetChrome(detents: [.height(340)])
    }

    private func apply(year targetYear: Int? = nil, month targetMonth: Int? = nil) {
        var components = DateComponents()
        components.year = targetYear ?? year
        components.month = targetMonth ?? month
        components.day = 1
        if let date = calendar.date(from: components) {
            anchor = date
        }
        dismiss()
    }
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
