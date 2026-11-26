import SwiftUI

/// BMS 专属页：电量环形仪表 + 电压电流主视觉 + 单体电压条 + 保护/告警位 + 通道诊断
struct BMSDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @ObservedObject var store: BMSStore
    @State private var showFlags = false
    @State private var showLogs = false

    private var realtime: BMSRealtime? { store.realtime }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                heroCard
                SectionHeader("实时数据")
                metricsGrid
                SectionHeader("单体电压")
                cellsCard
                SectionHeader("状态与保护")
                statusCard
                SectionHeader("通信通道")
                channelCard
                SectionHeader("自定义指令")
                commandCard
                LogPanel(title: "通信日志", logs: store.logs)
                    .padding(.top, 8)
                HStack(spacing: 12) {
                    Button { showLogs = true } label: {
                        Label("原始报文", systemImage: "doc.text.magnifyingglass")
                            .font(Theme.footnote)
                    }
                    .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                    Spacer()
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, Theme.page)
            .padding(.bottom, 40)
        }
        .background(Theme.groupedBackground)
        .navigationTitle("BMS 保护板")
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
        .sheet(isPresented: $showFlags) { flagsSheet }
        .sheet(isPresented: $showLogs) { rawSheet }
    }

    // MARK: - 主视觉

    private var heroCard: some View {
        let rt = realtime
        return AppleCard(padding: 16) {
            VStack(spacing: 16) {
                HStack {
                    Label("电池状态", systemImage: "battery.100.bolt")
                        .font(Theme.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    StatusPill(
                        text: store.channelStatus,
                        color: store.channelStatus.contains("正常") || store.channelStatus.contains("可用") ? .green : .orange
                    )
                }

                HStack(spacing: 22) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.20), lineWidth: 13)
                        Circle()
                            .trim(from: 0, to: CGFloat(min(100, max(0, Double(rt?.soc ?? 0)))) / 100)
                            .stroke(
                                LinearGradient(colors: [.green, .yellow, .orange], startPoint: .bottom, endPoint: .top),
                                style: StrokeStyle(lineWidth: 13, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text("\(rt?.soc ?? 0)")
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("SOC %")
                                .font(Theme.caption)
                                .foregroundStyle(Color.white.opacity(0.75))
                        }
                    }
                    .frame(width: 122, height: 122)

                    VStack(alignment: .leading, spacing: 10) {
                        heroLine("总电压", String(format: "%.2f", rt?.totalVoltage ?? 0), "V")
                        heroLine("电流", String(format: "%.1f", rt?.current ?? 0), "A")
                        heroLine("功率", "\(rt?.power ?? 0)", "W")
                    }
                    Spacer(minLength: 0)
                }

                Divider().background(Color.white.opacity(0.2))

                HStack {
                    Text(BMSProtocol.batteryStateText(rt?.state ?? 0))
                        .font(Theme.callout)
                        .foregroundStyle(.white)
                    Spacer()
                    Text("权限 \(rt?.auth ?? 0) 级 · SOH \(rt?.soh ?? 0)%")
                        .font(Theme.caption)
                        .foregroundStyle(Color.white.opacity(0.8))
                }
            }
        }
        .background(
            LinearGradient(
                colors: [Color(hex: 0x1D2B44), Color(hex: 0x101A2C)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private func heroLine(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(Color.white.opacity(0.65))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(unit)
                    .font(Theme.caption)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
    }

    // MARK: - 指标

    private var metricsGrid: some View {
        let rt = realtime
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MetricTile(title: "最高单体", value: String(format: "%.3f", rt?.highestCell ?? 0), unit: "V", accent: .orange)
            MetricTile(title: "最低单体", value: String(format: "%.3f", rt?.lowestCell ?? 0), unit: "V", accent: .teal)
            MetricTile(title: "压差", value: String(format: "%.3f", rt?.voltageDiff ?? 0), unit: "V", accent: (rt?.voltageDiff ?? 0) > 0.02 ? .red : .green)
            MetricTile(title: "平均单体", value: String(format: "%.3f", rt?.averageCell ?? 0), unit: "V")
            MetricTile(title: "MOS 温度", value: "\(rt?.mosTemperature ?? 0)", unit: "℃")
            MetricTile(title: "剩余容量", value: String(format: "%.2f", rt?.remainingCapacity ?? 0), unit: "Ah", accent: .indigo)
            MetricTile(title: "物理容量", value: String(format: "%.2f", rt?.physicalCapacity ?? 0), unit: "Ah")
            MetricTile(title: "充电剩余", value: "\(rt?.chargeRemainingMinutes ?? 0)", unit: "min")
        }
    }

    private var cellsCard: some View {
        let rt = realtime
        return AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(rt?.cellCount ?? 0) 串")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Text("温度 \(rt?.temperatures.map { String($0) }.joined(separator: "/") ?? "—") ℃")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }
                if let rt, !rt.cellVoltages.isEmpty {
                    ForEach(rt.cellVoltages.indices, id: \.self) { index in
                        let voltage = rt.cellVoltages[index]
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.tertiary)
                                .frame(width: 16, alignment: .trailing)
                            GeometryReader { geo in
                                let ratio = CGFloat(min(1, max(0, (voltage - 2.5) / 1.7)))
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.surfaceAlt)
                                    Capsule()
                                        .fill(ratio > 0.85 ? Theme.green : ratio < 0.35 ? Theme.red : Theme.brand)
                                        .frame(width: geo.size.width * ratio)
                                    if rt.cellBalance.indices.contains(index), rt.cellBalance[index] > 0 {
                                        Capsule()
                                            .strokeBorder(Theme.orange, lineWidth: 1.5)
                                    }
                                }
                            }
                            .frame(height: 9)
                            Text(String(format: "%.3f", voltage))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                } else {
                    Text("等待实时数据…")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
    }

    private var statusCard: some View {
        let rt = realtime
        let warnings = BMSProtocol.flagNames(rt?.warningFlags ?? 0, table: BMSProtocol.warningFlags)
        let protections = BMSProtocol.flagNames(rt?.protectFlags ?? 0, table: BMSProtocol.protectFlags)
        return AppleCard(padding: 14) {
            VStack(spacing: 12) {
                HStack {
                    Text("告警 \(warnings.count)")
                        .font(Theme.footnote)
                        .foregroundStyle(warnings.isEmpty ? Theme.green : Theme.red)
                    Spacer()
                    Text("保护 \(protections.count)")
                        .font(Theme.footnote)
                        .foregroundStyle(protections.isEmpty ? Theme.green : Theme.orange)
                }
                Button { showFlags = true } label: {
                    HStack {
                        Text(warnings.isEmpty ? "无活动告警" : warnings.prefix(2).joined(separator: "、"))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 16) {
                    Label("放电 MOS \(rt?.dischargeMOS ?? 0)", systemImage: "bolt")
                    Label("充电 MOS \(rt?.chargeMOS ?? 0)", systemImage: "plug")
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                Text(BMSProtocol.batteryTypeText(rt?.batteryType ?? 0))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

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
                        color: store.channelStatus.contains("正常") || store.channelStatus.contains("可用") ? .green : .orange
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
                Text("依次探测 FFE1 / FFF3-FFF4 / FFF5-FFF6，命中实时帧后自动锁定通道。")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var commandCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("功能码 / 地址 / 数据均为十六进制，响应码 0x61 会显示在日志中。")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
                HStack(spacing: 8) {
                    TextField("功能码", text: $store.customFuncHex)
                    TextField("地址", text: $store.customAddressHex)
                    TextField("数据", text: $store.customDataHex)
                }
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                HStack {
                    Text("应答：\(store.lastAck.isEmpty ? "—" : store.lastAck)")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Button {
                        Task { await store.sendCustomCommand() }
                    } label: {
                        Label("发送", systemImage: "paperplane")
                            .font(Theme.footnote)
                    }
                    .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                }
            }
        }
    }

    private var flagsSheet: some View {
        let rt = realtime
        let warnings = BMSProtocol.flagNames(rt?.warningFlags ?? 0, table: BMSProtocol.warningFlags)
        let protections = BMSProtocol.flagNames(rt?.protectFlags ?? 0, table: BMSProtocol.protectFlags)
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader("告警位")
                    flagList(warnings, empty: "无活动告警", color: Theme.red)
                    SectionHeader("保护位")
                    flagList(protections, empty: "无活动保护", color: Theme.orange)
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 30)
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

    private func flagList(_ items: [String], empty: String, color: Color) -> some View {
        Group {
            if items.isEmpty {
                Text(empty)
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.green)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(Theme.caption)
                            .foregroundStyle(color)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(color.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
    }

    private var rawSheet: some View {
        NavigationStack {
            ScrollView {
                Text(realtime?.rawHex ?? "暂无数据")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.page)
            }
            .background(Theme.groupedBackground)
            .navigationTitle("0x11 原始 DATA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showLogs = false }
                }
            }
        }
    }
}
