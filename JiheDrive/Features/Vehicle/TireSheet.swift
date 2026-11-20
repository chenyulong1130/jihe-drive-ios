import SwiftUI

/// 胎压监测二级页：对齐小程序 tire.vue（双轮卡 + 压力区间 + 说明）
struct TireSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle

    @State private var refreshing = false
    @State private var reading: TireReading?

    private let lowBar: Double = 1.9
    private let highBar: Double = 3.2

    var body: some View {
        SheetShell(
            title: "胎压监测",
            subtitle: "\(vehicle.name) · 实时胎压与胎温",
            onClose: { dismiss() }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if refreshing && !hasData {
                        loading
                    } else if !hasData {
                        empty
                    } else {
                        if let banner = bannerText {
                            SoftBanner(text: banner, icon: "exclamationmark.triangle.fill", tone: Theme.orange)
                        }
                        duoCards
                        gaugeCard
                        tipsCard
                        if let updated = reading?.updatedAt ?? model.tire?.updatedAt {
                            Text("更新于 \(updated)")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 4)
                        }
                        refreshButton
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .refreshable { await reload() }
        }
        .sheetChrome(detents: [.medium, .large])
        .task {
            reading = model.tire
            await reload()
        }
    }

    // MARK: - 数据

    private var hasData: Bool {
        front != nil || rear != nil
    }

    private var front: WheelReading? {
        wheel(bar: reading?.frontBar ?? model.tire?.frontBar, temp: reading?.frontTemp ?? model.tire?.frontTemp, label: "前轮")
    }

    private var rear: WheelReading? {
        wheel(bar: reading?.rearBar ?? model.tire?.rearBar, temp: reading?.rearTemp ?? model.tire?.rearTemp, label: "后轮")
    }

    private var wheels: [WheelReading] {
        [front, rear].compactMap { $0 }
    }

    private func wheel(bar: Double?, temp: Double?, label: String) -> WheelReading? {
        guard let bar, bar > 0.3, bar < 6 else { return nil }
        let warn = (reading?.warning ?? model.tire?.warning ?? 0) != 0
        return WheelReading(label: label, pressure: bar, temp: temp, sensorWarn: warn)
    }

    private var bannerText: String? {
        let parts = wheels.compactMap { w -> String? in
            if w.sensorWarn { return "\(w.label)传感器告警" }
            if w.pressure < lowBar { return "\(w.label)胎压偏低（<\(String(format: "%.1f", lowBar)) bar）" }
            if w.pressure > highBar { return "\(w.label)胎压偏高" }
            return nil
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "；") + "，请及时检查"
    }

    // MARK: - 双轮卡

    private var duoCards: some View {
        HStack(spacing: 10) {
            ForEach(wheels) { wheel in
                wheelCard(wheel)
            }
        }
    }

    private func wheelCard(_ wheel: WheelReading) -> some View {
        let ok = wheel.isOk(low: lowBar, high: highBar)
        return VStack(spacing: 12) {
            HStack {
                Text(wheel.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Circle()
                        .fill(ok ? Theme.green : Theme.orange)
                        .frame(width: 6, height: 6)
                    Text(ok ? "正常" : statusText(wheel))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ok ? Theme.green : Theme.orange)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill((ok ? Theme.green : Theme.orange).opacity(0.12))
                )
            }

            ZStack {
                Circle()
                    .strokeBorder(ok ? Theme.brand.opacity(0.22) : Theme.orange.opacity(0.35), lineWidth: 8)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(Theme.surfaceAlt)
                    .frame(width: 34, height: 34)
                Text(wheel.temp.map { String(format: "%.0f°C", $0) } ?? "—")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .monospacedDigit()
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: "%.1f", wheel.pressure))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(ok ? Theme.label : Theme.orange)
                    .monospacedDigit()
                Text("bar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }

            Text("胎温 \(wheel.temp.map { String(format: "%.0f ℃", $0) } ?? "—")")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.4), lineWidth: 0.5)
        }
    }

    private func statusText(_ wheel: WheelReading) -> String {
        if wheel.sensorWarn { return "告警" }
        if wheel.pressure < lowBar { return "偏低" }
        if wheel.pressure > highBar { return "偏高" }
        return "正常"
    }

    // MARK: - 压力区间

    private var gaugeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("压力区间")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Spacer()
                Text("量程 0 – 4.0 bar")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        zone(color: Theme.orange.opacity(0.55), label: "偏低", width: width * (1.9 / 4.0))
                        zone(color: Theme.green.opacity(0.55), label: "安全", width: width * ((3.2 - 1.9) / 4.0))
                        zone(color: Theme.orange.opacity(0.55), label: "偏高", width: width * ((4.0 - 3.2) / 4.0))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    ForEach(wheels) { wheel in
                        let x = min(max(wheel.pressure / 4.0, 0), 1) * width
                        VStack(spacing: 2) {
                            Text(String(format: "%.1f", wheel.pressure))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(wheel.label == "前轮" ? Theme.brand : Theme.orange)
                                .monospacedDigit()
                            Capsule()
                                .fill(wheel.label == "前轮" ? Theme.brand : Theme.orange)
                                .frame(width: 3, height: 28)
                        }
                        .offset(x: x - 12)
                    }
                }
            }
            .frame(height: 44)

            HStack {
                ForEach(["0", "1.0", "2.0", "3.0", "4.0"], id: \.self) { tick in
                    Text(tick)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 16) {
                legend(color: Theme.brand, text: "前轮")
                legend(color: Theme.orange, text: "后轮")
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
        }
    }

    private func zone(color: Color, label: String, width: CGFloat) -> some View {
        ZStack {
            color
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: max(1, width), height: 28)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
        }
    }

    // MARK: - 说明 / 状态

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            tip("胎压低于 1.9 bar 判为偏低，能耗与磨损增大")
            tip("胎压过高影响抓地与滤震，冷胎参考值以车架铭牌标注为准")
            tip("打开本页会重新拉取传感器读数；下拉或点刷新可立即更新")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
        }
    }

    private func tip(_ text: String) -> some View {
        Text("· \(text)")
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在读取胎压")
                .font(Theme.footnote)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.circle")
                .font(.system(size: 34))
                .foregroundStyle(Theme.tertiary)
            Text("暂无胎压传感器读数")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.label)
            Text("需要车辆安装胎压传感器并已上报有效读数")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            refreshButton
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private var refreshButton: some View {
        Button {
            Task { await reload() }
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

    private func reload() async {
        refreshing = true
        await model.loadTire(vin: vehicle.vinNo)
        reading = model.tire
        refreshing = false
    }
}

private struct WheelReading: Identifiable {
    var id: String { label }
    let label: String
    let pressure: Double
    let temp: Double?
    let sensorWarn: Bool

    func isOk(low: Double, high: Double) -> Bool {
        !sensorWarn && pressure >= low && pressure <= high
    }
}
