import Foundation

// MARK: - BMS 帧

struct BMSFrame {
    let funcCode: UInt8
    let address: UInt16
    let data: [UInt8]
    let raw: [UInt8]
}

enum BMSProtocol {
    /// CRC16-Modbus：init 0xFFFF，poly 0xA001，结果高字节在前
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    /// 读帧 LEN=读取长度（0 表示读取全部）；写帧 LEN=数据长度
    static func frame(funcCode: UInt8, address: UInt16, data: [UInt8] = [], readLength: UInt8 = 0) -> Data {
        var body: [UInt8] = [
            0xA1,
            funcCode,
            UInt8(address & 0xFF),
            UInt8(address >> 8),
            data.isEmpty ? readLength : UInt8(min(data.count, 255))
        ]
        body.append(contentsOf: data)
        let crc = crc16(body)
        let raw: [UInt8] = [0x7E] + body + [UInt8(crc >> 8), UInt8(crc & 0xFF), 0xAA, 0x55]
        return Data(raw)
    }

    static func ackMessage(_ data: [UInt8]) -> String {
        guard data.count >= 2 else { return "应答帧过短" }
        let code = Int(data[0]) | (Int(data[1]) << 8)
        switch code {
        case 0: return "无操作"
        case 1: return "设置成功"
        case 2: return "控制执行失败"
        case 3: return "权限校验失败"
        case 4: return "地址超过限制"
        case 5: return "电池类型错误"
        case 6: return "电流信息错误"
        case 7: return "固件不匹配"
        default: return "未知结果码 \(code)"
        }
    }

    static func flagNames(_ mask: UInt64, table: [String]) -> [String] {
        var result: [String] = []
        for index in 0..<min(table.count, 64) {
            if (mask & (UInt64(1) << UInt64(index))) != 0 { result.append(table[index]) }
        }
        return result
    }

    static let warningFlags: [String] = [
        "单体过压告警", "总压过压告警", "单体欠压告警", "总压欠压告警", "单体压差告警",
        "充电高温告警", "放电高温告警", "充电低温告警", "放电低温告警", "MOS 高温告警",
        "充电过流告警", "放电过流告警", "SOC 一级告警", "SOC 二级告警", "单体校验异常",
        "总压校验异常", "预充失败", "电池充满", "充电中", "放电中",
        "CAN 充电连接", "485 充电连接", "充电连接 CUR", "充电 MOS 开", "放电 MOS 开",
        "均衡开", "待机中", "均衡极限", "均衡压差", "均衡自动",
        "均衡过温", "电压保护", "温度保护", "系统错误", "GPS 通信丢失",
        "均衡检测", "电加热开启", "强制输出中", "蓝牙关闭", "继电器预充中",
        "MOS 预充中", "充电继电器开", "放电继电器开", "时钟异常", "强制开启充电",
        "调试模式", "可用时间到达", "可用即将到达", "防打火中", "即将低压关机",
        "蚂蚁充电连接", "均衡等待", "测试模式", "内部通信不稳定"
    ]

    static let protectFlags: [String] = [
        "设置电芯类型", "单体过压保护", "单体二级过压", "总压过压保护", "单体欠压保护",
        "单体二级欠压", "总压欠压保护", "单体压差保护", "充电高温保护", "放电高温保护",
        "MOS 高温保护", "充电低温保护", "放电低温保护", "充电过流保护", "放电过流保护",
        "二级过流保护", "短路保护", "放电开关 1", "放电开关 2", "放电开关 3",
        "放电开关 4", "充电开关 1", "充电开关 2", "充电开关 3", "充电开关 4",
        "均衡线掉串", "电流异常", "放电 MOS 异常", "充电 MOS 异常", "内部通信异常",
        "预充失败", "BMS 初始化", "自检 1", "自检 2", "自检 3",
        "充电通信检测", "GPS 丢失保护", "防打火工作", "请升级固件", "继电器预充关",
        "继电器粘连", "放电保险异常", "充电保险异常", "模组失联", "可用时间到达",
        "预放 MOS 异常", "预充 MOS 异常", "负载锁定开启", "采集接收模式", "采集保留",
        "采集 Boot 模式"
    ]

