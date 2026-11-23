import Foundation
import UIKit

/// 同机 CarPlay 引导会话：通过 CoreAccessories 直连传输跑 iAP2
/// （在线探测 → SYN → 配件认证 0xAA00-05 → 识别 0x1D00/1D02 →
/// CarPlay 可用 0x4300 → StartSession 0x4301），
/// iPhone 收到 0x4301 后会向本机 7000 端口发起 CarPlay RTSP 连接。
final class CPBootstrap {

    enum Stage: Equatable {
        case idle
        case transportReady
        case linkConnected
        case authenticated
        case identified
        case sessionRequested
        case controlConnected
        case failed(String)
        case finished(String)
    }

    var onStage: ((Stage) -> Void)?
    var onLog: ((String) -> Void)?

    private let transport = CPDirectAccessoryTransport()
    private var parser = CPIAP2.Parser()
    private var identity: CPAccessoryIdentity?
    private var configuration: CPInfo.Configuration?
    private var active = false
    private var linked = false
    private var authenticated = false
    private var identified = false
    private var requested = false
    private var controlConnected = false
    private var sequence: UInt8 = 0x10
    private var acknowledgement: UInt8 = 0
    private var session: UInt8 = 1
    private var lastPayloadSequence: UInt8?
    private var messageBytes = Data()
    private var workItems: [DispatchWorkItem] = []

    /// iPhone 打开 CarPlay 控制连接（由 CPReceiver 的 onControlConnected 转入）。
    func didConnectControl() {
        guard active else { return }
        controlConnected = true
        stage(.controlConnected)
        stage("CarPlay 控制连接已建立")
    }

