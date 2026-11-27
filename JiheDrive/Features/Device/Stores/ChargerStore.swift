import Foundation

/// 蚂蚁充电机数据源：新协议引擎帧（ChargerProtocol）。
/// 实时读（0x11）+ 历史监控数据（FUNC=86，页号+起始序号）+ 自定义帧调试。
/// 充电机专属寄存器表在服务端协议 JSON 下发，本地以 ChargerCommandConfig 收口，
/// 联调时可通过自定义帧面板补齐。
@MainActor
final class ChargerStore: ObservableObject {
    @Published private(set) var realtime: ChargerRealtime?
    @Published private(set) var historyRecords: [ChargerHistoryRecord] = []
    @Published private(set) var historyStatus = "尚未读取"
    @Published private(set) var lastAck = ""
    @Published private(set) var isPolling = false
    @Published private(set) var logs: [String] = []
    /// 轮询间隔（秒）
    @Published var pollInterval: TimeInterval = {
        let stored = UserDefaults.standard.double(forKey: "device.charger.pollInterval")
        return stored >= 0.5 ? stored : 1.0
    }() {
        didSet {
            let clamped = min(max(pollInterval, 0.5), 10)
            if clamped != pollInterval { pollInterval = clamped; return }
            UserDefaults.standard.set(pollInterval, forKey: "device.charger.pollInterval")
        }
    }
    /// 自定义通讯地址（帧头第二字节），空串 = 默认 0xA1
    @Published var customAddressHex = ""
    @Published var customFuncHex = "11"
    @Published var customRegisterHex = "0000"
    @Published var customDataHex = ""

    private let decoder = ChargerFrameDecoder()
    private weak var ble: DeviceBLEManager?
    private var pollTask: Task<Void, Never>?

    /// 当前通讯地址：自定义优先，回落默认
    var address: UInt8 {
        UInt8(customAddressHex.filter { !$0.isWhitespace }, radix: 16) ?? ChargerCommandConfig.defaultAddress
    }

    func attach(_ ble: DeviceBLEManager) {
        self.ble = ble
        ble.registerDataHandler("charger") { [weak self] data in
            Task { @MainActor in self?.feed(data) }
        }
        appendLog("充电机协议：蚂蚁新协议引擎（CRC 小端 / 寄存器小端）")
    }

    func deactivate() {
        ble?.unregisterDataHandler("charger")
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
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
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
        do {
            try await ble.write(ChargerProtocol.realtimeFrame(address: address))
        } catch {
            appendLog("读取失败：\(error.localizedDescription)")
        }
    }

    private func feed(_ data: Data) {
        for frame in decoder.feed(data) {
            switch frame.funcCode {
            case ChargerCommandConfig.realtimeFunc:
                if let parsed = ChargerRealtime.from(data: frame.data) {
                    realtime = parsed
                } else {
                    appendLog("0x11 响应 \(frame.data.count) 字节（布局不兼容，见诊断）")
                    realtime = realtime ?? ChargerRealtime()
                    realtime?.rawHex = frame.data.hexString
                }
            case ChargerCommandConfig.historyFunc:
                let records = ChargerProtocol.parseHistoryRecords(frame.data)
                if records.isEmpty {
                    historyStatus = historyRecords.isEmpty ? "无更多记录" : "读取完成 · \(historyRecords.count) 条"
                } else {
                    historyRecords.append(contentsOf: records)
                    historyStatus = "已读取 \(historyRecords.count) 条"
                }
            default:
                appendLog("收到功能码 0x\(String(format: "%02X", frame.funcCode))，寄存器 \(frame.register)，\(frame.data.count) 字节")
            }
        }
    }

    // MARK: - 历史数据

    /// 按页拉取历史监控数据（ChargerHistoryTools：页大小 + 起始序号，序号从 1 起）
    func fetchHistory(pages: Int = 3) async {
        guard let ble, ble.isConnected else {
            historyStatus = "请先连接设备"
            return
        }
        historyRecords.removeAll()
        historyStatus = "读取中…"
        for page in 0..<max(1, pages) {
            guard !Task.isCancelled else { return }
            do {
                try await ble.write(ChargerProtocol.historyFrame(page: page, pageSize: ChargerCommandConfig.historyPageSize, address: address))
                // 页间留间隔，等设备返回再翻页
                try? await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                historyStatus = "读取失败：\(error.localizedDescription)"
                appendLog("历史数据读取失败：\(error.localizedDescription)")
                return
            }
        }
    }

    /// 最近一条保护标志位（历史记录或实时帧）
    var latestProtectionFlags: UInt64? {
        if case .protection(let flags)? = historyRecords.last(where: {
            if case .protection = $0 { return true }
            return false
        }) { return flags }
        if let rt = realtime, rt.protectFlags != 0 { return rt.protectFlags }
        return nil
    }

    // MARK: - 调试

    /// 自定义帧：FUNC / 寄存器 / 数据（寄存器小端由协议层统一处理）
    func sendCustomCommand() async {
        guard let ble, ble.isConnected else { return }
        guard let funcCode = UInt8(customFuncHex.filter { !$0.isWhitespace }, radix: 16),
              let register = UInt16(customRegisterHex.filter { !$0.isWhitespace }, radix: 16),
              let data = Self.bytes(from: customDataHex) else {
            appendLog("十六进制格式不正确")
            return
        }
        let frame = ChargerProtocol.frame(funcCode: funcCode, register: register, data: data, readLength: data.isEmpty ? 0xF5 : 0, address: address)
        do {
            try await ble.write(frame)
            lastAck = "已发送，等待应答"
            appendLog("自定义指令：\(frame.hexString)")
        } catch {
            appendLog("发送失败：\(error.localizedDescription)")
        }
    }

    private static func bytes(from hex: String) -> [UInt8] {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return [] }
        if cleaned.isEmpty { return [] }
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
