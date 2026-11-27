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
    // MARK: 配置项（连接时补读，SET 后本地乐观更新）
    /// 当前表盘样式（A01~A04/B01~B03/C01/D01/E01）
    @Published private(set) var dialStyle = ""
    /// 电量显示模式：1=电量格 2=容量 3=电压
    @Published private(set) var batteryDisplayMode: Int = 1
    /// 时间格式：1=24h 2=12h
    @Published private(set) var timeFormat: Int = 1
    /// 背光：1=低 2=中 3=高
    @Published private(set) var backlight: Int = 2
    /// 能耗单位：1=Wh/km 2=Ah/km
    @Published private(set) var energyUnit: Int = 1
    @Published private(set) var magneticSwitch = false
    @Published private(set) var switchSound = false
    /// 续航里程更新阈值（1~100）
    @Published private(set) var socThreshold: Int = 0
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

    /// 清空缓存数据（实时/测速/设备信息/日志），下次连接重新补读配置
    func clearCache() {
        realtime = nil
        speedTest = nil
        batterySeries = 0
        batteryFullVoltage = 0
        deviceID = ""
        versionMain = ""
        lastAck = ""
        logs = []
        realtimeTick = 0
        didBootstrap = false
    }

    /// 连接后补读电池/设备信息/配置（对齐小程序 synchroData 的 connected 阶段）
    private func bootstrap() async {
        guard let ble, ble.isConnected else { return }
        let targets: [UInt8] = [
            DianjingRegister.batteryDirect,
            DianjingRegister.speedTestRecord,
            DianjingRegister.deviceID,
            DianjingRegister.versionMain,
            DianjingRegister.dialStyle,
            DianjingRegister.batteryDisplayMode,
            DianjingRegister.timeFormat,
            DianjingRegister.backlight,
            DianjingRegister.energyUnit,
            DianjingRegister.magneticSwitch,
            DianjingRegister.switchSound,
            DianjingRegister.socPercent
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
            case DianjingRegister.dialStyle:
                dialStyle = DianjingProtocol.ascii(frame.data)
            case DianjingRegister.batteryDisplayMode:
                batteryDisplayMode = Int(frame.data.first ?? 1)
            case DianjingRegister.timeFormat:
                timeFormat = Int(frame.data.first ?? 1)
            case DianjingRegister.backlight:
                backlight = Int(frame.data.first ?? 2)
            case DianjingRegister.energyUnit:
                energyUnit = Int(frame.data.first ?? 1)
            case DianjingRegister.magneticSwitch:
                magneticSwitch = frame.data.first == 1
            case DianjingRegister.switchSound:
                switchSound = frame.data.first == 1
            case DianjingRegister.socPercent:
                socThreshold = Int(frame.data.first ?? 0)
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

    // MARK: - 配置下发（对齐点睛小程序设置页）

    /// 切表盘样式：寄存器 4 写 3 字节样式名 ASCII
    func setDialStyle(_ id: String) async {
        let bytes = Array(id.uppercased().utf8.prefix(3))
        guard bytes.count == 3 else { return }
        await sendSet(DianjingRegister.dialStyle, content: bytes)
        dialStyle = id.uppercased()
    }

    /// 电量显示三选一：1=电量格 2=容量 3=电压
    func setBatteryDisplay(_ mode: Int) async {
        await sendSet(DianjingRegister.batteryDisplayMode, content: [UInt8(mode)])
        batteryDisplayMode = mode
    }

    /// 时间格式：1=24h 2=12h
    func setTimeFormat(_ value: Int) async {
        await sendSet(DianjingRegister.timeFormat, content: [UInt8(value)])
        timeFormat = value
    }

    /// 背光：1=低 2=中 3=高
    func setBacklight(_ value: Int) async {
        await sendSet(DianjingRegister.backlight, content: [UInt8(value)])
        backlight = value
    }

    /// 能耗单位：1=Wh/km 2=Ah/km
    func setEnergyUnit(_ value: Int) async {
        await sendSet(DianjingRegister.energyUnit, content: [UInt8(value)])
        energyUnit = value
    }

    /// 开关类寄存器（磁控/轮切声音）：1=开 2=关
    func setSwitch(_ register: UInt8, on: Bool) async {
        await sendSet(register, content: [on ? 1 : 2])
        if register == DianjingRegister.magneticSwitch {
            magneticSwitch = on
        } else if register == DianjingRegister.switchSound {
            switchSound = on
        }
    }

    /// 续航里程更新阈值（1~100）
    func setSocThreshold(_ value: Int) async {
        let clamped = min(100, max(1, value))
        await sendSet(DianjingRegister.socPercent, content: [UInt8(clamped)])
        socThreshold = clamped
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
        let data = Self.bytes(from: customDataHex)
        guard let target = UInt8(customTargetHex.filter { !$0.isWhitespace }, radix: 16),
              let code = UInt8(customCodeHex.filter { !$0.isWhitespace }, radix: 16) else {
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
