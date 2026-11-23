import SwiftUI
import ReplayKit

/// 投屏页：两种模式
/// ① 同机 CarPlay → 极核仪表（需要配件身份三件套）
/// ② 整屏镜像（ReplayKit 广播，可投任意 App）→ 极核仪表
/// WiFi 名称自动检测、密码按 SSID 记忆、支持一键加入仪表热点；
/// 启动前自动预检（身份 / Wi-Fi / 本机地址 / 仪表可达），日志可导出。
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
            // 10pt 基础间距：选择器/状态卡之间不再贴死；分组标题自带 24pt 上边距，叠加后约 34pt 一组
            VStack(spacing: 10) {
                LargeTitle("投屏")
                    .staggerIn(0)

                modeSelector.staggerIn(0)

                statusCard.staggerIn(1)

                if mode == "carplay" && controller.phase.isRunning {
                    SectionHeader("CarPlay 预览")
                    previewCard.staggerIn(2)
                }

                SectionHeader("预检")
                preflightCard.staggerIn(2)

                SectionHeader("网络")
                networkCard.staggerIn(3)

                SectionHeader("仪表")
                dashboardCard.staggerIn(4)

                SectionHeader("使用步骤")
                guideCard.staggerIn(5)

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
            // 进页自动预检一次，身份/网络状态不用手动点「重新预检」才知道
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
            return "可投任意 App（高德 / 苹果地图等），音频留在手机"
        }
        if case .identityMissing = controller.phase {
            return "需要苹果签发的 CarPlay 配件身份三件套"
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
                Text(controller.phase.isRunning ? "停止投屏" : "启动 CarPlay 投屏")
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
        VStack(spacing: 10) {
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
                        Text("开始整屏镜像（屏幕录制）")
                            .font(Theme.headline)
                    }
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
                )
            Text("在弹出的系统面板中选择「极核投屏」；仪表未就绪时扩展会自动重试约 1 分钟。")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - 预检卡

    private var preflightCard: some View {
        AppleCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                if let hint = store.identityHint {
                    SoftBanner(text: hint, icon: "key.horizontal.fill", tone: Theme.orange)
                }
                HStack {
                    Text(runningChecks ? "正在预检…" : (checks.isEmpty ? "启动前自动预检身份、网络与仪表" : "最近一次预检结果"))
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    Button {
                        Task { await runChecks() }
                    } label: {
                        if runningChecks {
                            ProgressView()
                        } else {
                            Text("重新预检").font(Theme.captionStrong)
                        }
                    }
                    .disabled(runningChecks)
                }
                HairLine()
                ForEach(checks) { result in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: result.passed ? "checkmark.circle.fill" :
                                (result.warning ? "exclamationmark.triangle.fill" : "xmark.circle.fill"))
                            .foregroundStyle(result.passed ? Theme.green :
                                                (result.warning ? Color(hex: 0xFF9F0A) : Theme.red))
                            .font(.system(size: 15))
                            .padding(.top, 2)
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
                    }
                }
                if checks.isEmpty {
                    Text("点「重新预检」立即检查，或直接启动投屏时自动执行。")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
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

    // MARK: - 网络卡

    private var networkCard: some View {
        AppleCard(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "wifi")
                        .foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.currentSSID ?? "未检测到 Wi-Fi")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.label)
                        Text(store.locationDenied
                             ? "在系统设置允许定位后可自动获取 Wi-Fi 名称"
                             : "已自动获取当前 Wi-Fi 名称")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("重新检测") {
                        store.detectSSID()
                    }
                    .font(Theme.footnote)
                }

                HairLine()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Wi-Fi 密码（按名称自动记忆）")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                    SecureField("开放网络可留空", text: $store.wifiPassword)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                HStack(spacing: 12) {
                    Button {
                        store.commitWiFi()
                    } label: {
                        Text("保存密码")
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.commitWiFi()
                        store.joinDashboardHotspot(ssid: store.currentSSID,
                                                   password: store.wifiPassword)
                    } label: {
                        Text("加入此网络")
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let status = store.hotspotStatus {
                    Text(status)
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    // MARK: - 仪表卡

    private var dashboardCard: some View {
        AppleCard(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "gauge.with.needle")
                        .foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("极核 6.2 寸仪表（AE4 MAX2+）")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.label)
                        Text("1024×480 · H.264 25帧 2.5Mbps · 拉帧式 PXC 协议")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Text("仪表 IP")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                    TextField("192.168.0.1", text: $store.dashboardIP)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Picker("裁剪", selection: $store.cropMode) {
                    Text("居中裁剪（导航区）").tag("crop")
                    Text("完整画面").tag("fit")
                }
                .pickerStyle(.segmented)
                .onChange(of: store.cropMode) { _, _ in
                    store.commitCropMode()
                }

                Text("iPhone 需加入仪表热点；默认地址 192.168.0.1。整屏镜像时「居中裁剪」会取屏幕中部横幅区域填满仪表。")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: - 指引卡

    private var guideCard: some View {
        AppleCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                guideRow(1, "把 iPhone 加入仪表热点（或点上方「加入此网络」）")
                guideRow(2, "在仪表上打开「投屏」功能页")
                if mode == "carplay" {
                    guideRow(3, "点「启动 CarPlay 投屏」，等待状态变为「正在投屏」")
                    guideRow(4, "CarPlay 画面出现在仪表上；导航语音仍由手机播放")
                } else {
                    guideRow(3, "点「开始整屏镜像」并在系统面板选择「极核投屏」")
                    guideRow(4, "任意 App 画面实时出现在仪表上；熄屏即停止")
                }
                HairLine()
                Text("身份三件套放入「文件」App → JiheDrive → IdentityImport/ 后重进本页自动导入。音视频仅在本机与局域网内处理，不经过任何服务器。")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(3)
            }
        }
    }

    private func guideRow(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(Circle().fill(Theme.brand))
            Text(text)
                .font(Theme.callout)
                .foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 日志卡

    private var logCard: some View {
        AppleCard(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近事件（本地保存 7 天，可导出反馈问题）")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    Button {
                        exportURL = MirrorLogStore.exportFile()
                        showExport = exportURL != nil
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14))
                    }
                    .padding(.trailing, 8)
                    Button {
                        controller.clearLogs()
                        MirrorLogStore.clearAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                    }
                }

                ForEach(Array(controller.logs.suffix(12).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
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