    func start(configuration: CPInfo.Configuration, identity: CPAccessoryIdentity) {
        stop()
        self.configuration = configuration
        self.identity = identity
        active = true
        do {
            try transport.start(withIdentifier: configuration.deviceID, transportType: 2)
            // 关键：必须在 transport.start() 之后设置回调。start() 内部会先 stop()，
            // 而 stop() 末尾执行 onData = nil；若提前设置，回调会被清空，iOS 回来的
            // iAP2 数据全部丢弃，握手停在「已创建配件端点」——CarWithin 的 stop 不清 onData。
            transport.onData = { [weak self] data in self?.receive(data) }
            stage(.transportReady)
            stage("已创建本机配件端点（Wi-Fi 直连），正在建立 iAP2")
            try transport.send(CPIAP2.presence)
            stage("已发送 iAP2 在线探测（\(CPIAP2.presence.count) 字节），等待 iOS 响应")
            let syn = CPIAP2.Packet(control: 0x80, sequence: sequence, acknowledgement: 0, session: 0,
                payload: Data([1, 5, 8, 0, 7, 0xd0, 0, 0xfa, 3, 3, 1, 0, 1]))
            schedule(after: 0.1) { [weak self] in
                guard let self, self.active else { return }
                do {
                    let bytes = try syn.encoded()
                    try self.transport.send(bytes)
                    self.stage("已发送 iAP2 SYN（\(bytes.count) 字节）")
                } catch {
                    self.finish("iAP2 SYN 写入失败：\(error.localizedDescription)")
                }
            }
            schedule(after: 20) { [weak self] in
                guard let self, self.active, !self.requested else { return }
                self.finish("会话启动超时（链路=\(self.linked)，认证=\(self.authenticated)，识别=\(self.identified)）")
            }
            schedule(after: 45) { [weak self] in
                guard let self, self.active, !self.controlConnected else { return }
                self.finish("未收到 CarPlay 控制连接，请检查 Wi-Fi 名称与密码后重试")
            }
        } catch {
            finish("本机配件传输失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        active = false
        workItems.forEach { $0.cancel() }
        workItems.removeAll()
        transport.stop()
        transport.onData = nil
        parser = CPIAP2.Parser()
        identity = nil
        configuration = nil
        messageBytes = Data()
        sequence = 0x10
        acknowledgement = 0
        session = 1
        lastPayloadSequence = nil
        linked = false
        authenticated = false
        identified = false
        requested = false
        controlConnected = false
    }

    private func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        let item = DispatchWorkItem(block: block)
        workItems.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func stage(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(text) }
    }

    private func stage(_ value: Stage) {
        DispatchQueue.main.async { [weak self] in self?.onStage?(value) }
    }

    private func finish(_ message: String) {
        stage(message)
        stop()
        DispatchQueue.main.async { [weak self] in self?.onStage?(.finished(message)) }
    }

    // MARK: - iAP2 收包处理

    private func receive(_ data: Data) {
        guard active else { return }
        stage("收到本机 iAP2 数据（\(data.count) 字节）")
        do {
            for event in try parser.append(data) {
                switch event {
                case .presence:
                    stage("本机 iOS 服务已响应 iAP2 在线探测")
                case .packet(let packet):
                    acknowledgement = packet.sequence
                    if packet.control & 0x20 != 0 {
                        throw CPError.rejected("iOS 重置了 iAP2 链路")
                    }
                    if packet.control & 0x80 != 0 {
                        guard packet.payload.count >= 13 else { throw CPError.malformed("iAP2 SYN 长度不足") }
                        session = packet.payload[packet.payload.startIndex + 10]
                        linked = true
                        try ack()
                        stage(.linkConnected)
                        stage("本机 iAP2 链路已连接，等待配件认证")
                        continue
                    }
                    guard linked, packet.session == session, !packet.payload.isEmpty else { continue }
                    try ack()
                    if lastPayloadSequence == packet.sequence { continue }
                    lastPayloadSequence = packet.sequence
                    guard messageBytes.count + packet.payload.count <= 65535 else {
                        throw CPError.limitExceeded("iAP2 控制消息重组")
                    }
                    messageBytes.append(packet.payload)
                    while messageBytes.count >= 6 {
                        let count = Int(messageBytes[messageBytes.startIndex + 2]) * 256
                            + Int(messageBytes[messageBytes.startIndex + 3])
                        guard count >= 6 else { throw CPError.malformed("控制消息长度") }
                        guard messageBytes.count >= count else { break }
                        let message = try CPIAP2.Message.parse(Data(messageBytes.prefix(count)))
                        messageBytes = Data(messageBytes.dropFirst(count))
                        try handle(message)
                        if !active { return }
                    }
                }
            }
        } catch {
            finish("本机配件会话失败：\(error.localizedDescription)")
        }
    }

    private func ack() throws {
        try transport.send(CPIAP2.Packet(control: 0x40, sequence: sequence,
                                         acknowledgement: acknowledgement, session: 0,
                                         payload: Data()).encoded())
    }

    private func send(_ message: CPIAP2.Message) throws {
        sequence &+= 1
        try transport.send(CPIAP2.Packet(control: 0x40, sequence: sequence,
                                         acknowledgement: acknowledgement, session: session,
                                         payload: message.encoded()).encoded())
        stage(String(format: "发送 iAP2 消息 0x%04X", message.id))
    }

    private func handle(_ message: CPIAP2.Message) throws {
        guard let identity, let configuration else { return }
        switch message.id {
        case 0xaa00:
            try send(CPIAP2.Message(id: 0xaa01,
                parameters: [CPIAP2.Parameter(id: 0, value: identity.certificateChain)]))
        case 0xaa02:
            guard let challenge = message.parameters.first(where: { $0.id == 0 })?.value else {
                throw CPError.malformed("缺少认证挑战")
            }
            try send(CPIAP2.Message(id: 0xaa03,
                parameters: [CPIAP2.Parameter(id: 0, value: try identity.sign(challenge: challenge))]))
        case 0xaa04:
            finish("iOS 拒绝了配件认证（0xAA04）——身份证书可能无效")
        case 0xaa05:
            authenticated = true
            stage(.authenticated)
            stage("iOS 已接受配件认证")
        case 0x1d00:
            try send(CPIAP2.identification(name: configuration.name, deviceID: configuration.deviceID))
        case 0x1d02:
            identified = true
            stage(.identified)
            stage("iOS 已接受配件识别，等待 CarPlay 可用通知")
        case 0x1d03:
            let rejected = message.parameters.map {
                String(format: "%04X:%@", $0.id,
                       $0.value.prefix(32).map { String(format: "%02X", $0) }.joined())
            }.joined(separator: ",")
            finish("iOS 拒绝了配件识别（0x1D03）：\(rejected)")
        case 0x4300:
            guard authenticated, identified else {
                throw CPError.malformed("认证或识别完成前收到 CarPlay 可用通知")
            }
            for group in message.parameters {
                if let nested = try? CPIAP2.Parameter.parse(group.value),
                   let value = nested.first(where: { $0.id == 0 })?.value.first {
                    stage(String(format: "CarPlay 可用传输 %d：%d", group.id, value))
                }
            }
            if controlConnected || requested { return }
            try requestSession(configuration)
            if !requested {
                // 3/6/9 秒重试，等待 Wi-Fi 路由就绪
                for delay in [3.0, 6.0, 9.0] {
                    schedule(after: delay) { [weak self] in
                        guard let self, self.active, !self.controlConnected else { return }
                        try? self.requestSession(self.configuration ?? CPInfo.Configuration.default(deviceID: ""))
                    }
                }
            }
            requested = true
            stage(.sessionRequested)
            stage("已请求在 \(configuration.address.isEmpty ? "本机" : configuration.address):\(configuration.port) 启动 CarPlay")
        default:
            stage(String(format: "未处理的配件消息 0x%04X", message.id))
        }
    }

    private func requestSession(_ configuration: CPInfo.Configuration) throws {
        let wifi = CPWiFiDefaults.validated()
        let wifiInfo = wifi.map { CPIAP2.WiFiInfo(ssid: $0.ssid, password: $0.password, channel: $0.channel) }
        try send(CPIAP2.carPlayStartSession(address: configuration.address,
                                            port: configuration.port,
                                            deviceID: configuration.deviceID,
                                            wifi: wifiInfo))
    }
}

// MARK: - Wi-Fi 预设存取（同机 CarPlay 需要 SSID/密码/信道）

enum CPWiFiDefaults {
    struct Preset {
        var ssid: String
        var password: String
        var channel: UInt8
    }

