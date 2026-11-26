import Foundation

/// 彦阳 BMS — Modbus RTU over BLE（对齐 Flutter `yanyang_protocol.dart` / 彦阳小程序）。
///
/// 轮询：
/// - 71~72 (4B) 运行时间
/// - 75~109 (70B) 基础 + 前 29 节电压
/// - 110~122 (26B) 末节/温度/容量/SOC/SOH
/// - 123~127 (10B) 循环次数
/// - 152~157 (12B) MOS / 告警
final class YanyangProtocol {
    private(set) var saAddress: UInt8 = 1
    private var merged: [String: Any] = [:]
    private var frameBuffer: [UInt8] = []

    private static let alarmNames = [
        "单串过压", "单串欠压", "总过压", "总欠压",
        "充电过流", "放电过流1", "放电过流2", "短路",
        "充电高温", "充电低温", "放电高温", "放电低温", "MOS高温"
    ]

    // MARK: - 请求

    static func modbusRead(addr: UInt8, startReg: UInt16, regCount: UInt16) -> Data {
        var body: [UInt8] = [
            addr,
            0x03,
            UInt8(startReg >> 8), UInt8(startReg & 0xFF),
            UInt8(regCount >> 8), UInt8(regCount & 0xFF)
        ]
        let crc = BMSProtocol.crc16(body)
        // Modbus CRC 低字节在前
        body.append(UInt8(crc & 0xFF))
        body.append(UInt8(crc >> 8))
        return Data(body)
    }

    func requestSaAddress() -> Data { Self.modbusRead(addr: 1, startReg: 0x00, regCount: 1) }
    func requestProtoFlag() -> Data { Self.modbusRead(addr: 1, startReg: 0x3F, regCount: 2) }

    func pollRequests() -> [Data] {
        let a = saAddress == 0 ? 1 : saAddress
        return [
            Self.modbusRead(addr: a, startReg: 71, regCount: 2),
            Self.modbusRead(addr: a, startReg: 75, regCount: 35),
            Self.modbusRead(addr: a, startReg: 110, regCount: 13),
            Self.modbusRead(addr: a, startReg: 123, regCount: 5),
            Self.modbusRead(addr: a, startReg: 152, regCount: 6)
        ]
    }

    func reset() {
        merged.removeAll()
        frameBuffer.removeAll()
    }

    // MARK: - 收包

    /// 喂入通知分片；合并出可用指标时返回 `BMSRealtime`。
    func onNotify(_ chunk: Data) -> BMSRealtime? {
        guard !chunk.isEmpty else { return nil }
        frameBuffer.append(contentsOf: chunk)
        if frameBuffer.count > 4096 {
            frameBuffer.removeFirst(frameBuffer.count - 2048)
        }

        var latest: BMSRealtime?
        while frameBuffer.count >= 5 {
            var start = -1
            for i in 0...(frameBuffer.count - 5) {
                if frameBuffer[i + 1] == 0x03 {
                    let n = Int(frameBuffer[i + 2])
                    if n > 0, n <= 200, i + 3 + n + 2 <= frameBuffer.count {
                        start = i
                        break
                    }
                }
            }
            if start < 0 {
                if frameBuffer.count > 64 {
                    frameBuffer.removeFirst(frameBuffer.count - 32)
                }
                break
            }
            if start > 0 { frameBuffer.removeFirst(start) }

            let dataLen = Int(frameBuffer[2])
            let frameLen = 3 + dataLen + 2
            guard frameLen <= frameBuffer.count else { break }

            let frame = Array(frameBuffer.prefix(frameLen))
            frameBuffer.removeFirst(frameLen)

            if frame[0] != 0 { saAddress = frame[0] }
            let data = Array(frame[3..<(3 + dataLen)])

            // SBDM 握手应答跳过
            if data.count >= 4,
               data[0] == 0x53, data[1] == 0x42, data[2] == 0x44, data[3] == 0x4D {
                continue
            }

            mergeFrame(byteCount: dataLen, data: data)
            if let snap = toRealtime() { latest = snap }
        }
        return latest
    }

    // MARK: - 合并

    private func u16LE(_ data: [UInt8], _ o: Int) -> UInt16 {
        guard o + 1 < data.count else { return 0 }
        return UInt16(data[o]) | (UInt16(data[o + 1]) << 8)
    }

    private func u32LE(_ data: [UInt8], _ o: Int) -> UInt32 {
        guard o + 3 < data.count else { return 0 }
        return UInt32(data[o])
            | (UInt32(data[o + 1]) << 8)
            | (UInt32(data[o + 2]) << 16)
            | (UInt32(data[o + 3]) << 24)
    }

    private func i32LE(_ data: [UInt8], _ o: Int) -> Int32 {
        Int32(bitPattern: u32LE(data, o))
    }

    private func decodeTemp(_ t: UInt8) -> Double {
        (t >= 0 && t <= 200) ? Double(Int(t) - 40) : 0
    }

