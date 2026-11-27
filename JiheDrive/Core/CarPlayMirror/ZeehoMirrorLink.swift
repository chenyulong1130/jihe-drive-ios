import Foundation
import UIKit
import Network

/// 极核仪表 PXC 投屏会话（档案驱动，支持极核各尺寸仪表）。
/// 手机监听 10922(控制)/10711(媒体)/10710(视频)，主动连仪表 10930 发起投屏请求；
/// 仪表回连后完成 RSA 身份协商，随后逐帧拉取 H.264。
/// 显示差异收敛在 DisplayProfile：媒体配置阶段仪表会上报实际面板尺寸，
/// 会话按协商结果回 0x11 并把输出尺寸暴露给上层（转码器按此重编码）。
final class ZeehoMirrorLink {

    /// 显示档案：一类极核仪表屏幕 = 一个档案（对齐参考实现 1.0.5 的 TailingDisplayProfile）。
    struct DisplayProfile: Equatable {
        let width: Int
        let height: Int
        let name: String

        static let zeeho62 = DisplayProfile(width: 1024, height: 480, name: "极核 6.2 寸")
        static let zeeho62New = DisplayProfile(width: 1024, height: 488, name: "极核 6.2 寸(新批次)")
        /// SE+ 5/5.5 寸实测上报 1600×770；其他 AE2/新屏按上报值自适应。
        static let zeehoSEPlus = DisplayProfile(width: 1600, height: 770, name: "极核 SE+ 5/5.5 寸")

        /// 回给仪表/编码器的输出尺寸：新批次面板上报 488 高，
        /// 但参考实现回 1024×480 才兼容，这里统一换算。
        var outputSize: (width: Int, height: Int) {
            if width == 1024 && height == 488 { return (1024, 480) }
            return (width, height)
        }
    }

    /// 已知极核屏幕档案；未匹配的尺寸按「合理范围」自适应接受。
    static let knownProfiles: [DisplayProfile] = [.zeeho62, .zeeho62New, .zeehoSEPlus]

    /// 用户在投屏页选择的车型档案；nil = 自动适配。
    /// 仪表上报与所选档案一致时直接按档案输出；上报的是未知尺寸时也按所选档案输出；
    /// 上报命中的是另一个已知档案时以仪表上报为准（已实测的路径不冒进）。
    var preferredProfile: DisplayProfile?

    /// 仪表上报的尺寸是否可接受（对齐参考实现 1.0.5 的档案边界）。
    /// AE2 档案：240–1920 × 240–1080；SE+ 档案：宽≥高、偶数尺寸（编码器 4:2:0 要求）。
    static func acceptable(width: Int, height: Int) -> Bool {
        if knownProfiles.contains(where: { $0.width == width && $0.height == height }) { return true }
        return (240...1920).contains(width) && (240...1080).contains(height)
            && width >= height
            && width.isMultiple(of: 2) && height.isMultiple(of: 2)
    }

    /// 编码器 4:2:0 需要偶数尺寸：向下取整到偶数。
    static func even(_ value: Int) -> Int { value & ~1 }


    struct Ports {
        let control: UInt16
        let auxiliary: UInt16
        let video: UInt16
        let announcement: UInt16
        static let standard = Ports(control: 10922, auxiliary: 10711, video: 10710, announcement: 10930)
    }

    struct PhoneProfile {
        let packageName: String
        let versionCode: Int
        let model: String
        let systemVersion: String
        let width: Int
        let height: Int

        static func current() -> PhoneProfile {
            let screen = UIScreen.main
            return PhoneProfile(
                packageName: Bundle.main.bundleIdentifier ?? "com.qianxu.jihedrive",
                versionCode: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0,
                model: "iPhone",
                systemVersion: UIDevice.current.systemVersion,
                width: Int(screen.bounds.width * screen.scale),
                height: Int(screen.bounds.height * screen.scale))
        }
    }

    enum State: Equatable {
        case idle
        case listening
        case announcing
        case negotiating
        case ready        // 媒体协商完成，等待拉帧
        case streaming
        case failed(String)
        case closed
    }

