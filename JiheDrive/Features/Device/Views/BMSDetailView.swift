import SwiftUI

/// 保护板数据页：对齐 Flutter `bms_panel_page` ——
/// 设备名 + SOC 环英雄区（容量概览/电池规格）+ 告警信息条 + 充电状态卡
/// + 图标指标网格 + 动态压差峰值 + 状态信息 + 单体电压网格。
/// 诊断（带复制）与设置（轮询间隔/通道）收进右上角图标弹窗。
struct BMSDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @ObservedObject var store: BMSStore
    @State private var showDiagnostics = false
    @State private var showSettings = false
    @State private var peakDiff: Double = 0
    @State private var copyToast = false

    private var rt: BMSRealtime? { store.realtime }
    private var connected: Bool { ble.isConnected(.bms) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                headerRow
                heroCard
                if connected { warningBar }
                if connected { chargeCard }
                metricsGrid
                diffPeakCard
                cellsSection
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .background(Theme.groupedBackground)
        .navigationTitle("保护板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    store.isPolling ? store.stopPolling() : store.startPolling()
                } label: {
                    Image(systemName: store.isPolling ? "pause.circle" : "play.circle")
                }
                Button {
                    showDiagnostics = true
                } label: {
                    Image(systemName: "waveform.path.ecg")
                }
                .accessibilityLabel("诊断")
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
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
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
    }

    private var flowColor: Color {
        guard connected, let rt else { return Theme.secondary }
        switch rt.flowLabel {
        case "充电中": return Theme.green
        case "放电中": return Color(hex: 0x0EA5E9)
        case "均衡中": return Theme.orange
        default: return Theme.secondary
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(ble.connectedDevice(for: .bms)?.displayName ?? "保护板")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.label)
                .lineLimit(1)
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
                        .stroke(Theme.surfaceAlt, lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: connected ? CGFloat(min(1, max(0, soc / 100))) : 0)
                        .stroke(
                            flowColor,
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
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
                        Text(statusText)
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

    /// 未连接 → 「未连接」；静置 → 「未充电状态」
    private var statusText: String {
        if !connected { return "未连接" }
        return rt?.flowLabel ?? "未充电状态"
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

    // MARK: - 告警信息条（连接时常驻：正常绿条 / 告警红橙列表）

    private var alarmEntries: [(text: String, critical: Bool)] {
        guard let rt else { return [] }
        let names: [String]
        if !rt.protectNames.isEmpty {
            names = rt.protectNames
        } else {
            names = BMSProtocol.flagNames(rt.warningFlags, table: BMSProtocol.warningFlags)
                + BMSProtocol.flagNames(rt.protectFlags, table: BMSProtocol.protectFlags)
        }
        return names.map { ($0, isCriticalAlarm($0)) }
    }

    /// 状态提醒类（充满/放空标志等非故障位）用橙色，其余故障/保护一律红色
    private func isCriticalAlarm(_ name: String) -> Bool {
        let noticeKeywords = ["标志", "SOC低", "储运", "锁状态", "硬件检测"]
        return !noticeKeywords.contains(where: { name.contains($0) })
    }

    @ViewBuilder
    private var warningBar: some View {
        let entries = alarmEntries
        if entries.isEmpty {
            AppleCard(padding: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.green)
                    Text("电池状态正常")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.green)
                    Spacer()
                }
            }
        } else {
            AppleCard(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("告警信息")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.label)
                    ForEach(entries.indices, id: \.self) { index in
                        alarmBar(entries[index].text, critical: entries[index].critical)
                    }
                }
            }
        }
    }

    private func alarmBar(_ text: String, critical: Bool) -> some View {
        let color: Color = critical ? Theme.red : Theme.orange
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 充电状态卡（连接时常驻）

    private var chargeCard: some View {
        let charging = rt?.flowLabel == "充电中"
        let power = abs(rt?.power ?? 0)
        let remain = rt?.remainingCapacity ?? 0
        let full = rt?.physicalCapacity ?? 0
        let current = abs(rt?.current ?? 0)
        let estFull: String = {
            guard charging, full > 0, full > remain, current > 0.1 else { return "--" }
            return formatDuration((full - remain) / current)
        }()

        return AppleCard(padding: 14) {
            HStack(spacing: 12) {
                CircleIconBadge(icon: "bolt.fill", color: flowColor, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(charging ? "预计充满" : "电池状态")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    Text(charging ? estFull : statusText)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(charging ? "充电功率" : "实时功率")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    Text(connected ? "\(power) W" : "--")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(flowColor)
                }
            }
        }
    }

    private func formatDuration(_ hours: Double) -> String {
        guard hours.isFinite, hours > 0 else { return "--" }
        let totalMinutes = Int((hours * 60).rounded())
        guard totalMinutes > 0 else { return "--" }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h == 0 { return "\(m) 分" }
        if m == 0 { return "\(h) 小时" }
        return "\(h) 小时 \(m) 分"
    }

    // MARK: - 图标指标网格

    private var metricsGrid: some View {
        let r = rt
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            MetricCard(icon: "battery.100", iconColor: Theme.brand, title: "总电压",
                       value: fmt(r?.totalVoltage, "%.2f"), unit: "V", valueColor: Theme.brand)
            MetricCard(icon: "gauge", iconColor: flowColor, title: "实时电流",
                       value: connected ? String(format: "%.1f", abs(r?.current ?? 0)) : "--",
                       unit: "A", valueColor: flowColor)
            MetricCard(icon: "bolt.fill", iconColor: Color(hex: 0x0EA5E9), title: "实时功率",
                       value: connected ? "\(abs(r?.power ?? 0))" : "--",
                       unit: "W", valueColor: Color(hex: 0x0EA5E9))
            MetricCard(icon: "arrow.up.circle.fill", iconColor: Theme.red, title: "最高电压",
                       value: (connected && (r?.highestCell ?? 0) > 0) ? fmt(r?.highestCell, "%.3f") : "--",
                       unit: "V", valueColor: Theme.red)
            MetricCard(icon: "arrow.down.circle.fill", iconColor: Theme.teal, title: "最低电压",
                       value: (connected && (r?.lowestCell ?? 0) > 0) ? fmt(r?.lowestCell, "%.3f") : "--",
                       unit: "V", valueColor: Theme.teal)
            MetricCard(icon: "waveform.path", iconColor: Theme.orange, title: "实时压差",
                       value: fmt(r?.voltageDiff, "%.3f"), unit: "V", valueColor: Theme.orange)
            MetricCard(icon: "thermometer", iconColor: Theme.orange, title: "MOS 温度",
                       value: connected ? String(format: "%.1f", Double(r?.mosTemperature ?? 0)) : "--",
                       unit: "℃", valueColor: Theme.orange)
            MetricCard(icon: "thermometer", iconColor: Color(hex: 0xF59E0B), title: "电芯温度",
                       value: connected ? (r?.temperatures.first.map { String(format: "%.1f", Double($0)) } ?? "--") : "--",
                       unit: "℃", valueColor: Color(hex: 0xF59E0B))
            MetricCard(icon: "arrow.2.circlepath", iconColor: Theme.green, title: "循环次数",
                       value: connected ? "\(r?.cycleCount ?? Int(r?.cycleCapacity ?? 0))" : "--",
                       unit: "次", valueColor: Theme.green)
        }
    }

    private func fmt(_ value: Double?, _ format: String) -> String {
        guard connected, let value else { return "--" }
        return String(format: format, value)
    }

    // MARK: - 动态压差峰值

    private var diffPeakCard: some View {
        AppleCard(padding: 12) {
            HStack(spacing: 10) {
                CircleIconBadge(icon: "waveform.path.ecg", color: Theme.orange, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("动态压差峰值")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Text("本次会话历史最大单体压差")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Text(connected && peakDiff > 0 ? String(format: "%.3f V", peakDiff) : "--")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(hex: 0xF5A623))
            }
        }
    }

    // MARK: - 状态信息

    private var statusCard: some View {
        let r = rt
        // 与 heroCard 的 flowColor 同一套语义：充绿 / 放蓝 / 均衡橙
        let flowTint: Color = {
            guard connected else { return Theme.secondary }
            switch r?.flowLabel ?? "" {
            case "充电中": return Theme.green
            case "放电中": return Color(hex: 0x0EA5E9)
            case "均衡中": return Theme.orange
            default: return Theme.label
            }
        }()
        let soh = connected ? (r?.soh ?? 0) : 0
        let dischargeOn = (r?.dischargeMOS ?? 0) == 1
        let chargeOn = (r?.chargeMOS ?? 0) == 1
        let balancing = (r?.balanceState ?? 0) == 1
        let offTint = Theme.tertiary

        return AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("状态信息")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.label)
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    StatusTile(icon: "bolt.fill", title: "电池状态",
                               value: connected ? (r?.flowLabel ?? "—") : "未连接",
                               valueColor: flowTint)
                    StatusTile(icon: "battery.100.fill", title: "电池类型",
                               value: r?.typeLabel ?? "--")
                    StatusTile(icon: "square.grid.2x2.fill", title: "电芯串数",
                               value: (r?.cellCount ?? 0) > 0 ? "\(r?.cellCount ?? 0) 串" : "--")
                    StatusTile(icon: "heart.fill", title: "SOH",
                               value: soh > 0 ? "\(soh)%" : "--",
                               valueColor: soh <= 0 ? Theme.label : (soh >= 80 ? Theme.green : Theme.orange))
                    StatusTile(icon: "clock.fill", title: "运行时间",
                               value: connected ? runningTimeText(r?.runningTime ?? 0) : "--")
                    StatusTile(icon: "arrow.down.circle.fill", title: "放电 MOS",
                               value: dischargeOn ? "开" : "关",
                               valueColor: dischargeOn ? Theme.green : offTint)
                    StatusTile(icon: "arrow.up.circle.fill", title: "充电 MOS",
                               value: chargeOn ? "开" : "关",
                               valueColor: chargeOn ? Theme.green : offTint)
                    StatusTile(icon: "arrow.left.arrow.right", title: "均衡",
                               value: balancing ? "均衡中" : "关闭",
                               valueColor: balancing ? Theme.orange : offTint)
                }
            }
        }
    }

    private func runningTimeText(_ seconds: UInt32) -> String {
        let minutes = Int(seconds) / 60
        if minutes < 1 { return "<1 分钟" }
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest > 0 ? "\(hours) 小时 \(rest) 分" : "\(hours) 小时"
        }
        return "\(hours / 24) 天 \(hours % 24) 小时"
    }

    // MARK: - 单体电压（摘要 + 4 列网格）

    private var cellsSection: some View {
        let cells = rt?.cellVoltages ?? []
        let hi = cells.max() ?? 0
        let lo = cells.min() ?? 0
        let avg = cells.isEmpty ? 0 : cells.reduce(0, +) / Double(cells.count)
        return AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("单体电压")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Text(connected ? "\(cells.count)串" : "—")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }

                if connected, !cells.isEmpty {
                    HStack(spacing: 8) {
                        cellSummary("最高", String(format: "%.3f", hi), Theme.red)
                        cellSummary("最低", String(format: "%.3f", lo), Theme.teal)
                        cellSummary("平均", String(format: "%.3f", avg), Theme.brand)
                        cellSummary("压差", String(format: "%.3f", hi - lo), Theme.orange)
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(cells.indices, id: \.self) { index in
                            cellChip(number: index + 1, value: cells[index], hi: hi, lo: lo)
                        }
                    }
                } else {
                    Text(connected ? "等待单体数据…" : "连接保护板后显示单体电压")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
    }

    private func cellSummary(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    private func cellChip(number: Int, value: Double, hi: Double, lo: Double) -> some View {
        let isMax = hi != lo && abs(value - hi) < 0.0005
        let isMin = hi != lo && abs(value - lo) < 0.0005
        let accent: Color = isMax ? Theme.red : isMin ? Theme.teal : Theme.label
        return VStack(alignment: .leading, spacing: 6) {
            Text("#\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: "%.3f", value))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("V")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    (isMax || isMin) ? accent.opacity(0.5) : Theme.separator.opacity(0.6),
                    lineWidth: 1
                )
        )
    }

    // MARK: - 诊断弹窗（带复制）

    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if connected { statusCard }

                    AppleCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            ConnectionBannerTile(
                                connected: connected,
                                deviceName: ble.connectedDevice(for: .bms)?.displayName ?? ""
                            )
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                spacing: 8
                            ) {
                                StatusTile(icon: "puzzlepiece.fill", title: "协议品牌", value: store.brand.title)
                                StatusTile(icon: "dot.radiowaves.left.and.right", title: "通道状态",
                                           value: store.channelStatus,
                                           valueColor: store.channelStatus.contains("正常") || store.channelStatus.contains("可用") ? Theme.green : Theme.orange)
                                StatusTile(icon: "timer", title: "轮询间隔",
                                           value: String(format: "%.1f 秒", store.pollInterval))
                                StatusTile(icon: "arrow.clockwise.circle.fill", title: "轮询",
                                           value: store.isPolling ? "进行中" : "已暂停",
                                           valueColor: store.isPolling ? Theme.green : Theme.secondary)
                            }
                        }
                    }

                    LogPanel(title: "通信日志", logs: store.logs)

                    Button {
                        copyToPasteboard(store.logs.joined(separator: "\n"), fallback: "暂无日志")
                    } label: {
                        Label("复制通信日志", systemImage: "doc.on.doc")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .foregroundStyle(Theme.brand)
                            .background(Theme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))

                    AppleCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("原始数据")
                                .font(Theme.headline)
                                .foregroundStyle(Theme.label)
                            Text(rt?.rawHex.isEmpty == false ? (rt?.rawHex ?? "") : "暂无数据")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Button {
                        copyToPasteboard(rt?.rawHex ?? "", fallback: "暂无数据")
                    } label: {
                        Label("复制原始数据", systemImage: "doc.on.doc")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .foregroundStyle(Theme.brand)
                            .background(Theme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Theme.groupedBackground)
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { showDiagnostics = false } }
            }
            .overlay(alignment: .bottom) {
                if copyToast {
                    Text("已复制到剪贴板")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Theme.label.opacity(0.85), in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: copyToast)
        }
    }

    private func copyToPasteboard(_ text: String, fallback: String) {
        UIPasteboard.general.string = text.isEmpty ? fallback : text
        copyToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            copyToast = false
        }
    }

    // MARK: - 设置弹窗

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    AppleCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("轮询间隔")
                                .font(Theme.headline)
                                .foregroundStyle(Theme.label)
                            Picker("轮询间隔", selection: $store.pollInterval) {
                                Text("0.5 秒").tag(TimeInterval(0.5))
                                Text("1 秒").tag(TimeInterval(1))
                                Text("2 秒").tag(TimeInterval(2))
                                Text("3 秒").tag(TimeInterval(3))
                                Text("5 秒").tag(TimeInterval(5))
                            }
                            .pickerStyle(.segmented)
                            Text("间隔越小数据越实时，耗电也越快。改完立即生效，下次进入详情页沿用。")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if store.brand == .ant {
                        AppleCard(padding: 14) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("通信通道")
                                    .font(Theme.headline)
                                    .foregroundStyle(Theme.label)
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

                    Text("彦阳保护板固定使用 FFE1/FFE2 通道，无需通道诊断。")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Theme.groupedBackground)
            .navigationTitle("保护板设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { showSettings = false } }
            }
        }
    }
}
