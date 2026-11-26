import SwiftUI

/// 设备 Tab 入口：未连接先展示设备列表与连接弹窗，连接后按设备类型进入各自专属详情页。
/// 详情推入时上抛 DeviceDetailActiveKey，主界面隐藏 Tab 栏（二级页面形态）。
struct DeviceTabView: View {
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.activeMainTab) private var activeMainTab

    @StateObject private var ble = DeviceBLEManager.shared
    @StateObject private var session = DeviceSession.shared
    @StateObject private var bmsStore = BMSStore()
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
                VStack(spacing: 12) {
                    LargeTitle(
                        "设备",
                        subtitle: ble.isConnected ? "已连接 \(ble.connectedDevice?.displayName ?? "")" : "保护板与大灯调节设备"
                    ) {
                        HStack(spacing: 8) {
                            circleButton(icon: "magnifyingglass", label: "扫描设备") {
                                requestScan(filter: nil)
                            }
                            circleButton(icon: "doc.text.magnifyingglass", label: "蓝牙日志") {
                                showBLELogs = true
                            }
                        }
                    }
                    .staggerIn(0)

                    ForEach(DeviceKind.allCases.indices, id: \.self) { index in
                        deviceCard(DeviceKind.allCases[index])
                            .staggerIn(index + 1)
                    }

                    if let error = ble.lastError {
                        Text(error)
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 4)
                .padding(.bottom, 118)
            }
            .background(Theme.groupedBackground)
            .animation(nil, value: appearance.resolvedScheme)
            .navigationDestination(for: DeviceKind.self) { kind in
                detailView(for: kind)
            }
            .preference(key: DeviceDetailActiveKey.self, value: !path.isEmpty)
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

    /// 标题右侧圆形图标按钮（扫描 / 日志）
    private func circleButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 36, height: 36)
                .background(Theme.surfaceAlt, in: Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
        .accessibilityLabel(label)
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
                            StatusPill(text: "已连接", color: Theme.green, pulsing: true)
                        }
                    }
                    Text(kind.detail)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                Image(systemName: connected ? "chevron.right" : "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(connected ? Theme.tertiary : accent)
            }
        }
    }

    private func accentColor(for kind: DeviceKind) -> Color {
        switch kind {
        case .bms: return .green
        case .shilanLight: return .teal
        }
    }

    @ViewBuilder
    private func detailView(for kind: DeviceKind) -> some View {
        switch kind {
        case .bms: BMSDetailView(store: bmsStore)
        case .shilanLight: HeadlightDetailView(store: headlightStore)
        }
    }
}