    static func batteryStateText(_ value: UInt8) -> String {
        switch value {
        case 0: return "静止"
        case 1: return "充电中"
        case 2: return "待机中"
        case 3: return "放电中"
        case 4: return "异常"
        default: return "未知(\(value))"
        }
    }

    static func batteryTypeText(_ value: UInt16) -> String {
        switch value {
        case 1: return "三元锂"
        case 2: return "磷酸铁锂"
        case 3: return "钛酸锂"
        case 4: return "钠电"
        case 5: return "其他"
        case 6: return "磷酸锰铁锂"
        default: return "未知(\(value))"
        }
    }
}

/// 通知分片 → 完整帧。找到头后校验帧尾与 CRC，失败则逐字节后移继续扫描。
final class BMSFrameDecoder {
    private var buffer: [UInt8] = []
    private let capacity = 4096

    func feed(_ chunk: Data) -> [BMSFrame] {
        buffer.append(contentsOf: chunk)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }

        var frames: [BMSFrame] = []
        var index = 0
        while index + 10 <= buffer.count {
            guard buffer[index] == 0x7E, buffer[index + 1] == 0xA1 else {
                index += 1
                continue
            }
            let length = Int(buffer[index + 5])
            let total = 10 + length
            if index + total > buffer.count { break }
            guard buffer[index + 8 + length] == 0xAA,
                  buffer[index + 9 + length] == 0x55 else {
                index += 1
                continue
            }
            let expected = (Int(buffer[index + 6 + length]) << 8) | Int(buffer[index + 7 + length])
            let crcRange = Array(buffer[index + 1...index + 5 + length])
            guard Int(BMSProtocol.crc16(crcRange)) == expected else {
                index += 1
                continue
            }
            let frame = BMSFrame(
                funcCode: buffer[index + 2],
                address: UInt16(buffer[index + 3]) | (UInt16(buffer[index + 4]) << 8),
                data: Array(buffer[index + 6..<(index + 6 + length)]),
                raw: Array(buffer[index..<(index + total)])
            )
            frames.append(frame)
            index += total
        }
        if index > 0 { buffer.removeFirst(index) }
        return frames
    }
}

// MARK: - 0x11 实时数据

struct BMSRealtime {
    var auth: UInt8 = 0
    var state: UInt8 = 0
    var cellCount: Int = 0
    var temperatureCount: Int = 0
    var protectFlags: UInt64 = 0
    var warningFlags: UInt64 = 0
    var pushFlags: UInt64 = 0
    var cellVoltages: [Double] = []
    var cellBalance: [Int] = []
    var temperatures: [Int] = []
    var mosTemperature: Int = 0
    var balanceTemperature: Int = 0
    var totalVoltage: Double = 0
    var current: Double = 0
    var soc: Int = 0
    var soh: Int = 0
    var dischargeMOS: UInt8 = 0
    var chargeMOS: UInt8 = 0
    var balanceState: UInt8 = 0
    var bmsType: UInt8 = 0
    var physicalCapacity: Double = 0
    var remainingCapacity: Double = 0
    var cycleCapacity: Double = 0
    var power: Int = 0
    var runningTime: UInt32 = 0
    var highestCell: Double = 0
    var highestCellIndex: UInt16 = 0
    var lowestCell: Double = 0
    var lowestCellIndex: UInt16 = 0
    var voltageDiff: Double = 0
    var averageCell: Double = 0
    var chargeRemainingMinutes: UInt16 = 0
    var dischargeRemainingMinutes: UInt16 = 0
    var highSpeedCurrent: Double = 0
    var chargerVoltage: Double = 0
    var chargerCurrent: Double = 0
    var chargerState: UInt16 = 0
    var batteryType: UInt16 = 0
    var rawHex = ""
}

private struct ByteReader {
    let bytes: [UInt8]
    var offset = 0
    var failed = false

    mutating func u8() -> UInt8 {
        guard offset < bytes.count else { failed = true; return 0 }
        let value = bytes[offset]
        offset += 1
        return value
    }

    mutating func u16() -> UInt16 {
        let low = u8(), high = u8()
        return UInt16(low) | (UInt16(high) << 8)
    }

    mutating func i16() -> Int16 {
        let low = u8(), high = u8()
        return Int16(bitPattern: UInt16(low) | (UInt16(high) << 8))
    }

