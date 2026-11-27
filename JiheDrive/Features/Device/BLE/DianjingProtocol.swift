import Foundation

// MARK: - 点睛仪表寄存器协议
// 对齐点睛小程序 utils/profile.js：帧头 0xAB / 帧尾 0xBA 的寄存器读写协议。
// 广播名前缀 VTB_EF_，主服务 FF00（写 FF01 / 通知 FF02），OTA 服务 EE00（暂不接入）。
// 帧结构：AB | target(1) | code(1) | lenLo | lenHi | content... | checksum | BA
// checksum = (0xAB + target + code + lenLo + lenHi + Σcontent) & 0xFF

enum DianjingCommand: UInt8 {
    /// 下发设置
    case set = 0
    /// 读取
    case read = 1
    /// 设置成功应答
    case setSuccess = 2
    case setFailed = 3
    /// 读取成功应答
    case readSuccess = 4
    case readFailed = 5
}

/// 寄存器 ID（profile.js RegisterId 全表的业务子集，暂接数据/测速/电池相关）
enum DianjingRegister {
    static let language: UInt8 = 0
    static let backlight: UInt8 = 2
    static let dialStyle: UInt8 = 4
    static let batteryDisplayMode: UInt8 = 6
    static let socPercent: UInt8 = 10
    static let deviceID: UInt8 = 22
    static let versionMain: UInt8 = 29
    static let versionSub: UInt8 = 30
    static let subModuleBindState: UInt8 = 33
    static let batterySetup: UInt8 = 96
    /// 直读电池信息：串数 + 满电电压
    static let batteryDirect: UInt8 = 97
    static let batteryConnState: UInt8 = 98
    static let speedCalibRatio: UInt8 = 113
    static let speedCalibState: UInt8 = 114
    /// 零百测速启停：SET 1=开始 2=停止
    static let speedTestControl: UInt8 = 128
    /// 零百测速记录（29 字节）
    static let speedTestRecord: UInt8 = 129
    /// 调试页实时参数（17 字节，小程序 500ms 轮询）
    static let debugParams: UInt8 = 193
    /// RSSI 信号（2 字节：[来源, 有符号信号值]）
    static let rssi: UInt8 = 194
    /// 清空单次行驶信息：SET 空 content
    static let clearSingleTrip: UInt8 = 192
}

struct DianjingFrame {
    let target: UInt8
    let code: UInt8
    let data: [UInt8]
    let raw: [UInt8]

    /// 是否读取成功应答
    var isReadSuccess: Bool { code == DianjingCommand.readSuccess.rawValue }
    /// 是否设置应答（成功/失败都算）
    var isSetAck: Bool {
        code == DianjingCommand.setSuccess.rawValue || code == DianjingCommand.setFailed.rawValue
    }
}

enum DianjingProtocol {
    /// 组帧：READ 时 content 传空数组，SET 时传数据
    static func frame(target: UInt8, code: DianjingCommand, content: [UInt8] = []) -> Data {
        let length = content.count
        var body: [UInt8] = [
            0xAB,
            target,
            code.rawValue,
            UInt8(length & 0xFF),
            UInt8((length >> 8) & 0xFF)
        ]
        body.append(contentsOf: content)
        var sum: UInt32 = 0
        for byte in body { sum &+= UInt32(byte) }
        let raw: [UInt8] = body + [UInt8(sum & 0xFF), 0xBA]
        return Data(raw)
    }

    /// 读寄存器
    static func readFrame(_ target: UInt8) -> Data {
        frame(target: target, code: .read, content: [])
    }

    /// 写寄存器
    static func setFrame(_ target: UInt8, content: [UInt8]) -> Data {
        frame(target: target, code: .set, content: content)
    }
}

/// 通知分片 → 完整帧。按 0xAB 头 + 0xBA 尾扫描，校验和不过就逐字节后移。
final class DianjingFrameDecoder {
    private var buffer: [UInt8] = []
    private let capacity = 4096

    func feed(_ chunk: Data) -> [DianjingFrame] {
        buffer.append(contentsOf: chunk)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }

        var frames: [DianjingFrame] = []
        var index = 0
        while index + 7 <= buffer.count {
            guard buffer[index] == 0xAB else {
                index += 1
                continue
            }
            guard let tail = buffer[index...].firstIndex(of: 0xBA), tail >= index + 6 else {
                // 没等到完整帧尾：若剩余数据过长再丢弃头部，避免缓冲无限增长
                if buffer.count - index > 1024 { index = buffer.count }
                break
            }
            let length = Int(buffer[index + 3]) | (Int(buffer[index + 4]) << 8)
            let total = 7 + length
            guard tail - index + 1 == total else {
                index += 1
                continue
            }
            let slice = Array(buffer[index..<tail])
            let expected = slice.dropLast(2).reduce(0) { $0 &+ UInt32($1) }
            guard UInt8(expected & 0xFF) == buffer[tail - 1] else {
                index += 1
                continue
            }
            let frame = DianjingFrame(
                target: buffer[index + 1],
                code: buffer[index + 2],
                data: length > 0 ? Array(buffer[(index + 5)..<(index + 5 + length)]) : [],
                raw: Array(buffer[index...tail])
            )
            frames.append(frame)
            index = tail + 1
        }
        if index > 0 { buffer.removeFirst(min(index, buffer.count)) }
        return frames
    }
}