    private func mergeFrame(byteCount: Int, data: [UInt8]) {
        // REQ0: 71~72 => 运行时间
        if byteCount == 0x04, data.count == 4 {
            merged["runningTime"] = u32LE(data, 0)
        }

        // FULL pack
        if (byteCount == 0x6A && data.count == 106) || (byteCount == 0x64 && data.count == 100) {
            mergeFullPack(data)
            return
        }

        // REQ1: 75~109 => 70B
        if byteCount == 0x46, data.count == 70 {
            let typeMap = [0: "三元锂", 1: "铁锂", 2: "钛酸锂"]
            let cellCount = Int(data[0])
            merged["cellCount"] = cellCount
            merged["batteryType"] = typeMap[Int(data[1])] ?? "未知"
            merged["totalVoltage"] = Double(u32LE(data, 2)) / 1000.0
            merged["current"] = Double(i32LE(data, 6)) / 100.0

            let maxCells = min(max(cellCount, 1), 30)
            var cells = Array(repeating: 0.0, count: maxCells)
            let loop = min(29, maxCells)
            for i in 0..<loop {
                let raw = u16LE(data, 12 + i * 2)
                cells[i] = raw > 0 ? Double(raw) / 1000.0 : 0
            }
            merged["cellVoltages"] = cells
        }

        // REQ2: 110~122 => 26B
        if byteCount == 0x1A, data.count == 26 {
            let expected = merged["cellCount"] as? Int ?? 0
            let maxCells = min(max(expected > 0 ? expected : 30, 1), 30)
            var base = (merged["cellVoltages"] as? [Double]) ?? Array(repeating: 0.0, count: maxCells)
            while base.count < maxCells { base.append(0) }
            if expected >= 30, maxCells >= 30 {
                let rawLast = u16LE(data, 0)
                base[29] = rawLast > 0 ? Double(rawLast) / 1000.0 : 0
            }
            merged["cellVoltages"] = base
            merged["maxCellPos"] = Int(data[2])
            merged["minCellPos"] = Int(data[3])
            merged["powerTubeTemp"] = decodeTemp(data[4])
            merged["balanceTemp"] = decodeTemp(data[5])

            var temps: [Double] = []
            for i in 6...13 where i < data.count {
                if data[i] > 0, data[i] <= 200 { temps.append(decodeTemp(data[i])) }
            }
            if !temps.isEmpty {
                merged["tempsC"] = temps
            }

            let rated = Double(u16LE(data, 16)) / 10.0
            let actual = Double(u16LE(data, 18)) / 10.0
            let soc = Int(data[20])
            let soh = Int(data[21])
            merged["ratedCapacity"] = rated
            merged["actualCapacity"] = actual
            merged["soc"] = soc
            merged["soh"] = soh
            merged["remainWh"] = Double(u32LE(data, 22))

            let cap = actual > 0 ? actual : rated
            if cap > 0, soc >= 0, soc <= 100 {
                merged["totalCapacityAh"] = cap
                merged["remainingCapacityAh"] = cap * Double(soc) / 100.0
            }
        }

        // REQ4: 123~127 => 10B，循环次数大端
        if byteCount == 0x0A, data.count == 10 {
            let cyc = (Int(data[8]) << 8) | Int(data[9])
            if cyc > 0, cyc < 100_000 { merged["cycleCount"] = cyc }
        }

        // REQ3: 152~157 => 12B
        if byteCount == 0x0C, data.count == 12 {
            let runState1 = u32LE(data, 0)
            let mode = Int((runState1 >> 26) & 0x03)
            merged["mode"] = mode
            merged["dischargeMOS"] = (runState1 & (1 << 0)) != 0
            merged["chargeMOS"] = (runState1 & (1 << 1)) != 0
            merged["activeBalance"] = (runState1 & (1 << 2)) != 0
            let alarm = u32LE(data, 8)
            merged["protectFlags"] = decodeAlarm(alarm)
        }
    }

    private func mergeFullPack(_ data: [UInt8]) {
        let typeMap = [0: "三元锂", 1: "铁锂", 2: "钛酸锂"]
        merged["cellCount"] = Int(data[0])
        merged["batteryType"] = typeMap[Int(data[1])] ?? "未知"
        merged["totalVoltage"] = Double(u32LE(data, 2)) / 1000.0
        merged["current"] = Double(i32LE(data, 6)) / 100.0

        var cells: [Double] = []
        for i in 0..<30 {
            let raw = u16LE(data, 12 + i * 2)
            if raw == 0 {
                if !cells.isEmpty { break }
                continue
            }
            let v = Double(raw) / 1000.0
            if v >= 1.5, v <= 5.0 { cells.append(v) }
        }
        merged["cellVoltages"] = cells

        if data.count > 75 {
            merged["powerTubeTemp"] = decodeTemp(data[74])
            merged["balanceTemp"] = decodeTemp(data[75])
        }
        var temps: [Double] = []
        for i in 76...83 where i < data.count {
            if data[i] > 0, data[i] <= 200 { temps.append(decodeTemp(data[i])) }
        }
        if !temps.isEmpty { merged["tempsC"] = temps }

        if data.count > 91 {
            let rated = Double(u16LE(data, 86)) / 10.0
            let actual = Double(u16LE(data, 88)) / 10.0
            let soc = Int(data[90])
            let soh = Int(data[91])
            merged["ratedCapacity"] = rated
            merged["actualCapacity"] = actual
            merged["soc"] = soc
            merged["soh"] = soh
            if data.count >= 96 { merged["remainWh"] = Double(u32LE(data, 92)) }
            let cap = actual > 0 ? actual : rated
            if cap > 0, soc >= 0, soc <= 100 {
                merged["totalCapacityAh"] = cap
                merged["remainingCapacityAh"] = cap * Double(soc) / 100.0
            }
        }
        if data.count >= 106 {
            let cyc = (Int(data[104]) << 8) | Int(data[105])
            if cyc > 0, cyc < 100_000 { merged["cycleCount"] = cyc }
        }
    }

