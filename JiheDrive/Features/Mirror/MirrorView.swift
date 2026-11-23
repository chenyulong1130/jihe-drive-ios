import SwiftUI
import ReplayKit

/// 投屏页：同机 CarPlay / 整屏镜像两种模式。
/// 布局从上到下：模式 → 状态（含自检摘要，点开弹窗看详情）→ 连接 → 日志，说明文字压到最少。
struct MirrorView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var store = MirrorStore()
    @StateObject private var controller = CPMirrorController()

    @State private var mode = "carplay"
    @State private var checks: [CPMirrorDiagnostics.CheckResult] = []
    @State private var runningChecks = false
    @State private var showExport = false
    @State private var exportURL: URL?
    @State private var timer: Timer?
    @State private var showFullscreen = false
    @State private var showPreflight = false
    @State private var pollTick = 0

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                LargeTitle("投屏")
                    .staggerIn(0)

                modeSelector.staggerIn(0)

                statusCard.staggerIn(1)

                if mode == "carplay" && controller.phase.isRunning {
                    previewCard.staggerIn(2)
                }

                SectionHeader("连接")
                connectionCard.staggerIn(3)

                if !controller.logs.isEmpty {
                    SectionHeader("日志")
                    logCard.staggerIn(6)
                }
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 8)
            .padding(.bottom, 118)
        }
        .background(Theme.groupedBackground)
        .onAppear {
            store.detectSSID()
            store.recheckIdentity()
            startPolling()
            if checks.isEmpty {
                Task { await runChecks() }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
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

    // MARK: - 状态卡

    private var statusCard: some View {
        AppleCard(padding: 18) {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(runningOrExt ? Theme.brand : Theme.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusText)
                            .font(Theme.headline)
                            .foregroundStyle(Theme.label)
                        Text(subtitle)
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    if runningOrExt {
                        StatusPill(text: "进行中", color: Theme.green)
                    } else if case .failed = controller.phase {
                        StatusPill(text: "失败", color: Theme.red)
                    } else {
                        StatusPill(text: "就绪", color: Theme.secondary)
                    }
                }

                if mode == "carplay" {
                    startButton
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
                    if controller.phase.isRunning {
                        Text("极核仪表：\(controller.zeehoStatus)")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    broadcastButton
                }

                // 自检摘要：一行带过，点开弹窗看逐项详情
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
                    .padding(.top, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(runningChecks)
            }
        }
    }

    private var runningOrExt: Bool {
        if mode == "screen" { return MirrorStore.extensionStatus() != nil }
        return controller.phase.isRunning
    }

    private var statusText: String {
        if mode == "screen" {
            return MirrorStore.extensionStatus() ?? "整屏镜像未运行"
        }
        return controller.phase.label
    }

    private var statusIcon: String {
        runningOrExt ? "dot.radiowaves.left.and.right" : "carplay"
    }

    private var subtitle: String {
        if mode == "screen" {
            return "可投任意 App，熄屏即停止"
        }
        if case .identityMissing = controller.phase {
            return "需要 CarPlay 配件身份"
        }
        if let ssid = store.currentSSID {
            return "当前 Wi-Fi：\(ssid)"
        }
        return store.locationDenied ? "获取 Wi-Fi 名称需要定位权限" : "未检测到 Wi-Fi"
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
                Text(controller.phase.isRunning ? "停止投屏" : "启动投屏")
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

    // MARK: - 连接卡（网络 + 仪表合并，减少碎卡）

    private var connectionCard: some View {
        AppleCard(padding: 18) {
            VStack(spacing: 14) {
                // 网络
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

                SecureField("热点密码（开放网络留空）", text: $store.wifiPassword)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

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

                if let status = store.hotspotStatus {
                    Text(status)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }

                HairLine()

                // 仪表（可选输出，不影响本地 CarPlay）
                Toggle("投屏到极核仪表", isOn: $store.castToZeeho)
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
                }
            }
        }
    }

    // MARK: - 自检：摘要行 + 详情弹窗（不再占页面位置）

    private var preflightSummaryText: String {
        if runningChecks { return "正在自检…" }
        if checks.isEmpty { return "尚未自检" }
        let failed = checks.filter { !$0.passed }
        if failed.isEmpty { return "自检全部通过（\(checks.count) 项）" }
        let names = failed.map(\.name).joined(separator: "、")
        return "自检 \(checks.count - failed.count)/\(checks.count) 未全过：\(names)"
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

    /// 自检详情弹窗：逐项展开（通过项也显示明细，如 SSID / 本机 IP）
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

    /// 弹窗里的详情行：每项名称 + 完整 detail（无论通过与否）
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
                HStack(spacing: 10) {
                    controlButton("house.fill", "主页") { controller.pressHome() }
                    controlButton("smallcircle.filled.circle", "选择") { controller.pressSelect() }
                    controlButton("chevron.backward", "返回") { controller.pressBack() }
                    controlButton("mic.fill", "Siri") { controller.requestSiri() }
                    controlButton("arrow.up.left.and.arrow.down.right", "全屏") { showFullscreen = true }
                }
            }
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

    // MARK: - 全屏预览

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

    // MARK: - 日志卡

    private var logCard: some View {
        AppleCard(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近事件（7 天）")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    Button {
                        exportURL = MirrorLogStore.exportFile()
                        showExport = exportURL != nil
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.trailing, 4)
                    Button {
                        controller.clearLogs()
                        MirrorLogStore.clearAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                    }
                }

                ForEach(Array(controller.logs.suffix(8).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 扩展状态轮询

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            if mode == "screen" {
                pollTick += 1
            }
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
