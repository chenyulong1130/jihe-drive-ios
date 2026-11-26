import Foundation

@MainActor
final class BMSStore: ObservableObject {
    @Published private(set) var realtime: BMSRealtime?
    @Published private(set) var channel: BMSChannel = .ffe1
    @Published private(set) var channelStatus = "尚未检测"
    @Published private(set) var lastAck = ""
    @Published private(set) var isPolling = false
    @Published private(set) var logs: [String] = []
    @Published var readLength: UInt8 = 0
    @Published var customFuncHex = "01"
    @Published var customAddressHex = "0000"
    @Published var customDataHex = ""

    private let decoder = BMSFrameDecoder()
    private weak var ble: DeviceBLEManager?
    private var pollTask: Task<Void, Never>?
    private var realtimeTick = 0

    func attach(_ ble: DeviceBLEManager) {
        self.ble = ble
        channel = ble.bmsChannel
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
            while !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    private func pollOnce() async {
        guard let ble, ble.isConnected else { return }
        let frame = BMSProtocol.frame(funcCode: 0x11, address: 0x0000, readLength: readLength)
        do {
            try await ble.write(frame)
        } catch {
            appendLog("读取失败：\(error.localizedDescription)")
        }
    }

    private func feed(_ data: Data) {
        for frame in decoder.feed(data) {
            switch frame.funcCode {
            case 0x11:
                if let parsed = BMSProtocol.parseRealtime(frame.data) {
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
    }

    func diagnoseChannels() async {
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