    private func decodeAlarm(_ flags: UInt32) -> [String] {
        guard flags != 0 else { return [] }
        var out: [String] = []
        for i in 0..<Self.alarmNames.count {
            if (flags & (1 << i)) != 0 { out.append(Self.alarmNames[i]) }
        }
        if out.isEmpty { out.append(String(format: "告警:0x%X", flags)) }
        return out
    }

    private func toRealtime() -> BMSRealtime? {
        let voltage = merged["totalVoltage"] as? Double ?? 0
        let soc = merged["soc"] as? Int ?? 0
        let soh = merged["soh"] as? Int ?? 0
        let cellsV = (merged["cellVoltages"] as? [Double]) ?? []
        let expected = merged["cellCount"] as? Int ?? 0
        let cells: [Double] = {
            let trimmed = (expected > 0 && cellsV.count > expected)
                ? Array(cellsV.prefix(expected)) : cellsV
            return trimmed.filter { $0 > 0 }
        }()
        guard voltage > 1 || !cells.isEmpty || soc > 0 else { return nil }

        let current = merged["current"] as? Double ?? 0
        var power = voltage * current
        let fullAh = (merged["totalCapacityAh"] as? Double)
            ?? (merged["actualCapacity"] as? Double)
            ?? (merged["ratedCapacity"] as? Double)
            ?? 0
        var remainAh = merged["remainingCapacityAh"] as? Double ?? 0
        if remainAh <= 0, fullAh > 0, soc > 0 {
            remainAh = fullAh * Double(soc) / 100.0
        }
        let remainWh = merged["remainWh"] as? Double ?? 0
        if remainAh <= 0, remainWh > 0, voltage > 1 {
            remainAh = remainWh / voltage
        }

        let temps = (merged["tempsC"] as? [Double]) ?? []
        let mos = merged["powerTubeTemp"] as? Double ?? 0
        let mode = merged["mode"] as? Int ?? 0
        let chargeMOS = (merged["chargeMOS"] as? Bool) == true
        let dischargeMOS = (merged["dischargeMOS"] as? Bool) == true
        let balance = (merged["activeBalance"] as? Bool) == true
        let typeName = merged["batteryType"] as? String ?? ""
        let protectNames = (merged["protectFlags"] as? [String]) ?? []
        let cycle = merged["cycleCount"] as? Int ?? 0
        let runSec = merged["runningTime"] as? UInt32 ?? 0
        let maxPos = merged["maxCellPos"] as? Int ?? 0
        let minPos = merged["minCellPos"] as? Int ?? 0

        var rt = BMSRealtime()
        rt.brand = .yanyang
        rt.soc = soc
        rt.soh = soh
        rt.totalVoltage = voltage
        rt.current = current
        rt.power = Int(power.rounded())
        rt.cellCount = expected > 0 ? expected : cells.count
        rt.cellVoltages = cells
        rt.physicalCapacity = fullAh
        rt.remainingCapacity = remainAh
        rt.cycleCapacity = Double(cycle)
        rt.mosTemperature = Int(mos.rounded())
        rt.temperatures = temps.map { Int($0.rounded()) }
        rt.temperatureCount = rt.temperatures.count
        rt.dischargeMOS = dischargeMOS ? 1 : 0
        rt.chargeMOS = chargeMOS ? 1 : 0
        rt.balanceState = balance ? 1 : 0
        rt.runningTime = runSec
        rt.batteryTypeLabel = typeName
        rt.protectNames = protectNames
        rt.cycleCount = cycle
        rt.state = UInt8(mode) // 0 静 1 充 2 放
        if !cells.isEmpty {
            let hi = cells.max() ?? 0
            let lo = cells.min() ?? 0
            rt.highestCell = hi
            rt.lowestCell = lo
            rt.voltageDiff = hi - lo
            rt.averageCell = cells.reduce(0, +) / Double(cells.count)
            rt.highestCellIndex = UInt16(max(0, maxPos))
            rt.lowestCellIndex = UInt16(max(0, minPos))
        }
        if typeName.contains("三元") { rt.batteryType = 1 }
        else if typeName.contains("铁锂") { rt.batteryType = 2 }
        else if typeName.contains("钛酸") { rt.batteryType = 3 }
        return rt
    }
}
