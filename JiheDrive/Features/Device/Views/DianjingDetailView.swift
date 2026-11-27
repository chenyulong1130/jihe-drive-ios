import SwiftUI

/// 点睛仪表详情页（对齐 Flutter 仪表环 + 点睛小程序信息结构）：
/// 270° 渐变仪表环英雄区（电量进度 + 0/50/100 刻度，中心 SOC + 电压）
/// + 里程大字卡（续航/总里程/单次电耗）+ 零百测速（启停/记录）
/// + 里程控制 + 诊断/设置。寄存器 193 实时参数 500ms 轮询。
struct DianjingDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @ObservedObject var store: DianjingStore
    @State private var showDiagnostics = false
    @State private var showSettings = false
    @State private var speedTestRunning = false
    @State private var copyToast = false

    private var rt: DianjingDebugParams? { store.realtime }
    private var connected: Bool { ble.isConnected }

    static let gaugeStart = Angle(degrees: 135)
    static let gaugeSweep = Angle(degrees: 270)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                headerRow
                gaugeHeroCard
                mileageCard
                speedTestCard
                mileageControlCard
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

    // MARK: - 仪表环英雄区（对齐 Flutter SpeedGauge：270° 渐变弧 + 端点光点 + 刻度）

    private var gaugeHeroCard: some View {
        let soc = connected ? Double(rt?.soc ?? 0) : 0
        let progress = min(1, max(0, soc / 100))
        let tipAngle = Self.gaugeStart + Angle(degrees: Self.gaugeSweep.degrees * progress)

        return AppleCard(padding: 16) {
            VStack(spacing: 0) {
                ZStack {
                    // 底弧
                    GaugeArc(progress: 1)
                        .stroke(Theme.surfaceAlt, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    // 渐变进度弧
                    GaugeArc(progress: progress)
                        .stroke(
                            AngularGradient(
                                colors: [Color(hex: 0x17B3A6), Color(hex: 0x2D7BF6), Color(hex: 0x5856D6)],
                                center: .center,
                                startAngle: Self.gaugeStart,
                                endAngle: Angle(degrees: Self.gaugeStart.degrees + Self.gaugeSweep.degrees)
                            ),
                            style: StrokeStyle(lineWidth: 18, lineCap: .round)
                        )
                        .animation(.easeOut(duration: 0.4), value: soc)
                    // 端点光点（弧半径 = 236/2 - 9 = 109）
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .shadow(color: Color(hex: 0x2D7BF6).opacity(0.5), radius: 7)
                        .position(
                            x: 118 + cos(tipAngle.radians) * 109,
                            y: 118 + sin(tipAngle.radians) * 109
                        )
                        .animation(.easeOut(duration: 0.4), value: soc)

                    // 刻度 0 / 50 / 100
                    gaugeTick(0, value: 0)
                    gaugeTick(0.5, value: 50)
                    gaugeTick(1, value: 100)

                    VStack(spacing: 6) {
                        if connected {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("\(Int(soc))")
                                    .font(.system(size: 62, weight: .light, design: .rounded))
                                    .foregroundStyle(Theme.label)
                                    .monospacedDigit()
                                Text("%")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(Theme.secondary)
                            }
                        } else {
                            Text("--")
                                .font(.system(size: 54, weight: .light, design: .rounded))
                                .foregroundStyle(Theme.label)
                        }
                        Text("电量")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                        if connected {
                            Text(String(format: "%.1f V", rt?.voltage ?? 0))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.brand)
                        }
                    }
                }
                .frame(width: 236, height: 236)
                .padding(.vertical, 14)

                Divider().opacity(0.6)

                HStack(spacing: 0) {
                    infoCell(
                        "剩余容量",
                        connected ? String(format: "%.1f", rt?.remainingCapacity ?? 0) : "--",
                        connected ? "Ah" : nil
                    )
                    Rectangle()
                        .fill(Theme.separator.opacity(0.5))
                        .frame(width: 1, height: 34)
                    infoCell(
                        "电池规格",
                        connected && store.batterySeries > 0 ? "\(store.batterySeries) 串" : "--",
                        connected && store.batterySeries > 0 ? String(format: "满电 %.1fV", store.batteryFullVoltage) : nil
                    )
                    Rectangle()
                        .fill(Theme.separator.opacity(0.5))
                        .frame(width: 1, height: 34)
                    infoCell(
                        "信号",
                        connected && store.rssi != 0 ? "\(store.rssi)" : "--",
                        connected && store.rssi != 0 ? "dBm" : nil
                    )
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 2)
            }
        }
    }

    /// 刻度数字：0 在左下（135°）、50 在正上方、100 在右下（45°）
    private func gaugeTick(_ progress: Double, value: Int) -> some View {
        let angle = Self.gaugeStart + Angle(degrees: Self.gaugeSweep.degrees * progress)
        let radius: CGFloat = 100
        return Text("\(value)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.tertiary)
            .position(
                x: 118 + cos(angle.radians) * radius,
                y: 118 + sin(angle.radians) * radius
            )
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

    // MARK: - 里程大字卡

    private var mileageCard: some View {
        AppleCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("行驶里程")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Spacer()
                    if connected {
                        Text("实时刷新 · 0.5s")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                    }
                }

                // 续航里程主数字（对齐 Flutter 大字英雄区）
                VStack(alignment: .leading, spacing: 2) {
                    Text("续航里程")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(connected ? String(format: "%.1f", rt?.enduranceMileage ?? 0) : "--")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.brand)
                            .monospacedDigit()
                        Text("km")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.secondary)
                    }
                }

                Divider().opacity(0.6)

                HStack(spacing: 0) {
                    mileageCell("总里程", connected ? String(format: "%.1f", rt?.totalMileage ?? 0) : "--", "km")
                    Rectangle()
                        .fill(Theme.separator.opacity(0.5))
                        .frame(width: 1, height: 34)
                    mileageCell("单次电耗", connected ? String(format: "%.2f", rt?.singleEnergy ?? 0) : "--", "kWh")
                }
            }
        }
    }

    private func mileageCell(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var mileageControlCard: some View {
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

// MARK: - 仪表环形状

/// 270° 圆弧（135° 起笔 → 45° 收笔），progress 控制扫过比例
struct GaugeArc: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 9
        path.addArc(
            center: center,
            radius: radius,
            startAngle: DianjingDetailView.gaugeStart,
            endAngle: DianjingDetailView.gaugeStart
                + Angle(degrees: DianjingDetailView.gaugeSweep.degrees * progress),
            clockwise: false
        )
        return path
    }
}

