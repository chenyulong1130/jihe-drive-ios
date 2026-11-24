import SwiftUI
import ReplayKit

/// 投屏页。信息层次参考 CarWithin：
/// 1) 一个 hero 卡承载标题、一句话说明、状态胶囊、连接指导、启动按钮；
/// 2) 卡在连接超过 5 秒才出现排障提示，不打扰正常启动；
/// 3) 视频区启动后才出现，带全屏；
/// 4) Wi-Fi 与输出分区收纳，首页保持清爽；
/// 5) 自检与日志收成一行摘要，点开看详情。
struct MirrorView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var store = MirrorStore()
    @StateObject private var controller = CPMirrorController()

    @State private var mode = "carplay"
    @State private var checks: [CPMirrorDiagnostics.CheckResult] = []
    @State private var runningChecks = false
    @State private var showExport = false
    @State private var exportURL: URL?
    @State private var showFullscreen = false
    @State private var showPreflight = false
    @State private var showLogs = false
    /// 启动超过 5 秒仍未出画面时显示的排障提示
    @State private var showStartupHint = false
    @State private var startupHintTask: Task<Void, Never>?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                LargeTitle("投屏")
                    .staggerIn(0)

                modeSelector.staggerIn(0)

                if mode == "carplay" {
                    carPlayHeroCard.staggerIn(1)
                    if controller.phase.isRunning {
                        previewCard.staggerIn(2)
                    }
                } else {
                    screenMirrorHeroCard.staggerIn(1)
                }

                SectionHeader("连接与网络")
                wifiCard.staggerIn(3)

                if mode == "carplay" {
                    SectionHeader("画面输出")
                    outputCard.staggerIn(4)
                }

                preflightRow.staggerIn(5)
                logSection.staggerIn(6)
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
    }

    // MARK: - 模式选择

    private var modeSelector: some View {
        Picker("模式", selection: $mode) {
            Text("同机 CarPlay").tag("carplay")
            Text("整屏镜像").tag("screen")
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 4)
    }

    // MARK: - Hero：本机 CarPlay

    private var carPlayHeroCard: some View {
        AppleCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "carplay")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本机 CarPlay")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.label)
                        Text("无需外接盒子，直接在这台 iPhone 上使用 CarPlay")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                StatusPill(text: controller.phase.label,
                           color: phaseColor,
                           pulsing: awaitingPicture)

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

    // MARK: - Hero：整屏镜像

    private var screenExtStatus: String? { MirrorStore.extensionStatus() }

    private var screenMirrorHeroCard: some View {
        AppleCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Theme.teal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("整屏镜像")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.label)
                        Text("把任意 App 的整屏画面投到极核仪表，熄屏即停止")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                StatusPill(text: screenExtStatus ?? "未运行",
                           color: screenExtStatus != nil ? Theme.green : Theme.secondary)

                broadcastButton
            }
        }
    }

    // MARK: - 启动按钮（CarPlay 模式）

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

    // MARK: - 广播按钮（整屏镜像模式）

    private var broadcastButton: some View {
        VStack(spacing: 8) {
            BroadcastPickerView(preferredExtension: "com.liruixin.jihedrive.mirror")
                .frame(height: 48)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                        .fill(Theme.brand)
                )
                .overlay(
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle")
                        Text("开始整屏镜像")
                            .font(Theme.headline)
                    }
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
                )
            Text("在系统面板选择「极核投屏」")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
        }
    }

    // MARK: - Wi-Fi 卡（只管网络）

    private var wifiCard: some View {
        AppleCard(padding: 18) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "wifi")
                        .foregroundStyle(Theme.brand)
                    Text(store.currentSSID ?? "未检测到 Wi-Fi")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    Spacer(minLength: 0)
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

                if store.locationDenied {
                    Text("获取 Wi-Fi 名称需要定位权限，可在系统设置中开启。")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.orange)
                }

                SecureField("Wi-Fi 密码（开放网络留空）", text: $store.wifiPassword)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                HStack(spacing: 10) {
                    Button {
                        store.commitWiFi()
                    } label: {
                        Text("仅保存")
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.commitWiFi()
                        store.joinDashboardHotspot(ssid: store.currentSSID,
                                                   password: store.wifiPassword)
                    } label: {
                        Text("加入此网络")
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let status = store.hotspotStatus {
                    Text(status)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    // MARK: - 输出卡（只管画面去向）

    private var outputCard: some View {
        AppleCard(padding: 18) {
            VStack(spacing: 14) {
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
                            .foregroundStyle(Theme.brand)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("极核 6.2 寸仪表")
                                .font(Theme.headline)
                                .foregroundStyle(Theme.label)
                            Text("1024×480 · H.264 25帧")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer(minLength: 0)
                        StatusPill(text: controller.zeehoStatus,
                                   color: controller.zeehoStatus == "投屏中" ? Theme.green : Theme.secondary)
                    }

                    HStack(spacing: 8) {
                        Text("IP")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                        TextField("192.168.0.1", text: $store.dashboardIP)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    Picker("裁剪", selection: $store.cropMode) {
                        Text("居中裁剪").tag("crop")
                        Text("完整画面").tag("fit")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: store.cropMode) { _, value in
                        store.commitCropMode()
                        controller.setCropMode(value)
                    }
                } else {
                    Text("关闭时仅在本机显示 CarPlay，预览与触控照常可用。")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
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

    // MARK: - CarPlay 预览卡

    private var previewCard: some View {
        AppleCard {
            VStack(spacing: 10) {
                CPPreviewView(controller: controller)
                    .aspectRatio(1024.0 / 480.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                controlRow
            }
        }
    }

    private var controlRow: some View {
        HStack(spacing: 10) {
            controlButton("house.fill", "主页") { controller.pressHome() }
            controlButton("smallcircle.filled.circle", "选择") { controller.pressSelect() }
            controlButton("chevron.backward", "返回") { controller.pressBack() }
            controlButton("mic.fill", "Siri") { controller.requestSiri() }
            controlButton("arrow.up.left.and.arrow.down.right", "全屏") { showFullscreen = true }
        }
    }

    private func controlButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(Theme.caption)
            }
            .foregroundStyle(Theme.label)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.groupedBackground)
            )
        }
        .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
    }

    private var fullscreenView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                CPPreviewView(controller: controller, fullscreen: true)
                    .aspectRatio(1024.0 / 480.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    controlButton("house.fill", "主页") { controller.pressHome() }
                    controlButton("smallcircle.filled.circle", "选择") { controller.pressSelect() }
                    controlButton("chevron.backward", "返回") { controller.pressBack() }
                    controlButton("mic.fill", "Siri") { controller.requestSiri() }
                    controlButton("xmark.circle.fill", "退出") { showFullscreen = false }
                }
                .padding(.horizontal, Theme.page)
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

// MARK: - 系统广播选择器

private struct BroadcastPickerView: UIViewRepresentable {
    let preferredExtension: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = preferredExtension
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {}
}

// MARK: - 分享面板

private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