    let width = 1024
    let height = 480

    /// 媒体协商完成后确定的实际输出尺寸（0x11 回给仪表的值）。
    /// 默认 1024×480；仪表上报 1024×488 时按参考实现回 480；
    /// 未知尺寸按上报值自适应。上层（转码器/界面）应读取此值。
    private(set) var outputSize: (width: Int, height: Int) = (1024, 480)
    private(set) var negotiatedName: String = DisplayProfile.zeeho62.name

    private let queue = DispatchQueue(label: "jihedrive.zeeho.link", qos: .userInitiated)
    private var controlListener: ZeehoMirrorListener?
    private var auxiliaryListener: ZeehoMirrorListener?
    private var videoListener: ZeehoMirrorListener?
    private var controlChannel: ZeehoMirrorChannel?
    private var auxiliaryChannel: ZeehoMirrorChannel?
    private var videoChannel: ZeehoMirrorChannel?
    private var reverseControlChannel: ZeehoMirrorChannel?
    private var heartbeat: DispatchSourceTimer?
    private var identity: ZeehoMirrorIdentity.Identity?
    private var huid: String?
    private var signedHUID: Data?
    private var configured = false
    private var mediaStarted = false
    private var closed = true
    private var targetIP: String = ""
    private var localIP: String = ""
    private var failure: Error?

    var onState: ((State) -> Void)?
    var onLog: ((String) -> Void)?

    /// 会话是否已关闭（喂帧循环用）。
    var isClosed: Bool {
        stateLock.withLock { closed }
    }

    private let stateLock = NSLock()

    var currentState: State = .idle {
        didSet {
            if currentState != oldValue {
                DispatchQueue.main.async { [weak self] in self?.onState?(self?.currentState ?? .idle) }
            }
        }
    }

    // MARK: - 生命周期

    /// 启动投屏会话。`startVideoFeeder` 在媒体协商完成后被调用（后台队列），
    /// 实现需在收到拉帧请求时回调 `onFrameRequest`。
    func start(localIP: String, targetIP: String) {
        stop()
        self.localIP = localIP
        self.targetIP = targetIP
        outputSize = (1024, 480)
        negotiatedName = Self.DisplayProfile.zeeho62.name
        closed = false
        failure = nil
        currentState = .listening
        report("正在监听仪表回连端口…")
        queue.async { [weak self] in self?.runSession() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.closed else { return }
            self.closed = true
            // 极核要求显式通知停止投屏
            if let reverse = self.reverseControlChannel,
               let payload = try? ZeehoMirrorFrame.json(["control": 0]),
               let control = try? ZeehoMirrorFrame.encodeControl(command: 0x20590,
                                                                 identifier: UInt32.max, payload: payload) {
                try? self.awaitWrite(reverse, control)
            }
            heartbeat?.cancel()
            heartbeat = nil
            controlListener?.stop()
            auxiliaryListener?.stop()
            videoListener?.stop()
            controlChannel?.close()
            auxiliaryChannel?.close()
            videoChannel?.close()
            reverseControlChannel?.close()
            controlListener = nil
            auxiliaryListener = nil
            videoListener = nil
            controlChannel = nil
            auxiliaryChannel = nil
            videoChannel = nil
            reverseControlChannel = nil
            self.huid = nil
            self.signedHUID = nil
            self.configured = false
            self.mediaStarted = false
            self.currentState = .closed
        }
    }

    deinit { stop() }

    private func fail(_ error: Error) {
        queue.async { [weak self] in
            guard let self else { return }
            let wasOpen = self.stateLock.withLock { !self.closed }
            guard wasOpen else { return }
            self.stateLock.withLock { self.closed = true }
            self.failure = error
            self.log("极核投屏失败：\(error.localizedDescription)")
            self.currentState = .failed(error.localizedDescription)
            self.teardownChannels()
        }
    }

