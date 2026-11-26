import Foundation

@MainActor
final class BMSStore: ObservableObject {
    @Published private(set) var realtime: BMSRealtime?
    @Published private(set) var brand: BMSBrand = .ant
    @Published private(set) var channel: BMSChannel = .ffe1
    @Published private(set) var channelStatus = "尚未检测"
    @Published private(set) var lastAck = ""
    @Published private(set) var isPolling = false
    @Published private(set) var logs: [String] = []
    /// 轮询间隔（秒），「我的 → 保护板设置 / 详情页设置」可改，持久化
    @Published var pollInterval: TimeInterval = {
        let stored = UserDefaults.standard.double(forKey: "device.bms.pollInterval")
        return stored >= 0.5 ? stored : 1.0
    }() {
        didSet {
            let clamped = min(max(pollInterval, 0.5), 10)
            if clamped != pollInterval { pollInterval = clamped; return }
            UserDefaults.standard.set(pollInterval, forKey: "device.bms.pollInterval")
        }
    }
    @Published var readLength: UInt8 = 0
    @Published var customFuncHex = "01"
    @Published var customAddressHex = "0000"
    @Published var customDataHex = ""

    private let antDecoder = BMSFrameDecoder()
    private let yanyang = YanyangProtocol()
    private weak var ble: DeviceBLEManager?
    private var pollTask: Task<Void, Never>?
    private var realtimeTick = 0

    func attach(_ ble: DeviceBLEManager) {
        self.ble = ble
        channel = ble.bmsChannel
        // 按已连接设备名判定品牌
        if let name = ble.connectedDevice?.name,
           let detected = BMSBrand.detect(name: name) {
            brand = detected
        } else if let stored = ble.connectedDevice?.bmsBrand {
            brand = stored
        } else {
            brand = .ant
        }
        yanyang.reset()
        appendLog("保护板协议：\(brand.title)")
        ble.registerDataHandler("bms") { [weak self] data in
            Task { @MainActor in self?.feed(data) }
        }
    }

    func deactivate() {
        ble?.unregisterDataHandler("bms")
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    func startPolling() {
        pollTask?.cancel()
        isPolling = true
        pollTask = Task { [weak self] in
            guard let self else { return }
            // 彦阳：启动时先探地址 / 协议标志
            if self.brand == .yanyang {
                await self.bootstrapYanyang()
            }
            while !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    private func bootstrapYanyang() async {
        guard let ble, ble.isConnected else { return }
        do {
            try await ble.write(yanyang.requestSaAddress())
            try? await Task.sleep(nanoseconds: 120_000_000)
            try await ble.write(yanyang.requestProtoFlag())
            appendLog("彦阳：已发送地址/协议探测")
        } catch {
            appendLog("彦阳探测失败：\(error.localizedDescription)")
        }
    }

    private func pollOnce() async {
        guard let ble, ble.isConnected else { return }
        switch brand {
        case .ant:
            let frame = BMSProtocol.frame(funcCode: 0x11, address: 0x0000, readLength: readLength)
            do {
                try await ble.write(frame)
            } catch {
                appendLog("读取失败：\(error.localizedDescription)")
            }
        case .yanyang:
            for req in yanyang.pollRequests() {
                guard !Task.isCancelled else { return }
                do {
                    try await ble.write(req)
                    try? await Task.sleep(nanoseconds: 80_000_000)
                } catch {
                    appendLog("彦阳轮询失败：\(error.localizedDescription)")
                    break
                }
            }
        }
    }

    private func feed(_ data: Data) {
        switch brand {
        case .ant:
            for frame in antDecoder.feed(data) {
                switch frame.funcCode {
                case 0x11:
                    if var parsed = BMSProtocol.parseRealtime(frame.data) {
                        parsed.brand = .ant
                        realtime = parsed
                        realtimeTick += 1
                        if channelStatus != "实时通信正常" { channelStatus = "实时通信正常" }
                    }
                case 0x61:
                    lastAck = BMSProtocol.ackMessage(frame.data)
                    appendLog("控制应答：\(lastAck)")
                default:
                    appendLog("收到功能码 0x\(String(format: "%02X", frame.funcCode))，\(frame.data.count) 字节")
                }
            }
        case .yanyang:
            if let snap = yanyang.onNotify(data) {
                realtime = snap
                realtimeTick += 1
                if channelStatus != "实时通信正常" { channelStatus = "实时通信正常" }
            }
        }
    }

    func diagnoseChannels() async {
        guard brand == .ant else {
            channelStatus = "彦阳固定 FFE1/FFE2，无需通道诊断"
            return
        }
        guard let ble, ble.isConnected else {
            channelStatus = "请先连接设备"
            return
        }
        stopPolling()
        defer { startPolling() }

        for option in BMSChannel.allCases {
            channelStatus = "检测中：\(option.title)"
            do {
                try await ble.selectBMSChannel(option)
                let probe = BMSProtocol.frame(funcCode: 0x01, address: 0x0000, readLength: 0xF5)
                try await ble.write(probe)
            } catch {
                appendLog("\(option.title) 探测失败：\(error.localizedDescription)")
                continue
            }
            if await waitForRealtime(seconds: 1.5) {
                channel = option
                channelStatus = "可用：\(option.title)"
                appendLog("通道诊断命中 \(option.title)")
                return
            }
            appendLog("\(option.title) 未收到实时数据")
        }
        channelStatus = "所有通道均无法通信"
    }

    private func waitForRealtime(seconds: Double) async -> Bool {
        let start = realtimeTick
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if realtimeTick > start { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func sendCustomCommand() async {
        guard brand == .ant else {
            appendLog("自定义指令目前仅支持蚂蚁协议")
            return
        }
        guard let ble, ble.isConnected else { return }
        guard let funcCode = Self.bytes(from: customFuncHex)?.first,
              let addressBytes = Self.bytes(from: customAddressHex),
              let dataBytes = Self.bytes(from: customDataHex) else {
            appendLog("十六进制格式不正确")
            return
        }
        let address: UInt16 = addressBytes.count >= 2
            ? UInt16(addressBytes[0]) | (UInt16(addressBytes[1]) << 8)
            : UInt16(addressBytes.first ?? 0)
        let frame = BMSProtocol.frame(funcCode: funcCode, address: address, data: dataBytes)
        do {
            try await ble.write(frame)
            lastAck = "已发送，等待应答"
            appendLog("自定义指令：\(frame.hexString)")
        } catch {
            appendLog("发送失败：\(error.localizedDescription)")
        }
    }

    private static func bytes(from hex: String) -> [UInt8]? {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let value = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            result.append(value)
            index = next
        }
        return result
    }

    private func appendLog(_ text: String) {
        logs.append(text)
        if logs.count > 60 { logs.removeFirst(logs.count - 60) }
    }
}