// MARK: - 数据字段解析（utils/util.js：全部小端，有符号按补码）

extension DianjingProtocol {
    /// 寄存器 193 调试页实时参数（17 字节），与 pages/debug/debugParams 解析一致
    static func parseDebugParams(_ data: [UInt8]) -> DianjingDebugParams? {
        guard data.count >= 17 else { return nil }
        return DianjingDebugParams(
            soc: Int(data[0]),
            voltage: Double(u16(data, 1)) / 10.0,
            remainingCapacity: Double(u16(data, 3)) / 10.0,
            totalMileage: Double(u32(data, 5)) / 1000.0,
            singleEnergy: Double(u32(data, 9)) / 1000.0,
            enduranceMileage: Double(u32(data, 13)) / 1000.0
        )
    }

    /// 寄存器 129 零百测速记录（29 字节），与 store/modules/speedtest.js 解析一致
    static func parseSpeedTestRecord(_ data: [UInt8]) -> DianjingSpeedTest? {
        guard data.count >= 29 else { return nil }
        return DianjingSpeedTest(
            zeroToFifty: Double(u32(data, 0)) / 100.0,
            zeroToHundred: Double(u32(data, 4)) / 100.0,
            maxSpeed: Int(u16(data, 8)),
            dynamicPressureDiff: Double(u16(data, 10)) / 1000.0,
            maxCurrent: Double(i16(data, 12)) / 10.0,
            minVoltage: Double(u16(data, 14)) / 10.0,
            staticVoltage: Double(u16(data, 16)) / 10.0,
            maxPower: Double(i32(data, 18)) / 1000.0,
            batteryCapacity: Double(u16(data, 22)) / 10.0,
            seriesCount: Int(u16(data, 24)),
            batterySoc: Int(data[26]),
            gpsMaxSpeed: Int(u16(data, 27))
        )
    }

    /// 寄存器 97 直读电池信息（3 字节）：串数 + 满电电压 mV
    static func parseBatteryDirect(_ data: [UInt8]) -> (series: Int, fullVoltage: Double)? {
        guard data.count >= 3 else { return nil }
        return (Int(data[0]), Double(u16(data, 1)) / 1000.0)
    }

    /// 寄存器 194 RSSI（2 字节）：[来源(1=仪表电池/2=子模块/3=子模块电池), 有符号信号值]
    static func parseRSSI(_ data: [UInt8]) -> (source: UInt8, rssi: Int)? {
        guard data.count >= 2 else { return nil }
        return (data[0], Int(Int8(bitPattern: data[1])))
    }

    /// ASCII 字符串字段（设备 ID / 版本号）
    static func ascii(_ data: [UInt8]) -> String {
        String(bytes: data.filter { $0 != 0 }, encoding: .ascii) ?? ""
    }

    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func i16(_ bytes: [UInt8], _ offset: Int) -> Int16 {
        Int16(bitPattern: u16(bytes, offset))
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(u16(bytes, offset)) | (UInt32(u16(bytes, offset + 2)) << 16)
    }

    static func i32(_ bytes: [UInt8], _ offset: Int) -> Int32 {
        Int32(bitPattern: u32(bytes, offset))
    }
}

// MARK: - 数据模型

struct DianjingDebugParams: Equatable {
    /// SOC %
    var soc: Int
    /// 电压 V
    var voltage: Double
    /// 剩余容量 Ah
    var remainingCapacity: Double
    /// 总里程 km
    var totalMileage: Double
    /// 单次电耗 kWh
    var singleEnergy: Double
    /// 续航里程 km
    var enduranceMileage: Double
}

struct DianjingSpeedTest: Equatable {
    /// 0-50 km/h 用时（秒）
    var zeroToFifty: Double
    /// 0-100 km/h 用时（秒）
    var zeroToHundred: Double
    /// 最高时速 km/h
    var maxSpeed: Int
    /// 动压差
    var dynamicPressureDiff: Double
    /// 最大电流 A（有符号）
    var maxCurrent: Double
    /// 最低电压 V
    var minVoltage: Double
    /// 静态电压 V
    var staticVoltage: Double
    /// 最大功率 W（有符号）
    var maxPower: Double
    /// 电池容量 Ah
    var batteryCapacity: Double
    /// 串数
    var seriesCount: Int
    /// SOC %
    var batterySoc: Int
    /// GPS 最高速 km/h
    var gpsMaxSpeed: Int
}
