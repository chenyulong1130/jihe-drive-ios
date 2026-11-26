import Foundation
import Network
import CryptoKit

/// CarPlay 接收端：监听 TCP 7000，处理 iPhone 发起的 RTSP 会话
/// （OPTIONS → /auth-setup → /pair-setup → /pair-verify → SETUP → RECORD → 媒体流）。
/// 视频访问单元通过 onVideo 回调上抛（Annex-B，可直接投给极核仪表）。
final class CPReceiver {
    private let queue = DispatchQueue(label: "jihedrive.cp.receiver")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var sessions: [UUID: SessionState] = [:]
    private var configuration: CPInfo.Configuration = .default(deviceID: "")
    private var identity: CPAccessoryIdentity?
    private var generation = UUID()
    /// 发现服务（与 `_airplay._tcp` 一起构成 CarWithin 同款发现层）
    /// 注意：不要挂在 NWListener.service 上——Bonjour 授权失败会把整个 TCP 监听一起 failed。
    private var discoveryServices: [NetService] = []
    /// TCP 已就绪后，后续的 Bonjour/权限错误只记日志，不再杀掉接收端。
    private var tcpReady = false
    // forceKeyFrame 状态：250ms 节流合并多个恢复方，未收到关键帧前每秒重发。
    private var keyframeWantedSince: DispatchTime?
    private var keyframeLastSent: DispatchTime?
    private var keyframeAttempts = 0
    private var keyframeReason = ""
    private var nightMode: Bool?

    var onVideo: ((Data, CPVideoCodec) -> Void)?
    var onLog: ((String) -> Void)?
    var onListening: ((UInt16) -> Void)?
    var onControlConnected: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private final class SessionState {
        var parser = CPRTSPParser()
        var setup: CPPairSetup?
        var verify: CPPairVerify?
        var cipher: CPControlCipher?
        var authenticated = false
        var media: CPMediaSession?
        var peerAddress: String = ""
        init() {
            if let signingKey = try? CPPairingStore.localSigningKey() {
                setup = CPPairSetup(identifier: CPPairingStore.localIdentifier(), signingKey: signingKey)
                verify = CPPairVerify(identifier: CPPairingStore.localIdentifier(), signingKey: signingKey)
            }
        }
    }