    mutating func u32() -> UInt32 {
        let b0 = u8(), b1 = u8(), b2 = u8(), b3 = u8()
        return UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(b3) << 24)
    }

    mutating func i32() -> Int32 {
        Int32(bitPattern: u32())
    }

    mutating func u64() -> UInt64 {
        let b0 = u8(), b1 = u8(), b2 = u8(), b3 = u8()
        let b4 = u8(), b5 = u8(), b6 = u8(), b7 = u8()
        return UInt64(b0) | (UInt64(b1) << 8) | (UInt64(b2) << 16) | (UInt64(b3) << 24)
            | (UInt64(b4) << 32) | (UInt64(b5) << 40) | (UInt64(b6) << 48) | (UInt64(b7) << 56)
    }
}

extension BMSProtocol {
    /// 解析 0x11 的 DATA 段，字段顺序与 bms_0x11_1.0.0.js 的顺序游标一致
    static func parseRealtime(_ data: [UInt8]) -> BMSRealtime? {
        guard data.count >= 28 else { return nil }
        var reader = ByteReader(bytes: data)
        var value = BMSRealtime()

        value.auth = reader.u8()
        value.state = reader.u8()
        value.temperatureCount = Int(reader.u8())
        value.cellCount = Int(reader.u8())
        value.protectFlags = reader.u64()
        value.warningFlags = reader.u64()
        value.pushFlags = reader.u64()

        guard value.cellCount <= 64, value.temperatureCount <= 32 else { return nil }

        for _ in 0..<value.cellCount {
            let low = reader.u8()
            let high = reader.u8()
            value.cellBalance.append(Int(high >> 5) & 0x07)
            let raw = UInt16(low) | ((UInt16(high) & 0x1F) << 8)
            value.cellVoltages.append(Double(raw) / 1000.0)
        }
        for _ in 0..<value.temperatureCount {
            value.temperatures.append(Int(reader.i16()))
        }

        value.mosTemperature = Int(reader.i16())
        value.balanceTemperature = Int(reader.i16())
        value.totalVoltage = Double(reader.u16()) / 100.0
        value.current = Double(reader.i16()) / 10.0
        value.soc = Int(reader.u16())
        value.soh = Int(reader.u16())
        value.dischargeMOS = reader.u8()
        value.chargeMOS = reader.u8()
        value.balanceState = reader.u8()
        value.bmsType = reader.u8()
        value.physicalCapacity = Double(reader.u32()) / 1_000_000.0
        value.remainingCapacity = Double(reader.u32()) / 1_000_000.0
        value.cycleCapacity = Double(reader.u32()) / 1_000.0
        value.power = Int(reader.i32())
        value.runningTime = reader.u32()
        _ = reader.u32() // 均衡标志位（主动均衡详情暂不展开）
        value.highestCell = Double(reader.u16()) / 1000.0
        value.highestCellIndex = reader.u16()
        value.lowestCell = Double(reader.u16()) / 1000.0
        value.lowestCellIndex = reader.u16()
        value.voltageDiff = Double(reader.u16()) / 1000.0
        value.averageCell = Double(reader.u16()) / 1000.0
        _ = reader.i16() // DSV
        _ = reader.u16() // DV
        _ = reader.u16() // CV
        _ = reader.u16() // COM
        value.batteryType = reader.u16()
        _ = reader.u32() // 累计放电容量
        _ = reader.u32() // 累计充电容量
        _ = reader.u32() // 累计放电时间
        _ = reader.u32() // 累计充电时间
        _ = reader.u32() // 本次充电时长
        _ = reader.u32() // 上次充电间隔
        value.chargeRemainingMinutes = reader.u16()
        value.dischargeRemainingMinutes = reader.u16()
        value.highSpeedCurrent = Double(reader.i16()) / 10.0
        _ = reader.u16() // 有效期
        _ = reader.u16() // 采集故障
        value.chargerVoltage = Double(reader.u16()) / 10.0
        value.chargerCurrent = Double(reader.u16()) / 10.0
        value.chargerState = reader.u16()

        guard !reader.failed else { return nil }
        value.rawHex = data.map { String(format: "%02X", $0) }.joined()
        return value
    }
}