    private static let defaults = UserDefaults.standard

    static func validated() -> Preset? {
        guard let ssid = defaults.string(forKey: "cp.wifi.ssid"), !ssid.isEmpty else { return nil }
        let password = defaults.string(forKey: "cp.wifi.password") ?? ""
        let channel = UInt8(defaults.integer(forKey: "cp.wifi.channel")) == 0
            ? 36
            : UInt8(defaults.integer(forKey: "cp.wifi.channel"))
        return Preset(ssid: ssid, password: password, channel: channel)
    }

    static func save(ssid: String, password: String, channel: UInt8) {
        defaults.set(ssid, forKey: "cp.wifi.ssid")
        defaults.set(password, forKey: "cp.wifi.password")
        defaults.set(Int(channel), forKey: "cp.wifi.channel")
    }

    static func clear() {
        defaults.removeObject(forKey: "cp.wifi.ssid")
        defaults.removeObject(forKey: "cp.wifi.password")
        defaults.removeObject(forKey: "cp.wifi.channel")
    }
}

/// 本机稳定配件 ID（MAC 形式，识别消息与 Bonjour 共用）。
enum CPDeviceID {
    static func persistent() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "cp.deviceID") { return existing }
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, 6, &bytes)
        bytes[0] = (bytes[0] & 0xFE) | 0x02 // 本地管理位
        let mac = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        defaults.set(mac, forKey: "cp.deviceID")
        return mac
    }
}