    func start(configuration: CPInfo.Configuration, identity: CPAccessoryIdentity) {
        self.configuration = configuration
        self.identity = identity
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.listen(port: configuration.port, identity: identity)
        }
    }

    var port: UInt16 { 7000 }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    // MARK: - 预览触控/按键转发（到活跃媒体会话）

    func touches(_ contacts: [CPInfo.TouchContact]) {
        queue.async { [weak self] in
            guard let media = self?.sessions.values.first(where: { $0.media != nil })?.media else { return }
            media.touch(contacts)
        }
    }

    func pressKnob(select: Bool = false, home: Bool = false, back: Bool = false) {
        queue.async { [weak self] in
            guard let media = self?.sessions.values.first(where: { $0.media != nil })?.media else { return }
            media.pressKnob(select: select, home: home, back: back)
        }
    }

    func requestSiri() {
        queue.async { [weak self] in
            guard let media = self?.sessions.values.first(where: { $0.media != nil })?.media else { return }
            media.requestSiri()
        }
    }

    /// 请求 iPhone 立即编码一个关键帧（解码/转码恢复用）。
    /// CarPlay 只在流开始时发一个关键帧，此后所有解码恢复都依赖该命令；
    /// 250ms 节流合并并发恢复方，每秒重试最多 8 次，之后等待自然关键帧。
    func requestKeyFrame(reason: String = "恢复") {
        queue.async { [weak self] in self?.requestKeyFrameOnQueue(reason: reason) }
    }

    private func requestKeyFrameOnQueue(reason: String) {
        let now = DispatchTime.now()
        if keyframeWantedSince == nil {
            keyframeWantedSince = now
            keyframeAttempts = 0
            keyframeReason = reason
        }
        if let last = keyframeLastSent, now.uptimeNanoseconds - last.uptimeNanoseconds < 250_000_000 { return }
        sendKeyFrameRequest()
    }

    private func sendKeyFrameRequest() {
        guard keyframeWantedSince != nil else { return }
        guard let media = sessions.values.first(where: { $0.media?.hasEventChannel == true })?.media else { return }
        keyframeAttempts += 1
        keyframeLastSent = .now()
        guard media.requestKeyFrame() else { return }
        if keyframeAttempts == 1 { log("已请求关键帧（\(keyframeReason)）") }
        guard keyframeAttempts < 8 else {
            log("iPhone 未响应关键帧请求（已重试 8 次），等待自然关键帧")
            keyframeWantedSince = nil
            return
        }
        let generation = self.generation
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.generation == generation, self.keyframeWantedSince != nil else { return }
            self.sendKeyFrameRequest()
        }
    }

    /// 收到随机访问单元时清空关键帧等待状态（接收线程调用，queue-confined）。
    private func clearKeyframeWanting() {
        guard let since = keyframeWantedSince else { return }
        keyframeWantedSince = nil
        let ms = (DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000
        log("关键帧已到达（\(ms) ms，\(keyframeAttempts) 次请求）")
    }

    /// 夜间模式：记住最新状态，事件通道就绪后立即下发（含之后新建的会话）。
    func setNightMode(_ night: Bool) {
        queue.async { [weak self] in
            guard let self, self.nightMode != night else { return }
            self.nightMode = night
            self.sessions.values.forEach { $0.media?.setNightMode(night) }
        }
    }

    private func stopOnQueue() {
        generation = UUID()
        tcpReady = false
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { [weak self] in
            self?.discoveryServices.forEach { $0.stop() }
            self?.discoveryServices.removeAll()
        }
        sessions.values.forEach { $0.media?.stop() }
        sessions.removeAll()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        keyframeWantedSince = nil
        keyframeLastSent = nil
        keyframeAttempts = 0
    }

    /// port 为 nil 时使用系统分配的临时端口：7000 被占用时自动回退，
    /// 实际端口经 onListening 回写引导会话的 StartSession 消息。
    private func listen(port: UInt16?, identity: CPAccessoryIdentity) {
        let generation = self.generation
        do {
            // 纯 TCP 监听：Bonjour 改用独立 NetService。
            // 日志里 -65555 NoAuth 就是把 _airplay._tcp 挂在 NWListener.service 上，
            // 本地网络未授权时整个 7000 监听被 failed，iPhone 永远回连不上。
            let candidate = try NWListener(using: .tcp,
                                           on: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                guard let self, let candidate,
                      self.generation == generation, self.listener === candidate else { return }
                switch state {
                case .ready:
                    guard let actualPort = candidate.port?.rawValue else {
                        self.fail("监听器未获得端口")
                        return
                    }
                    self.tcpReady = true
                    self.log("CarPlay 控制监听器已在端口 \(actualPort) 就绪")
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.publishDiscovery(port: actualPort)
                        self.onListening?(actualPort)
                    }
                case .failed(let error):
                    if let port, case .posix(.EADDRINUSE) = error {
                        self.log("端口 \(port) 已被占用，正在申请可用端口")
                        candidate.cancel()
                        self.listener = nil
                        self.tcpReady = false
                        self.listen(port: nil, identity: identity)
                    } else if self.tcpReady {
                        // TCP 已在听：Bonjour/权限类失败不能掐死接收端，否则 0x4301 发出去也没人接
                        self.log("发现服务/网络权限告警（TCP \(candidate.port?.rawValue ?? 0) 仍在监听）：\(error.localizedDescription)")
                    } else {
                        self.fail("监听器失败：\(error.localizedDescription)")
                    }
                default:
                    break
                }
            }
            candidate.newConnectionHandler = { [weak self, weak candidate] connection in
                guard let self, self.generation == generation, self.listener === candidate,
                      self.connections.count < 8 else {
                    connection.cancel()
                    return
                }
                let id = UUID()
                self.connections[id] = connection
                let state = SessionState()
                self.sessions[id] = state
                if state.setup == nil || state.verify == nil {
                    self.log("警告：配对签名密钥不可用，pair-setup/pair-verify 将失败")
                }
                if case .hostPort(let host, _) = connection.endpoint {
                    state.peerAddress = "\(host)"
                }
                connection.stateUpdateHandler = { [weak self, weak connection] update in
                    guard let self, let connection else { return }
                    switch update {
                    case .ready:
                        self.log("iPhone 已建立 CarPlay 控制连接")
                        DispatchQueue.main.async { [weak self] in self?.onControlConnected?() }
                        self.receive(connection, id: id, state: state)
                    case .failed, .cancelled:
                        state.media?.stop()
                        self.sessions.removeValue(forKey: id)
                        self.connections.removeValue(forKey: id)
                    default:
                        break
                    }
                }
                connection.start(queue: self.queue)
            }
            listener = candidate
            candidate.start(queue: queue)
        } catch let error as NWError {
            if let port, case .posix(.EADDRINUSE) = error {
                log("端口 \(port) 已被占用，正在申请可用端口")
                listen(port: nil, identity: identity)
            } else {
                fail("无法创建监听器：\(error.localizedDescription)")
            }
        } catch {
            fail("无法创建监听器：\(error.localizedDescription)")
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, state: SessionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            do {
                if let data, !data.isEmpty {
                    var input = data
                    while true {
                        let plaintext = try state.cipher?.receive(input) ?? input
                        guard let request = try state.parser.append(plaintext, maximumRequests: 1).first else { break }
                        self.log("\(request.method) \(request.target.prefix(100))")
                        let response = try self.respond(request, state: state)
                        let encoded = response.encoded(for: request)
                        let wire = try state.cipher?.encrypt(encoded) ?? encoded
                        connection.send(content: wire, completion: .contentProcessed { [weak self] error in
                            if let error {
                                self?.log("控制通道写入失败：\(error.localizedDescription)")
                                connection.cancel()
                            }
                        })
                        input = Data()
                        if state.cipher == nil, let keys = state.verify?.keys {
                            // pair-verify 的 M4 是明文；后续字节用协商出的记录密钥
                            state.cipher = CPControlCipher(readKey: keys.read, writeKey: keys.write)
                            input = state.parser.takeBufferedData()
                            self.log("Pair-Verify 通过，控制通道已加密")
                        }
                    }
                }
                if complete || error != nil {
                    connection.cancel()
                    self.connections.removeValue(forKey: id)
                } else {
                    self.receive(connection, id: id, state: state)
                }
            } catch {
                self.log("控制连接终止：\(error)")
                connection.cancel()
                self.connections.removeValue(forKey: id)
            }
        }
    }

    private func respond(_ request: CPRTSPRequest, state: SessionState) throws -> CPRTSPResponse {
        switch (request.method, request.target.components(separatedBy: "?")[0]) {
        case ("OPTIONS", _):
            return CPRTSPResponse()
        case ("SETUP", _):
            guard state.cipher != nil, state.authenticated, let secret = state.verify?.mediaSecret else {
                throw CPError.rejected("在配件会话通过验证前收到 SETUP")
            }
            if state.media == nil {
                let media = CPMediaSession(queue: queue, secret: secret, peerAddress: state.peerAddress)
                media.onLog = { [weak self] in self?.log($0) }
                media.onVideo = { [weak self] data, codec in
                    guard let self else { return }
                    if CPAnnexB.containsRandomAccess(data) { self.clearKeyframeWanting() }
                    self.onVideo?(data, codec)
                }
                if let nightMode { media.setNightMode(nightMode) }
                state.media = media
            }
            return CPRTSPResponse(body: try state.media!.setup(request.body),
                                  contentType: "application/x-apple-binary-plist")
        case ("RECORD", _):
            guard state.media != nil else { throw CPError.malformed("在 SETUP 前收到 RECORD") }
            log("已接受 RECORD，等待 CarPlay 视频")
            return CPRTSPResponse()
        case ("POST", "/pair-setup"):
            guard state.cipher == nil, let setup = state.setup else {
                throw CPError.malformed("pair-setup 不可用")
            }
            let body = try setup.handle(request.body)
            if setup.complete { log("Pair-Setup 完成，控制端已保存") }
            return CPRTSPResponse(body: body, contentType: "application/pairing+tlv8")
        case ("POST", "/pair-verify"):
            guard state.cipher == nil, let verify = state.verify else {
                throw CPError.malformed("pair-verify 不可用")
            }
            return CPRTSPResponse(body: try verify.handle(request.body), contentType: "application/pairing+tlv8")
        case ("GET", "/info"), ("POST", "/info"):
            let info = CPInfo.build(configuration)
            return CPRTSPResponse(
                body: try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0),
                contentType: "application/x-apple-binary-plist")
        case ("POST", "/auth-setup"):
            guard let identity else { throw CPError.malformed("缺少配件身份") }
            let body = try CPMFiSAP.respond(to: request.body, identity: identity)
            state.authenticated = true
            log("已生成 MFi 认证响应")
            return CPRTSPResponse(body: body)
        case ("POST", "/feedback"):
            return CPRTSPResponse()
        case ("POST", "/command"):
            guard state.cipher != nil else { throw CPError.rejected("验证完成前收到 command") }
            if let command = try? PropertyListSerialization.propertyList(from: request.body, format: nil) {
                log("CarPlay 命令：\(command)")
            }
            return CPRTSPResponse()
        case ("TEARDOWN", _):
            // 按流拆除：只停被指定的流，其余流保持。
            if try state.media?.teardown(request.body) == true { state.media = nil }
            return CPRTSPResponse()
        default:
            log("未实现：\(request.method) \(request.target.prefix(80))")
            return CPRTSPResponse(status: 501, reason: "Not Implemented")
        }
    }

    /// 独立发布 Bonjour，不绑 NWListener——授权失败也不会关掉 7000。
    /// 只发 _tds-carkit._tcp（对齐可用参考实现；多发的 _airplay._tcp 曾在
    /// 本地网络未授权时干扰监听，且 iPhone 回连发现并不依赖它）。
    private func publishDiscovery(port: UInt16) {
        discoveryServices.forEach { $0.stop() }
        discoveryServices.removeAll()

        let tds = NetService(domain: "local.", type: "_tds-carkit._tcp",
                             name: configuration.name, port: Int32(port))
        tds.setTXTRecord(NetService.data(fromTXTRecord: [
            "app": Data("TDSCarKit".utf8),
            "deviceid": Data(configuration.deviceID.utf8),
        ]))
        tds.publish()
        discoveryServices.append(tds)
        log("正在通过 _tds-carkit._tcp 发布 \(configuration.name)")
    }

    private func fail(_ message: String) {
        log(message)
        stopOnQueue()
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(message) }
    }
}

