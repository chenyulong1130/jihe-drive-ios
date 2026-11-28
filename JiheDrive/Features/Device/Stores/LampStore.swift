import Foundation

/// 速牛灯具数据源：按传输通道组帧（标准 5A A5 / UQ / 紧凑）。
/// 仅保留通用 RGB 调试：颜色（80）/ 亮度（81）/ 模式速度（82）/ 灯效模式（85）。
/// 产品与模式库来自速调试目录（LampCatalog + LampModeLibrary），每产品不同。
@MainActor
final class LampStore: ObservableObject {
    @Published private(set) var transport: LampTransport?
    /// 产品目录识别出的产品名（如「极核AE4/5前位置灯二代」），未命中为 nil
    @Published private(set) var catalogProductName: String?
    /// 目录产品 ID（模式库按此取该产品的模式列表）
    @Published private(set) var catalogProductId: Int?
    /// 该产品的模式库列表（每产品不同）
    @Published private(set) var libraryModes: [LampLibraryMode] = []
    @Published private(set) var lastError = ""
    @Published private(set) var logs: [String] = []
    @Published var customCommandHex = ""

    private let decoder = LampFrameDecoder()
    private weak var ble: DeviceBLEManager?
    private var serial: UInt16 = 0
    /// 回执等待锁：上一条指令未完成前不再下发（对齐参考实现 commandBusy）
    private var commandBusy = false

    func attach(_ ble: DeviceBLEManager) {
        self.ble = ble
        transport = ble.connectedDevice?.lampTransport ?? LampTransport.detect(name: ble.connectedDevice?.name ?? "")
        // 产品识别（速调试同款目录机制）：最长前缀匹配 → 产品名 + 产品 ID
        if let name = ble.connectedDevice?.name, let matched = LampCatalog.match(for: name) {
            catalogProductName = matched.productName
            catalogProductId = matched.productId
            libraryModes = LampModeLibrary.modes(for: matched.productId)
            appendLog("已按产品目录识别：\(matched.productName)（模式 \(libraryModes.count) 个）")
        } else {
            catalogProductName = nil
            catalogProductId = nil
            libraryModes = []
        }
        serial = 0
        commandBusy = false
        ble.registerDataHandler("lamp") { [weak self] data in
            Task { @MainActor in self?.feed(data) }
        }
        appendLog("灯具通道：\(transport?.title ?? "未识别")")
    }

    func deactivate() {
        ble?.unregisterDataHandler("lamp")
    }

    /// 清空缓存数据（日志/错误），不动产品识别结果
    func clearCache() {
        logs = []
        lastError = ""
        commandBusy = false
    }

    // MARK: - 组帧下发

    private func send(parent: UInt8, command: UInt8, payload: [UInt8], genericMapped: Bool = false, label: String, channel: Int? = nil) async {
        guard let ble, ble.isConnected else { return }
        guard let transport else {
            lastError = "未识别灯具通道，请在扫描列表手动按灯具打开"
            return
        }
        guard !commandBusy else {
            lastError = "正在等待设备回执，请稍后操作"
            return
        }
        serial &+= 1
        let frame: Data
        switch transport {
        case .uq:
            // UQ：有通道时命令码置 01，载荷变 [通道, 事件命令, 数据长度, 数据…]
            let wire = genericMapped ? (LampProtocol.genericCommand(command, transport: transport) ?? command) : command
            frame = LampProtocol.uqFrame(
                command: wire,
                payload: payload,
                serial: serial,
                channel: channel.map { [UInt8(max(0, min(255, $0)))] }
            )
        case .compact:
            guard let wire = genericMapped ? LampProtocol.genericCommand(command, transport: transport) : command else {
                lastError = "该设备尚未适配此功能"
                return
            }
            frame = LampProtocol.compactFrame(command: wire, payload: payload)
        default:
            // 标准帧：通道以分区 TLV（command 01）附加在控制 TLV 之前
            let wire = genericMapped ? (LampProtocol.genericCommand(command, transport: transport) ?? command) : command
            frame = LampProtocol.frame(
                parent: parent,
                command: wire,
                payload: payload,
                serial: serial,
                partition: channel.map { [UInt8(max(0, min(255, $0)))] }
            )
        }
        commandBusy = true
        defer { commandBusy = false }
        do {
            try await ble.write(frame, useResponse: transport != .uq)
            appendLog("\(label)：\(frame.hexString)")
        } catch {
            lastError = error.localizedDescription
            appendLog("发送失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 对外操作

    /// RGB 颜色（通用命令 80）
    func setColor(red: Int, green: Int, blue: Int) async {
        await send(parent: 2, command: LampProtocol.GenericCommand.rgbColor,
                   payload: [UInt8(red), UInt8(green), UInt8(blue)],
                   genericMapped: true, label: "设置 RGB 颜色")
    }

    /// 通用控制：亮度（81）/ 模式速度（82）
    func setGeneric(_ command: UInt8, value: Int) async {
        await send(parent: 2, command: command, payload: [UInt8(value)], genericMapped: true,
                   label: command == LampProtocol.GenericCommand.brightness ? "设置灯光亮度" : "设置模式速度")
    }

    /// 灯效模式选择（原命令 85 → 普通协议 08 / 紧凑 93）。
    /// - Parameter channel: 行车 0 / 开机 1 / 转向 2 / 急刹 3，按分区帧下发
    func setMode(_ mode: Int, channel: Int? = nil) async {
        let payload = [UInt8(max(1, min(0x6A, mode)))]
        await send(parent: 2, command: LampProtocol.GenericCommand.mode,
                   payload: payload, genericMapped: true, label: "设置灯效模式", channel: channel)
    }

    /// 应用模式库中的一条模式（每产品独立数据）：模式号走通用命令，
    /// 分组映射到通道 TLV（行车/开机/转向/急刹），其余分组不带通道
    func applyLibraryMode(_ mode: LampLibraryMode) async {
        guard let number = mode.number, number > 0, number <= 0x6A else {
            lastError = "模式号 \(mode.no) 超出设备支持范围（1–106）"
            return
        }
        await setMode(number, channel: mode.channel?.rawValue)
    }

    /// 调试面板：按当前通道组帧发送任意 HEX 载荷
    func sendCustom(parent: UInt8, command: UInt8, payload: [UInt8]) async {
        await send(parent: parent, command: command, payload: payload, label: "自定义指令")
    }

    // MARK: - 回包处理

    private func feed(_ data: Data) {
        for frame in decoder.feed(data) {
            switch frame.kind {
            case .standard(_, let serial, let fields):
                appendLog("回包 serial=\(serial)：\(fields.map { "0x\(String(format: "%02X", $0.command))(\($0.data.count)B)" }.joined(separator: " "))")
            case .compact(let command, let payload):
                appendLog("紧凑回包 0x\(String(format: "%02X", command))：\(payload.map { String(format: "%02X", $0) }.joined())")
            }
        }
    }

    private func appendLog(_ text: String) {
        logs.append(text)
        if logs.count > 60 { logs.removeFirst(logs.count - 60) }
    }
}
