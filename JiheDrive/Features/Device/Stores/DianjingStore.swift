import Foundation

/// 点睛仪表数据源：对齐点睛小程序的轮询与读取节奏。
/// 连接后补读配置寄存器（表盘样式 4 / 电量显示 / 时间格式 / 背光 / 能耗单位 /
/// 磁控 / 轮切声音 / 续航阈值），轮询保活并回读当前样式。
@MainActor
final class DianjingStore: ObservableObject {
    /// 电池直读：串数 + 满电电压 V
    @Published private(set) var batterySeries: Int = 0
    @Published private(set) var batteryFullVoltage: Double = 0
    @Published private(set) var deviceID = ""
    @Published private(set) var rssi: Int = 0
    // MARK: 配置项（连接时补读，SET 后本地乐观更新）
    /// 当前表盘样式（A01~A04/B01~B03/C01/D01/E01）
    @Published private(set) var dialStyle = ""
    // MARK: 样式自动轮切（寄存器 7）
    /// 1=单屏显示 2=轮切显示
    @Published private(set) var autoStyleState: Int = 1
    /// 轮切间隔（秒）
    @Published private(set) var autoStyleTime: Int = 0
    /// 参与轮切的主题 ID（A01…E01）
    @Published private(set) var autoStyleStyles: [String] = []
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
    private let decoder = DianjingFrameDecoder()
    private weak var ble: DeviceBLEManager?
    private var pollTask: Task<Void, Never>?
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

    /// 清空缓存数据（设备信息/日志），下次连接重新补读配置
    func clearCache() {
        batterySeries = 0
        batteryFullVoltage = 0
        deviceID = ""
        lastAck = ""
        logs = []
        didBootstrap = false
    }

    /// 连接后补读电池/设备信息/配置（对齐小程序 synchroData 的 connected 阶段）
    private func bootstrap() async {
        guard let ble, ble.isConnected(.dianjingMeter) else { return }
        let targets: [UInt8] = [
            DianjingRegister.batteryDirect,
            DianjingRegister.deviceID,
            DianjingRegister.dialStyle,
            DianjingRegister.autoStyleSwitch,
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
                try await ble.write(DianjingProtocol.readFrame(target), kind: .dianjingMeter)
                try? await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                appendLog("读寄存器 \(target) 失败：\(error.localizedDescription)")
            }
        }
    }

    /// 轮询改为低频保活 + 周期回读当前表盘样式/配置
    private func pollOnce() async {
        guard let ble, ble.isConnected(.dianjingMeter) else { return }
        do {
            try await ble.write(DianjingProtocol.readFrame(DianjingRegister.dialStyle), kind: .dianjingMeter)
        } catch {
            appendLog("读取失败：\(error.localizedDescription)")
        }
    }

    private func feed(_ data: Data) {
        for frame in decoder.feed(data) {
            switch frame.target {
            case DianjingRegister.batteryDirect:
                if let battery = DianjingProtocol.parseBatteryDirect(frame.data) {
                    batterySeries = battery.series
                    batteryFullVoltage = battery.fullVoltage
                }
            case DianjingRegister.deviceID:
                deviceID = DianjingProtocol.ascii(frame.data)
            case DianjingRegister.dialStyle:
                // 清洗尾部空白/不可见字符，否则选中主题无法高亮
                let raw = DianjingProtocol.ascii(frame.data)
                dialStyle = raw.filter { $0.isLetter || $0.isNumber }.uppercased()
            case DianjingRegister.autoStyleSwitch:
                // 布局（对齐点睛小程序）：[状态, 主题数, 时间低, 时间高, 主题名ASCII×3字节…]
                let d = frame.data
                if d.count >= 4 {
                    autoStyleState = Int(d[0])
                    let count = Int(d[1])
                    autoStyleTime = Int(d[2]) | (Int(d[3]) << 8)
                    var styles: [String] = []
                    var pos = 4
                    for _ in 0..<min(count, 10) where pos + 3 <= d.count {
                        if let name = String(bytes: d[pos..<pos + 3], encoding: .ascii)?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                            styles.append(name)
                        }
                        pos += 3
                    }
                    autoStyleStyles = styles
                }
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

    // MARK: - 配置下发（对齐点睛小程序设置页）

    /// 切表盘样式：寄存器 4 写 3 字节样式名 ASCII
    func setDialStyle(_ id: String) async {
        let bytes = Array(id.uppercased().utf8.prefix(3))
        guard bytes.count == 3 else { return }
        await sendSet(DianjingRegister.dialStyle, content: bytes)
        dialStyle = id.uppercased()
    }

    /// 样式自动轮切（寄存器 7，对齐点睛小程序字节布局）：
    /// [状态, 主题数, 时间低, 时间高, 主题名ASCII×3字节×N 补零到30]
    /// - Parameter state: 1=单屏显示 2=轮切显示
    func setAutoStyleSwitch(state: Int, time: Int, styles: [String]) async {
        var bytes: [UInt8] = [UInt8(max(1, min(2, state))), UInt8(min(10, styles.count))]
        let t = min(65_535, max(0, time))
        bytes += [UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF)]
        var packed: [UInt8] = []
        for style in styles.prefix(10) {
            packed += Array(style.uppercased().utf8.prefix(3))
        }
        while packed.count < 30 { packed.append(0) }
        bytes += packed
        await sendSet(DianjingRegister.autoStyleSwitch, content: bytes)
        autoStyleState = min(2, max(1, state))
        autoStyleTime = t
        autoStyleStyles = Array(styles.prefix(10))
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
        guard let ble, ble.isConnected(.dianjingMeter) else { return }
        do {
            try await ble.write(DianjingProtocol.setFrame(target, content: content), kind: .dianjingMeter)
            appendLog("SET 寄存器 \(target)：\(content.map { String(format: "%02X", $0) }.joined())")
        } catch {
            appendLog("写入失败：\(error.localizedDescription)")
        }
    }

    private func appendLog(_ text: String) {
        logs.append(text)
        if logs.count > 60 { logs.removeFirst(logs.count - 60) }
    }
}