// MARK: - 媒体会话（事件通道 / 时钟同步 / 视频流）

final class CPMediaSession {
    private let queue: DispatchQueue
    private let secret: SymmetricKey
    private let peerAddress: String
    private var eventListener: CPMediaTCPListener?
    private var videoListener: CPMediaTCPListener?
    private var event: CPMediaTCPConnection?
    private var video: CPMediaTCPConnection?
    private var timing: CPMediaTiming?
    private var eventCipher: CPControlCipher?
    private var eventParser = CPRTSPParser(allowResponses: true)
    private var screen: CPScreenStream?
    private var cseq = 0
    private var videoPackets = 0
    private var videoBytes = 0
    private var pendingNightMode: Bool?

    var onLog: ((String) -> Void)?
    var onVideo: ((Data, CPVideoCodec) -> Void)?

    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(message) }
    }

    init(queue: DispatchQueue, secret: SymmetricKey, peerAddress: String) {
        self.queue = queue
        self.secret = secret
        self.peerAddress = peerAddress
    }

    /// 处理 SETUP：无 streams 字段 = 初始 SETUP（事件+时钟），有 = 具体媒体流。
    func setup(_ data: Data) throws -> Data {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CPError.malformed("SETUP 属性列表")
        }
        var response: [String: Any] = [:]
        if let streams = values["streams"] as? [[String: Any]] {
            var replies: [[String: Any]] = []
            for stream in streams {
                guard let type = stream["type"] as? NSNumber else { throw CPError.malformed("媒体流类型") }
                // 音频流（100/101/102）不支持：音频留在 iPhone 本机
                guard type.intValue == 110,
                      let connectionID = stream["streamConnectionID"] as? NSNumber else {
                    log("跳过媒体流类型 \(type.intValue)（音频留在手机）")
                    continue
                }
                guard eventListener != nil else { throw CPError.malformed("初始 SETUP 前请求了屏幕流") }
                video?.stop()
                video = nil
                videoListener?.stop()
                screen = CPScreenStream(secret: secret, connectionID: connectionID.uint64Value)
                videoPackets = 0
                videoBytes = 0
                let listener = try CPMediaTCPListener(queue: queue, peerAddress: peerAddress)
                videoListener = listener
                listener.onConnection = { [weak self] connection in
                    guard let self, self.video == nil else {
                        connection.stop()
                        return
                    }
                    self.video = connection
                    self.log("视频 TCP 通道已连接")
                    connection.onBytes = { [weak self] bytes in
                        guard let self, let screen = self.screen else { return }
                        self.videoBytes += bytes.count
                        do {
                            for unit in try screen.append(bytes) {
                                self.videoPackets += 1
                                if self.videoPackets <= 2 {
                                    self.log("已解码 \(screen.codec.displayName) 访问单元 \(self.videoPackets)（\(unit.count) 字节）")
                                }
                                self.onVideo?(unit, screen.codec)
                            }
                        } catch {
                            self.log("视频数据被拒绝：\(error)")
                            throw error
                        }
                    }
                    connection.onClose = { [weak self] in
                        self?.video = nil
                        self?.log("视频通道已关闭")
                    }
                    connection.start()
                    self.recoverFirstVideoUnit(on: connection, attempt: 1)
                }
                replies.append(["type": 110, "dataPort": listener.port])
                log("视频监听器已在端口 \(listener.port) 就绪")
            }
            response["streams"] = replies
        } else {
            guard eventListener == nil else { throw CPError.malformed("重复的初始 SETUP") }
            let timingPort = (values["timingPort"] as? NSNumber)?.intValue ?? 0
            guard (0...65535).contains(timingPort) else { throw CPError.malformed("时钟同步端口") }
            timing = try CPMediaTiming(queue: queue, peerAddress: peerAddress, peerPort: UInt16(timingPort))
            let listener = try CPMediaTCPListener(queue: queue, peerAddress: peerAddress)
            eventListener = listener
            listener.onConnection = { [weak self] connection in self?.acceptEvent(connection) }
            let features = ["viewAreas"]
            response = ["eventPort": listener.port, "timingPort": timing!.port, "enabledFeatures": features]
            log("事件/时钟监听器已就绪：\(listener.port)/\(timing!.port)")
        }
        return try PropertyListSerialization.data(fromPropertyList: response, format: .binary, options: 0)
    }

    private func acceptEvent(_ connection: CPMediaTCPConnection) {
        guard event == nil else {
            connection.stop()
            return
        }
        event = connection
        eventCipher = CPControlCipher(
            readKey: CPPairVerify.derive(secret, salt: "Events-Salt", info: "Events-Read-Encryption-Key"),
            writeKey: CPPairVerify.derive(secret, salt: "Events-Salt", info: "Events-Write-Encryption-Key"))
        log("加密事件通道已连接")
        connection.onBytes = { [weak self, weak connection] bytes in
            guard let self, let connection, let cipher = self.eventCipher else { return }
            for request in try self.eventParser.append(cipher.receive(bytes)) {
                if request.method.hasPrefix("RTSP/") || request.method.hasPrefix("HTTP/") {
                    // 我方命令的响应；仅失败值得记录
                    if request.target != "200" {
                        self.log("iPhone 拒绝了事件命令（状态 \(request.target)，CSeq \(request.headers["cseq"] ?? "?")）")
                    }
                    continue
                }
                try connection.send(cipher.encrypt(CPRTSPResponse().encoded(for: request)))
            }
        }
        connection.onClose = { [weak self] in
            self?.event = nil
            self?.eventCipher = nil
            self?.log("事件通道已关闭")
        }
        connection.start()
        flushNightMode()
    }

    var hasEventChannel: Bool { event != nil && eventCipher != nil }

    /// 事件通道就绪前的夜间模式先暂存，就绪后立即下发。
    func setNightMode(_ night: Bool) {
        pendingNightMode = night
        flushNightMode()
    }

    private func flushNightMode() {
        guard let night = pendingNightMode, hasEventChannel else { return }
        if sendCommand(["type": "setNightMode", "params": ["nightMode": night]], label: "夜间模式") {
            pendingNightMode = nil
            log("已通知 iPhone 切换为\(night ? "夜间" : "白天")外观")
        }
    }

    /// 视频通道连上但迟迟没有访问单元时：请求关键帧并输出诊断
    /// （区分「字节没来」和「字节来了但解不出」）。
    private func recoverFirstVideoUnit(on connection: CPMediaTCPConnection, attempt: Int) {
        queue.asyncAfter(deadline: .now() + (attempt == 1 ? 2 : 3)) { [weak self, weak connection] in
            guard let self, let connection, self.video === connection, self.videoPackets == 0 else { return }
            let sent = self.requestKeyFrame()
            self.log("等待首帧：视频 TCP 已读 \(self.videoBytes) 字节，第 \(attempt) 次关键帧请求\(sent ? "已发送" : "未发送")")
            if attempt < 2 { self.recoverFirstVideoUnit(on: connection, attempt: attempt + 1) }
        }
    }

    /// 请求 iPhone 立即编码一个关键帧。
    func requestKeyFrame() -> Bool {
        sendCommand(["type": "forceKeyFrame"], label: "关键帧请求")
    }

    // MARK: - HID 触控与按键（预览区操作回传）

    /// 全量多点触控状态：每个槽都上报，缺失槽上报抬起。
    func touch(_ contacts: [CPInfo.TouchContact]) {
        sendHID(CPInfo.HID.touch, CPInfo.touchReport(contacts), label: "触控")
    }

    /// 瞬时按键：按下报告后紧跟全抬起报告。
    func pressHID(_ uuid: String, _ report: Data, label: String) {
        guard sendHID(uuid, report, label: label) else {
            log("按键未发送：事件通道尚未连接")
            return
        }
        _ = sendHID(uuid, Data(repeating: 0, count: 4), label: label)
    }

    /// 旋钮类按键：select / home / back。
    func pressKnob(select: Bool = false, home: Bool = false, back: Bool = false) {
        pressHID(CPInfo.HID.knob, CPInfo.knobReport(select: select, home: home, back: back), label: "按键")
    }

    /// 请求 Siri（按下/抬起两个动作）。
    func requestSiri() {
        guard sendCommand(["type": "requestSiri", "params": ["siriAction": 2]], label: "Siri") else {
            log("Siri 未发送：事件通道尚未连接")
            return
        }
        _ = sendCommand(["type": "requestSiri", "params": ["siriAction": 3]], label: "Siri")
    }

    private func sendHID(_ uuid: String, _ report: Data, label: String) -> Bool {
        sendCommand(["type": "hidSendReport", "uuid": uuid, "hidReport": report], label: label)
    }

    private func sendCommand(_ command: [String: Any], label: String) -> Bool {
        guard let event, let eventCipher else { return false }
        do {
            let body = try PropertyListSerialization.data(fromPropertyList: command, format: .binary, options: 0)
            cseq += 1
            let header = "POST /command RTSP/1.0\r\nContent-Type: application/x-apple-binary-plist\r\n"
                + "Content-Length: \(body.count)\r\nCSeq: \(cseq)\r\n\r\n"
            try event.send(eventCipher.encrypt(Data(header.utf8) + body))
            return true
        } catch {
            log("\(label)写入失败：\(error)")
            event.stop()
            return false
        }
    }

    /// 按流拆除：body 带 streams 时只停指定流（返回 false，会话保留）；否则整会话停止（返回 true）。
    func teardown(_ body: Data) throws -> Bool {
        guard !body.isEmpty,
              let values = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any],
              let streams = values["streams"] as? [[String: Any]] else {
            stop()
            return true
        }
        for stream in streams {
            guard let type = stream["type"] as? NSNumber else { continue }
            if type.intValue == 110 {
                video?.stop()
                video = nil
                videoListener?.stop()
                videoListener = nil
                screen = nil
            }
        }
        return false
    }

    func stop() {
        eventListener?.stop()
        videoListener?.stop()
        event?.stop()
        video?.stop()
        timing?.stop()
        eventListener = nil
        videoListener = nil
        event = nil
        video = nil
        timing = nil
        screen = nil
        eventCipher = nil
    }

    deinit { stop() }
}
