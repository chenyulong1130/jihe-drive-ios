import SwiftUI

/// 点睛仪表详情页：对齐保护板页的卡片流 ——
/// 设备名 + SOC 环英雄区（电池规格/单次电耗）+ 实时指标网格
/// + 零百测速卡（启停/记录）+ 里程控制 + 诊断弹窗。
struct DianjingDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @ObservedObject var store: DianjingStore
    @State private var showDiagnostics = false
    @State private var showSettings = false
    @State private var speedTestRunning = false
    @State private var copyToast = false

    private var rt: DianjingDebugParams? { store.realtime }
    private var connected: Bool { ble.isConnected }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                headerRow
                heroCard
                metricsGrid
                speedTestCard
                mileageCard
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .background(Theme.groupedBackground)
        .navigationTitle("仪表")
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
            Text(ble.connectedDevice?.displayName ?? "仪表")
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

    // MARK: - Hero（SOC 环 + 电池规格 / 单次电耗）

    private var heroCard: some View {
        let soc = connected ? Double(rt?.soc ?? 0) : 0
        let socColor: Color = soc > 20 ? Theme.green : Theme.orange

        return AppleCard(padding: 0) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .stroke(Theme.surfaceAlt, lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: connected ? CGFloat(min(1, max(0, soc / 100))) : 0)
                        .stroke(
                            socColor,
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
                        Text(connected ? "电量" : "未连接")
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
                        "电池规格",
                        connected && store.batterySeries > 0
                            ? "\(store.batterySeries) 串"
                            : "--",
                        connected && store.batterySeries > 0 ? String(format: "满电 %.1fV", store.batteryFullVoltage) : nil
                    )
                    Rectangle()
                        .fill(Theme.separator.opacity(0.5))
                        .frame(width: 1, height: 34)
                    infoCell(
                        "单次电耗",
                        connected ? String(format: "%.2f", rt?.singleEnergy ?? 0) : "--",
                        connected ? "kWh" : nil
                    )
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 8)
            }
        }
    }

    private func infoCell(_ label: String, _ value: String, _ note: String?) -> some View {
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
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 实时指标网格

    private var metricsGrid: some View {
        let r = rt
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            MetricCard(icon: "bolt.fill", iconColor: Theme.brand, title: "电压",
                       value: connected ? String(format: "%.1f", r?.voltage ?? 0) : "--",
                       unit: "V", valueColor: Theme.brand)
            MetricCard(icon: "battery.25", iconColor: Theme.green, title: "剩余容量",
                       value: connected ? String(format: "%.1f", r?.remainingCapacity ?? 0) : "--",
                       unit: "Ah", valueColor: Theme.green)
            MetricCard(icon: "road.lanes", iconColor: Color(hex: 0x0EA5E9), title: "总里程",
                       value: connected ? String(format: "%.1f", r?.totalMileage ?? 0) : "--",
                       unit: "km", valueColor: Color(hex: 0x0EA5E9))
            MetricCard(icon: "point.topleft.down.curvedto.point.bottomright.up", iconColor: Theme.orange, title: "续航里程",
                       value: connected ? String(format: "%.1f", r?.enduranceMileage ?? 0) : "--",
                       unit: "km", valueColor: Theme.orange)
            MetricCard(icon: "dot.radiowaves.left.and.right", iconColor: Theme.teal, title: "信号",
                       value: connected && store.rssi != 0 ? "\(store.rssi)" : "--",
                       unit: "dBm", valueColor: Theme.teal)
            MetricCard(icon: "cpu", iconColor: Theme.secondary, title: "固件",
                       value: store.versionMain.isEmpty ? "--" : store.versionMain,
                       unit: "", valueColor: Theme.secondary)
        }
    }

    // MARK: - 零百测速

    private var speedTestCard: some View {
        let record = store.speedTest
        return AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("零百测速")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Button {
                        Task {
                            speedTestRunning.toggle()
                            await store.setSpeedTest(start: speedTestRunning)
                        }
                    } label: {
                        Label(speedTestRunning ? "停止" : "开始",
                              systemImage: speedTestRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(speedTestRunning ? Theme.red : Theme.brand, in: Capsule())
                    }
                    .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
                    .disabled(!connected)
                }

                if connected, let record {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        speedTile("0-50 加速", String(format: "%.2f", record.zeroToFifty), "s", Theme.brand)
                        speedTile("0-100 加速", String(format: "%.2f", record.zeroToHundred), "s", Theme.brand)
                        speedTile("最高时速", "\(record.maxSpeed)", "km/h", Theme.red)
                        speedTile("最大电流", String(format: "%.1f", record.maxCurrent), "A", Theme.orange)
                        speedTile("最低电压", String(format: "%.1f", record.minVoltage), "V", Theme.teal)
                        speedTile("静态电压", String(format: "%.1f", record.staticVoltage), "V", Theme.teal)
                        speedTile("最大功率", String(format: "%.2f", record.maxPower), "kW", Color(hex: 0x0EA5E9))
                        speedTile("电池容量", String(format: "%.1f", record.batteryCapacity), "Ah", Theme.green)
                        speedTile("GPS 最高速", "\(record.gpsMaxSpeed)", "km/h", Theme.secondary)
                    }
                } else {
                    Text(connected ? "等待测速记录…" : "连接仪表后显示零百测速记录")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
    }

    private func speedTile(_ label: String, _ value: String, _ unit: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 里程控制

    private var mileageCard: some View {
        AppleCard(padding: 12) {
            HStack(spacing: 10) {
                CircleIconBadge(icon: "road.lanes.circle.fill", color: Theme.orange, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("单次里程")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Text("下发后仪表单次行驶数据归零")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button {
                    Task { await store.clearSingleTrip() }
                } label: {
                    Label("清空单次里程", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                .disabled(!connected)
            }
        }
    }

    // MARK: - 诊断弹窗（带复制）

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
                                StatusTile(icon: "cpu", title: "协议", value: "点睛寄存器协议")
                                StatusTile(icon: "number", title: "设备 ID",
                                           value: store.deviceID.isEmpty ? "--" : store.deviceID)
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
                                Text("5 秒").tag(TimeInterval(5))
                            }
                            .pickerStyle(.segmented)
                            Text("点睛小程序默认 500ms 轮询实时参数。间隔越小数据越实时，耗电也越快。")
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
            .navigationTitle("仪表设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { showSettings = false } }
            }
        }
    }
}
