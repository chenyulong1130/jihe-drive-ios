import SwiftUI

/// 电池详情：对齐小程序 battery.vue + 几何面板双源合并
/// V2 骨架（充电文案 / 功率 / 续航 / 在线）+ batteryInfo 覆盖 soc/电压/电流，本地采样电量曲线。
struct BatterySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle

    @State private var refreshing = false
    @State private var samples: [BatterySample] = []
    @State private var rangeAll = false
    @State private var selectedBar: Int = -1
    @State private var fetchedAt: Date?
    @State private var confirmClear = false

    var body: some View {
        SheetShell(
            title: "电池",
            subtitle: "\(vehicle.name) · 电量与充电",
            onClose: { dismiss() }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if model.batteryLoading && !hasData {
                        skeleton
                    } else if !hasData {
                        empty
                    } else {
                        hero
                        packCard
                        if showCharge { chargeCard }
                        if hasHealth { healthCard }
                        if hasUsage { usageCard }
                        if model.batteries.count > 1 { listCard }
                        traceCard
                        if let error = model.batteryError, hasData {
                            SoftBanner(text: error, icon: "exclamationmark.triangle", tone: Theme.orange)
                        }
                        if let stamp = updatedText {
                            Text(stamp)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .refreshable { await load(manual: true) }
        }
        .sheetChrome(detents: [.large])
        .confirmationDialog("清空电量曲线", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                BatterySocTrace.clear(vin: vehicle.vinNo)
                samples = []
                selectedBar = -1
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本地采样的历史数据将被删除，且无法恢复。")
        }
        .task {
            samples = BatterySocTrace.load(vin: vehicle.vinNo)
            await load(manual: false)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { break }
                await load(manual: false)
            }
        }
    }

    // MARK: - 数据

    private var battery: BatteryInfo? { model.batteries.first }

    private var hasData: Bool {
        battery != nil || vehicle.soc > 0 || !samples.isEmpty
    }

    private var soc: Int {
        min(max(battery?.level ?? vehicle.soc, 0), 100)
    }

    private var charging: Bool {
        battery?.isCharging ?? vehicle.isCharging
    }

    private var rangeKm: Int {
        battery?.rangeKm ?? vehicle.rangeKm
    }

    private var volts: Double {
        let v = battery?.voltage ?? 0
        return v > 0 ? v : (vehicle.voltage ?? 0)
    }

    private var amps: Double? { battery?.current }

    private var watts: Double? {
        if let p = battery?.power { return p }
        if let a = amps, volts > 0 { return abs(a) * volts }
        return nil
    }

    private var temp: Double {
        let t = battery?.temperature ?? 0
        return t != 0 ? t : (vehicle.temperature ?? 0)
    }

    private var showCharge: Bool {
        charging || !(battery?.chargeTimeString ?? "").isEmpty
    }

    private var hasHealth: Bool {
        battery?.soh != nil
            || battery?.score != nil
            || battery?.cycleCount != nil
            || battery?.capacity != nil
            || battery?.batteryLevel != nil
    }

    private var hasUsage: Bool { battery?.hasUsage == true }

    private var etaText: String {
        if let raw = battery?.etaFullText, !raw.isEmpty { return raw }
        if let m = battery?.chargeMinutes, m > 0 {
            return "约 " + BatterySocTrace.minutesText(m)
        }
        if charging, let m = BatterySocTrace.estimateFullMinutes(samples: samples, currentSoc: soc) {
            return "≈ " + BatterySocTrace.minutesText(m)
        }
        return ""
    }

    private var etaShort: String {
        guard charging else { return "" }
        var t = etaText
        if t.hasPrefix("约 ") { t.removeFirst(2) }
        if t.hasPrefix("≈ ") { t.removeFirst(2) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private var updatedText: String? {
        if let remote = battery?.refreshTime, !remote.isEmpty {
            return "更新于 \(remote)"
        }
        guard let fetchedAt else { return nil }
        let s = Int(Date().timeIntervalSince(fetchedAt))
        if s < 60 { return "更新于刚刚 · 本页停留时每 20 秒同步" }
        let m = s / 60
        if m < 60 { return "更新于 \(m) 分钟前 · 本页停留时每 20 秒同步" }
        return "更新于 \(m / 60) 小时前"
    }

    // MARK: - Hero

    private var hero: some View {
        let colors: [Color] = charging
            ? [Color(hex: 0x14532D), Color(hex: 0x15803D), Color(hex: 0x22C55E)]
            : [Color(hex: 0x0F3D74), Color(hex: 0x0B6BCB), Color(hex: 0x22A3F5)]

        return VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: CGFloat(soc) / 100)
                        .stroke(
                            Color.white,
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(soc)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                        Text("%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: 88, height: 88)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(charging ? "充电中" : (battery?.stateText.isEmpty == false ? battery!.stateText : "待机"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                        if charging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(rangeKm)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                        Text("km 可骑")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    if !etaShort.isEmpty {
                        Text("充满还需 \(etaShort)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                    } else if temp != 0 {
                        Text("电池温度 \(Int(temp))°C")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                heroLive("电压", volts > 0 ? String(format: "%.1f", volts) : "—", "V")
                heroLive("电流", amps.map { String(format: "%.1f", $0) } ?? "—", "A")
                heroLive("功率", watts.map { "\(Int($0.rounded()))" } ?? "—", "W")
                heroLive("温度", temp != 0 ? "\(Int(temp))" : "—", "°C")
            }
            .padding(.top, 4)
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.16)).frame(height: 1)
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(
            color: (charging ? Color(hex: 0x15803D) : Color(hex: 0x0B6BCB)).opacity(0.38),
            radius: 16,
            y: 8
        )
    }

    private func heroLive(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.62))
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 动力电池

    private var packCard: some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("动力电池")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Text(temp > 0 ? "温度 \(Int(temp))°C" : "实时工况")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }

                socBar
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                HStack {
                    ForEach(["0", "25", "50", "75", "100"], id: \.self) { tick in
                        Text(tick)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity, alignment: tick == "0" ? .leading : (tick == "100" ? .trailing : .center))
                    }
                }
                .padding(.top, 8)

            }
        }
    }

    private var socBar: some View {
        GeometryReader { geo in
            let pct = CGFloat(soc) / 100
            let fill = charging
                ? [Color(hex: 0x30D158).opacity(0.55), Color(hex: 0x30D158)]
                : [Color(hex: 0x0B6BCB).opacity(0.5), Color(hex: 0x0B6BCB)]
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceAlt)
                Capsule()
                    .fill(LinearGradient(colors: fill, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * pct))
                TriangleDown()
                    .fill(Theme.tertiary.opacity(0.7))
                    .frame(width: 10, height: 6)
                    .offset(x: geo.size.width * pct - 5, y: 8)
            }
        }
        .frame(height: 10)
    }

    // MARK: - 充电

    private var chargeCard: some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: 0x4ADE80), Color(hex: 0x30D158)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 30, height: 30)
                    Text("充电信息")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Spacer()
                    StatusPill(
                        text: charging ? "充电中" : "已停止",
                        color: charging ? Theme.green : Theme.secondary,
                        pulsing: charging
                    )
                }

                HStack(spacing: 0) {
                    VStack(spacing: 4) {
                        Text({
                            let raw = battery?.chargeTimeString ?? ""
                            return raw.isEmpty ? "—" : raw
                        }())
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Theme.label)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("已充电时长")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(width: 1, height: 26)
                    VStack(spacing: 4) {
                        Text(etaText.isEmpty ? "—" : etaText)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Theme.label)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("预计充满")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - 健康 / 用电

    private var healthCard: some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("健康状态")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.label)
                let chips: [(String, String, String?, String, Color)] = {
                    var rows: [(String, String, String?, String, Color)] = []
                    if let soh = battery?.soh {
                        rows.append(("健康度", String(format: "%.0f", soh), "%", "heart.fill", Theme.green))
                    }
                    if let score = battery?.score, !score.isEmpty {
                        rows.append(("状态评分", score, nil, "star.fill", Theme.orange))
                    }
                    if let grade = battery?.batteryLevel {
                        rows.append(("电池等级", "\(grade)", "%", "gauge", Theme.brand))
                    }
                    if let cycles = battery?.cycleCount ?? vehicle.cycleCount {
                        rows.append(("循环次数", "\(cycles)", "次", "arrow.triangle.2.circlepath", Theme.indigo))
                    }
                    if let cap = battery?.capacity {
                        rows.append(("额定容量", String(format: "%.1f", cap), "Ah", "battery.100percent", Theme.teal))
                    }
                    return rows
                }()
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        MetricChip(title: chip.0, value: chip.1, unit: chip.2, icon: chip.3, color: chip.4)
                    }
                }
            }
        }
    }

    private var usageCard: some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("用电统计")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.label)
                HStack(spacing: 10) {
                    MetricChip(title: "今日用电", value: battery?.powerUseToday.map { String(format: "%.1f", $0) } ?? "--", unit: "度", icon: "sun.max", color: Theme.orange)
                    MetricChip(title: "本月用电", value: battery?.powerUseMonth.map { String(format: "%.1f", $0) } ?? "--", unit: "度", icon: "calendar", color: Theme.brand)
                }
                HStack(spacing: 10) {
                    MetricChip(title: "本月充电量", value: battery?.powerChargeMonth.map { String(format: "%.1f", $0) } ?? "--", unit: "度", icon: "bolt.circle", color: Theme.green)
                    MetricChip(title: "本月充电次数", value: battery?.chargeCount.map { "\($0)" } ?? "--", unit: "次", icon: "repeat", color: Theme.indigo)
                }
            }
        }
    }

    private var listCard: some View {
        AppleCard {
            VStack(spacing: 12) {
                CardTitle(text: "电池列表", trailing: "共 \(model.batteries.count) 组")
                ForEach(Array(model.batteries.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { HairLine() }
                    HStack {
                        Text(item.name)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.label)
                        Spacer()
                        Text("\(item.level)%")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - 电量曲线

    private var viewSamples: [BatterySample] {
        BatterySocTrace.view(samples, rangeAll: rangeAll)
    }

    private var bars: [(h: CGFloat, sample: BatterySample)] {
        let src = viewSamples
        guard !src.isEmpty else { return [] }
        let values = src.map(\.soc)
        let lo = values.min() ?? 0
        let hi = values.max() ?? 100
        let span = max(6, hi - lo)
        let base = hi - span
        return src.map { p in
            let n = CGFloat(max(0, min(1, Double(p.soc - base) / Double(span))))
            return (22 + n * 72, p)
        }
    }

    private var spanText: String {
        let src = viewSamples
        guard !src.isEmpty else { return "" }
        let lo = src.map(\.soc).min() ?? 0
        let hi = src.map(\.soc).max() ?? 0
        return "\(lo)–\(hi)%"
    }

    private var traceCard: some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Text("电量曲线")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Text("本地采样" + (spanText.isEmpty ? "" : " · \(spanText)"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if samples.count >= 2 {
                        Button("清空") { confirmClear = true }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.red)
                    }
                }

                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        seg("近 48 点", on: !rangeAll) {
                            rangeAll = false
                            selectedBar = -1
                        }
                        seg("全部", on: rangeAll) {
                            rangeAll = true
                            selectedBar = -1
                        }
                    }
                    .padding(2)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Theme.surfaceAlt)
                    )
                    Spacer(minLength: 0)
                    if let sel = selectedInfo {
                        Text(sel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(chargingBarColor(selectedBar))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else if bars.count >= 2 {
                        Text("点柱子看单点")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                    }
                }

                if bars.count >= 2 {
                    chart
                    HStack {
                        Text("\(BatterySocTrace.clock(bars.first!.sample)) → \(BatterySocTrace.clock(bars.last!.sample))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary)
                        Spacer()
                        Text("当前 \(soc)%")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.brand)
                    }
                } else {
                    Text("采样不足：停留本页会自动记录，约 20 秒记一点")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.surfaceAlt)
                        )
                }
            }
        }
    }

    private var selectedInfo: String? {
        guard selectedBar >= 0, selectedBar < bars.count else { return nil }
        let p = bars[selectedBar].sample
        return "\(BatterySocTrace.clock(p)) · \(p.soc)%" + (p.c ? " · 充电中" : "")
    }

    private func chargingBarColor(_ index: Int) -> Color {
        guard index >= 0, index < bars.count else { return Theme.brand }
        return bars[index].sample.c ? Theme.green : Theme.brand
    }

    private var chart: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                let on = selectedBar == index
                let dim = selectedBar >= 0 && !on
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: bar.sample.c
                                ? [Color(hex: 0x22C55E), Color(hex: 0x22C55E).opacity(0.4)]
                                : [Color(hex: 0x0B6BCB).opacity(0.95), Color(hex: 0x0B6BCB).opacity(0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: max(4, 96 * bar.h / 100))
                    .opacity(dim ? 0.3 : 1)
                    .overlay {
                        if on {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedBar = selectedBar == index ? -1 : index
                    }
            }
        }
        .frame(height: 96, alignment: .bottom)
        .padding(.top, 8)
        .background(
            VStack(spacing: 23) {
                ForEach(0..<4, id: \.self) { _ in
                    Rectangle()
                        .fill(Theme.separator.opacity(0.35))
                        .frame(height: 1)
                    Spacer(minLength: 0)
                }
            }
        )
    }

    private func seg(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Theme.label : Theme.secondary)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? Theme.surface : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 空 / 骨架

    private var skeleton: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x0F3D74), Color(hex: 0x0B6BCB)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 148)
                .overlay {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SkeletonBar(width: 88, height: 36, radius: 8)
                            Spacer()
                            SkeletonBar(width: 88, height: 36, radius: 8)
                        }
                        SkeletonBar(height: 10, radius: 5)
                    }
                    .padding(18)
                }
            AppleCard {
                VStack(spacing: 12) {
                    SkeletonBar(width: 72, height: 14)
                    SkeletonBar(height: 10, radius: 5)
                    HStack(spacing: 12) {
                        SkeletonBar(height: 28, radius: 8)
                        SkeletonBar(height: 28, radius: 8)
                        SkeletonBar(height: 28, radius: 8)
                    }
                }
            }
            AppleCard {
                VStack(spacing: 10) {
                    SkeletonBar(width: 80, height: 14)
                    SkeletonBar(height: 96, radius: 10)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var empty: some View {
        AppleCard {
            VStack(spacing: 10) {
                Image(systemName: "battery.0percent")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.top, 8)
                Text(model.batteryError ?? "暂无电池数据")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.label)
                Text("车辆上报后这里会展示电量、电压电流与本地电量曲线")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await load(manual: true) }
                } label: {
                    Text(refreshing ? "读取中…" : "重新加载")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 132, height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.brand)
                        )
                }
                .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                .disabled(refreshing)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    // MARK: - 加载

    private func load(manual: Bool) async {
        if manual { refreshing = true }
        await model.loadBattery(vin: vehicle.vinNo, quiet: !manual && hasData)
        sampleNow()
        fetchedAt = Date()
        if manual { refreshing = false }
    }

    private func sampleNow() {
        let live = model.batteries.first
        let value = live?.level ?? vehicle.soc
        let p: Double? = {
            if let w = live?.power { return w }
            if let a = live?.current, let v = live?.voltage, v > 0 { return abs(a) * v }
            return nil
        }()
        samples = BatterySocTrace.record(
            vin: vehicle.vinNo,
            soc: value,
            charging: live?.isCharging ?? vehicle.isCharging,
            voltage: live?.voltage,
            current: live?.current,
            power: p
        )
    }
}

private struct TriangleDown: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
