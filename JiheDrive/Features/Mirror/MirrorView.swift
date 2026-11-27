import SwiftUI
import WebKit

/// CarPlay 页：CarWithin 式单页流程——预览即操作面（点按/滑动直接控制），
/// 启动立即进进度（自检是第 0 步），Wi-Fi 与输出设置内联成卡片，无流程弹窗。
struct MirrorView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var store = MirrorStore()
    @StateObject private var controller = CPMirrorController()

    @State private var checks: [CPMirrorDiagnostics.CheckResult] = []
    @State private var runningChecks = false
    /// 自检硬性失败的合并原因（内联展示，不再弹窗）
    @State private var checkFailure: String?
    @State private var showExport = false
    @State private var exportURL: URL?
    @State private var showFullscreen = false
    @State private var wifiSaveTask: Task<Void, Never>?
    @State private var wifiSaved = false
    @State private var showLogs = false
    @State private var showSettings = false
    @State private var showStartupHint = false
    @State private var startupHintTask: Task<Void, Never>?
    @State private var exitButtonVisible = true
    @State private var exitFadeTask: Task<Void, Never>?
    @State private var showVehicleInfo = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                LargeTitle(
                    "CarPlay",
                    subtitle: controller.hasVideo
                        ? "画面已就绪 · 点按/滑动画面直接操作"
                        : "启动后画面在上方，直接触控操作"
                ) {
                    HStack(spacing: 10) {
                        circleIcon("gearshape.fill", label: "CarPlay 设置") { showSettings = true }
                        circleIcon("doc.text.magnifyingglass", label: "运行日志") { showLogs = true }
                    }
                }
                .staggerIn(0)

                previewSection.staggerIn(1)

                launchCard.staggerIn(2)
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 8)
            .padding(.bottom, 118)
        }
        .background(Theme.groupedBackground)
        .onAppear {
            // 只做本地检查；蓝牙/定位/本地网络权限一律延迟到真正需要时
            store.recheckIdentity()
        }
        .onChange(of: controller.phase) { _, phase in
            handlePhase(phase)
        }
        // CarPlay 主屏「车辆按钮」点按（requestUI）：退全屏并弹车辆信息页
        .onChange(of: controller.carUIRequestID) { _, id in
            guard id != nil else { return }
            showFullscreen = false
            showVehicleInfo = true
        }
        .sheet(isPresented: $showExport) {
            if let exportURL {
                ActivitySheet(url: exportURL)
            }
        }
        .sheet(isPresented: $showVehicleInfo) { vehicleInfoSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showLogs) { logsSheet }
        .fullScreenCover(isPresented: $showFullscreen) {
            fullscreenView
        }
    }

    // MARK: - 预览区（第一交互面）

    /// 出画前是同尺寸占位框，出画后画面直接可点/可滑（同手机小窗）；
    /// 全屏与画中画收进画面右上角浮层，不再单独占一行按钮。
    @ViewBuilder
    private var previewSection: some View {
        Group {
        if controller.hasVideo {
            ZStack(alignment: .topTrailing) {
                // 全屏呈现期间卡片停喂数据：同一帧不再两路解码（点全屏卡住的根因之一）
                CPPreviewView(controller: controller, paused: showFullscreen)
                    .aspectRatio(1024.0 / 480.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { showFullscreen = true }

                HStack(spacing: 8) {
                    previewOverlayIcon("pip.enter", label: "画中画") {
                        _ = controller.startPictureInPicture()
                    }
                    previewOverlayIcon("arrow.up.left.and.arrow.down.right", label: "全屏") {
                        showFullscreen = true
                    }
                }
                .padding(10)
            }
        } else {
            // 启动前占位：与出画后的预览同比例，流程视觉不断档
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface.opacity(0.55))
                .aspectRatio(1024.0 / 480.0, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.tertiary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: controller.phase.isRunning ? "iphone.gen3.radiowaves.left.and.right" : "car.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(phaseColor.opacity(0.7))
                        Text(controller.phase.isRunning ? "正在连接，画面就绪后显示在这里" : "启动后画面显示在这里")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                        Text("出画后点按 / 滑动画面即可直接操作")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.tertiary)
                    }
                }
        }
        }
        // 主页面 16pt 边距内再外扩 8pt：预览栏更宽更大
        .padding(.horizontal, -8)
    }

    /// 预览右上角的半透明浮层小圆钮
    private func previewOverlayIcon(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.black.opacity(0.5)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
        .accessibilityLabel(label)
    }

    // MARK: - Wi-Fi 预设

    /// 标题右侧圆形图标按钮
    private func circleIcon(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
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

    // MARK: - 车辆信息页（CarPlay 主屏车辆按钮点按后弹出）

    @State private var refreshingInfo = false

    private var vehicleInfoSheet: some View {
        SheetShell(
            title: "车辆信息",
            subtitle: "在 CarPlay 主屏点按车辆按钮打开",
            onClose: { showVehicleInfo = false },
            trailing: {
                Button {
                    refreshInfo()
                } label: {
                    Group {
                        if refreshingInfo {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .foregroundStyle(Theme.brand)
                    .frame(width: 36, height: 36)
                    .background(Theme.surfaceAlt, in: Circle())
                }
                .disabled(refreshingInfo)
                .accessibilityLabel("刷新车辆数据")
            }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if let vehicle = model.selectedVehicle {
                        AppleCard(padding: 16) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 10) {
                                    Image(systemName: "car.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Theme.brand)
                                        .frame(width: 28)
                                    Text(vehicle.name)
                                        .font(Theme.headline)
                                        .foregroundStyle(Theme.label)
                                    Spacer(minLength: 0)
                                    StatusPill(text: vehicle.isOnline ? "在线" : "离线",
                                               color: vehicle.isOnline ? Theme.green : Theme.secondary)
                                }
                                Divider()
                                vehicleInfoRow("battery.100percent", "电量",
                                               "\(vehicle.soc)% · 续航 \(vehicle.rangeKm) km")
                                vehicleInfoRow("bolt.fill", "充电状态",
                                               vehicle.isCharging ? "充电中" : "未充电")
                                vehicleInfoRow("lock.fill", "锁车状态",
                                               vehicle.isLocked ? "已锁车" : "已解锁")
                                if let tire = model.tire {
                                    if let front = tire.frontBar, let rear = tire.rearBar {
                                        vehicleInfoRow("gauge.high", "胎压",
                                                       String(format: "前 %.1f bar · 后 %.1f bar", front, rear))
                                    }
                                    if let front = tire.frontTemp, let rear = tire.rearTemp {
                                        vehicleInfoRow("thermometer.medium", "胎温",
                                                       String(format: "前 %.0f℃ · 后 %.0f℃", front, rear))
                                    }
                                }
                                if let battery = model.liveBatteryOfSelected {
                                    vehicleInfoRow("bolt.horizontal.fill", "电池电压",
                                                   String(format: "%.1f V", battery.voltage))
                                    if let power = battery.power, power > 0 {
                                        vehicleInfoRow("waveform.path.ecg", "实时功率",
                                                       String(format: "%.0f W", power))
                                    }
                                    if let current = battery.current, current > 0 {
                                        vehicleInfoRow("arrow.up.arrow.down", "实时电流",
                                                       String(format: "%.1f A", current))
                                    }
                                    vehicleInfoRow("thermometer.medium", "电池温度",
                                                   String(format: "%.1f ℃", battery.temperature))
                                }
                                if let updated = model.lastUpdatedAt {
                                    vehicleInfoRow("clock.arrow.circlepath", "数据更新于",
                                                   DateFormatter.localizedString(from: updated,
                                                                                dateStyle: .none, timeStyle: .short))
                                }
                            }
                        }
                    } else {
                        AppleCard(padding: 16) {
                            Text("暂无车辆数据（未登录或列表未加载）")
                                .font(Theme.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                    }

                    AppleCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: "carplay")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Theme.brand)
                                    .frame(width: 28)
                                Text("CarPlay 状态")
                                    .font(Theme.headline)
                                    .foregroundStyle(Theme.label)
                                Spacer(minLength: 0)
                            }
                            Divider()
                            vehicleInfoRow("dot.radiowaves.left.and.right", "连接",
                                           controller.phase.label)
                            vehicleInfoRow("gauge.with.needle", "极核仪表投屏",
                                           controller.zeehoSpecText)
                        }
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
            .background(Theme.groupedBackground)
        }
    }

    /// 车辆信息页刷新：轻量轮询（电池+详情+胎压），不刷车辆列表
    private func refreshInfo() {
        guard !refreshingInfo else { return }
        refreshingInfo = true
        Task {
            await model.refreshQuiet()
            refreshingInfo = false
        }
    }

    private func vehicleInfoRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 24)
            Text(title)
                .font(Theme.footnote)
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(Theme.footnote.weight(.semibold))
                .foregroundStyle(Theme.label)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 运行日志弹窗（完整列表 + 导出 / 清空 / 复制）

    private var logsSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        Button {
                            exportURL = MirrorLogStore.exportFile()
                            showExport = exportURL != nil
                        } label: {
                            Label("导出", systemImage: "square.and.arrow.up")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Button {
                            UIPasteboard.general.string = controller.logs.joined(separator: "\n")
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Button {
                            controller.clearLogs()
                            MirrorLogStore.clearAll()
                        } label: {
                            Label("清空", systemImage: "trash")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Spacer()
                    }

                    if controller.logs.isEmpty {
                        Text("暂无日志")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(controller.logs.suffix(200).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Theme.groupedBackground)
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { showLogs = false } }
            }
        }
    }

    /// 设置弹窗：Wi-Fi 预设 + 输出设置两卡合一
    private var settingsSheet: some View {
        SheetShell(
            title: "CarPlay 设置",
            subtitle: "Wi-Fi 预设与输出",
            onClose: { showSettings = false }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    wifiSetupCard
                    outputSettingsCard
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .background(Theme.groupedBackground)
        }
        .sheetChrome()
    }

    // MARK: - Wi-Fi 预设卡片（内联，输入后防抖自动保存）

    private var wifiSetupCard: some View {
        AppleCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "wifi")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wi-Fi 预设")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.label)
                        Text(store.currentSSID.map { "已检测：\($0)" }
                              ?? (store.locationDenied
                                  ? "定位被拒，请手填名称"
                                  : "可手填；须与手机当前网络一致"))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                    if wifiSaved {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .font(Theme.caption.weight(.semibold))
                            .foregroundStyle(Theme.green)
                    }
                    Button { store.detectSSID() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.surfaceAlt))
                    }
                    .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
                }

                TextField("Wi-Fi 名称（SSID）", text: $store.wifiSSID)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: store.wifiSSID) { _, _ in scheduleWifiSave() }

                SecureField("Wi-Fi 密码（开放网络留空，否则 8–63 位）", text: $store.wifiPassword)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: store.wifiPassword) { _, _ in scheduleWifiSave() }

                // 只保存预设（CarPlay 会话用），不会替你去连接热点——
                // 加入仪表热点请在系统设置完成
                HStack(spacing: 8) {
                    Image(systemName: wifiSaved ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(wifiSaved ? Theme.green : Theme.secondary)
                    Text(wifiSaved ? "已保存，启动 CarPlay 时自动使用"
                                   : "填写后自动保存（仅保存，不会替你连接热点）")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - 启动卡（自检并入进度：点启动立即响应）

    private var launchCard: some View {
        AppleCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [phaseColor.opacity(0.35), phaseColor.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "car.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(phaseColor)
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("启动本机 CarPlay")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.label)
                        Text(controller.hasVideo
                             ? "本地预览与触控可用"
                             : "点启动立即进进度，自检自动完成")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                    StatusPill(text: controller.phase.label,
                               color: phaseColor,
                               pulsing: awaitingPicture)
                }

                if !controller.hasVideo {
                    PhaseStepTracker(steps: Self.startupSteps,
                                     completed: startupProgress.completed,
                                     active: startupProgress.active,
                                     failed: startupProgress.failed,
                                     accent: phaseColor)

                    if let checkFailure {
                        // 自检硬性失败：红色软底行内联原因，改完条件直接再点启动
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "xmark.octagon.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.red)
                            Text(checkFailure)
                                .font(Theme.footnote)
                                .foregroundStyle(Theme.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .background(Theme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.brand)
                            Text(connectionGuide)
                                .font(Theme.footnote)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                if showStartupHint {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Theme.orange)
                        Text("已发 0x4301 但仍无控制连接时：核对 Wi-Fi 名/密码是否与当前网络完全一致，并确认本地网络已授权。")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Theme.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if case .liveFallback = controller.phase {
                    Button {
                        controller.retryBootstrap()
                    } label: {
                        Label("重试本机 CarPlay 引导", systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.brand)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Theme.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                }

                startButton
            }
        }
    }

    // MARK: - 输出设置（画面输出到哪：本机预览，可选投到极核仪表）

    private var outputSettingsCard: some View {
        AppleCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 24)
                    Text("输出设置")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    if store.castToZeeho {
                        if controller.zeehoStatus.hasPrefix("失败") {
                            Button {
                                controller.retryDashboardLink()
                            } label: {
                                Label("重试", systemImage: "arrow.clockwise")
                                    .font(Theme.caption.weight(.semibold))
                                    .foregroundStyle(Theme.brand)
                            }
                            .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
                        }
                        StatusPill(text: controller.zeehoStatus,
                                   color: controller.zeehoStatus == "投屏中" ? Theme.green : Theme.secondary)
                    }
                }

                Toggle("投到极核仪表", isOn: $store.castToZeeho)
                    .font(Theme.footnote.weight(.semibold))
                    .foregroundStyle(Theme.label)
                    .tint(Theme.brand)
                    .onChange(of: store.castToZeeho) { _, value in
                        store.commitCastToZeeho()
                        controller.setCastToZeeho(value)
                    }

                if !store.castToZeeho {
                    Text("关闭时只在本机出画面；仪表 IP、车型与裁剪在开启后显示。")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }

                if store.castToZeeho {
                    HStack(spacing: 10) {
                        Image(systemName: "gauge.with.needle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 24)
                        TextField("仪表 IP，如 192.168.0.1", text: $store.dashboardIP)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: store.dashboardIP) { _, _ in store.commitDashboardIP() }
                        Menu {
                            Picker("裁剪", selection: $store.cropMode) {
                                Text("居中裁剪").tag("crop")
                                Text("完整画面").tag("fit")
                            }
                        } label: {
                            Image(systemName: "crop.rotate")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 36, height: 36)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Theme.surfaceAlt))
                        }
                        .onChange(of: store.cropMode) { _, value in
                            store.commitCropMode()
                            controller.setCropMode(value)
                        }
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "car.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 24)
                        Text("仪表车型")
                            .font(Theme.footnote.weight(.medium))
                            .foregroundStyle(Theme.label)
                        Spacer(minLength: 8)
                        Menu {
                            ForEach(CPMirrorController.zeehoModels, id: \.id) { model in
                                Button {
                                    controller.setZeehoModel(model.id)
                                } label: {
                                    if controller.zeehoModelID == model.id {
                                        Label(model.name, systemImage: "checkmark")
                                    } else {
                                        Text(model.name)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(controller.zeehoModelName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(Theme.label)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.surfaceAlt, in: Capsule())
                        }
                    }

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(controller.zeehoSpecText)
                                .font(Theme.caption.weight(.semibold))
                                .foregroundStyle(Theme.label)
                            Text(controller.zeehoModelID == "auto"
                                 ? "投屏规格随仪表协商自动适配"
                                 : "已选 \(controller.zeehoModelName) · 规格按所选车型协商，异常时回退自适应")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer(minLength: 0)
                        StatusPill(text: controller.zeehoStatus,
                                   color: controller.zeehoStatus == "投屏中" ? Theme.green : Theme.secondary)
                    }
                }
            }
        }
    }

    /// 阶段配色：出画=绿，失败/缺身份=红，回退=橙，其余=蓝
    private var phaseColor: Color {
        switch controller.phase {
        case .localStreaming, .streaming: return Theme.green
        case .failed, .identityMissing: return Theme.red
        case .liveFallback, .stopped: return Theme.orange
        default: return Theme.brand
        }
    }

    /// 处于「已启动但还没出画面」的阶段——用于延迟排障提示
    private var awaitingPicture: Bool {
        switch controller.phase {
        case .starting, .transportReady, .linkConnected, .authenticated,
             .identified, .sessionRequested, .waitingControl, .controlConnected:
            return true
        default:
            return false
        }
    }

    // MARK: - 启动步骤与进度

    static let phaseSteps = ["配件端点", "iAP2 链路", "配件认证", "配件识别", "会话请求", "控制连接", "画面输出"]
    /// 启动全流程：自检是第 0 步——点启动立即进进度，自检不再挡在按钮前面
    static let startupSteps = ["自检"] + phaseSteps

    /// 启动进度（相对 startupSteps）：自检中=第 0 步进行中；
    /// 自检硬性失败=第 0 步染红；之后随引导阶段逐格点亮。
    private var startupProgress: (completed: Int, active: Int, failed: Bool) {
        if let checkFailure { return (0, -1, true) }
        if runningChecks { return (0, 0, false) }
        switch controller.phase {
        case .idle, .stopped:
            return (0, -1, false)
        default:
            break
        }
        let base = phaseProgress
        if base.failed { return (0, -1, true) }
        if base.completed >= Self.phaseSteps.count { return (Self.startupSteps.count, -1, false) }
        return (base.completed + 1, base.active >= 0 ? base.active + 1 : -1, false)
    }

    private var phaseProgress: (completed: Int, active: Int, failed: Bool) {
        switch controller.phase {
        case .idle, .stopped: return (0, -1, false)
        case .identityMissing: return (0, -1, true)
        case .starting: return (0, 0, false)
        case .transportReady: return (1, 1, false)
        case .linkConnected: return (2, 2, false)
        case .authenticated: return (3, 3, false)
        case .identified: return (4, 4, false)
        case .sessionRequested, .waitingControl: return (5, 5, false)
        case .controlConnected: return (6, 6, false)
        case .localStreaming: return (7, -1, false)
        case .streaming: return (7, -1, false)
        case .liveFallback, .failed: return (0, -1, true)
        }
    }

    private var connectionGuide: String {
        if case .identityMissing = controller.phase {
            return "需要 CarPlay 配件身份，请把身份三件套放入「文件」App 的 JiheDrive/IdentityImport/ 目录。"
        }
        if case .failed(let reason) = controller.phase {
            return reason
        }
        if let checkFailure {
            return "自检未通过，修正上方问题后重新点启动。"
        }
        let ssid = store.resolvedSSID
        if !ssid.isEmpty {
            return "将使用 Wi-Fi「\(ssid)」发起会话。先出本机画面，需要投仪表时在下方「输出设置」开启。"
        }
        return "请先连上 Wi-Fi/仪表热点，并点右上角「Wi-Fi 预设」填写名称与密码，否则 iPhone 无法回连控制端口。"
    }

    /// 启动阶段计时：5 秒还没出画面才显示提示；出画/停止后清除
    private func handlePhase(_ phase: CPMirrorController.Phase) {
        switch phase {
        case .starting, .transportReady, .linkConnected:
            guard startupHintTask == nil else { return }
            let task = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if awaitingPicture { showStartupHint = true }
                }
            }
            startupHintTask = task
        case .localStreaming, .streaming, .failed, .stopped, .idle,
             .identityMissing, .liveFallback:
            startupHintTask?.cancel()
            startupHintTask = nil
            showStartupHint = false
        default:
            break
        }
    }

    // MARK: - 启动按钮

    private var startButton: some View {
        Button {
            if controller.phase.isRunning {
                controller.stop()
            } else {
                startMirror()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: controller.phase.isRunning ? "stop.fill" : "play.fill")
                Text(controller.phase.isRunning ? "停止 CarPlay" : "启动本机 CarPlay")
                    .font(Theme.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                    .fill(controller.phase.isRunning ? AnyShapeStyle(Theme.red) : AnyShapeStyle(Theme.brand))
            )
        }
        .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
    }

    /// 启动：点按钮立即进进度（自检 = 第 0 步），自检通过自动继续发起会话；
    /// 硬性失败内联展示原因，不再弹窗打断。
    @MainActor
    private func startMirror() {
        checkFailure = nil
        Task {
            // 权限在这一步才请求：本地网络（CarPlay 会话必需）+ Wi-Fi 名称检测（定位）
            CPLocalNetworkGate.requestAuthorizationIfNeeded()
            store.detectSSID()
            // 先写入 Wi-Fi 预设，再自检——否则 StartSession 会因「未配置」直接失败
            store.commitWiFi()
            store.commitDashboardIP()
            store.commitCastToZeeho()

            let results = await runChecks()
            let hardFailures = results.filter { !$0.passed && !$0.warning }
            if !hardFailures.isEmpty {
                checkFailure = hardFailures
                    .map { "\($0.name)：\($0.detail)" }
                    .joined(separator: "\n")
                return
            }
            let localIP = CPMirrorDiagnostics.localIPv4() ?? ""
            guard !localIP.isEmpty else {
                checkFailure = "未获取到 Wi-Fi IP：请先在系统设置连接热点，再重新点启动。"
                return
            }
            controller.start(dashboardIP: store.dashboardIP, localIP: localIP,
                             castToZeeho: store.castToZeeho)
        }
    }

    // MARK: - 全屏（纯黑容器 + 5 秒淡出退出按钮）

    private var fullscreenView: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            CPPreviewView(controller: controller, fullscreen: true)
                .aspectRatio(1024.0 / 480.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { reviveFullscreenExit() }

            if exitButtonVisible {
                Button {
                    showFullscreen = false
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                }
                .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
                .padding(16)
                .transition(.opacity)
            }
        }
        .onAppear { setFullscreenLandscape(true) }
        .onDisappear { setFullscreenLandscape(false) }
        .onAppear { reviveFullscreenExit() }
        .onDisappear {
            exitFadeTask?.cancel()
            exitFadeTask = nil
            exitButtonVisible = true
        }
    }

    /// 全屏自动横屏：门控放行横屏 + 请求几何旋转；退出时回到竖屏
    private func setFullscreenLandscape(_ landscape: Bool) {
        AppDelegate.orientationMask = landscape ? .landscape : .portrait
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        Task {
            try? await scene.requestGeometryUpdate(.iOS(
                interfaceOrientations: landscape ? .landscapeRight : .portrait
            ))
        }
    }

    /// 全屏退出按钮：5 秒无操作淡出到消失，触摸画面立即恢复。
    private func reviveFullscreenExit() {
        exitFadeTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { exitButtonVisible = true }
        exitFadeTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) { exitButtonVisible = false }
            }
        }
    }

    /// 密码输入防抖自动保存，省掉「仅保存」按钮。
    private func scheduleWifiSave() {
        wifiSaveTask?.cancel()
        wifiSaveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            store.commitWiFi()
            await MainActor.run { wifiSaved = true }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { wifiSaved = false }
        }
    }

    // MARK: - 自检（并入启动进度，结果内联展示）

    private func runChecks() async -> [CPMirrorDiagnostics.CheckResult] {
        await MainActor.run { runningChecks = true }
        let results = await CPMirrorDiagnostics.preflight(
            dashboardIP: store.dashboardIP,
            includeDashboard: store.castToZeeho
        )
        await MainActor.run {
            checks = results
            runningChecks = false
        }
        MirrorLogStore.append("预检完成：" + results.map {
            "\($0.name)=\($0.passed ? "通过" : ($0.warning ? "提示" : "未通过"))"
        }.joined(separator: "，"))
        return results
    }


}

