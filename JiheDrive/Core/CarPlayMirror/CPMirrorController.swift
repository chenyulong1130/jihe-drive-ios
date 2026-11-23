import Foundation

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

    func clearLogs() {
        DispatchQueue.main.async { [weak self] in self?.logs.removeAll() }
    }

    private let videoBox = CPFrameBox()
    /// 兼容性重编码管线（与 CarWithin 验证参数一致：1024×480@25fps/2.5Mbps/Baseline）
    let transcoder = CPVideoTranscoder()
    private var bootstrap: CPBootstrap?
    private var receiver: CPReceiver?
    private var zeehoLink: ZeehoMirrorLink?
    private var feederTask: Task<Void, Never>?
    private let stateLock = NSLock()
    private var firstFrameSent = false
    private var localVideoReceived = false
    private var dashboardIP: String = ""
    private var localIP: String = ""
    private var currentConfiguration: CPInfo.Configuration?
    private var currentIdentity: CPAccessoryIdentity?
    private var startToken = UUID()

    // MARK: - 启动 / 停止

    /// 先起 RTSP 接收端；拿到实际监听端口后再发起 iAP2 引导（CarWithin 同款顺序）。
    /// castToZeeho = false 时完全不触碰极核链路，本地 CarPlay 独立运行。
    func start(dashboardIP: String, localIP: String, castToZeeho: Bool) {
        guard !phase.isRunning else { return }
        let token = UUID()
        startToken = token
        DispatchQueue.main.async { [weak self] in
            self?.logs.removeAll(keepingCapacity: true)
        }
        self.dashboardIP = dashboardIP
        self.localIP = localIP
        self.castToZeeho = castToZeeho
        self.localVideoReceived = false
        self.zeehoStatus = castToZeeho ? "等待连接" : "未启用"

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
        currentConfiguration = configuration
        currentIdentity = identity
        setPhase(.starting)
        appendLog("启动同机 CarPlay（\(configuration.width)×\(configuration.height)@\(configuration.maxFPS)，音频留在手机，极核投屏\(castToZeeho ? "开启" : "关闭")）")

        // 1) 极核仪表输出链路（可选）
        if castToZeeho { installZeehoLink() }

        // 2) CarPlay RTSP 接收端
        let receiver = CPReceiver()
        receiver.onLog = { [weak self] in self?.appendLog($0) }
        receiver.onVideo = { [weak self] data, codec in
            guard codec == .h264, let self else { return }
            self.videoBox.store(data)
            self.transcoder.appendAnnexB(data)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.localVideoReceived else { return }
                self.localVideoReceived = true
                self.appendLog("已收到 CarPlay 视频，本地预览与触控可用")
                self.setPhase(.localStreaming)
            }
        }
        receiver.onFailure = { [weak self] reason in
            guard let self, self.startToken == token else { return }
            self.setPhase(.failed(reason))
            self.appendLog("本地接收端失败：\(reason)")
        }
        receiver.onListening = { [weak self] port in
            guard let self, self.startToken == token, self.receiver === receiver else { return }
            var live = configuration
            live.port = port
            self.currentConfiguration = live
            self.appendLog("控制端口 \(port) 就绪，正在发起 CarPlay 会话")
            self.startBootstrap(with: live, identity: identity, token: token)
        }
        receiver.start(configuration: configuration, identity: identity)
        self.receiver = receiver
    }

    func stop() {
        startToken = UUID()
        feederTask?.cancel()
        feederTask = nil
        bootstrap?.stop()
        bootstrap = nil
        receiver?.stop()
        receiver = nil
        zeehoLink?.stop()
        zeehoLink = nil
        videoBox.clear()
        transcoder.invalidate()
        stateLock.lock()
        firstFrameSent = false
        stateLock.unlock()
        localVideoReceived = false
        currentConfiguration = nil
        currentIdentity = nil
        zeehoStatus = "未启用"
        if phase.isRunning {
            setPhase(.stopped(nil))
        }
        appendLog("投屏已停止")
    }

    /// 引导失败后重试（不重启接收端，画面/触控不中断）。
    func retryBootstrap() {
        guard phase.isRunning, let configuration = currentConfiguration,
              let identity = currentIdentity else { return }
        appendLog("重新发起本机 CarPlay 引导…")
        bootstrap?.stop()
        bootstrap = nil
        setPhase(.starting)
        startBootstrap(with: configuration, identity: identity, token: startToken)
    }

    /// 运行中切换极核输出（下次启动也会读取同一状态）。
    func setCastToZeeho(_ enabled: Bool) {
        guard castToZeeho != enabled else { return }
        castToZeeho = enabled
        if !phase.isRunning { return }
        if enabled {
            if zeehoLink == nil { installZeehoLink() }
            startDashboardLink()
            appendLog("已开启极核仪表投屏")
        } else {
            feederTask?.cancel()
            feederTask = nil
            zeehoLink?.stop()
            zeehoLink = nil
            zeehoStatus = "未启用"
            if case .streaming = phase { setPhase(.localStreaming) }
            appendLog("已关闭极核仪表投屏，本地 CarPlay 继续运行")
        }
    }

    // MARK: - 引导与阶段

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
        bootstrap.start(configuration: configuration, identity: identity)
        self.bootstrap = bootstrap
    }

    // MARK: - 极核链路与喂帧循环

    private func installZeehoLink() {
        let link = ZeehoMirrorLink()
        link.onLog = { [weak self] in self?.appendLog($0) }
        link.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .streaming:
                self.zeehoStatus = "投屏中"
                if self.localVideoReceived { self.setPhase(.streaming) }
            case .ready:
                self.zeehoStatus = "协商完成"
            case .failed(let reason):
                self.zeehoStatus = "失败：\(reason)"
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
        zeehoStatus = "连接中"
        appendLog("开始极核仪表投屏（\(dashboardIP)）")
        stateLock.lock()
        firstFrameSent = false
        stateLock.unlock()
        link.start(localIP: localIP, targetIP: dashboardIP)
        let task = Task.detached { [weak link, weak self] in
            var first = true
            var nextFrameTime: TimeInterval = 0
            while !Task.isCancelled, let link, !link.isClosed, let self {
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
                guard let frame = self.transcoder.encodeLatest(forceKeyframe: first) else {
                    continue
                }
                link.sendVideoFrame(frame, isFirstFrame: first)
                if first {
                    first = false
                    self.appendLog("已发送首帧（IDR）")
                }
            }
        }
        feederTask = task
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
            let x = UInt16(min(max(point.x, 0), 1) * 1024)
            let y = UInt16(min(max(point.y, 0), 1) * 480)
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

    // MARK: - 状态

    private func setPhase(_ value: Phase) {
        DispatchQueue.main.async { [weak self] in
            self?.phase = value
        }
    }

    private func appendLog(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        MirrorLogStore.append(message)
        DispatchQueue.main.async { [weak self] in
            self?.logs.append("[\(stamp)] \(message)")
            if let logs = self?.logs, logs.count > 200 {
                self?.logs.removeFirst(logs.count - 200)
            }
        }
    }
}
