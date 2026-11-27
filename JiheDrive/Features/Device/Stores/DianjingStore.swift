import Foundation

/// 点睛仪表数据源：对齐点睛小程序的轮询与读取节奏。
/// 实时参数（寄存器 193）小程序 500ms 轮询一次；连接后补读电池直读（97）/
/// 零百记录（129）/ 设备信息（22/29）。
@MainActor
final class DianjingStore: ObservableObject {
    @Published private(set) var realtime: DianjingDebugParams?
    @Published private(set) var speedTest: DianjingSpeedTest?
    /// 电池直读：串数 + 满电电压 V
    @Published private(set) var batterySeries: Int = 0
    @Published private(set) var batteryFullVoltage: Double = 0
    @Published private(set) var deviceID = ""
    @Published private(set) var versionMain = ""
    @Published private(set) var rssi: Int = 0
    @Published private(set) var lastAck = ""
    @Published private(set) var isPolling = false
    @Published private(set) var logs: [String] = []
    /// 轮询间隔（秒）；小程序默认 500ms
    @Published var pollInterval: TimeInterval = {
        let stored = UserDefaults.standard.double(forKey: "device.dianjing.pollInterval")
        return stored >= 0.5 ? stored : 0.5
    }() {
        didSet {
            let clamped = min(max(pollInterval, 0.5), 5)
            if clamped != pollInterval { pollInterval = clamped; return }
            UserDefaults.standard.set(pollInterval, forKey: "device.dianjing.pollInterval")
        }
    }
    @Published var customTargetHex = "C1"
    @Published var customCodeHex = "00"
    @Published var customDataHex = ""

    private let decoder = DianjingFrameDecoder()
    private weak var ble: DeviceBLEManager?
    private var pollTask: Task<Void, Never>?
    private var realtimeTick = 0
    private var didBootstrap = false

    func attach(_ ble: DeviceBLEManager) {
        self.ble = ble
        ble.registerDataHandler("dianjing") { [weak self] data in
            Task { @MainActor in self?.feed(data) }
        }
        appendLog("仪表协议：点睛寄存器协议（FF01/FF02）")
    }

    func deactivate() {
        ble?.unregisterDataHandler("dianjing")
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    func startPolling() {
        pollTask?.cancel()
        isPolling = true
        pollTask = Task { [weak self] in
            guard let self else { return }
            if !self.didBootstrap {
                self.didBootstrap = true
                await self.bootstrap()
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

    /// 连接后补读电池/设备信息（对齐小程序 synchroData 的 connected 阶段）
    private func bootstrap() async {
        guard let ble, ble.isConnected else { return }
        let targets: [UInt8] = [
            DianjingRegister.batteryDirect,
            DianjingRegister.speedTestRecord,
            DianjingRegister.deviceID,
            DianjingRegister.versionMain
        ]
        for target in targets {
            do {
                try await ble.write(DianjingProtocol.readFrame(target))
                try? await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                appendLog("读寄存器 \(target) 失败：\(error.localizedDescription)")
            }
        }
    }

    private func pollOnce() async {
        guard let ble, ble.isConnected else { return }
        do {
            try await ble.write(DianjingProtocol.readFrame(DianjingRegister.debugParams))
        } catch {
            appendLog("读取失败：\(error.localizedDescription)")
        }
    }

    private func feed(_ data: Data) {
        for frame in decoder.feed(data) {
            switch frame.target {
            case DianjingRegister.debugParams:
                if let params = DianjingProtocol.parseDebugParams(frame.data) {
                    realtime = params
                    realtimeTick += 1
                }
            case DianjingRegister.speedTestRecord:
                if let record = DianjingProtocol.parseSpeedTestRecord(frame.data) {
                    speedTest = record
                }
            case DianjingRegister.batteryDirect:
                if let battery = DianjingProtocol.parseBatteryDirect(frame.data) {
                    batterySeries = battery.series
                    batteryFullVoltage = battery.fullVoltage
                }
            case DianjingRegister.deviceID:
                deviceID = DianjingProtocol.ascii(frame.data)
            case DianjingRegister.versionMain:
                versionMain = DianjingProtocol.ascii(frame.data)
            case DianjingRegister.rssi:
                if let rssi = DianjingProtocol.parseRSSI(frame.data) { self.rssi = rssi.rssi }
            default:
                if frame.isSetAck {
                    lastAck = frame.code == DianjingCommand.setSuccess.rawValue
                        ? "设置成功" : "设置失败"
                    appendLog("寄存器 \(frame.target) 应答：\(lastAck)")
                } else if frame.isReadSuccess {
                    appendLog("寄存器 \(frame.target) 返回 \(frame.data.count) 字节")
                }
            }
        }
    }

    // MARK: - 控制

    /// 零百测速启停：SET 寄存器 128，1=开始 2=停止
    func setSpeedTest(start: Bool) async {
        await sendSet(DianjingRegister.speedTestControl, content: [start ? 1 : 2])
    }

    /// 清空单次行驶信息：SET 寄存器 192 空 content
    func clearSingleTrip() async {
        await sendSet(DianjingRegister.clearSingleTrip, content: [])
    }

    private func sendSet(_ target: UInt8, content: [UInt8]) async {
        guard let ble, ble.isConnected else { return }
        do {
            try await ble.write(DianjingProtocol.setFrame(target, content: content))
            appendLog("SET 寄存器 \(target)：\(content.map { String(format: "%02X", $0) }.joined())")
        } catch {
            appendLog("写入失败：\(error.localizedDescription)")
        }
    }

    /// 调试面板自定义帧：任意 target/code/数据
    func sendCustomCommand() async {
        guard let ble, ble.isConnected else { return }
        guard let target = UInt8(customTargetHex, radix: 16),
              let code = UInt8(customCodeHex, radix: 16),
              let data = Self.bytes(from: customDataHex) else {
            appendLog("十六进制格式不正确")
            return
        }
        do {
            try await ble.write(DianjingProtocol.frame(target: target, code: DianjingCommand(rawValue: code) ?? .read, content: data))
            appendLog("自定义帧 AB \(String(format: "%02X", target)) \(String(format: "%02X", code))")
        } catch {
            appendLog("发送失败：\(error.localizedDescription)")
        }
    }

    private static func bytes(from hex: String) -> [UInt8] {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0, !cleaned.isEmpty else { return [] }
        var result: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let value = UInt8(cleaned[index..<next], radix: 16) else { return [] }
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
