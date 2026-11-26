import SwiftUI
import WebKit

/// CarPlay 页（参考 CarWithin 的接收端视觉与交互）：
/// 1) 连接卡：彩色图标 + 标题 + 状态胶囊 + 启动步骤进度 + 启动按钮；
/// 2) 出画后才显示内嵌视频容器、操作行（全屏/画中画/预览窗）与胶囊按键条；
/// 3) 全屏 = 纯黑容器 + 左上角 5 秒淡出的圆形退出按钮，触摸画面即恢复；
/// 4) Wi-Fi 与极核仪表输出收进连接设置卡，自检与日志收成一行摘要。
struct MirrorView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var store = MirrorStore()
    @StateObject private var controller = CPMirrorController()

    @State private var checks: [CPMirrorDiagnostics.CheckResult] = []
    @State private var runningChecks = false
    @State private var showExport = false
    @State private var exportURL: URL?
    @State private var showFullscreen = false
    @State private var showPreviewWindow = false
    @State private var previewWindowFullscreen = false
    @State private var wifiSaveTask: Task<Void, Never>?
    @State private var wifiSaved = false
    @State private var showPreflight = false
    @State private var showLogs = false
    /// 启动超过 5 秒仍未出画面时显示的排障提示
    @State private var showStartupHint = false
    @State private var startupHintTask: Task<Void, Never>?
    /// 全屏退出按钮可见性（5 秒无操作淡出，触摸恢复）
    @State private var exitButtonVisible = true
    @State private var exitFadeTask: Task<Void, Never>?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                LargeTitle("CarPlay")
                    .staggerIn(0)

                carPlayHeroCard.staggerIn(1)

                if controller.hasVideo {
                    videoSection.staggerIn(2)
                }

                SectionHeader("连接设置")
                settingsCard.staggerIn(3)

                preflightRow.staggerIn(4)
                logSection.staggerIn(5)
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 8)
            .padding(.bottom, 118)
        }
        .background(Theme.groupedBackground)
        .onAppear {
            store.detectSSID()
            store.recheckIdentity()
            if checks.isEmpty {
                Task { await runChecks() }
            }
        }
        .onChange(of: controller.phase) { _, phase in
            handlePhase(phase)
        }
        .sheet(isPresented: $showExport) {
            if let exportURL {
                ActivitySheet(url: exportURL)
            }
        }
        .sheet(isPresented: $showPreflight) {
            preflightSheet
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            fullscreenView
        }
        .sheet(isPresented: $showPreviewWindow) {
            previewWindowSheet
        }
        .fullScreenCover(isPresented: $previewWindowFullscreen) {
            previewWindowFullscreenView
        }
    }

    // MARK: - 连接卡（CarWithin 的 connection card）

    private var carPlayHeroCard: some View {
        AppleCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "car.2.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本机 CarPlay")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.label)
                        Text("无需外接盒子，直接在这台 iPhone 上使用 CarPlay，画面可触控")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                StatusPill(text: controller.phase.label,
                           color: phaseColor,
                           pulsing: awaitingPicture)

                PhaseStepTracker(steps: Self.phaseSteps,
                                 completed: phaseProgress.completed,
                                 active: phaseProgress.active,
                                 failed: phaseProgress.failed,
                                 accent: phaseColor)

                Text(connectionGuide)
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if showStartupHint {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Theme.orange)
                        Text("连接较久时，可尝试在系统设置中关闭再打开 Wi-Fi。当前仍在继续连接。")
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
                        Text("重试本机 CarPlay 引导")
                            .font(Theme.footnote.weight(.semibold))
                            .foregroundStyle(Theme.brand)
                    }
                    .buttonStyle(.plain)
                }

                startButton
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

    /// completed = 已走完的步骤数；active = 进行中的步骤下标（-1 无）；
    /// failed = 引导/接收端失败（进度条染红）。
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
        if let ssid = store.currentSSID {
            return "当前 Wi-Fi：\(ssid)。若已保存同名网络密码，直接点下方按钮即可。"
        }
        return "先在系统设置连接 Wi-Fi，再回到这里启动。"
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
                Task { await startCarPlayAfterPreflight() }
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

    /// 启动前预检：硬性失败（身份缺失/无本机地址）不启动，自动弹出自检详情展示原因。
    private func startCarPlayAfterPreflight() async {
        let results = await runChecks()
        let hardFailures = results.filter { !$0.passed && !$0.warning }
        guard hardFailures.isEmpty else {
            controller.stop()
            await MainActor.run { showPreflight = true }
            return
        }
        store.commitWiFi()
        store.commitDashboardIP()
        store.commitCastToZeeho()
        let localIP = CPMirrorDiagnostics.localIPv4() ?? ""
        controller.start(dashboardIP: store.dashboardIP, localIP: localIP,
                         castToZeeho: store.castToZeeho)
    }

    // MARK: - 视频区（出画后才出现，CarWithin 的 inline video container）

    private var videoSection: some View {
        VStack(spacing: 10) {
            CPPreviewView(controller: controller)
                .aspectRatio(1024.0 / 480.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .clipped()

            // 操作行：全屏（突出）+ 画中画 + 预览窗
            HStack(spacing: 10) {
                actionButton("全屏显示", "arrow.up.left.and.arrow.down.right", prominent: true) {
                    showFullscreen = true
                }
                actionButton("画中画", "pip.enter") {
                    _ = controller.startPictureInPicture()
                }
                actionButton("预览窗", "rectangle.inset.filled") {
                    showPreviewWindow = true
                }
            }

            // 按键条：出画后才显示（CarWithin 的胶囊控制条）
            HStack(spacing: 10) {
                pillButton("house.fill", "主页") { controller.pressHome() }
                pillButton("chevron.backward", "返回") { controller.pressBack() }
                pillButton("smallcircle.filled.circle", "选择") { controller.pressSelect() }
                pillButton("mic.fill", "Siri") { controller.requestSiri() }
            }

            Text("画面可直接触控操作")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiary)
        }
    }

    private func actionButton(_ title: String, _ icon: String,
                              prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(Theme.footnote.weight(.semibold))
            }
            .foregroundStyle(prominent ? Color.white : Theme.brand)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Theme.brand)
                                    : AnyShapeStyle(Theme.brand.opacity(0.12)))
            )
        }
        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
    }

    private func pillButton(_ icon: String, _ label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.brand)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .fill(Theme.brand.opacity(0.1))
            )
        }
        .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
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
        .onAppear { reviveFullscreenExit() }
        .onDisappear {
            exitFadeTask?.cancel()
            exitFadeTask = nil
            exitButtonVisible = true
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

    // MARK: - 连接设置卡（Wi-Fi + 画面输出，自动保存）

    /// Wi-Fi 与仪表输出合并为一张设置卡：输入自动保存，去掉多余的按钮组。
    private var settingsCard: some View {
        AppleCard(padding: 16) {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "wifi")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.currentSSID ?? "未检测到 Wi-Fi")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.label)
                            .lineLimit(1)
                        Text(store.locationDenied ? "需要定位权限读取 Wi-Fi 名称" : "与仪表保持同一网络")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                    if wifiSaved {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .font(Theme.caption.weight(.semibold))
                            .foregroundStyle(Theme.green)
                            .transition(.opacity)
                    }
                    Button {
                        store.detectSSID()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.surfaceAlt))
                    }
                    .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
                }

                SecureField("Wi-Fi 密码（开放网络留空）", text: $store.wifiPassword)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: store.wifiPassword) { _, _ in scheduleWifiSave() }

                Button {
                    store.commitWiFi()
                    store.joinDashboardHotspot(ssid: store.currentSSID,
                                               password: store.wifiPassword)
                } label: {
                    Label("一键加入此 Wi-Fi", systemImage: "antenna.radiowaves.left.and.right")
                        .font(Theme.footnote.weight(.semibold))
                        .foregroundStyle(Theme.brand)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.brand.opacity(0.1)))
                }
                .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))

                if let status = store.hotspotStatus {
                    Text(status)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                Toggle("同时投放到极核仪表", isOn: $store.castToZeeho)
                    .font(Theme.footnote.weight(.semibold))
                    .foregroundStyle(Theme.label)
                    .tint(Theme.brand)
                    .onChange(of: store.castToZeeho) { _, value in
                        store.commitCastToZeeho()
                        controller.setCastToZeeho(value)
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(controller.zeehoSpecText)
                                .font(Theme.caption.weight(.semibold))
                                .foregroundStyle(Theme.label)
                            Text("投屏输出规格随仪表协商结果自动适配")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer(minLength: 0)
                        StatusPill(text: controller.zeehoStatus,
                                   color: controller.zeehoStatus == "投屏中" ? Theme.green : Theme.secondary)
                    }
                } else {
                    Text("关闭后仅本机显示 CarPlay，预览窗与画中画照常可用。")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

    // MARK: - 自检摘要行 + 详情弹窗

    private var preflightSummaryText: String {
        if runningChecks { return "正在自检…" }
        if checks.isEmpty { return "尚未自检" }
        let failed = checks.filter { !$0.passed }
        if failed.isEmpty { return "自检全部通过（\(checks.count) 项）" }
        let names = failed.map(\.name).joined(separator: "、")
        return "自检 \(checks.count - failed.count)/\(checks.count)：\(names)"
    }

    private var preflightSummaryIcon: String {
        if runningChecks || checks.isEmpty { return "circle.dotted" }
        let failed = checks.filter { !$0.passed }
        if failed.isEmpty { return "checkmark.circle.fill" }
        return failed.contains { !$0.warning } ? "xmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var preflightSummaryColor: Color {
        if runningChecks || checks.isEmpty { return Theme.secondary }
        let failed = checks.filter { !$0.passed }
        if failed.isEmpty { return Theme.green }
        return failed.contains { !$0.warning } ? Theme.red : Color(hex: 0xFF9F0A)
    }

    private var preflightRow: some View {
        Button {
            showPreflight = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: preflightSummaryIcon)
                    .font(.system(size: 15))
                    .foregroundStyle(preflightSummaryColor)
                Text(preflightSummaryText)
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("详情")
                    .font(Theme.footnote.weight(.semibold))
                    .foregroundStyle(Theme.brand)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.surface)
        )
        .disabled(runningChecks)
    }

    private var preflightSheet: some View {
        SheetShell(
            title: "启动自检",
            subtitle: preflightSummaryText,
            onClose: { showPreflight = false },
            trailing: {
                Button {
                    Task { await runChecks() }
                } label: {
                    if runningChecks {
                        ProgressView()
                    } else {
                        Text("重新自检")
                            .font(Theme.footnote.weight(.semibold))
                            .foregroundStyle(Theme.brand)
                    }
                }
                .disabled(runningChecks)
            }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if checks.isEmpty {
                        Text(runningChecks ? "正在自检…" : "尚未自检")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 60)
                    } else {
                        ForEach(checks) { result in
                            preflightDetailRow(result)
                        }
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
    }

    @ViewBuilder
    private func preflightDetailRow(_ result: CPMirrorDiagnostics.CheckResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.passed ? "checkmark.circle.fill" :
                    (result.warning ? "exclamationmark.triangle.fill" : "xmark.circle.fill"))
                .foregroundStyle(result.passed ? Theme.green :
                                    (result.warning ? Color(hex: 0xFF9F0A) : Theme.red))
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 4) {
                Text(result.name)
                    .font(Theme.footnote.weight(.semibold))
                    .foregroundStyle(Theme.label)
                Text(result.detail)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func runChecks() async -> [CPMirrorDiagnostics.CheckResult] {
        await MainActor.run { runningChecks = true }
        let results = await CPMirrorDiagnostics.preflight(dashboardIP: store.dashboardIP,
                                                          includeDashboard: store.castToZeeho)
        await MainActor.run {
            checks = results
            runningChecks = false
        }
        MirrorLogStore.append("预检完成：" + results.map {
            "\($0.name)=\($0.passed ? "通过" : ($0.warning ? "提示" : "未通过"))"
        }.joined(separator: "，"))
        return results
    }

    // MARK: - 可操作预览窗口

    /// 弹出的可操作预览窗口：内嵌触控画面，同一 Wi-Fi 下的 iPad/电脑
    /// 打开提示地址也能看到同一画面并回传触控。可全屏。
    private var previewWindowSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Capsule()
                    .fill(Theme.tertiary.opacity(0.4))
                    .frame(width: 40, height: 5)
                Spacer()
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 10)

            HStack(spacing: 10) {
                Image(systemName: "rectangle.inset.filled")
                    .foregroundStyle(Theme.brand)
                Text("可操作预览窗口")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.label)
                Spacer(minLength: 0)
                Button {
                    showPreviewWindow = false
                    _ = controller.startPictureInPicture()
                } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.surfaceAlt))
                }
                .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))

                Button {
                    showPreviewWindow = false
                    previewWindowFullscreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.surfaceAlt))
                }
                .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 8)

            if let url = controller.previewURL {
                Text("同一 Wi-Fi 下的 iPad / 电脑浏览器打开：\(url)，即可看到同一画面并触控操作。")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.page)
                    .padding(.top, 4)
                    .textSelection(.enabled)

                PreviewWindowWebView(url: url)
                    .aspectRatio(1024.0 / 480.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, Theme.page)
                    .padding(.top, 10)
            } else {
                Text("预览窗口服务尚未就绪，请先启动投屏。")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .presentationDetents([.large])
        .background(Theme.groupedBackground)
    }

    /// 全屏态预览窗口。
    private var previewWindowFullscreenView: some View {        ZStack {
            Color.black.ignoresSafeArea()
            if let url = controller.previewURL {
                PreviewWindowWebView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            previewWindowFullscreen = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
                        .padding(16)
                    }
                    Spacer()
                }
            } else {
                Text("预览窗口服务尚未就绪，请先启动投屏。")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: - 日志：默认收起，点开看详情

    private var logSection: some View {
        AppleCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("运行日志", systemImage: "doc.text.magnifyingglass")
                        .font(Theme.footnote.weight(.semibold))
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    Button {
                        exportURL = MirrorLogStore.exportFile()
                        showExport = exportURL != nil
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                    }
                    Button {
                        controller.clearLogs()
                        MirrorLogStore.clearAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                    }
                    Button {
                        withAnimation { showLogs.toggle() }
                    } label: {
                        Image(systemName: showLogs ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 24)
                    }
                }

                if showLogs {
                    if controller.logs.isEmpty {
                        Text("暂无日志")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.tertiary)
                    } else {
                        ForEach(Array(controller.logs.suffix(20).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                } else if let last = controller.logs.last {
                    Text(last)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 可操作预览窗口的触控页面

private struct PreviewWindowWebView: UIViewRepresentable {
    let url: String

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.backgroundColor = .black
        if let address = URL(string: url) {
            view.load(URLRequest(url: address))
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
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
