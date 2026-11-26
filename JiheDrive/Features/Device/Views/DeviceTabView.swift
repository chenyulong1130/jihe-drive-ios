import SwiftUI

/// 设备 Tab 入口：未连接先展示设备列表与连接弹窗，连接后按设备类型进入各自专属详情页
struct DeviceTabView: View {
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.activeMainTab) private var activeMainTab

    @StateObject private var ble = DeviceBLEManager.shared
    @StateObject private var session = DeviceSession.shared
    @StateObject private var bmsStore = BMSStore()
    @StateObject private var motorStore = MotorStore()
    @StateObject private var headlightStore = MotorStore()

    @State private var showPowerPassword = false
    @State private var showScan = false
    @State private var showBLELogs = false
    @State private var scanFilter: DeviceKind?
    @State private var pendingKind: DeviceKind?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    LargeTitle(
                        "设备",
                        subtitle: ble.isConnected ? "已连接 \(ble.connectedDevice?.displayName ?? "")" : "连接保护板与大灯调节设备"
                    )
                    .staggerIn(0)

                    connectionCard.staggerIn(1)

                    SectionHeader("设备列表")
                    ForEach(DeviceKind.allCases.indices, id: \.self) { index in
                        deviceCard(DeviceKind.allCases[index])
                            .staggerIn(index + 2)
                    }

                    SectionHeader("蓝牙")
                    bleCard.staggerIn(5)

                    if let error = ble.lastError {
                        Text(error)
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 118)
            }
            .background(Theme.groupedBackground)
            .animation(nil, value: appearance.resolvedScheme)
            .navigationDestination(for: DeviceKind.self) { kind in
                detailView(for: kind)
            }
            .sheet(isPresented: $showScan) {
                DeviceScanSheet(filter: scanFilter) { device in
                    // 扫描页手动改分类可能绕过入口校验，进入前对大灯类再验一次 8 位密码
                    if device.kind.requiresPowerAuth && !DeviceAuth.isVerified() {
                        pendingKind = device.kind
                        showPowerPassword = true
                        return
                    }
                    session.resetServiceAuth()
                    path.append(device.kind)
                }
            }
            .sheet(isPresented: $showPowerPassword) {
                PowerPasswordSheet {
                    scanFilter = pendingKind
                    showScan = true
                }
            }
            .sheet(isPresented: $showBLELogs) { bleLogSheet }
        }
        .environmentObject(ble)
        .environmentObject(session)
        .onChange(of: activeMainTab) { _, tab in
            if tab != .device { ble.stopScan() }
        }
    }

    // MARK: - 连接状态

    private var connectionCard: some View {
        AppleCard(padding: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(ble.isConnected ? Theme.green.opacity(0.14) : Theme.surfaceAlt)
                    Image(systemName: ble.isConnected ? "bluetooth" : "bluetooth.slash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ble.isConnected ? Theme.green : Theme.secondary)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(ble.isConnected ? (ble.connectedDevice?.displayName ?? "已连接") : "未连接设备")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                    Text(ble.isConnected
                         ? "\(ble.connectedDevice?.kind.title ?? "") · \(ble.connectedDevice?.rssi ?? 0) dBm"
                         : "点击设备卡片搜索并连接蓝牙设备")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if ble.isConnected {
                    Button("断开") { ble.disconnect() }
                        .font(Theme.footnote)
                        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                } else {
                    Button("扫描") { requestScan(filter: nil) }
                        .font(Theme.footnote)
                        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                }
            }
        }
    }

    private func deviceCard(_ kind: DeviceKind) -> some View {
        let connected = ble.isConnected && ble.connectedDevice?.kind == kind
        let accent = accentColor(for: kind)
        return AppleCard(padding: 14, onTap: {
            if connected {
                path.append(kind)
            } else {
                requestScan(filter: kind)
            }
        }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.24), accent.opacity(0.08)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: kind.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(kind.title)
                            .font(Theme.headline)
                            .foregroundStyle(Theme.label)
                        if connected {
                            StatusPill(text: "已连接", color: Theme.green)
                        }
                    }
                    Text(kind.detail)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var bleCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("蓝牙状态", systemImage: "antenna.radiowaves.left.and.right")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Text(powerText)
                        .font(Theme.footnote)
                        .foregroundStyle(ble.powerState == .poweredOn ? Theme.green : Theme.orange)
                }
                HStack {
                    Button("搜索设备") { requestScan(filter: nil) }
                        .font(Theme.footnote)
                    Spacer()
                    Button("通信日志") { showBLELogs = true }
                        .font(Theme.footnote)
                }
            }
        }
    }

    private var powerText: String {
        switch ble.powerState {
        case .poweredOn: return "可用"
        case .poweredOff: return "已关闭"
        case .unauthorized: return "无权限"
        case .unsupported: return "不支持"
        default: return "正在初始化"
        }
    }

    private var bleLogSheet: some View {
        NavigationStack {
            ScrollView {
                if ble.logs.isEmpty {
                    Text("暂无通信记录")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.page)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ble.logs.indices, id: \.self) { index in
                            Text(ble.logs[index])
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(Theme.page)
                }
            }
            .background(Theme.groupedBackground)
            .navigationTitle("蓝牙日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { showBLELogs = false } }
            }
        }
    }

    // MARK: - 交互

    private func requestScan(filter: DeviceKind?) {
        // 石栏大灯（NB-/SL-）与控制器沿用小程序的 8 位开机密码；BMS 不需要
        if let filter, filter.requiresPowerAuth, !DeviceAuth.isVerified() {
            pendingKind = filter
            showPowerPassword = true
            return
        }
        scanFilter = filter
        showScan = true
    }

    private func accentColor(for kind: DeviceKind) -> Color {
        switch kind {
        case .bms: return .green
        case .controller: return .orange
        case .shilanLight: return .teal
        }
    }

    @ViewBuilder
    private func detailView(for kind: DeviceKind) -> some View {
        switch kind {
        case .bms: BMSDetailView(store: bmsStore)
        case .controller: MotorDetailView(store: motorStore)
        case .shilanLight: HeadlightDetailView(store: headlightStore)
        }
    }
}
