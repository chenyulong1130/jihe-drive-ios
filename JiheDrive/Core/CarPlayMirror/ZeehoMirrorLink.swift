import Foundation
import UIKit
import Network

/// 极核仪表 PXC 投屏会话（2026-11-28 按 CarWithin 参考实现全面对齐）。
/// 手机监听 10922(控制)/10921(媒体)/10920(视频)，主动连仪表 10930 发起投屏请求；
/// 仪表回连后完成 RSA 身份协商，媒体通道下发采集配置（0x10→0x11）与开流（0x70→0x71），
/// 随后在媒体/视频通道上用 0x72 逐帧"拉"H.264，手机回 [u32 长度][Annex-B 帧]。
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
        /// 对齐参考实现 PxcConnection：手机监听 10920(视频)/10921(媒体)/10922(控制)，
        /// 仪表回连这三个端口；10930 只用于投屏请求探测。
        /// （此前 10710/10711 是首驱方案的端口，PXC 仪表永远不会回连。）
        static let standard = Ports(control: 10922, auxiliary: 10921, video: 10920, announcement: 10930)
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
    /// 仪表逐帧拉取（0x72）信号量：媒体/视频通道的读取循环各 producer，
    /// 喂帧循环 waitForFrameRequest() 消费。start/stop 时清空残留。
    private let frameRequestSemaphore = DispatchSemaphore(value: 0)

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

    /// 启动投屏会话。媒体协商完成后喂帧循环以 waitForFrameRequest() 等待仪表拉帧。
    func start(localIP: String, targetIP: String) {
        stop()
        self.localIP = localIP
        self.targetIP = targetIP
        outputSize = (1024, 480)
        negotiatedName = Self.DisplayProfile.zeeho62.name
        closed = false
        failure = nil
        while frameRequestSemaphore.wait(timeout: .now()) == .success {}
        currentState = .listening
        report("正在监听仪表回连端口…")
        queue.async { [weak self] in self?.runSession() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.closed else { return }
            self.closed = true
            heartbeat?.cancel()
            heartbeat = nil
            controlListener?.stop()
            auxiliaryListener?.stop()
            videoListener?.stop()
            controlChannel?.close()
            auxiliaryChannel?.close()
            videoChannel?.close()
            controlListener = nil
            auxiliaryListener = nil
            videoListener = nil
            controlChannel = nil
            auxiliaryChannel = nil
            videoChannel = nil
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
        controlListener = nil
        auxiliaryListener = nil
        videoListener = nil
        controlChannel = nil
        auxiliaryChannel = nil
        videoChannel = nil
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

    private func awaitRead(_ channel: ZeehoMirrorChannel, count: Int, waitForFirstByte: Bool = false) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        Task.detached {
            do {
                let data = try await channel.readExactly(count, waitForFirstByte: waitForFirstByte)
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
            // 参考实现对媒体/视频两个端口跑同一套媒体协议读取：
            // 0x72 拉帧请求可能出现在任一通道（抓包里 10920 逐帧拉取）
            if videoChannel == nil {
                videoChannel = channel
                handleAuxiliary(channel)
            } else {
                channel.close()
            }
        case Ports.standard.auxiliary:
            if auxiliaryChannel == nil {
                auxiliaryChannel = channel
                handleAuxiliary(channel)
            } else {
                channel.close()
            }
        default:
            if controlChannel == nil {
                controlChannel = channel
                handleControl(channel)
            } else {
                channel.close()
            }
        }
    }

    /// 控制通道：协商命令处理。头部首字节长等（会话建立后通道可长时间静默）。
    private func handleControl(_ channel: ZeehoMirrorChannel) {
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                while self.isClosed == false {
                    let request = try ZeehoMirrorFrame.decodeControl { count in
                        try self.awaitRead(channel, count: count, waitForFirstByte: true)
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
            // SN 校验：回执后按参考实现主动回 0x201c0 校验结果
            let object = try? ZeehoMirrorFrame.object(request.payload)
            let sn = (object?["sn"]).map { "\($0)" } ?? ""
            log("仪表请求序列号校验（sn=\(sn)）")
            try await replyControl(request, channel: channel, payload: Data())
            let result: [String: Any] = ["isOk": true, "errCode": 0, "errMsg": "",
                                         "id": sn, "client_set": "easy_conn"]
            try await channel.write(try ZeehoMirrorFrame.encodeControl(
                command: 0x201c0, payload: try ZeehoMirrorFrame.json(result)))
            log("SN 校验通过，已回 0x201c0")
            return
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
                "phoneBrand": "Apple",
                "phoneModel": "iPhone",
                "phoneOsVersion": UIDevice.current.systemVersion,
                "phoneOs": "iOS",
                "package": Bundle.main.bundleIdentifier ?? "com.qianxu.jihedrive",
                "versionCode": Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0,
                "token": 0,
                "pubkey": try ZeehoMirrorIdentity.publicKeyDER(identity).base64EncodedString(),
                "encryptedHUID": signature.base64EncodedString(),
                "bluetoothName": "JiheDrive",
                "supportH264IFrame": true,
                "supportFunction": 0,
                "appVersionFingerPrint": "jihedrive",
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

    /// 媒体通道（10921，视频通道 10920 同协议）：媒体配置、开流与逐帧拉取。
    private func handleAuxiliary(_ channel: ZeehoMirrorChannel) {
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                while self.isClosed == false {
                    let request = try ZeehoMirrorFrame.decodeAuxiliary { count in
                        try self.awaitRead(channel, count: count, waitForFirstByte: true)
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
            guard request.payload.count >= 4 else { throw CPError.malformed("媒体配置载荷不足 4 字节") }
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
            // 响应格式对齐参考 PxcConnection：[编码器 u32][宽 u16][高 u16][扩展标志 u8]
            // （此前漏了扩展标志字节、编码器字段写死 codec，仪表可能解析失败）
            let encoder: UInt32 = request.payload.count >= 12 ? request.payload.uint32LE(8) : 2
            let ext: UInt8 = request.payload.count >= 30 ? request.payload[request.payload.startIndex + 29] : 0
            ZeehoMirrorFrame.appendLE(&payload, encoder == 0 ? UInt32(2) : encoder)
            ZeehoMirrorFrame.appendLE(&payload, UInt16(output.width))
            ZeehoMirrorFrame.appendLE(&payload, UInt16(output.height))
            payload.append(ext)
            response = 0x11
            configured = true
            outputSize = output
            negotiatedName = name
            log("媒体身份回显校验通过：仪表面板 \(width)×\(height)，投屏输出 \(name) \(output.width)×\(output.height) H.264")
        case 0x70:
            guard configured else { throw CPError.rejected("仪表在配置完成前请求媒体启动") }
            try await channel.write(try ZeehoMirrorFrame.encodeAuxiliary(command: 0x71, token: request.token))
            mediaStarted = true
            log("仪表要求开流，已回 0x71（等待仪表逐帧拉取）")
            return
        case 0x72:
            // 逐帧拉取请求：仅给喂帧循环发信号，不回包（对齐参考实现）
            frameRequestSemaphore.signal()
            return
        case 0x40:
            response = 0x41
        case 0x30:
            // 版本查询对齐参考实现：回 [u32 3][u32 1]（此前回 5002 系首驱方案遗留）
            ZeehoMirrorFrame.appendLE(&payload, UInt32(3))
            ZeehoMirrorFrame.appendLE(&payload, UInt32(1))
            response = 0x31
        case 0x60:
            // 扩展采集配置：参考实现回 {"state": 0}
            payload = try ZeehoMirrorFrame.json(["state": 0])
            response = 0x61
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

    /// 等待仪表的一次拉帧请求（0x72，可能来自媒体或视频通道），随后应发送一帧。
    /// 在后台队列阻塞调用；返回 false 表示超时或会话已关闭。
    func waitForFrameRequest() -> Bool {
        guard let videoChannel, isClosed == false else { return false }
        let result = frameSemaphoreWait(timeout: 10)
        return result && isClosed == false
    }

    private func frameSemaphoreWait(timeout: TimeInterval) -> Bool {
        frameRequestSemaphore.wait(timeout: .now() + timeout) == .success
    }

    /// 发送一帧 H.264 访问单元（Annex-B）。对齐参考实现：每帧 [u32 长度][访问单元]，
    /// 无首帧前缀（此前首帧多写 8 字节零头会让仪表解码失败）。
    func sendVideoFrame(_ accessUnit: Data) {
        guard let videoChannel, isClosed == false else { return }
        do {
            let packet = try ZeehoMirrorFrame.encodeVideo(accessUnit)
            try awaitWrite(videoChannel, packet)
            if currentState != .streaming {
                currentState = .streaming
            }
        } catch {
            fail(error)
        }
    }
}
