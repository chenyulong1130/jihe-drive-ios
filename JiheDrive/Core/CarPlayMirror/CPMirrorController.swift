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

/// 投屏总控：本机 CarPlay（CoreAccessories 直连 + RTSP 接收）→ H.264 透传 → 极核仪表。
/// CarPlay 显示分辨率即仪表的 1024×480，视频访问单元直接透传，无需二次编码。
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
        case negotiatingDashboard
        case streaming
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
            case .negotiatingDashboard: return "正在连接极核仪表…"
            case .streaming: return "正在投屏 · 1024×480 · H.264"
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
    private var dashboardIP: String = ""
    private var localIP: String = ""

    // MARK: - 启动 / 停止

    /// 启动同机 CarPlay 并投屏到极核仪表。
    func start(dashboardIP: String, localIP: String) {
        guard !phase.isRunning else { return }
        DispatchQueue.main.async { [weak self] in
            self?.logs.removeAll(keepingCapacity: true)
        }
        self.dashboardIP = dashboardIP
        self.localIP = localIP
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
        setPhase(.starting)
        appendLog("启动同机 CarPlay（\(configuration.width)×\(configuration.height)@\(configuration.maxFPS)，音频留在手机）")

        // 1) 极核仪表输出链路
        let link = ZeehoMirrorLink()
        link.onLog = { [weak self] in self?.appendLog($0) }
        link.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .streaming:
                self.setPhase(.streaming)
            case .ready:
                self.setPhase(.negotiatingDashboard)
            case .failed(let reason):
                self.appendLog("仪表链路失败：\(reason)")
            default:
                break
            }
        }
        zeehoLink = link

        // 2) CarPlay RTSP 接收端
        let receiver = CPReceiver()
        receiver.onLog = { [weak self] in self?.appendLog($0) }
        receiver.onVideo = { [weak self] data, codec in
            guard codec == .h264 else { return }
            self?.videoBox.store(data)
            self?.transcoder.appendAnnexB(data)
        }
        receiver.onFailure = { [weak self] reason in
            self?.setPhase(.failed(reason))
        }
        receiver.start(configuration: configuration, identity: identity)
        self.receiver = receiver

        // 3) 同机引导会话
        let bootstrap = CPBootstrap()
        bootstrap.onLog = { [weak self] in self?.appendLog($0) }
        bootstrap.onStage = { [weak self] stage in
            guard let self else { return }
            switch stage {
            case .transportReady: self.setPhase(.transportReady)
            case .linkConnected: self.setPhase(.linkConnected)
            case .authenticated: self.setPhase(.authenticated)
            case .identified: self.setPhase(.identified)
            case .sessionRequested: self.setPhase(.waitingControl)
            case .controlConnected:
                self.setPhase(.controlConnected)
                self.startDashboardLink()
            case .finished(let message):
                self.setPhase(.stopped(message))
            case .failed(let message):
                self.setPhase(.failed(message))
            default:
                break
            }
        }
        bootstrap.start(configuration: configuration, identity: identity)
        self.bootstrap = bootstrap
    }

    func stop() {
        feederTask?.cancel()
        feederTask = nil
        bootstrap?.stop()
        bootstrap = nil
        receiver?.stop()
        receiver = nil
        zeehoLink?.stop()
        zeehoLink = nil
        videoBox.clear()
        stateLock.lock()
        firstFrameSent = false
        stateLock.unlock()
        if phase.isRunning {
            setPhase(.stopped(nil))
        }
        appendLog("投屏已停止")
    }

    // MARK: - 仪表链路与喂帧循环

    private func startDashboardLink() {
        let link = zeehoLink
        guard let link else { return }
        setPhase(.negotiatingDashboard)
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
