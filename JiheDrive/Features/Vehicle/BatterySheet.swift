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
                    if model.batteryLoading && model.batteries.isEmpty {
                        loading
                    } else if let error = model.batteryError, model.batteries.isEmpty {
                        banner(error)
                        fallbackCard
                    } else if model.batteries.isEmpty {
                        fallbackCard
                    } else {
                        if let first = model.batteries.first {
                            mainCard(first)
                            metrics(first)
                            if let abnormal = first.abnormal {
                                banner("电池异常：\(abnormal)")
                            }
                            if first.isPulledOut {
                                banner("检测到电池被拔出")
                            }
                        }
                        if model.batteries.count > 1 {
                            listCard
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
        .sheetChrome(detents: [.medium, .large])
        .task { await load() }
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
        let capacity = battery.capacity
        let chargeMin = battery.chargeMinutes

        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                MetricChip(
                    title: "电压",
                    value: battery.voltage > 0
                        ? String(format: "%.1f", battery.voltage)
                        : (vehicle.voltage.map { String(format: "%.1f", $0) } ?? "--"),
                    unit: "V",
                    icon: "bolt",
                    color: Theme.orange
                )
                MetricChip(
                    title: "温度",
                    value: battery.temperature != 0
                        ? String(format: "%.0f", battery.temperature)
                        : (vehicle.temperature.map { String(format: "%.0f", $0) } ?? "--"),
                    unit: "℃",
                    icon: "thermometer.medium",
                    color: Theme.teal
                )
            }

            HStack(spacing: 12) {
                MetricChip(
                    title: "循环次数",
                    value: cycles.map { "\($0)" } ?? "--",
                    unit: "次",
                    icon: "arrow.triangle.2.circlepath",
                    color: Theme.indigo
                )
                MetricChip(
                    title: "容量",
                    value: capacity.map { String(format: "%.0f", $0) } ?? "--",
                    unit: "Ah",
                    icon: "battery.100percent",
                    color: Theme.brand
                )
            }

            HStack(spacing: 12) {
                MetricChip(
                    title: "续航",
                    value: "\(vehicle.rangeKm)",
                    unit: "km",
                    icon: "point.bottomleft.forward.to.point.topright.scurvepath",
                    color: Theme.green
                )
                MetricChip(
                    title: battery.isCharging ? "已充时长" : "充满预估",
                    value: chargeMin.map { "\($0)" }
                        ?? chargeEstimateText(battery.fullChargeText)
                        ?? "--",
                    unit: chargeMin != nil || battery.fullChargeText != nil ? "min" : "",
                    icon: "clock",
                    color: Theme.brand
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
