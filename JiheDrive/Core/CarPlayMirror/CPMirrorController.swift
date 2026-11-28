import Foundation
import UIKit

/// 线程安全的「最新视频帧」槽：CarPlay 收帧线程写入，仪表拉帧线程取走。
final class CPFrameBox {
    private let lock = NSLock()
    private var frame: Data?

    var latest: Data? {
        lock.withLock { frame }
    }

    func store(_ data: Data) {
        lock.withLock { frame = data }
    }

    func clear() {
        lock.withLock { frame = nil }
    }
}

/// 投屏总控：本机 CarPlay（CoreAccessories 直连 + RTSP 接收）为核心，
/// 画面与触控在本地预览即可使用；「投屏到极核仪表」是可开关的输出选项。
final class CPMirrorController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case identityMissing(String)
        case starting
        case transportReady
        case linkConnected
        case authenticated
        case identified
        case sessionRequested
        case waitingControl
        case controlConnected
        case localStreaming          // 本地画面已通，可预览与操作（核心目标）
        case streaming               // 本地 + 极核仪表同时投屏
        case liveFallback(String)    // 引导失败但接收端仍在运行，等待已有/手动会话
        case stopped(String?)
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "未启动"
            case .identityMissing(let hint): return "缺少配件身份：\(hint)"
            case .starting: return "正在启动本机 CarPlay…"
            case .transportReady: return "配件端点已就绪"
            case .linkConnected: return "iAP2 链路已连接"
            case .authenticated: return "配件认证已通过"
            case .identified: return "配件识别已通过"
            case .sessionRequested: return "已请求 CarPlay 会话"
            case .waitingControl: return "等待 CarPlay 控制连接…"
            case .controlConnected: return "CarPlay 控制连接已建立"
            case .localStreaming: return "CarPlay 已连接 · 本地可操作"
            case .streaming: return "CarPlay + 极核仪表投屏中"
            case .liveFallback(let reason): return "接收端运行中：\(reason)"
            case .stopped(let reason): return reason.map { "已停止：\($0)" } ?? "已停止"
            case .failed(let reason): return "失败：\(reason)"
            }
        }

        var isRunning: Bool {
            switch self {
            case .idle, .identityMissing, .stopped, .failed:
                return false
            default:
                return true
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var logs: [String] = []
    /// 本地 CarPlay 与极核输出解耦：关闭后仍保留预览和触控。
    @Published private(set) var castToZeeho = true
    @Published private(set) var zeehoStatus = "未启用"
    /// 已收到第一帧 CarPlay 视频（出画后才显示视频区/操作行/按键条）。
    @Published private(set) var hasVideo = false
    /// 极核仪表协商出的投屏规格文案（如「极核 6.2 寸 1024×480 · H.264」）。
    @Published private(set) var zeehoSpecText = "极核 6.2 寸 1024×480 · H.264"
    /// 用户选择的仪表车型档案 ID（"auto" = 自动适配）；「我的/投屏页」可改，持久化。
    @Published private(set) var zeehoModelID: String =
        UserDefaults.standard.string(forKey: "mirror.zeeho.model") ?? "auto"
    /// CarPlay 主屏「车辆按钮」被点按（requestUI）：每次点按生成新 UUID，
    /// 页面层 onChange(of:) 响应后打开车辆信息页。
    @Published private(set) var carUIRequestID: UUID?

    /// 极核仪表车型选项（与 ZeehoMirrorLink.DisplayProfile 对齐）
    static let zeehoModels: [(id: String, name: String)] = [
        ("auto", "自动适配"),
        ("zeeho62", "极核 6.2 寸"),
        ("zeeho62New", "极核 6.2 寸(新批次)"),
        ("zeehoSEPlus", "极核 SE+ 5/5.5 寸"),
    ]

    var zeehoModelName: String {
        Self.zeehoModels.first { $0.id == zeehoModelID }?.name ?? "自动适配"
    }

    /// 选择仪表车型：立即写偏好并在链路存活时热切换
    func setZeehoModel(_ id: String) {
        UserDefaults.standard.set(id, forKey: "mirror.zeeho.model")
        zeehoModelID = id
        zeehoLink?.preferredProfile = Self.profile(for: id)
        appendLog("仪表车型已选：\(Self.zeehoModels.first { $0.id == id }?.name ?? "自动适配")")
    }

    private static func profile(for id: String) -> ZeehoMirrorLink.DisplayProfile? {
        switch id {
        case "zeeho62": return .zeeho62
        case "zeeho62New": return .zeeho62New
        case "zeehoSEPlus": return .zeehoSEPlus
        default: return nil
        }
    }

    /// 生成 CarPlay 主屏车辆按钮图标：品牌蓝圆底 + 白色车形，
    /// 正方形 PNG（128px，协议上限 192px），/info 以 prerendered 形式下发。
    static func vehicleButtonIconPNG(size: CGFloat = 128) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            UIColor.systemBlue.setFill()
            context.cgContext.fillEllipse(in: rect.insetBy(dx: 3, dy: 3))
            let config = UIImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
            guard let glyph = UIImage(systemName: "car.fill",
                                      withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
            let glyphSize = glyph.size
            glyph.draw(in: CGRect(
                x: (size - glyphSize.width) / 2,
                y: (size - glyphSize.height) / 2,
                width: glyphSize.width, height: glyphSize.height))
        }
        return image.pngData()
    }

    func clearLogs() {
        DispatchQueue.main.async { [weak self] in self?.logs.removeAll() }
    }

    private let videoBox = CPFrameBox()
    /// 原始视频帧广播：预览层直接订阅，避免依赖转码器自解码。
    let frameHub = CPVideoFrameHub()
    /// 兼容性重编码管线（1024×480@25fps/2.5Mbps/Baseline）
    let transcoder = CPVideoTranscoder()
    /// 可操作预览窗口服务：画面以 MJPEG 提供给本机弹窗与同网设备，触控/按键回传。
    let previewServer = CPBrowserServer()
    /// 系统画中画悬浮窗（可拖动/缩放/覆盖其他 App，离开 App 也能保持）。
    let pip = CPPictureInPicture()
    private var bootstrap: CPBootstrap?
    private var bootstrapWatchTask: Task<Void, Never>?
    private var networkRestartCount = 0
    private var receiver: CPReceiver?
    private var zeehoLink: ZeehoMirrorLink?
    /// 仪表链路是否已启动（幂等标记：引导阶段与出画兜底都会触发启动，防双重拉起）。
    private var dashboardActive = false
    private var feederTask: Task<Void, Never>?
    private let stateLock = NSLock()
    private var firstFrameSent = false
    private var localVideoReceived = false
    private var pendingControlConnected = false
    private var dashboardIP: String = ""
    private var localIP: String = ""
    private var currentConfiguration: CPInfo.Configuration?
    private var currentIdentity: CPAccessoryIdentity?
    private var startToken = UUID()

    private var pipWanted = false

    // MARK: - 启动 / 停止

    /// 先起 RTSP 接收端；拿到实际监听端口后再发起 iAP2 引导（端口就绪前发会话会白等）。
    /// castToZeeho = false 时完全不触碰极核链路，本地 CarPlay 独立运行。
    func start(dashboardIP: String, localIP: String, castToZeeho: Bool) {
        guard !phase.isRunning else { return }
        let token = UUID()
        startToken = token
        UIApplication.shared.isIdleTimerDisabled = true
        // 黑屏修复关键：音频会话必须在前台、虚拟 CarPlay 路由被选中之前激活并全程持有。
        CPKeepAlive.shared.start()
        DispatchQueue.main.async { [weak self] in
            self?.logs.removeAll(keepingCapacity: true)
        }
        self.dashboardIP = dashboardIP
        self.localIP = localIP
        self.castToZeeho = castToZeeho
        self.localVideoReceived = false
        self.hasVideo = false
        self.dashboardActive = false
        self.pendingControlConnected = false
        self.transcoder.onKeyframeNeeded = { [weak self] in self?.requestKeyFrame() }
        // 每次启动前应用最新画面/投屏参数（分辨率/帧率/外观/极核帧率码率编码档）
        self.transcoder.configureCastSettings()
        self.applyCarPlayAppearance()
        self.zeehoStatus = castToZeeho ? "等待连接" : "未启用"
        setCropMode(UserDefaults(suiteName: MirrorLogStore.appGroupID)?.string(forKey: "mirror.crop") ?? "crop")
        startPreviewServer()

        let identity: CPAccessoryIdentity
        do {
            identity = try CPAccessoryIdentity.load()
        } catch {
            setPhase(.identityMissing(error.localizedDescription))
            appendLog("缺少配件身份：\(error.localizedDescription)")
            return
        }

        var configuration = CPInfo.Configuration.default(deviceID: CPDeviceID.persistent())
        configuration.name = "JiheDrive"
        configuration.address = localIP
        // CarPlay 主屏车辆按钮：点按后 iPhone 发 requestUI，App 弹出车辆信息页
        if configuration.oemIconPNG == nil {
            configuration.oemIconPNG = Self.vehicleButtonIconPNG()
        }
        currentConfiguration = configuration
        currentIdentity = identity
        setPhase(.starting)
        appendLog("启动同机 CarPlay（\(configuration.width)×\(configuration.height)@\(configuration.maxFPS) · \(CPDisplayConfig.resolution.rawValue)档，音频留在手机，极核投屏\(castToZeeho ? "开启" : "关闭")）")

        // 1) 极核仪表输出链路（可选）
        if castToZeeho { installZeehoLink() }

        // 2) CarPlay RTSP 接收端
        let receiver = CPReceiver()
        receiver.onLog = { [weak self] in self?.appendLog($0) }
        // 全量帧：转码器（极核仪表输出）依赖连续解码流，不做任何丢弃。
        // 但它只服务三处消费者——仪表投屏 / 画中画 / 网页预览；都不在用时
        // 别白解一路（整条 VT 解码管线跟预览抢 CPU/GPU，预览就发涩）
        receiver.onVideo = { [weak self] data, codec in
            guard let self, codec == .h264 else { return }
            if self.castToZeeho || self.pip.isActive || self.pipWanted
                || self.previewServer.hasActiveViewers() {
                self.transcoder.appendAnnexB(data)
            }
        }
        // 本机预览帧：受接收端背压控制（积压时跳到关键帧），直接吃原始访问单元
        receiver.onLocalVideo = { [weak self] data, codec in
            guard let self else { return }
            self.frameHub.publish(.frame(data, codec))
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.localVideoReceived else { return }
                self.localVideoReceived = true
                self.hasVideo = true
                self.pip.startFeed()
                self.appendLog("已收到 CarPlay 视频，本地预览与触控可用")
                self.setPhase(.localStreaming)
                // 兜底：引导已死/晚连/重连场景下 .controlConnected 可能不会再来，
                // 出画时仪表链路还没跑就由这里拉起（startDashboardLink 幂等，不会重复启动）
                if self.castToZeeho, self.zeehoLink != nil { self.startDashboardLink() }
            }
        }
        // CarPlay 主屏「车辆按钮」点按 → 打开 App 内车辆信息页
        receiver.onCarUIRequested = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.carUIRequestID = UUID() }
        }
        receiver.onControlConnected = { [weak self] in
            guard let self, self.startToken == token else { return }
            // 通知引导会话：否则它会在 45 秒后误判为「未收到控制连接」。
            if let bootstrap = self.bootstrap {
                bootstrap.didConnectControl()
            } else {
                self.pendingControlConnected = true
            }
        }
        receiver.onFailure = { [weak self] reason in
            guard let self, self.startToken == token else { return }
            // NoAuth / Bonjour 类失败不应整页判死——TCP 7000 可能仍在听；
            // 真正无端口时 listen 失败会在启动早期触发，这里降级为告警并允许引导继续。
            let soft = reason.contains("NoAuth") || reason.contains("-65555")
                || reason.contains("发现服务") || reason.contains("Bonjour")
            if soft {
                self.appendLog("本地接收端告警（不中断引导）：\(reason)")
                return
            }
            self.setPhase(.failed(reason))
            self.appendLog("本地接收端失败：\(reason)")
        }
        receiver.onListening = { [weak self] port in
            guard let self, self.startToken == token, self.receiver === receiver else { return }
            var live = configuration
            live.port = port
            self.currentConfiguration = live
            self.appendLog("控制端口 \(port) 就绪，等待本机网络后发起 CarPlay 会话")
            self.startBootstrapWhenNetworkReady(with: live, identity: identity, token: token)
        }
        receiver.start(configuration: configuration, identity: identity)
        self.receiver = receiver
    }

    func stop() {
        startToken = UUID()
        UIApplication.shared.isIdleTimerDisabled = false
        CPKeepAlive.shared.stop()
        bootstrapWatchTask?.cancel()
        bootstrapWatchTask = nil
        networkRestartCount = 0
        feederTask?.cancel()
        feederTask = nil
        previewPumpTask?.cancel()
        previewPumpTask = nil
        previewServer.stop()
        pip.stop()
        pipWanted = false
        bootstrap?.stop()
        bootstrap = nil
        receiver?.stop()
        receiver = nil
        zeehoLink?.stop()
        zeehoLink = nil
        dashboardActive = false
        videoBox.clear()
        frameHub.publish(.reset)
        transcoder.invalidate()
        stateLock.lock()
        firstFrameSent = false
        stateLock.unlock()
        localVideoReceived = false
        currentConfiguration = nil
        currentIdentity = nil
        zeehoStatus = "未启用"
        zeehoSpecText = "极核 6.2 寸 1024×480 · H.264"
        if phase.isRunning {
            setPhase(.stopped(nil))
        }
        appendLog("投屏已停止")
    }

    /// 引导失败后重试（不重启接收端，画面/触控不中断）。重试也带上 IP 盯守。
    func retryBootstrap() {
        guard phase.isRunning, var configuration = currentConfiguration,
              let identity = currentIdentity else { return }
        if let ip = CPMirrorDiagnostics.localIPv4(), ip != configuration.address {
            appendLog("本机 IP 已变化（\(configuration.address) → \(ip)），用新地址重试")
            configuration.address = ip
            currentConfiguration = configuration
        }
        appendLog("重新发起本机 CarPlay 引导…")
        bootstrap?.stop()
        bootstrap = nil
        setPhase(.starting)
        startBootstrap(with: configuration, identity: identity, token: startToken)
        startAddressWatch(initialAddress: configuration.address,
                          configuration: configuration, identity: identity, token: startToken)
    }

    /// 裁剪模式与整屏镜像共用 App Group 设置。
    func setCropMode(_ value: String) {
        transcoder.scaleMode = value == "fit" ? .fit : .crop
    }

    /// 运行中切换极核输出（下次启动也会读取同一状态）。
    func setCastToZeeho(_ enabled: Bool) {
        guard castToZeeho != enabled else { return }
        castToZeeho = enabled
        if !phase.isRunning { return }
        if enabled {
            if zeehoLink == nil { installZeehoLink() }
            startDashboardLink()
            // 转码器此前可能被按需解码饿着：先要关键帧才能立刻出画面
            requestKeyFrame()
            appendLog("已开启极核仪表投屏")
        } else {
            feederTask?.cancel()
            feederTask = nil
            zeehoLink?.stop()
            zeehoLink = nil
            dashboardActive = false
            zeehoStatus = "未启用"
            if case .streaming = phase { setPhase(.localStreaming) }
            appendLog("已关闭极核仪表投屏，本地 CarPlay 继续运行")
        }
    }

    // MARK: - 引导与阶段

    /// 本机没有 Wi-Fi IP 时不发 0x4301（空地址 iOS 连不回来，只能干等超时）。
    /// 等 IP 稳定后发起会话，并继续盯 IP 变化（手机切网/重连后 IP 会变，
    /// 会话必须用当前地址重发，否则永远停在"等待控制连接"）。
    private func startBootstrapWhenNetworkReady(with configuration: CPInfo.Configuration,
                                                identity: CPAccessoryIdentity, token: UUID) {
        bootstrapWatchTask?.cancel()
        networkRestartCount = 0
        if !configuration.address.isEmpty {
            startBootstrap(with: configuration, identity: identity, token: token)
            startAddressWatch(initialAddress: configuration.address,
                              configuration: configuration, identity: identity, token: token)
            return
        }
        appendLog("本机还没有 Wi-Fi IP，等待网络就绪…")
        let task = Task { [weak self] in
            var candidate: String?
            var stable = 0
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled, self.startToken == token else { return }
                let address = CPMirrorDiagnostics.localIPv4() ?? ""
                if address != candidate { candidate = address; stable = 0 }
                stable += 1
                guard let ip = candidate, !ip.isEmpty, stable >= 2 else { continue }
                await MainActor.run {
                    guard self.startToken == token else { return }
                    var live = configuration
                    live.address = ip
                    self.currentConfiguration = live
                    self.appendLog("本机 IP \(ip)，发起 CarPlay 会话")
                    self.startBootstrap(with: live, identity: identity, token: token)
                    self.startAddressWatch(initialAddress: ip,
                                           configuration: live, identity: identity, token: token)
                }
                return
            }
            await MainActor.run { [weak self] in
                self?.appendLog("20 秒内未获取到本机 Wi-Fi IP，请确认已加入 Wi-Fi 后重试")
            }
        }
        bootstrapWatchTask = task
    }

    /// 会话已发出但画面未通期间，监听本机 IP 变化；变化即用新地址重发会话（最多 2 次）。
    private func startAddressWatch(initialAddress: String, configuration: CPInfo.Configuration,
                                   identity: CPAccessoryIdentity, token: UUID) {
        bootstrapWatchTask?.cancel()
        let task = Task { [weak self] in
            var candidate: String?
            var stable = 0
            var lostAddress = false
            for _ in 0..<90 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                guard let self, self.startToken == token, !self.localVideoReceived else { return }
                let address = CPMirrorDiagnostics.localIPv4() ?? ""
                if address.isEmpty { lostAddress = true }
                if address != candidate { candidate = address; stable = 0 }
                stable += 1
                guard let ip = candidate, (ip != initialAddress || lostAddress), stable >= 3 else { continue }
                await MainActor.run {
                    guard self.startToken == token, !self.localVideoReceived,
                          self.networkRestartCount < 2 else { return }
                    self.networkRestartCount += 1
                    self.appendLog("启动期间本机 IP 变化（\(initialAddress.isEmpty ? "无" : initialAddress) → \(ip)），用新地址重发 CarPlay 会话")
                    var live = configuration
                    live.address = ip
                    self.currentConfiguration = live
                    self.bootstrap?.stop()
                    self.bootstrap = nil
                    self.setPhase(.starting)
                    self.startBootstrap(with: live, identity: identity, token: token)
                    self.startAddressWatch(initialAddress: ip, configuration: live,
                                           identity: identity, token: token)
                }
                return
            }
        }
        bootstrapWatchTask = task
    }

    private func startBootstrap(with configuration: CPInfo.Configuration,
                                identity: CPAccessoryIdentity, token: UUID) {
        let bootstrap = CPBootstrap()
        bootstrap.onLog = { [weak self] in self?.appendLog($0) }
        bootstrap.onStage = { [weak self] stage in
            guard let self, self.startToken == token else { return }
            // 本地画面已通时，不让引导的异步阶段把状态倒退回去。
            if self.localVideoReceived { return }
            switch stage {
            case .transportReady: self.setPhase(.transportReady)
            case .linkConnected: self.setPhase(.linkConnected)
            case .authenticated: self.setPhase(.authenticated)
            case .identified: self.setPhase(.identified)
            case .sessionRequested: self.setPhase(.waitingControl)
            case .controlConnected:
                self.setPhase(.controlConnected)
                if self.castToZeeho { self.startDashboardLink() }
            case .finished(let message), .failed(let message):
                // 关键：引导失败不等于本地接收失败——接收端继续监听，预览保持可用。
                self.appendLog("本机引导未成功：\(message)（本地接收端仍在运行）")
                self.setPhase(.liveFallback(message))
            default:
                break
            }
        }
        self.bootstrap = bootstrap
        bootstrap.start(configuration: configuration, identity: identity)
        if pendingControlConnected {
            pendingControlConnected = false
            bootstrap.didConnectControl()
        }
    }

    // MARK: - 极核链路与喂帧循环

    private func installZeehoLink() {
        let link = ZeehoMirrorLink()
        link.preferredProfile = Self.profile(for: zeehoModelID)
        link.onLog = { [weak self] in self?.appendLog($0) }
        link.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .streaming:
                self.zeehoStatus = "投屏中"
                if self.localVideoReceived { self.setPhase(.streaming) }
            case .ready:
                self.zeehoStatus = "协商完成"
                // 媒体协商完成：按仪表实际上报尺寸切换转码输出，适配极核各尺寸屏幕
                let size = link.outputSize
                self.transcoder.setOutputSize(width: size.width, height: size.height)
                self.zeehoSpecText = "\(link.negotiatedName) \(size.width)×\(size.height) · H.264"
            case .failed(let reason):
                self.zeehoStatus = "失败：\(reason)"
                // 失败后允许再次拉起（出画兜底 / 手动重试）
                self.dashboardActive = false
                self.appendLog("仪表链路失败：\(reason)（本地 CarPlay 不受影响）")
            case .closed:
                self.zeehoStatus = "已关闭"
            default:
                self.zeehoStatus = "连接中"
            }
        }
        zeehoLink = link
    }

    private func startDashboardLink() {
        guard castToZeeho else { return }
        guard let link = zeehoLink else { return }
        guard !dashboardActive else { return }
        dashboardActive = true
        zeehoStatus = "连接中"
        appendLog("开始极核仪表投屏（\(dashboardIP)）")
        stateLock.lock()
        firstFrameSent = false
        stateLock.unlock()
        link.start(localIP: localIP, targetIP: dashboardIP)
        let task = Task.detached { [weak link, weak self] in
            var first = true
            var sentFrames = 0
            var decodeWait: TimeInterval = 0
            var nextFrameTime: TimeInterval = 0
            while !Task.isCancelled, let link, !link.isClosed, let self {
                // 极核是拉帧模式：首帧未解出前不要消耗 0x72，否则仪表可能一直黑屏。
                // 这里原先静默死等——解码卡住时投屏无声无息失败，加周期日志给信号。
                while !Task.isCancelled, !self.transcoder.hasDecodedFrame {
                    Thread.sleep(forTimeInterval: 0.02)
                    decodeWait += 0.02
                    if decodeWait >= 10 {
                        decodeWait = 0
                        self.appendLog("已等待 CarPlay 解码首帧 10 秒仍无输出（预览有画面而转码器未解出帧时投屏不会开始，留意日志中的「解码失败」）")
                    }
                }
                guard !Task.isCancelled, !link.isClosed else { break }
                guard link.waitForFrameRequest() else {
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                // 25fps 节流：仪表拉快也不超发
                let now = ProcessInfo.processInfo.systemUptime
                let remaining = nextFrameTime - now
                if remaining > 0 {
                    Thread.sleep(forTimeInterval: min(remaining, 0.04))
                    continue
                }
                nextFrameTime = ProcessInfo.processInfo.systemUptime + 1.0 / 25.0
                // 一次拉帧对应一次回帧：编码失败时在本次拉取内重试，别把请求吞掉。
                var frame: Data?
                for _ in 0..<20 {
                    frame = self.transcoder.encodeLatest(forceKeyframe: first)
                    if frame != nil { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                guard let frame else {
                    self.requestKeyFrame()
                    continue
                }
                link.sendVideoFrame(frame, isFirstFrame: first)
                sentFrames += 1
                if sentFrames % 125 == 0 {
                    self.appendLog("已向仪表持续送帧 \(sentFrames) 帧")
                }
                if first {
                    first = false
                    self.appendLog("已发送首帧（IDR）")
                }
            }
        }
        feederTask = task
    }

    /// 仪表链路失败后的手动重试：重建链路并重新拉起（幂等标记已由失败回调清零）。
    func retryDashboardLink() {
        guard phase.isRunning, castToZeeho else { return }
        appendLog("手动重试极核仪表投屏")
        feederTask?.cancel()
        feederTask = nil
        dashboardActive = false
        zeehoLink?.stop()
        zeehoLink = nil
        installZeehoLink()
        startDashboardLink()
    }

    // MARK: - 可操作预览窗口

    /// 预览窗口地址（服务就绪且有本机 IP 时有效）。
    var previewURL: String? {
        guard previewServer.port > 0 else { return nil }
        guard let ip = CPMirrorDiagnostics.localIPv4() else { return nil }
        return "http://\(ip):\(previewServer.port)"
    }

    /// 有观看者连接时按 ~15fps 出 JPEG（没有观看者时完全不消耗 CPU）。
    private var previewPumpTask: Task<Void, Never>?

    private func startPreviewServer() {
        pip.frameProvider = { [weak self] in self?.transcoder.snapshotForDisplay() }
        pip.onLog = { [weak self] in self?.appendLog($0) }
        pip.onStopped = { [weak self] in
            self?.pipWanted = false
            self?.appendLog("画中画已关闭")
        }
        previewServer.onTouch = { [weak self] id, x, y, down in
            self?.touches([(id: id, x: x, y: y, down: down)])
        }
        previewServer.onKey = { [weak self] key in
            switch key {
            case "home": self?.pressHome()
            case "back": self?.pressBack()
            case "select": self?.pressSelect()
            case "siri": self?.requestSiri()
            default: break
            }
        }
        previewServer.onLog = { [weak self] in self?.appendLog($0) }
        previewServer.onViewerCountChanged = { [weak self] active in
            self?.setPreviewPumping(active)
        }
        previewServer.start(preferredPort: 8089)
    }

    private func setPreviewPumping(_ active: Bool) {
        guard active else {
            previewPumpTask?.cancel()
            previewPumpTask = nil
            return
        }
        guard previewPumpTask == nil else { return }
        previewPumpTask = Task { [weak self] in
            while !Task.isCancelled {
                if let jpeg = self?.transcoder.jpegLatest() {
                    self?.previewServer.publish(jpeg)
                }
                try? await Task.sleep(nanoseconds: 66_000_000) // ≈15fps
            }
        }
    }

    // MARK: - 预览触控与按键

    private struct TouchSlot {
        let id: Int
        var x: UInt16
        var y: UInt16
    }

    private let slotLock = NSLock()
    private var slots: [TouchSlot?] = [nil, nil] // CarPlay 触控描述符 2 槽

    /// 预览区触摸回调（归一化 0…1 坐标）→ 槽位管理 → HID 报告回传。
    func touches(_ points: [(id: Int, x: Double, y: Double, down: Bool)]) {
        guard phase.isRunning else { return }
        var report: [CPInfo.TouchContact] = []
        slotLock.lock()
        // 抬起：槽内 id 不在本次集合中
        for index in 0..<slots.count {
            if let slot = slots[index], !points.contains(where: { $0.id == slot.id }) {
                report.append(CPInfo.TouchContact(slot: index, x: slot.x, y: slot.y, down: false))
                slots[index] = nil
            }
        }
        for point in points {
            let x = UInt16(min(max(point.x, 0), 1) * Double(CPDisplayConfig.width))
            let y = UInt16(min(max(point.y, 0), 1) * Double(CPDisplayConfig.height))
            if let index = slots.firstIndex(where: { $0?.id == point.id }) {
                slots[index] = TouchSlot(id: point.id, x: x, y: y)
            } else if let free = slots.firstIndex(where: { $0 == nil }) {
                slots[free] = TouchSlot(id: point.id, x: x, y: y)
            }
        }
        for (index, slot) in slots.enumerated() {
            if let slot {
                report.append(CPInfo.TouchContact(slot: index, x: slot.x, y: slot.y, down: true))
            }
        }
        slotLock.unlock()
        receiver?.touches(report)
    }

    func pressHome() { receiver?.pressKnob(home: true) }
    func pressBack() { receiver?.pressKnob(back: true) }
    func pressSelect() { receiver?.pressKnob(select: true) }
    func requestSiri() { receiver?.requestSiri() }

    /// 启动系统画中画悬浮窗（需在用户手势里调用）。
    func startPictureInPicture() -> Bool {
        // 先标记想要画中画：转码器解码门控放行，首次启动才拿得到画面
        pipWanted = true
        requestKeyFrame()
        let started = pip.start()
        appendLog(started ? "已启动画中画悬浮窗" : "画中画暂未就绪（画面输出后才能启动）")
        return started
    }

    /// 显示层/转码器需要重新同步时，请系统立即编码一个关键帧。
    func requestKeyFrame() { receiver?.requestKeyFrame() }

    /// 应用 CarPlay 白天/夜间外观（跟随系统 = 不覆盖，白天/夜间 = 命令覆盖）。
    /// 接收端会记住最新状态并对之后新建的媒体会话自动生效。
    func applyCarPlayAppearance() {
        let appearance = CPDisplayConfig.appearance
        guard appearance != .system else { return }
        receiver?.setNightMode(appearance == .dark)
    }

    // MARK: - 状态

    private func setPhase(_ value: Phase) {
        DispatchQueue.main.async { [weak self] in
            self?.phase = value
        }
    }

    private func appendLog(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        MirrorLogStore.append(message)
        // 同步进主线程事件环：卡死报告里能看到卡死时 CarPlay 在干什么
        MainThreadHangMonitor.note("CP \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.logs.append("[\(stamp)] \(message)")
            if let logs = self?.logs, logs.count > 200 {
                self?.logs.removeFirst(logs.count - 200)
            }
        }
    }
}
