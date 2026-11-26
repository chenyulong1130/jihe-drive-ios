import SwiftUI

/// 保护板数据页：对齐 Flutter `bms_panel_page` ——
/// 居中 SOC 环英雄区 + 容量/规格 + 指标网格 + 单体电压条。
struct BMSDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @ObservedObject var store: BMSStore
    @State private var showFlags = false
    @State private var showLogs = false
    @State private var peakDiff: Double = 0

    private var rt: BMSRealtime? { store.realtime }
    private var connected: Bool { ble.isConnected }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                headerRow
                heroCard
                if isCharging { chargeCard }
                metricsGrid
                if peakDiff > 0 { peakDiffCard }
                if hasAlerts { alertsCard }
                cellsCard

                if store.brand == .ant {
                    SectionHeader("通信通道")
                    channelCard
                }

                LogPanel(title: "通信日志", logs: store.logs)
                HStack {
                    Button { showLogs = true } label: {
                        Label("原始数据", systemImage: "doc.text.magnifyingglass")
                            .font(Theme.footnote)
                    }
                    .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .background(Theme.groupedBackground)
        .navigationTitle("保护板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.isPolling ? store.stopPolling() : store.startPolling()
                } label: {
                    Image(systemName: store.isPolling ? "pause.circle" : "play.circle")
                }
            }
        }
        .onAppear {
            store.attach(ble)
            store.startPolling()
        }
        .onDisappear {
            store.stopPolling()
            store.deactivate()
        }
        .onChange(of: rt?.voltageDiff ?? 0) { _, diff in
            if connected, diff > peakDiff { peakDiff = diff }
        }
        .sheet(isPresented: $showFlags) { flagsSheet }
        .sheet(isPresented: $showLogs) { rawSheet }
    }

    private var isCharging: Bool {
        guard connected, let rt else { return false }
        if store.brand == .yanyang { return rt.state == 1 }
        return rt.state == 1
    }

    private var hasAlerts: Bool {
        guard let rt else { return false }
        if !rt.protectNames.isEmpty { return true }
        let w = BMSProtocol.flagNames(rt.warningFlags, table: BMSProtocol.warningFlags)
        let p = BMSProtocol.flagNames(rt.protectFlags, table: BMSProtocol.protectFlags)
        return !w.isEmpty || !p.isEmpty
    }

    private var flowColor: Color {
        guard connected, let rt else { return Theme.secondary }
        switch rt.flowLabel {
        case "充电中": return Theme.green
        case "放电中": return Theme.orange
        case "均衡中": return Theme.teal
        default: return Theme.brand
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ble.connectedDevice?.displayName ?? "保护板")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Text("\(store.brand.title)协议 · \(store.channelStatus)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            StatusPill(
                text: connected ? "已连接" : "未连接",
                color: connected ? Theme.green : Theme.secondary,
                pulsing: connected
            )
        }
    }

    // MARK: - Hero（居中 SOC 环 + 容量/规格）

    private var heroCard: some View {
        let soc = connected ? Double(rt?.soc ?? 0) : 0
        let remain = rt?.remainingCapacity ?? 0
        let full = rt?.physicalCapacity ?? 0
        let series = rt?.cellCount ?? 0
        let type = rt?.typeLabel ?? "--"

        return AppleCard(padding: 0) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .stroke(Theme.surfaceAlt, lineWidth: 14)
                    Circle()
                        .trim(from: 0, to: connected ? CGFloat(min(1, max(0, soc / 100))) : 0)
                        .stroke(
                            flowColor,
                            style: StrokeStyle(lineWidth: 14, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.45), value: soc)

                    VStack(spacing: 6) {
                        if connected {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("\(Int(soc))")
                                    .font(.system(size: 46, weight: .bold, design: .rounded))
                                    .foregroundStyle(Theme.label)
                                Text("%")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(Theme.label)
                            }
                        } else {
                            Text("--")
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.label)
                        }
                        Text(connected ? (rt?.flowLabel ?? "—") : "未连接")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .frame(width: 180, height: 180)
                .padding(.top, 22)
                .padding(.bottom, 22)

                Divider().opacity(0.6)

                HStack(spacing: 0) {
                    infoCell(
                        "容量概览",
                        connected && full > 0
                            ? String(format: "%.1f / %.1f", remain, full)
                            : "--",
                        connected && full > 0 ? "Ah" : nil
                    )
                    Rectangle()
                        .fill(Theme.separator.opacity(0.5))
                        .frame(width: 1, height: 34)
                    infoCell(
                        "电池规格",
                        connected ? (series > 0 ? "\(type) / \(series)" : type) : "--",
                        connected && series > 0 ? "串" : nil
                    )
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 8)
            }
        }
    }

    private func infoCell(_ label: String, _ value: String, _ unit: String?) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 充电卡

    private var chargeCard: some View {
        let power = abs(rt?.power ?? 0)
        let remain = rt?.remainingCapacity ?? 0
        let full = rt?.physicalCapacity ?? 0
        let current = abs(rt?.current ?? 0)
        let est: String = {
            guard full > remain, current > 0.1 else { return "--" }
            let hours = (full - remain) / current
            if hours < 1 { return "\(Int(hours * 60)) 分钟" }
            return String(format: "%.1f 小时", hours)
        }()

        return AppleCard(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("充电中")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                    Text("预计充满 \(est) · \(power) W")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: - 指标网格

    private var metricsGrid: some View {
        let r = rt
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MetricTile(title: "总电压", value: fmt(r?.totalVoltage, "%.2f"), unit: "V", accent: Theme.brand)
            MetricTile(
                title: "实时电流",
                value: connected
                    ? String(format: "%.1f", abs(r?.current ?? 0))
                    : "--",
                unit: "A",
                accent: flowColor
            )
            MetricTile(title: "实时功率", value: connected ? "\(abs(r?.power ?? 0))" : "--", unit: "W", accent: Color(hex: 0x0EA5E9))
            MetricTile(title: "最高电压", value: fmt(r?.highestCell, "%.3f"), unit: "V", accent: Theme.red)
            MetricTile(title: "最低电压", value: fmt(r?.lowestCell, "%.3f"), unit: "V", accent: Theme.teal)
            MetricTile(
                title: "实时压差",
                value: fmt(r?.voltageDiff, "%.3f"),
                unit: "V",
                accent: (r?.voltageDiff ?? 0) > 0.05 ? Theme.red : Theme.orange
            )
            MetricTile(title: "MOS 温度", value: connected ? "\(r?.mosTemperature ?? 0)" : "--", unit: "℃", accent: Theme.orange)
            MetricTile(
                title: "电芯温度",
                value: connected
                    ? (r?.temperatures.first.map(String.init) ?? "--")
                    : "--",
                unit: "℃",
                accent: Color(hex: 0xF59E0B)
            )
            MetricTile(
                title: "循环次数",
                value: connected
                    ? "\(r?.cycleCount ?? Int(r?.cycleCapacity ?? 0))"
                    : "--",
                unit: "次",
                accent: Theme.green
            )
        }
    }

    private func fmt(_ value: Double?, _ format: String) -> String {
        guard connected, let value else { return "--" }
        return String(format: format, value)
    }

    private var peakDiffCard: some View {
        AppleCard(padding: 14) {
            HStack {
                Text("峰值压差")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Text(String(format: "%.3f V", peakDiff))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.orange)
            }
        }
    }

    // MARK: - 告警

    private var alertsCard: some View {
        let names: [String] = {
            guard let rt else { return [] }
            if !rt.protectNames.isEmpty { return rt.protectNames }
            return BMSProtocol.flagNames(rt.warningFlags, table: BMSProtocol.warningFlags)
                + BMSProtocol.flagNames(rt.protectFlags, table: BMSProtocol.protectFlags)
        }()
        return AppleCard(padding: 14, onTap: { showFlags = true }) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.orange)
                Text(names.isEmpty ? "状态正常" : names.prefix(2).joined(separator: "、"))
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Spacer()
                Text("\(names.count)")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.orange)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    // MARK: - 单体

    private var cellsCard: some View {
        let cells = rt?.cellVoltages ?? []
        let hi = cells.max() ?? 0
        let lo = cells.min() ?? 0
        return AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("单体电压")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Text(connected ? "\(cells.count) 串" : "—")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }

                if connected, !cells.isEmpty {
                    ForEach(cells.indices, id: \.self) { index in
                        let v = cells[index]
                        let isHi = abs(v - hi) < 0.0005 && hi > 0
                        let isLo = abs(v - lo) < 0.0005 && lo > 0
                        HStack(spacing: 8) {
                            Text(String(format: "%02d", index + 1))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.tertiary)
                                .frame(width: 22, alignment: .trailing)
                            GeometryReader { geo in
                                let ratio = CGFloat(min(1, max(0, (v - 2.5) / 1.7)))
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.surfaceAlt)
                                    Capsule()
                                        .fill(isHi ? Theme.red : isLo ? Theme.teal : Theme.brand)
                                        .frame(width: geo.size.width * ratio)
                                }
                            }
                            .frame(height: 8)
                            Text(String(format: "%.3f", v))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(isHi ? Theme.red : isLo ? Theme.teal : Theme.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                } else {
                    Text(connected ? "等待单体数据…" : "连接后显示单体电压")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
    }

    // MARK: - 蚂蚁通道

    private var channelCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("通信通道", selection: Binding(
                    get: { store.channel },
                    set: { newValue in
                        Task { try? await ble.selectBMSChannel(newValue) }
                    }
                )) {
                    ForEach(BMSChannel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    StatusPill(
                        text: store.channelStatus,
                        color: store.channelStatus.contains("正常") || store.channelStatus.contains("可用")
                            ? .green : .orange
                    )
                    Spacer()
                    Button {
                        Task { await store.diagnoseChannels() }
                    } label: {
                        Label("通道检测", systemImage: "waveform.path.ecg")
                            .font(Theme.footnote)
                    }
                    .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                }
            }
        }
    }

    // MARK: - Sheets

    private var flagsSheet: some View {
        let names: [String] = {
            guard let rt else { return [] }
            if !rt.protectNames.isEmpty { return rt.protectNames }
            return BMSProtocol.flagNames(rt.warningFlags, table: BMSProtocol.warningFlags)
                + BMSProtocol.flagNames(rt.protectFlags, table: BMSProtocol.protectFlags)
        }()
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if names.isEmpty {
                        Text("无活动告警 / 保护")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.green)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 8) {
                            ForEach(names, id: \.self) { item in
                                Text(item)
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Theme.orange.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
                .padding(Theme.page)
            }
            .background(Theme.groupedBackground)
            .navigationTitle("告警与保护")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showFlags = false }
                }
            }
        }
    }

    private var rawSheet: some View {
        NavigationStack {
            ScrollView {
                Text(rt?.rawHex.isEmpty == false ? (rt?.rawHex ?? "") : "暂无数据")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.page)
            }
            .background(Theme.groupedBackground)
            .navigationTitle("原始数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showLogs = false }
                }
            }
        }
    }
}
