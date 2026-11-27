import SwiftUI

/// 蚂蚁充电机详情页：对齐保护板页的卡片流 ——
/// 设备名 + 充电状态英雄区 + 实时指标网格 + 保护信息 + 历史日志 + 诊断（含自定义帧调试）。
/// 说明：充电机专属寄存器表在服务端协议 JSON 下发，实时字段优先按蚂蚁 0x11
/// 通用布局解析，不兼容时保留原始帧（诊断面板可复制，供联调补表）。
struct ChargerDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @ObservedObject var store: ChargerStore
    @State private var showDiagnostics = false
    @State private var showSettings = false
    @State private var copyToast = false

    private var rt: ChargerRealtime? { store.realtime }
    private var connected: Bool { ble.isConnected }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                headerRow
                heroCard
                if connected { protectionCard }
                metricsGrid
                historyCard
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .background(Theme.groupedBackground)
        .navigationTitle("充电机")
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
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(ble.connectedDevice?.displayName ?? "充电机")
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

    /// 实时数据是否已解析出结构化字段
    private var hasParsedRealtime: Bool { connected && (rt?.parsed ?? false) }

    // MARK: - Hero（充电状态 + 功率概览）

    private var heroCard: some View {
        let charging = hasParsedRealtime && abs(rt?.current ?? 0) > 0.1
        let power = abs(rt?.power ?? 0)

        return AppleCard(padding: 0) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .stroke(Theme.surfaceAlt, lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: hasParsedRealtime ? CGFloat(min(1, max(0, Double(rt?.soc ?? 0) / 100))) : 0)
                        .stroke(
                            charging ? Theme.green : Theme.secondary,
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.45), value: rt?.soc ?? 0)

                    VStack(spacing: 6) {
                        Image(systemName: charging ? "bolt.fill" : "powerplug.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(charging ? Theme.green : Theme.secondary)
                        Text(charging ? "充电中" : (connected ? "待机" : "未连接"))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Theme.label)
                        if hasParsedRealtime, (rt?.soc ?? 0) > 0 {
                            Text("电量 \(rt?.soc ?? 0)%")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }
                .frame(width: 180, height: 180)
                .padding(.top, 22)
                .padding(.bottom, 22)

                Divider().opacity(0.6)

                HStack(spacing: 0) {
                    infoCell("充电功率", hasParsedRealtime ? "\(power)" : "--", hasParsedRealtime ? "W" : nil)
                    Rectangle()
                        .fill(Theme.separator.opacity(0.5))
                        .frame(width: 1, height: 34)
                    infoCell("端口电压", hasParsedRealtime ? String(format: "%.1f", rt?.voltage ?? 0) : "--", hasParsedRealtime ? "V" : nil)
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

    // MARK: - 保护信息条

    private var protectionEntries: [String] {
        guard let flags = store.latestProtectionFlags, flags != 0 else { return [] }
        return BMSProtocol.flagNames(flags, table: ChargerHistoryRecord.protectionFlags)
    }

    @ViewBuilder
    private var protectionCard: some View {
        let entries = protectionEntries
        if entries.isEmpty {
            AppleCard(padding: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.green)
                    Text("无保护触发")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.green)
                    Spacer()
                }
            }
        } else {
            AppleCard(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("保护信息")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.label)
                    ForEach(entries, id: \.self) { name in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.red)
                            Text(name)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.red)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Theme.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: - 实时指标网格

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            MetricCard(icon: "arrow.down.circle.fill", iconColor: Theme.brand, title: "输出电压",
                       value: hasParsedRealtime ? String(format: "%.1f", rt?.chargerVoltage ?? 0) : "--",
                       unit: "V", valueColor: Theme.brand)
            MetricCard(icon: "gauge", iconColor: Color(hex: 0x0EA5E9), title: "输出电流",
                       value: hasParsedRealtime ? String(format: "%.1f", rt?.chargerCurrent ?? 0) : "--",
                       unit: "A", valueColor: Color(hex: 0x0EA5E9))
            MetricCard(icon: "bolt.fill", iconColor: Theme.orange, title: "实时功率",
                       value: hasParsedRealtime ? "\(abs(rt?.power ?? 0))" : "--",
                       unit: "W", valueColor: Theme.orange)
            MetricCard(icon: "thermometer", iconColor: Theme.orange, title: "MOS 温度",
                       value: hasParsedRealtime ? String(format: "%.1f", Double(rt?.mosTemperature ?? 0)) : "--",
                       unit: "℃", valueColor: Theme.orange)
            MetricCard(icon: "thermometer", iconColor: Color(hex: 0xF59E0B), title: "电芯温度",
                       value: hasParsedRealtime ? String(format: "%.1f", Double(rt?.cellTemperature ?? 0)) : "--",
                       unit: "℃", valueColor: Color(hex: 0xF59E0B))
            MetricCard(icon: "battery.100", iconColor: Theme.green, title: "电池电压",
                       value: hasParsedRealtime ? String(format: "%.2f", rt?.voltage ?? 0) : "--",
                       unit: "V", valueColor: Theme.green)
        }
    }

    // MARK: - 历史日志

    private var historyCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("历史日志")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Text(store.historyStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                    Button {
                        Task { await store.fetchHistory() }
                    } label: {
                        Label("读取", systemImage: "arrow.down.circle")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                    .disabled(!connected)
                }

                if store.historyRecords.isEmpty {
                    Text(connected
                         ? "读取充电机历史监控数据（输入/输出电压电流、保护记录、阶段变化）"
                         : "连接充电机后读取历史日志")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(store.historyRecords.prefix(30)) { record in
                            historyRow(record)
                        }
                    }
                    if store.historyRecords.count > 30 {
                        Text("仅显示最近 30 条，共 \(store.historyRecords.count) 条")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ record: ChargerHistoryRecord) -> some View {
        switch record {
        case .measure(let inputCurrent, let inputVoltage, let outputVoltage, let outputCurrent):
            HStack(spacing: 10) {
                CircleIconBadge(icon: "waveform.path.ecg", color: Theme.brand, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("测量记录")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Text(String(format: "输入 %.1fV / %.1fA · 输出 %.1fV / %.1fA", inputVoltage, inputCurrent, outputVoltage, outputCurrent))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        case .protection(let flags):
            let names = record.protectionNames
            HStack(spacing: 10) {
                CircleIconBadge(icon: names.isEmpty ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                                color: names.isEmpty ? Theme.green : Theme.red, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(names.isEmpty ? "保护记录（无触发位）" : "保护记录")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(names.isEmpty ? Theme.label : Theme.red)
                    Text(names.isEmpty
                         ? String(format: "标志位 0x%016llX", flags)
                         : names.joined(separator: " / "))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        case .stageChange(let chargeStage, let workStatus):
            HStack(spacing: 10) {
                CircleIconBadge(icon: "arrow.triangle.swap", color: Theme.orange, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("阶段变化")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Text("充电阶段 \(chargeStage) · 工作状态 \(workStatus)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    // MARK: - 诊断弹窗（含自定义帧调试）

    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    AppleCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            ConnectionBannerTile(
                                connected: connected,
                                deviceName: ble.connectedDevice?.displayName ?? ""
                            )
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                spacing: 8
                            ) {
                                StatusTile(icon: "cpu", title: "协议", value: "蚂蚁新协议引擎")
                                StatusTile(icon: "number", title: "通讯地址",
                                           value: String(format: "0x%02X", store.address))
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

                    customCommandCard
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

    /// 自定义帧调试：FUNC / 寄存器 / 数据，联调补寄存器表用
    private var customCommandCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("自定义指令")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.label)
                HStack(spacing: 8) {
                    hexField("FUNC", $store.customFuncHex)
                    hexField("寄存器", $store.customRegisterHex)
                    hexField("数据", $store.customDataHex)
                }
                Button {
                    Task { await store.sendCustomCommand() }
                } label: {
                    Label("发送", systemImage: "paperplane.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .foregroundStyle(.white)
                        .background(Theme.brand, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                }
                .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                .disabled(!connected)
                Text("帧格式自动按新协议引擎组包（CRC 小端 / 寄存器小端 / 帧头 7E+通讯地址 / 帧尾 AA55）。读帧数据留空时 LEN=0xF5。")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func hexField(_ label: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            TextField("", text: binding)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .padding(8)
                .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                            Text("间隔越小数据越实时，耗电也越快。改完立即生效。")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    AppleCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("通讯地址")
                                .font(Theme.headline)
                                .foregroundStyle(Theme.label)
                            TextField("默认 0xA1，可填自定义地址（如 C1）", text: $store.customAddressHex)
                                .font(.system(size: 14, design: .monospaced))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                                .padding(10)
                                .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text("帧头第二字节：默认 A1（7E A1 …）。设备设置过自定义通讯地址时填新地址（帧头变为 7E xx …）。")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Theme.groupedBackground)
            .navigationTitle("充电机设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { showSettings = false } }
            }
        }
    }
}
