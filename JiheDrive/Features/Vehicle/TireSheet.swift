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

    // MARK: - 压力区间（每轮一行刻度，避免针脚叠在一起）

    private var gaugeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("压力区间")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Spacer()
                Text("安全 1.9 – 3.2 bar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }

            VStack(spacing: 14) {
                ForEach(wheels) { wheel in
                    wheelGauge(wheel)
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
        }
    }

    private func wheelGauge(_ wheel: WheelReading) -> some View {
        let ok = wheel.isOk(low: lowBar, high: highBar)
        let tint: Color = {
            if wheel.pressure < lowBar { return Theme.orange }
            if wheel.pressure > highBar { return Theme.red }
            return wheel.label == "前轮" ? Theme.brand : Color(hex: 0xFF8A3D)
        }()
        let scaleMax: Double = 4.0

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(wheel.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Spacer()
                Text(statusText(wheel))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ok ? Theme.green : Theme.orange)
                Text(String(format: "%.1f bar", wheel.pressure))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(ok ? Theme.label : tint)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                let w = geo.size.width
                let lowX = w * CGFloat(lowBar / scaleMax)
                let highX = w * CGFloat(highBar / scaleMax)
                let needle = min(max(CGFloat(wheel.pressure / scaleMax), 0), 1) * w

                ZStack(alignment: .leading) {
                    // 三段色带：偏低 / 安全 / 偏高
                    HStack(spacing: 0) {
                        Capsule()
                            .fill(Theme.orange.opacity(0.28))
                            .frame(width: max(4, lowX))
                        Capsule()
                            .fill(Theme.green.opacity(0.42))
                            .frame(width: max(4, highX - lowX))
                        Capsule()
                            .fill(Theme.red.opacity(0.28))
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: 12)
                    .clipShape(Capsule())

                    // 刻度竖线
                    ForEach([lowBar, highBar], id: \.self) { mark in
                        Rectangle()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: 1.5, height: 16)
                            .offset(x: w * CGFloat(mark / scaleMax) - 0.75)
                    }

                    Circle()
                        .fill(tint)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2.5))
                        .shadow(color: tint.opacity(0.4), radius: 5, y: 1)
                        .offset(x: max(0, min(w - 18, needle - 9)))
                }
            }
            .frame(height: 18)

            HStack {
                Text("偏低")
                    .foregroundStyle(Theme.orange)
                Spacer()
                Text("1.9 安全区 3.2")
                    .foregroundStyle(Theme.green)
                Spacer()
                Text("偏高")
                    .foregroundStyle(Theme.red)
            }
            .font(.system(size: 10, weight: .semibold))
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