// MARK: - 启动步骤追踪器（分段胶囊进度）

/// 展示 CarPlay 引导的 7 个阶段：一排分段胶囊随完成度逐格点亮，
/// 下方单行文字说明当前步骤——不放一排小圆点，保持干净。
private struct PhaseStepTracker: View {
    let steps: [String]
    let completed: Int
    let active: Int
    let failed: Bool
    let accent: Color

    private var headline: String {
        if failed { return "连接未完成，可查看下方日志或重试" }
        if completed >= steps.count { return "连接完成，画面输出中" }
        let step = active >= 0 && active < steps.count ? steps[active] : steps.first ?? ""
        let ordinal = active >= 0 ? active + 1 : min(completed + 1, steps.count)
        return "第 \(ordinal)/\(steps.count) 步 · \(step)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, _ in
                    Capsule()
                        .fill(segmentColor(index))
                        .frame(height: 8)
                        .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 6) {
                if failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(accent)
                } else if completed >= steps.count {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.green)
                } else if active >= 0 {
                    Circle()
                        .fill(accent)
                        .frame(width: 6, height: 6)
                        .opacity(pulsing ? 0.35 : 1)
                }
                Text(headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(Theme.caption)
            .foregroundStyle(failed ? accent : Theme.secondary)
        }
        .animation(.easeInOut(duration: 0.3), value: completed)
        .animation(.easeInOut(duration: 0.3), value: active)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }

    @State private var pulsing = false

    private func segmentColor(_ index: Int) -> Color {
        if index < completed { return Theme.green }
        if index == active {
            return failed ? accent : accent.opacity(pulsing ? 0.55 : 1)
        }
        return Theme.surfaceAlt
    }
}

// MARK: - 分享面板

private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
