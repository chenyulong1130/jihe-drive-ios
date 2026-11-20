import SwiftUI

/// 电池详情：走云端 batteryInfo，字段缺失时降级展示车辆自身电量
struct BatterySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle

    @State private var refreshing = false

    var body: some View {
        SheetShell(
            title: "电池信息",
            subtitle: vehicle.name,
            onClose: { dismiss() }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    overviewHero

                    if model.batteryLoading && model.batteries.isEmpty {
                        loading
                    } else if let error = model.batteryError, model.batteries.isEmpty {
                        banner(error)
                        fallbackCard
                    } else if model.batteries.isEmpty {
                        fallbackCard
                    } else if let first = model.batteries.first {
                        liveElectrical(first)
                        if first.hasChargeInfo {
                            chargeCard(first)
                        }
                        metrics(first)
                        healthCard(first)
                        if first.hasUsage {
                            usageCard(first)
                        }
                        if let abnormal = first.abnormal {
                            banner("电池异常：\(abnormal)")
                        }
                        if first.isPulledOut {
                            banner("检测到电池被拔出")
                        }
                        if model.batteries.count > 1 {
                            listCard
                        }
                        if let stamp = first.refreshTime, !stamp.isEmpty {
                            Text("更新于 \(stamp)")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiary)
                                .frame(maxWidth: .infinity)
                        }
                        refreshButton
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .refreshable { await load() }
        }
        .sheetChrome(detents: [.large])
        .task { await load() }
    }

    // MARK: - 概览 Hero

    private var overviewHero: some View {
        let battery = model.batteries.first
        let level = min(max(battery?.level ?? vehicle.soc, 0), 100)
        let charging = battery?.isCharging ?? vehicle.isCharging
        let range = battery?.rangeKm ?? vehicle.rangeKm
        let tint = charging ? Theme.green : Theme.brand

        return AppleCard {
            VStack(spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        RingProgress(
                            progress: Double(level) / 100,
                            color: tint,
                            track: Theme.surfaceAlt,
                            lineWidth: 10,
                            size: 108
                        )
                        VStack(spacing: 0) {
                            Text("\(level)")
                                .font(.system(size: 32, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.label)
                                .monospacedDigit()
                            Text("%")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        StatusPill(
                            text: charging ? "充电中" : (battery?.stateText ?? "待机"),
                            color: tint,
                            pulsing: charging
                        )
                        Text("预计续航")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(range)")
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.label)
                                .monospacedDigit()
                            Text("km")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.tertiary)
                        }
                        Text(battery?.type ?? "动力电池")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func liveElectrical(_ battery: BatteryInfo) -> some View {
        let volts = battery.voltage > 0 ? battery.voltage : (vehicle.voltage ?? 0)
        let current = battery.current
        let power: Double? = {
            if let p = battery.power { return p }
            if let a = current, volts > 0 { return abs(a) * volts }
            return nil
        }()

        return AppleCard {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(text: "实时工况", trailing: battery.isCharging ? "充电中" : "待机")
                HStack(spacing: 12) {
                    MetricChip(
                        title: "电压",
                        value: volts > 0 ? String(format: "%.1f", volts) : "--",
                        unit: "V",
                        icon: "bolt",
                        color: Theme.orange
                    )
                    MetricChip(
                        title: "电流",
                        value: current.map { String(format: "%.1f", $0) } ?? "--",
                        unit: "A",
                        icon: "wave.3.right",
                        color: Theme.teal
                    )
                    MetricChip(
                        title: "功率",
                        value: power.map { String(format: "%.0f", $0) } ?? "--",
                        unit: "W",
                        icon: "bolt.fill",
                        color: Theme.brand
                    )
                }
            }
        }
    }

    private func chargeCard(_ battery: BatteryInfo) -> some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("充电信息")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    StatusPill(
                        text: battery.isCharging ? "充电中" : "已停止",
                        color: battery.isCharging ? Theme.green : Theme.secondary,
                        pulsing: battery.isCharging
                    )
                }
                HStack(spacing: 12) {
                    MetricChip(
                        title: "已充电时长",
                        value: battery.chargeTimeString
                            ?? battery.chargeMinutes.map { "\($0)" }
                            ?? "--",
                        unit: battery.chargeTimeString == nil && battery.chargeMinutes != nil ? "min" : nil,
                        icon: "clock",
                        color: Theme.brand
                    )
                    MetricChip(
                        title: "预计充满",
                        value: battery.etaFullText
                            ?? chargeEstimateText(battery.fullChargeText)
                            ?? battery.chargeMinutes.map { "\($0)" }
                            ?? "--",
                        unit: battery.etaFullText == nil ? "min" : nil,
                        icon: "battery.100percent.bolt",
                        color: Theme.green
                    )
                }
            }
        }
    }

    private func usageCard(_ battery: BatteryInfo) -> some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(text: "用电统计")
                HStack(spacing: 12) {
                    MetricChip(
                        title: "今日用电",
                        value: battery.powerUseToday.map { String(format: "%.1f", $0) } ?? "--",
                        unit: "度",
                        icon: "sun.max",
                        color: Theme.orange
                    )
                    MetricChip(
                        title: "本月用电",
                        value: battery.powerUseMonth.map { String(format: "%.1f", $0) } ?? "--",
                        unit: "度",
                        icon: "calendar",
                        color: Theme.brand
                    )
                }
                HStack(spacing: 12) {
                    MetricChip(
                        title: "本月充电量",
                        value: battery.powerChargeMonth.map { String(format: "%.1f", $0) } ?? "--",
                        unit: "度",
                        icon: "bolt.circle",
                        color: Theme.green
                    )
                    MetricChip(
                        title: "本月充电次数",
                        value: battery.chargeCount.map { "\($0)" } ?? "--",
                        unit: "次",
                        icon: "repeat",
                        color: Theme.indigo
                    )
                }
            }
        }
    }

    private func healthCard(_ battery: BatteryInfo) -> some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("健康状态")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.label)

                InfoRow(title: "充放电状态", value: battery.stateText)
                InfoRow(
                    title: "健康度",
                    value: battery.soh.map { String(format: "%.0f%%", $0) } ?? (battery.score ?? "—")
                )
                InfoRow(
                    title: "循环次数",
                    value: (battery.cycleCount ?? vehicle.cycleCount).map { "\($0) 次" } ?? "—"
                )
                InfoRow(
                    title: "额定容量",
                    value: battery.capacity.map { String(format: "%.1f Ah", $0) } ?? "—"
                )
                InfoRow(
                    title: "充满预估",
                    value: battery.etaFullText
                        ?? battery.chargeMinutes.map { "\($0) 分钟" }
                        ?? chargeEstimateText(battery.fullChargeText).map { "\($0) 分钟" }
                        ?? "—"
                )
                if battery.isPulledOut {
                    Text("传感器检测到电池可能已拔出")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.orange)
                }
            }
        }
    }

    // MARK: - 主卡

    private func mainCard(_ battery: BatteryInfo) -> some View {
        let tint = battery.isCharging ? Theme.green : Theme.brand

        return AppleCard {
            HStack(spacing: 16) {
                ZStack {
                    RingProgress(
                        progress: Double(battery.level) / 100,
                        color: tint,
                        track: Color(uiColor: .tertiarySystemFill),
                        lineWidth: 8,
                        size: 92
                    )
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(battery.level)")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(Theme.label)
                            .monospacedDigit()
                        Text("%")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    StatusPill(
                        text: battery.stateText,
                        color: battery.isCharging ? Theme.green : Theme.brand,
                        pulsing: battery.isCharging
                    )

                    InfoRow(title: "电池型号", value: battery.type)
                    InfoRow(title: "总电压", value: String(format: "%.1f V", battery.voltage))
                        .opacity(battery.voltage > 0 ? 1 : 0.4)
                    InfoRow(title: "温度", value: String(format: "%.0f ℃", battery.temperature))
                        .opacity(battery.temperature != 0 ? 1 : 0.4)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func metrics(_ battery: BatteryInfo) -> some View {
        let cycles = battery.cycleCount ?? vehicle.cycleCount
        let temp = battery.temperature != 0 ? battery.temperature : (vehicle.temperature ?? 0)

        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                MetricChip(
                    title: "温度",
                    value: temp != 0 ? String(format: "%.0f", temp) : "--",
                    unit: "℃",
                    icon: "thermometer.medium",
                    color: Theme.teal
                )
                MetricChip(
                    title: "循环次数",
                    value: cycles.map { "\($0)" } ?? "--",
                    unit: "次",
                    icon: "arrow.triangle.2.circlepath",
                    color: Theme.indigo
                )
            }
        }
    }

    private var listCard: some View {
        AppleCard {
            VStack(spacing: 12) {
                CardTitle(text: "电池列表", trailing: "共 \(model.batteries.count) 组")

                ForEach(Array(model.batteries.enumerated()), id: \.element.id) { index, battery in
                    if index > 0 { HairLine() }
                    batteryRow(battery)
                }
            }
        }
    }

    private func batteryRow(_ battery: BatteryInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(battery.name)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(battery.level)%")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .tertiarySystemFill))
                    Capsule()
                        .fill(Theme.brand)
                        .frame(width: max(4, geo.size.width * CGFloat(battery.level) / 100))
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 3)
    }

    // MARK: - 降级 / 状态

    private var fallbackCard: some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(text: "车辆电量")

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(vehicle.soc)")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                    Text("%")
                        .font(Theme.callout)
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    Text("续航 \(vehicle.rangeKm) km")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(uiColor: .tertiarySystemFill))
                        Capsule()
                            .fill(Theme.brand)
                            .frame(width: max(4, geo.size.width * CGFloat(min(100, max(0, vehicle.soc))) / 100))
                    }
                }
                .frame(height: 6)

                Text(model.batteryError ?? "云端未返回电池明细，仅显示整车电量。车辆上报后重试可见电压、温度与循环次数。")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                refreshButton
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在读取电池数据")
                .font(Theme.footnote)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func banner(_ text: String) -> some View {
        SoftBanner(text: text, icon: "exclamationmark.triangle", tone: Theme.orange)
    }

    private var refreshButton: some View {
        Button {
            Task { await load() }
        } label: {
            HStack(spacing: 8) {
                if refreshing {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                }
                Text(refreshing ? "读取中…" : "重新读取")
                    .font(.system(size: 17, weight: .medium))
            }
            .foregroundStyle(Theme.brand)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                    .fill(Theme.surfaceAlt)
            )
        }
        .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
        .disabled(refreshing)
    }

    private func load() async {
        refreshing = true
        await model.loadBattery(vin: vehicle.vinNo)
        refreshing = false
    }

    /// 充满预估可能是秒数 / 分钟数 / 文案
    private func chargeEstimateText(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let seconds = Double(raw), seconds > 0 {
            return "\(max(1, Int(seconds / 60)))"
        }
        let digits = raw.filter(\.isNumber)
        if let value = Int(digits), value > 0 { return "\(value)" }
        return raw
    }
}
