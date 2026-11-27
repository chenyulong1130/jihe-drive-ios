import Foundation

/// 速牛灯具数据源：按传输通道组帧（标准 5A A5 / UQ / 紧凑），
/// 专用参数（角度 1F / AE7-M5-FX 20）走 LampState 快照，
/// 通用控制（RGB 颜色 / 亮度 / 模式速度）走 80/81/82 命令映射。
@MainActor
final class LampStore: ObservableObject {
    @Published private(set) var transport: LampTransport?
    @Published private(set) var profile: LampState.Profile = .angle {
        didSet {
            // 切换调试类型即重置快照，等重新读取
            if oldValue != profile { state.select(profile); syncProfileToView() }
        }
    }
    @Published private(set) var synced = false
    @Published private(set) var minAngle = -60
    @Published private(set) var maxAngle = 60
    @Published private(set) var step = 1
    @Published private(set) var angle: Int = 0
    @Published private(set) var lastError = ""
    @Published private(set) var logs: [String] = []
    @Published var customCommandHex = ""

    private let state = LampState()
    private let decoder = LampFrameDecoder()
    private weak var ble: DeviceBLEManager?
    private var serial: UInt16 = 0
    /// 等待专用参数回包（回包串行号需与查询一致才收）
    private var pendingSerial: UInt16?
    /// 回执等待锁：上一条指令未完成前不再下发（对齐参考实现 commandBusy）
    private var commandBusy = false

    func attach(_ ble: DeviceBLEManager) {
        self.ble = ble
        transport = ble.connectedDevice?.lampTransport ?? LampTransport.detect(name: ble.connectedDevice?.name ?? "")
        state.select(profile)
        syncProfileToView()
        ble.registerDataHandler("lamp") { [weak self] data in
            Task { @MainActor in self?.feed(data) }
        }
        appendLog("灯具通道：\(transport?.title ?? "未识别")")
    }

    func deactivate() {
        ble?.unregisterDataHandler("lamp")
    }

    /// 切换调试类型（视图入口；didSet 里统一重置快照）
    func selectProfile(_ profile: LampState.Profile) {
        self.profile = profile
    }

    private func syncProfileToView() {
        synced = state.synced
        minAngle = state.minAngle
        maxAngle = state.maxAngle
        step = state.step
        if let snapshot = state.snapshot, profile == .angle {
            angle = Int(Int8(bitPattern: snapshot[0]))
        }
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
        if parent == 1 { pendingSerial = serial }
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

    /// 读取设备参数（专用查询；通用 RGB 协议未确认查询指令）
    func readParams() async {
        guard profile != .rgb else {
            lastError = "通用 RGB 协议支持颜色、亮度和模式，暂未确认参数查询指令"
            return
        }
        guard transport != .compact else {
            lastError = "该紧凑协议设备未适配专用查询"
            return
        }
        await send(parent: 1, command: state.command, payload: state.queryPayload, label: "读取设备参数")
    }

    /// 设置灯光角度（角度类型专用）
    func setAngle(_ value: Int, reset: Bool) async {
        do {
            let payload = try state.setAnglePayload(value, reset: reset)
            await send(parent: 2, command: 0x1F, payload: payload, label: "设置灯光角度")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 修改 12 字节配置快照（AE7/M5/FX 专用项）
    func change(kind: String, value: Int) async {
        do {
            let payload = try state.changePayload(kind: kind, value: value)
            await send(parent: 2, command: state.command, payload: payload, label: "设置灯光参数")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// RGB 颜色（M5/AE7 快照 / RGB 通用命令）
    func setColor(red: Int, green: Int, blue: Int) async {
        let rgb = (red << 16) | (green << 8) | blue
        if profile == .rgb {
            await send(parent: 2, command: LampProtocol.GenericCommand.rgbColor,
                       payload: [UInt8(red), UInt8(green), UInt8(blue)],
                       genericMapped: true, label: "设置 RGB 颜色")
        } else {
            do {
                let payload = try state.colorPayload(rgb: rgb)
                await send(parent: 2, command: state.command, payload: payload, label: "设置 RGB 颜色")
            } catch {
                lastError = error.localizedDescription
            }
        }
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
                for field in fields {
                    // 串行号与当前查询相符才更新专用参数快照
                    if serial == pendingSerial, state.accept(command: field.command, data: field.data) {
                        pendingSerial = nil
                        synced = true
                        minAngle = state.minAngle
                        maxAngle = state.maxAngle
                        step = state.step
                        if profile == .angle {
                            angle = Int(Int8(bitPattern: field.data[0]))
                        }
                        appendLog("专用参数已同步（\(profile.rawValue)）")
                    }
                }
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
