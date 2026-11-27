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
    @StateObject private var chargerStore = ChargerStore()
    @StateObject private var dianjingStore = DianjingStore()
    @StateObject private var lampStore = LampStore()

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
                        subtitle: ble.isConnected ? "已连接 \(ble.connectedDevice?.displayName ?? "")" : "保护板 · 大灯 · 灯具 · 充电机 · 仪表"
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
        .onChange(of: ble.powerState) { _, state in
            if state == .poweredOn { ble.autoConnectSavedDevice() }
        }
        .onAppear {
            ble.autoConnectSavedDevice()
            syncListPolling()
        }
        .onChange(of: ble.connectionState) { _, _ in
            syncListPolling()
        }
        .onChange(of: path) { _, newPath in
            // 从详情页返回列表时恢复列表卡片的实时轮询
            if newPath.isEmpty { syncListPolling() }
        }
    }

    /// 列表卡片实时摘要的数据源：连接期间保持对应 Store 轮询；
    /// 进入详情页后由详情页接管，返回列表（path 清空）时恢复。
    private func syncListPolling() {
        guard ble.isConnected, let kind = ble.connectedDevice?.kind else {
            bmsStore.stopPolling()
            headlightStore.deactivate()
            chargerStore.deactivate()
            dianjingStore.deactivate()
            lampStore.deactivate()
            return
        }
        // 每种设备同一时刻只保留一个 Store 在跑，避免通知回调互相竞争
        bmsStore.stopPolling()
        headlightStore.deactivate()
        chargerStore.deactivate()
        dianjingStore.deactivate()
        lampStore.deactivate()
        switch kind {
        case .bms:
            bmsStore.attach(ble)
            bmsStore.startPolling()
        case .shilanLight:
            headlightStore.attach(ble, handlerKey: "headlight")
            if !headlightStore.paramsLoaded { headlightStore.loadParams() }
        case .charger:
            chargerStore.attach(ble)
            chargerStore.startPolling()
        case .dianjingMeter:
            dianjingStore.attach(ble)
            dianjingStore.startPolling()
        case .lamp:
            lampStore.attach(ble)
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
            VStack(spacing: 12) {
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
                        Text(connected ? (ble.connectedDevice?.displayName ?? kind.detail) : kind.detail)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                    Image(systemName: connected ? "chevron.right" : "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(connected ? Theme.tertiary : accent)
                }

                if connected {
                    deviceSummary(kind)
                }
            }
        }
    }

    /// 连接后的实时摘要格（对齐 ALong 参考样式：值大字 + 标签小字）
    private func deviceSummary(_ kind: DeviceKind) -> some View {
        switch kind {
        case .bms:
            let rt = bmsStore.realtime
            // SOC 帧未到达时（刚连接）不显示误导性的 0%，只显示已有数据
            let soc = rt?.soc ?? 0
            return AnyView(HStack(spacing: 8) {
                if soc > 0 {
                    summaryTile(value: "\(soc)", unit: "%", label: "电量", color: Theme.green)
                }
                summaryTile(value: fmt1(rt?.totalVoltage), unit: "V", label: "电压", color: Theme.brand)
                summaryTile(value: fmt1(rt.map { abs($0.current) }), unit: "A", label: "电流", color: Color(hex: 0x0EA5E9))
                summaryTile(value: "\(rt.map { abs($0.power) } ?? 0)", unit: "W", label: "功率", color: Theme.orange)
            })
        case .shilanLight:
            // 已存记忆：显示记忆预设，点击直接下发移动（不进详情页）；未存：显示当前角度
            let saved = HeadlightMemory.load()
            if saved.isEmpty {
                let p = headlightStore.params
                return AnyView(HStack(spacing: 8) {
                    summaryTile(value: "\(p.absolutePercent)", unit: "%", label: "当前高度", color: Theme.teal)
                    summaryTile(value: "\(p.targetPercent)", unit: "%", label: "目标", color: Theme.orange)
                    summaryTile(value: "\(p.minPercent)–\(p.maxPercent)", unit: "%", label: "限位", color: Theme.label)
                    summaryTile(value: headlightStore.busy ? "运行" : "空闲", unit: "", label: "电机", color: headlightStore.busy ? Theme.orange : Theme.green)
                })
            }
            return AnyView(HStack(spacing: 8) {
                ForEach(saved.prefix(4)) { item in
                    summaryTile(value: "\(item.percent)", unit: "%", label: item.name, color: Theme.teal)
                        .onTapGesture { triggerHeadlightMemory(item.percent) }
                }
            })
        case .charger:
            // 连接即轮询实时帧；未解析出结构化字段时显示通道状态
            let rt = chargerStore.realtime
            return AnyView(HStack(spacing: 8) {
                summaryTile(value: rt?.parsed == true ? String(format: "%.1f", rt?.voltage ?? 0) : "--", unit: "V", label: "电池电压", color: Theme.green)
                summaryTile(value: rt?.parsed == true ? String(format: "%.1f", rt?.chargerCurrent ?? 0) : "--", unit: "A", label: "输出电流", color: Theme.brand)
                summaryTile(value: rt?.parsed == true ? "\(abs(rt?.power ?? 0))" : "--", unit: "W", label: "功率", color: Theme.orange)
                summaryTile(value: rt?.parsed == true ? "运行" : "等待", unit: "", label: "实时帧", color: rt?.parsed == true ? Theme.green : Theme.secondary)
            })
        case .dianjingMeter:
            let rt = dianjingStore.realtime
            return AnyView(HStack(spacing: 8) {
                summaryTile(value: "\(rt?.soc ?? 0)", unit: "%", label: "电量", color: Theme.green)
                summaryTile(value: fmt1(rt?.voltage), unit: "V", label: "电压", color: Theme.brand)
                summaryTile(value: fmt1(rt?.totalMileage), unit: "km", label: "总里程", color: Color(hex: 0x0EA5E9))
                summaryTile(value: fmt1(rt?.enduranceMileage), unit: "km", label: "续航", color: Theme.orange)
            })
        case .lamp:
            // 灯具：显示调试类型与同步状态，点击卡片进详情调节
            return AnyView(HStack(spacing: 8) {
                summaryTile(value: lampStore.profile.title, unit: "", label: "调试类型", color: Theme.brand)
                summaryTile(value: lampStore.synced ? "已同步" : "未读取", unit: "", label: "参数快照", color: lampStore.synced ? Theme.green : Theme.orange)
                summaryTile(value: lampStore.transport?.title ?? "--", unit: "", label: "通道", color: Theme.secondary)
            })
        }
    }

    private func fmt1(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f", value)
    }

    /// 列表记忆格点击：已连接石栏设备时直接下发移动，不进详情页；
    /// 参数未读时先读参数再动；未连接则不动（点击卡片本体才扫描/进详情）
    private func triggerHeadlightMemory(_ percent: Int) {
        guard ble.isConnected, ble.connectedDevice?.kind == .shilanLight else { return }
        if !headlightStore.paramsLoaded {
            headlightStore.attach(ble, handlerKey: "headlight")
            headlightStore.loadParams()
            // 参数读到后自动走到记忆位（loadParams 成功后由详情/列表共用 store 触发）
            Task {
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if headlightStore.paramsLoaded {
                        headlightStore.moveTo(percent: Double(percent))
                        return
                    }
                }
            }
            return
        }
        headlightStore.moveTo(percent: Double(percent))
    }

    private func summaryTile(value: String, unit: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 交互

    private func requestScan(filter: DeviceKind?) {
        // 石栏大灯（NB-/SL-）沿用小程序的 8 位开机密码；BMS 不需要
        if let filter, filter.requiresPowerAuth, !DeviceAuth.isVerified() {
            pendingKind = filter
            showPowerPassword = true
            return
        }
        scanFilter = filter
        showScan = true
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
                        Button {
                            UIPasteboard.general.string = ble.logs.joined(separator: "\n")
                        } label: {
                            Label("复制全部日志", systemImage: "doc.on.doc")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.bottom, 4)

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

    private func accentColor(for kind: DeviceKind) -> Color {
        switch kind {
        case .bms: return .green
        case .shilanLight: return .teal
        case .charger: return .orange
        case .dianjingMeter: return .indigo
        case .lamp: return Color(hex: 0xF59E0B)
        }
    }

    @ViewBuilder
    private func detailView(for kind: DeviceKind) -> some View {
        switch kind {
        case .bms: BMSDetailView(store: bmsStore)
        case .shilanLight: HeadlightDetailView(store: headlightStore)
        case .charger: ChargerDetailView(store: chargerStore)
        case .dianjingMeter: DianjingDetailView(store: dianjingStore)
        case .lamp: LampDetailView(store: lampStore)
        }
    }
}