    private func teardownChannels() {
        closed = true
        heartbeat?.cancel()
        heartbeat = nil
        controlListener?.stop()
        auxiliaryListener?.stop()
        videoListener?.stop()
        controlChannel?.close()
        auxiliaryChannel?.close()
        videoChannel?.close()
        reverseControlChannel?.close()
        controlListener = nil
        auxiliaryListener = nil
        videoListener = nil
        controlChannel = nil
        auxiliaryChannel = nil
        videoChannel = nil
        reverseControlChannel = nil
    }

    private func report(_ message: String) {
        log(message)
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(message) }
    }

    // MARK: - 会话主流程（后台队列）

    private func runSession() {
        do {
            let identity = try ZeehoMirrorIdentity.load()
            self.identity = identity

            // 先全部监听，再请求仪表反向连接
            let listeners: [(UInt16, ZeehoMirrorListener)] = try [
                Ports.standard.control, Ports.standard.auxiliary, Ports.standard.video,
            ].map { port in
                let listener = ZeehoMirrorListener(queue: queue)
                try listener.start(port: port) { [weak self] channel in
                    self?.accept(channel, port: port)
                }
                return (port, listener)
            }
            for (port, listener) in listeners {
                switch port {
                case Ports.standard.control: controlListener = listener
                case Ports.standard.auxiliary: auxiliaryListener = listener
                default: videoListener = listener
                }
            }
            log("已监听 \(localIP):\(Ports.standard.control)/\(Ports.standard.auxiliary)/\(Ports.standard.video)")

            // 主动向仪表发起投屏请求
            currentState = .announcing
            let announcement: ZeehoMirrorChannel
            do {
                announcement = try awaitConnect(host: targetIP, port: Ports.standard.announcement, name: "仪表公告通道")
            } catch {
                // 直连失败：仪表不一定是 .1，按 /24 自动发现（上次成功地址优先）后重试
                guard let found = awaitAsync({ await Self.discoverDashboard(localIP: self.localIP, log: self.log) }),
                      let address = found else {
                    throw CPError.timeout("未在网段内发现仪表（10930）——请确认仪表已开启投屏/互联功能，或手动填写仪表 IP")
                }
                targetIP = address
                announcement = try awaitConnect(host: address, port: Ports.standard.announcement, name: "仪表公告通道")
            }
            defer { announcement.close() }
            let request = try ZeehoMirrorFrame.encodeControl(
                command: 0x70000010,
                payload: try ZeehoMirrorFrame.json([
                    "phoneType": "iOS",
                    "packageName": Bundle.main.bundleIdentifier ?? "com.qianxu.jihedrive",
                ]))
            try awaitWrite(announcement, request)
            let reply = try ZeehoMirrorFrame.decodeControl { count in
                try awaitRead(announcement, count: count, timeout: 3)
            }
            guard reply.command == 0x70000011,
                  let status = try? ZeehoMirrorFrame.object(reply.payload)["status"] as? Bool, status else {
                throw CPError.rejected("仪表未接受 iOS 投屏请求（0x\(String(reply.command, radix: 16))）")
            }
            currentState = .negotiating
            log("仪表已接受请求，等待其回连与协商…")

            // 等待：签名完成 + 视频回连 + 媒体启动（最多 20 秒）
            let deadline = Date().addingTimeInterval(20)
            while isClosed == false, failure == nil,
                  signedHUID == nil || videoChannel == nil || !mediaStarted {
                Thread.sleep(forTimeInterval: 0.05)
                if Date() > deadline {
                    throw CPError.timeout("媒体会话未就绪（请退出官方投屏后重新打开仪表投屏）")
                }
            }
            currentState = .ready
            log("媒体协商完成，等待仪表逐帧请求")
        } catch {
            fail(error)
        }
    }

    private var condition = NSCondition()

    // MARK: - 仪表 IP 自动发现（/24 TCP 探测；思路对齐 CarWithin 的 TailingDiscovery：
    // 单播 TCP 不依赖组播 entitlement；上次成功地址优先，其次网关/网段常规地址，最后全段）

    static let discoveredAddressKey = "zeehoLastDiscoveredAddress"

    /// 并发探测网段内监听 10930 的设备，命中即返回 IP（只做 TCP 连接探测，不发 PXC 帧）
    static func discoverDashboard(localIP: String, log: @escaping (String) -> Void) async -> String? {
        guard let parts = ipv4Parts(localIP) else { return nil }
        let prefix = "\(parts.0).\(parts.1).\(parts.2)"
        var candidates: [String] = []
        if let previous = UserDefaults.standard.string(forKey: discoveredAddressKey) {
            candidates.append(previous)
        }
        candidates.append("\(prefix).1")   // 仪表热点网关（最常见）
        candidates.append("\(prefix).2")   // 部分固件占用 .2
        for host in 1...254 {
            candidates.append("\(prefix).\(host)")
        }
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0).inserted && $0 != localIP }

        log("直连失败，开始自动发现仪表（/24 探测 10930，共 \(candidates.count) 个地址）…")
        var batchStart = 0
        while batchStart < candidates.count {
            let batch = Array(candidates[batchStart..<min(batchStart + 16, candidates.count)])
            batchStart += 16
            let hit: String? = await withTaskGroup(of: String?.self) { group in
                for address in batch {
                    group.addTask { await probePort(address, port: Ports.standard.announcement) ? address : nil }
                }
                var found: String?
                for await result in group {
                    if let result {
                        found = result
                        group.cancelAll()
                    }
                }
                return found
            }
            if let hit {
                UserDefaults.standard.set(hit, forKey: discoveredAddressKey)
                log("已在 \(hit) 发现仪表")
                return hit
            }
        }
        return nil
    }

    private static func ipv4Parts(_ address: String) -> (UInt8, UInt8, UInt8)? {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// 单次 TCP 连接探测（1.2s 超时；该地址 10930 有监听即命中）
    static func probePort(_ host: String, port: UInt16, timeout: TimeInterval = 1.2) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let portValue = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: portValue, using: .tcp)
            let queue = DispatchQueue(label: "jihedrive.probe")
            var finished = false
            let finish: (Bool) -> Void = { ok in
                if !finished {
                    finished = true
                    connection.cancel()
                    continuation.resume(returning: ok)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
            connection.start(queue: queue)
        }
    }

    /// async 工作桥接到同步上下文（runSession 运行在串行 queue 上）
    private func awaitAsync<T>(_ work: @escaping () async -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        Task.detached {
            result = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func awaitConnect(host: String, port: UInt16, name: String) throws -> ZeehoMirrorChannel {
        log("正在连接\(name) \(host):\(port)…")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<ZeehoMirrorChannel, Error>?
        Task.detached {
            do {
                let channel = try await ZeehoMirrorChannel.connect(host: host, port: port, name: name)
                result = .success(channel)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        // 必须带超时：仪表未开启投屏（10930 未监听）时 TCP 可能静默挂起，
        // 没有超时会让整个投屏流程无日志卡死
        if semaphore.wait(timeout: .now() + 6) == .timedOut {
            throw CPError.timeout("连接\(name)超时——请确认仪表已开启投屏/互联功能")
        }
        switch result! {
        case .success(let channel):
            log("\(name)已连接")
            return channel
        case .failure(let error): throw error
        }
    }

    private func awaitRead(_ channel: ZeehoMirrorChannel, count: Int, timeout: TimeInterval) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        Task.detached {
            do {
                let data = try await channel.readExactly(count, timeout: timeout)
                result = .success(data)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch result! {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }

    /// 同步桥：async write → 阻塞返回（定时器 / 主流程等同步上下文用）。
    private func awaitWrite(_ channel: ZeehoMirrorChannel, _ data: Data) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        Task.detached {
            do {
                try await channel.write(data)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch result! {
        case .success: break
        case .failure(let error): throw error
        }
    }

    // MARK: - 仪表回连处理

    private func accept(_ channel: ZeehoMirrorChannel, port: UInt16) {
        guard isClosed == false else {
            channel.close()
            return
        }
        log("仪表已回连 TCP\(port)")
        switch port {
        case Ports.standard.video:
            if videoChannel == nil {
                videoChannel = channel
            } else {
                channel.close()
            }
        case Ports.standard.auxiliary:
            auxiliaryChannel = channel
            handleAuxiliary(channel)
        default:
            controlChannel = channel
            handleControl(channel)
        }
    }

    /// 控制通道：协商命令处理。
    private func handleControl(_ channel: ZeehoMirrorChannel) {
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                while true {
                    let request = try ZeehoMirrorFrame.decodeControl { count in
                        try self.awaitRead(channel, count: count, timeout: 5)
                    }
                    try await self.dispatchControl(request, channel: channel)
                }
            } catch {
                self.fail(error)
            }
        }
    }

    private func dispatchControl(_ request: ZeehoMirrorFrame.Control, channel: ZeehoMirrorChannel) async throws {
        var payload = Data()
        switch request.command {
        case 0x10000, 0x20000, 0x10740, 0x10040, 0x70000000:
            break
        case 0x10690, 0x10780:
            break // 仪表上报 FTP 速率/日志，仅确认收到
        case 0x103e0:
            log("仪表请求序列号校验，等待其继续媒体协商")
        case 0x10010:
            let object = try ZeehoMirrorFrame.object(request.payload)
            guard let name = object["HUName"] as? String, !name.isEmpty, name.utf8.count <= 128,
                  let huid = object["HUID"] as? String, !huid.isEmpty else {
                throw CPError.malformed("仪表设备资料不完整")
            }
            guard let identity else { throw CPError.closed("本机身份未就绪") }
            let signature = try ZeehoMirrorIdentity.signHUID(identity, huid)
            payload = try ZeehoMirrorFrame.json([
                "pxcVersion": "1.0.2",
                "phoneUUID": identity.phoneID,
                "phoneBrand": "iPhone",
                "phoneModel": "iPhone",
                "phoneOsVersion": UIDevice.current.systemVersion,
                "phoneOs": "iOS",
                "package": Bundle.main.bundleIdentifier ?? "com.qianxu.jihedrive",
                "versionCode": Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0,
                "token": 0,
                "pubkey": try ZeehoMirrorIdentity.publicKeyDER(identity).base64EncodedString(),
                "encryptedHUID": signature.base64EncodedString(),
                "bluetoothName": "",
                "supportH264IFrame": true,
                "supportFunction": 128,
                "mirrorRequestReconnect": true,
            ])
            try await replyControl(request, channel: channel, payload: payload)
            self.huid = huid
            self.signedHUID = signature
            log("仪表报告 HUName=\(name)，已回应本机 RSA2048 身份")
            return
        case 0x10450:
            let time = Int64(Date().timeIntervalSince1970 * 1_000)
            payload = try ZeehoMirrorFrame.json([
                "time": time,
                "currentTime": time + Int64(TimeZone.current.secondsFromGMT()) * 1_000,
                "currentTimeZone": TimeZone.current.identifier,
            ])
        case 0x80000010:
            return // "不支持某项控制消息"的回应，继续核对必要协商
        case 0x20021, 0x20031, 0x204c1, 0x20491, 0x20051, 0x20591, 0x205a1, 0x70000001:
            return // 回应不再回应，避免往返循环
        default:
            // 新屏幕（SE+/AE2 固件）会发 MotoPlay 等扩展通知：按参考实现 1.0.5 的
            // zeehoExtensionReply 策略，保留 identifier 回空载荷确认（命令+1），不中断协商。
            log("极核扩展通知 0x\(String(request.command, radix: 16))（\(request.payload.count) 字节），已回复接收确认")
            try await channel.write(try ZeehoMirrorFrame.encodeControl(
                command: request.command &+ 1, identifier: request.identifier, payload: Data()))
            return
        }
        try await replyControl(request, channel: channel, payload: payload)
        if request.command == 0x20000 && reverseControlChannel == nil {
            // 会话建立后的主动配置序列
            try await sendControl(channel, command: 0x204c0, identifier: 1,
                            object: ["state": 0, "msg": ""])
            let phone = PhoneProfile.current()
            try await sendControl(channel, command: 0x20020, identifier: 2,
                            object: display(mode: 2, phone: phone))
            try await sendControl(channel, command: 0x20030, identifier: 3,
                            object: display(mode: 1, phone: phone))
            try await channel.write(try ZeehoMirrorFrame.encodeControl(command: 0x20050, identifier: 4))
            try await sendControl(channel, command: 0x205a0, identifier: 5,
                            object: ["isMaskVisible": false])
            // 极核专属：通知仪表开始投屏
            try await sendControl(channel, command: 0x20590, identifier: 6,
                            object: ["control": 1])
            reverseControlChannel = channel
            log("已发送开始投屏通知")
            startHeartbeat(channel)
        }
    }

    private func display(mode: Int, phone: PhoneProfile) -> [String: Any] {
        let portrait = mode == 2
        return [
            "displayRotation": 0,
            "width": portrait ? min(phone.width, phone.height) : phone.width,
            "height": portrait ? max(phone.width, phone.height) : phone.height,
            "enableAccessibility": false,
            "enableAOAHid": false,
            "mode": mode,
        ]
    }

    private func replyControl(_ request: ZeehoMirrorFrame.Control, channel: ZeehoMirrorChannel,
                              payload: Data) async throws {
        let reply = try ZeehoMirrorFrame.encodeControl(command: request.command &+ 1,
                                                       identifier: request.identifier, payload: payload)
        try await channel.write(reply)
    }

    private func sendControl(_ channel: ZeehoMirrorChannel, command: UInt32, identifier: UInt32,
                             object: [String: Any]) async throws {
        let payload = try ZeehoMirrorFrame.json(object)
        try await channel.write(try ZeehoMirrorFrame.encodeControl(command: command,
                                                                   identifier: identifier, payload: payload))
    }

    private func startHeartbeat(_ channel: ZeehoMirrorChannel) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var identifier: UInt32 = 7
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self, weak channel] in
            guard let self, let channel else { return }
            do {
                try self.awaitWrite(channel, try ZeehoMirrorFrame.encodeControl(command: 0x70000000,
                                                                                identifier: identifier))
                identifier &+= 1
            } catch {
                self.fail(error)
            }
        }
        heartbeat = timer
        timer.resume()
    }

    /// 媒体通道：媒体配置（签名回显校验）与启动。
    private func handleAuxiliary(_ channel: ZeehoMirrorChannel) {
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                while true {
                    let request = try ZeehoMirrorFrame.decodeAuxiliary { count in
                        try self.awaitRead(channel, count: count, timeout: 5)
                    }
                    try await self.dispatchAuxiliary(request, channel: channel)
                }
            } catch {
                self.fail(error)
            }
        }
    }

    private func dispatchAuxiliary(_ request: ZeehoMirrorFrame.Auxiliary, channel: ZeehoMirrorChannel) async throws {
        var payload = Data()
        let response: UInt16
        switch request.command {
        case 0x10:
            guard request.payload.count >= 32 else { throw CPError.malformed("媒体配置载荷不足 32 字节") }
            let width = request.payload.uint16LE(0)
            let height = request.payload.uint16LE(2)
            guard ZeehoMirrorLink.acceptable(width: Int(width), height: Int(height)) else {
                throw CPError.rejected("仪表媒体尺寸 \(width)×\(height) 与极核配置不符")
            }
            guard let signature = signedHUID, let huid, let identity else {
                throw CPError.malformed("媒体配置先于身份协商")
            }
            guard let echoed = Data(base64Encoded: request.payload.dropFirst(32)),
                  echoed == signature,
                  ZeehoMirrorIdentity.verifyEcho(identity, signature: echoed, huid: huid) else {
                throw CPError.rejected("媒体身份回显不匹配")
            }
            // 1024×488 的新批次仪表：按参考实现回 1024×480（已实测兼容）；
            // 其他未知尺寸按上报值自适应，转码器输出随协商结果走。
            let output: (width: Int, height: Int)
            let name: String
            let reportedKnown = ZeehoMirrorLink.knownProfiles.first { $0.width == Int(width) && $0.height == Int(height) }
            if let preferred = preferredProfile,
               reportedKnown == nil || reportedKnown == preferred {
                // 用户指定了车型：未知尺寸或与所选一致时按所选档案输出
                output = preferred.outputSize
                name = preferred.name
                if reportedKnown == nil {
                    log("按所选车型 \(preferred.name) 输出 \(output.width)×\(output.height)（仪表上报 \(width)×\(height)）")
                }
            } else if width == 1024 && height == 488 {
                output = DisplayProfile.zeeho62New.outputSize
                name = DisplayProfile.zeeho62New.name
            } else if let known = reportedKnown {
                output = known.outputSize
                name = known.name
            } else {
                // AE2 档案同款：上报值取偶（编码器 4:2:0 要求）
                output = (Self.even(Int(width)), Self.even(Int(height)))
                name = "极核仪表 \(Self.even(Int(width)))×\(Self.even(Int(height)))"
            }
            ZeehoMirrorFrame.appendLE(&payload, UInt32(2)) // codec = H.264
            ZeehoMirrorFrame.appendLE(&payload, UInt16(output.width))
            ZeehoMirrorFrame.appendLE(&payload, UInt16(output.height))
            response = 0x11
            configured = true
            outputSize = output
            negotiatedName = name
            log("媒体身份回显校验通过：仪表面板 \(width)×\(height)，投屏输出 \(name) \(output.width)×\(output.height) H.264")
        case 0x70:
            guard configured else { throw CPError.rejected("仪表在配置完成前请求媒体启动") }
            try await channel.write(try ZeehoMirrorFrame.encodeAuxiliary(command: 0x71, token: request.token))
            mediaStarted = true
            return
        case 0x40:
            response = 0x41
        case 0x30:
            response = 0x31
            ZeehoMirrorFrame.appendLE(&payload, UInt32(5002))
            ZeehoMirrorFrame.appendLE(&payload, UInt32(1))
        case 0x60:
            response = 0x61
            payload = try ZeehoMirrorFrame.json(["supportFunction": 0])
        case 0x20:
            return // 仪表反控触摸：不执行
        default:
            response = 0x7f02
            log("媒体控制通道暂不支持 0x\(String(request.command, radix: 16))")
        }
        try await channel.write(try ZeehoMirrorFrame.encodeAuxiliary(command: response, token: request.token,
                                                                     payload: payload))
    }

    // MARK: - 视频发送（供上层喂帧）

    /// 等待仪表的一次拉帧请求（0x72），随后应发送一帧。在后台队列阻塞调用。
    /// 返回 false 表示会话已关闭。
    func waitForFrameRequest() -> Bool {
        guard let videoChannel, isClosed == false else { return false }
        do {
            let request = try awaitRead(videoChannel, count: 8, timeout: 5)
            let command = request.uint16LE(0)
            let length = Int(request.uint16LE(2))
            guard command == 0x72, length == 0 else {
                throw CPError.malformed("视频通道收到 0x\(String(command, radix: 16))（\(length) 字节），预期空载荷 0x72")
            }
            return true
        } catch {
            // 通道空闲超时不算致命（仪表静止时可能暂停拉帧）
            if isClosed == false {
                log("等待拉帧请求：\(error.localizedDescription)")
            }
            return false
        }
    }

    /// 发送一帧 H.264 访问单元（Annex-B）。首帧自动带 8 字节前缀。
    func sendVideoFrame(_ accessUnit: Data, isFirstFrame: Bool) {
        guard let videoChannel, isClosed == false else { return }
        do {
            let packet = try ZeehoMirrorFrame.encodeVideo(accessUnit, isFirstFrame: isFirstFrame)
            try awaitWrite(videoChannel, packet)
            if currentState != .streaming {
                currentState = .streaming
            }
        } catch {
            fail(error)
        }
    }
}
