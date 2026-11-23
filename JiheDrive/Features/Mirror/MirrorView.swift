import SwiftUI
import ReplayKit

/// 投屏页：同机 CarPlay / 整屏镜像两种模式。
/// 布局从上到下：模式 → 状态 → 预览 → 网络 → 仪表 → 自检 → 日志，说明文字压到最少。
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

                SectionHeader("网络")
                networkCard.staggerIn(3)

                SectionHeader("仪表")
                dashboardCard.staggerIn(4)

                SectionHeader("自检")
                preflightCard.staggerIn(5)

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
            VStack(spacing: 16) {
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

                if let hint = store.identityHint {
                    SoftBanner(text: hint, icon: "key.horizontal.fill", tone: Theme.orange)
                }

                if mode == "carplay" {
                    startButton
                } else {
                    broadcastButton
                }
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

    /// 启动前预检：硬性失败（身份缺失/无本机地址）不启动，其余提示后允许启动。
    private func startCarPlayAfterPreflight() async {
        let results = await runChecks()
        let hardFailures = results.filter { !$0.passed && !$0.warning }
        guard hardFailures.isEmpty else {
            controller.stop()
            return
        }
        store.commitWiFi()
        store.commitDashboardIP()
        let localIP = CPMirrorDiagnostics.localIPv4() ?? ""
        controller.start(dashboardIP: store.dashboardIP, localIP: localIP)
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

    // MARK: - 网络卡

    private var networkCard: some View {
        AppleCard(padding: 18) {
            VStack(spacing: 14) {
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
            }
        }
    }

    // MARK: - 仪表卡

    private var dashboardCard: some View {
        AppleCard(padding: 18) {
            VStack(spacing: 14) {
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
                .onChange(of: store.cropMode) { _, _ in
                    store.commitCropMode()
                }
            }
        }
    }

    // MARK: - 自检卡（通过项一行带过，失败项才展开详情）

    private var preflightCard: some View {
        AppleCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(runningChecks ? "正在自检…" : "共 \(checks.count) 项")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    Button {
                        Task { await runChecks() }
                    } label: {
                        if runningChecks {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Theme.surfaceAlt))
                        }
                    }
                    .disabled(runningChecks)
                }

                if checks.allSatisfy(\.passed) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.green)
                            .font(.system(size: 15))
                        Text("全部通过")
                            .font(Theme.footnote.weight(.semibold))
                            .foregroundStyle(Theme.label)
                        Spacer(minLength: 0)
                    }
                } else {
                    ForEach(checks) { result in
                        preflightRow(result)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func preflightRow(_ result: CPMirrorDiagnostics.CheckResult) -> some View {
        let failed = !result.passed
        HStack(alignment: failed ? .top : .center, spacing: 10) {
            Image(systemName: result.passed ? "checkmark.circle.fill" :
                    (result.warning ? "exclamationmark.triangle.fill" : "xmark.circle.fill"))
                .foregroundStyle(result.passed ? Theme.green :
                                    (result.warning ? Color(hex: 0xFF9F0A) : Theme.red))
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: failed ? 4 : 0) {
                Text(result.name)
                    .font(Theme.footnote.weight(.semibold))
                    .foregroundStyle(Theme.label)
                if failed {
                    Text(result.detail)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func runChecks() async -> [CPMirrorDiagnostics.CheckResult] {
        await MainActor.run { runningChecks = true }
        let results = await CPMirrorDiagnostics.preflight(dashboardIP: store.dashboardIP)
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
