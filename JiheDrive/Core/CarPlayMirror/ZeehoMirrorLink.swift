import Foundation
import UIKit

/// 极核仪表 PXC 投屏会话（6.2 寸，1024×480 H.264）。
/// 手机监听 10922(控制)/10711(媒体)/10710(视频)，主动连仪表 10930 发起投屏请求；
/// 仪表回连后完成 RSA 身份协商，随后逐帧拉取 H.264。
final class ZeehoMirrorLink {

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
                packageName: Bundle.main.bundleIdentifier ?? "com.liruixin.jihedrive",
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
            if let reverse = self.reverseControlChannel {
                try? reverse.write(try? ZeehoMirrorFrame.encodeControl(command: 0x20590, identifier: UInt32.max,
                    payload: try? ZeehoMirrorFrame.json(["control": 0])))
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
            let announcement = try awaitConnect(host: targetIP, port: Ports.standard.announcement, name: "仪表公告通道")
            defer { announcement.close() }
            let request = try ZeehoMirrorFrame.encodeControl(
                command: 0x70000010,
                payload: try ZeehoMirrorFrame.json([
                    "phoneType": "iOS",
                    "packageName": Bundle.main.bundleIdentifier ?? "com.liruixin.jihedrive",
                ]))
            try announcement.write(request)
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

    private func awaitConnect(host: String, port: UInt16, name: String) throws -> ZeehoMirrorChannel {
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
        semaphore.wait()
        switch result! {
        case .success(let channel): return channel
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
                    try self.dispatchControl(request, channel: channel)
                }
            } catch {
                self.fail(error)
            }
        }
    }

    private func dispatchControl(_ request: ZeehoMirrorFrame.Control, channel: ZeehoMirrorChannel) throws {
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
                "package": Bundle.main.bundleIdentifier ?? "com.liruixin.jihedrive",
                "versionCode": Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0,
                "token": 0,
                "pubkey": try ZeehoMirrorIdentity.publicKeyDER(identity).base64EncodedString(),
                "encryptedHUID": signature.base64EncodedString(),
                "bluetoothName": "",
                "supportH264IFrame": true,
                "supportFunction": 128,
                "mirrorRequestReconnect": true,
            ])
            try replyControl(request, channel: channel, payload: payload)
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
            log("未知协商命令 0x\(String(request.command, radix: 16))，已忽略")
            return
        }
        try replyControl(request, channel: channel, payload: payload)
        if request.command == 0x20000 && reverseControlChannel == nil {
            // 会话建立后的主动配置序列
            try sendControl(channel, command: 0x204c0, identifier: 1,
                            object: ["state": 0, "msg": ""])
            let phone = PhoneProfile.current()
            try sendControl(channel, command: 0x20020, identifier: 2,
                            object: display(mode: 2, phone: phone))
            try sendControl(channel, command: 0x20030, identifier: 3,
                            object: display(mode: 1, phone: phone))
            try channel.write(try ZeehoMirrorFrame.encodeControl(command: 0x20050, identifier: 4))
            try sendControl(channel, command: 0x205a0, identifier: 5,
                            object: ["isMaskVisible": false])
            // 极核专属：通知仪表开始投屏
            try sendControl(channel, command: 0x20590, identifier: 6,
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
                              payload: Data) throws {
        let reply = try ZeehoMirrorFrame.encodeControl(command: request.command &+ 1,
                                                       identifier: request.identifier, payload: payload)
        try channel.write(reply)
    }

    private func sendControl(_ channel: ZeehoMirrorChannel, command: UInt32, identifier: UInt32,
                             object: [String: Any]) throws {
        let payload = try ZeehoMirrorFrame.json(object)
        try channel.write(try ZeehoMirrorFrame.encodeControl(command: command,
                                                             identifier: identifier, payload: payload))
    }

    private func startHeartbeat(_ channel: ZeehoMirrorChannel) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var identifier: UInt32 = 7
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self, weak channel] in
            guard let self, let channel else { return }
            do {
                try channel.write(try ZeehoMirrorFrame.encodeControl(command: 0x70000000,
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
                    try self.dispatchAuxiliary(request, channel: channel)
                }
            } catch {
                self.fail(error)
            }
        }
    }

    private func dispatchAuxiliary(_ request: ZeehoMirrorFrame.Auxiliary, channel: ZeehoMirrorChannel) throws {
        var payload = Data()
        let response: UInt16
        switch request.command {
        case 0x10:
            guard request.payload.count >= 32 else { throw CPError.malformed("媒体配置载荷不足 32 字节") }
            let width = request.payload.uint16LE(0)
            let height = request.payload.uint16LE(2)
            guard width == 1024, height == 480 || height == 488 else {
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
            ZeehoMirrorFrame.appendLE(&payload, UInt32(2)) // codec = H.264
            ZeehoMirrorFrame.appendLE(&payload, UInt16(width))
            ZeehoMirrorFrame.appendLE(&payload, UInt16(height))
            response = 0x11
            configured = true
            log("媒体身份回显校验通过，回应 H.264 / \(width)×\(height)")
        case 0x70:
            guard configured else { throw CPError.rejected("仪表在配置完成前请求媒体启动") }
            try channel.write(try ZeehoMirrorFrame.encodeAuxiliary(command: 0x71, token: request.token))
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
        try channel.write(try ZeehoMirrorFrame.encodeAuxiliary(command: response, token: request.token,
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
            try videoChannel.write(packet)
            if currentState != .streaming {
                currentState = .streaming
            }
        } catch {
            fail(error)
        }
    }
}
