import Foundation

// MARK: - 蚂蚁充电机协议（新协议引擎）
// 依据蚂蚁小程序（wxe7b6244f6461fc6c）反编译代码：
// - 通道/连接层与保护板共用 FFE0 服务（FFE1 / FFF3/FFF4 / FFF5/FFF6 三组通道）。
// - 帧格式走新协议引擎（sdk/api/common/utils/CheckPackage.js + ProtocolBasic.js）：
//   [0x7E, addr] FUNC(1) REG_L REG_H(小端) LEN(1) DATA... CRC_L CRC_H(小端) [0xAA, 0x55]
//   · CRC16-Modbus，计算范围 = addr + FUNC + REG + LEN + DATA（首个子帧含 addr 字节），
//     与保护板老帧不同：结果低字节在前（小端），寄存器地址也是小端。
//   · 帧头第二字节为通讯地址（默认 0xA1，可被自定义通讯地址替换，如 0xC1）。
//   · 一个通知包内可串联多个 FUNC 子帧（ bleComApi 实测帧头 7ea11100 / 7ec11100 均有出现）。
// - 充电机专属命令寄存器表在服务端协议 JSON（code=charger）下发，本地反编译无缓存；
//   这里集中放已实锤的命令（历史数据 FUNC=86，ChargerHistoryTools.js），
//   实时读沿用蚂蚁族 0x11（BLE 实测实时帧头 7ea11100），联调后如不同只改 ChargerCommandConfig。

/// 充电机命令集中配置：寄存器/功能码全部收口在此，实机联调后按需调整
enum ChargerCommandConfig {
    /// 实时数据读：蚂蚁族 BLE 实测帧头 7EA1 11 00（功能码 0x11 / 寄存器 0x0000）
    static let realtimeFunc: UInt8 = 0x11
    static let realtimeRegister: UInt16 = 0x0000
    static let realtimeReadLength: UInt8 = 0xF5
    /// 历史监控数据（ChargerHistoryTools.js 实锤 funcCode="86"）
    static let historyFunc: UInt8 = 0x86
    /// 历史数据每页条数（ChargerHistoryTools.buildCommand 页大小）
    static let historyPageSize: UInt8 = 10
    /// 默认通讯地址（帧头第二字节）
    static let defaultAddress: UInt8 = 0xA1
}

struct ChargerFrame {
    let funcCode: UInt8
    /// 寄存器地址（小端解析后）
    let register: UInt16
    let data: [UInt8]
    let raw: [UInt8]
}

enum ChargerProtocol {
    /// 组读/写帧。读帧 LEN=读取长度；写帧 LEN=数据长度。
    /// - Parameter address: 通讯地址（帧头第二字节），默认 0xA1
    static func frame(
        funcCode: UInt8,
        register: UInt16,
        data: [UInt8] = [],
        readLength: UInt8 = 0,
        address: UInt8 = ChargerCommandConfig.defaultAddress
    ) -> Data {
        var body: [UInt8] = [
            address,
            funcCode,
            UInt8(register & 0xFF),
            UInt8((register >> 8) & 0xFF),
            data.isEmpty ? readLength : UInt8(min(data.count, 255))
        ]
        body.append(contentsOf: data)
        // CRC 范围 = addr + FUNC + REG + LEN + DATA（ProtocolBasic.packageCommand：prefix 去掉首字节 0x7E）
        let crc = BMSProtocol.crc16(body)
        // 新引擎 CRC 小端（低字节在前），与保护板老帧相反
        let raw: [UInt8] = [0x7E] + body + [UInt8(crc & 0xFF), UInt8(crc >> 8), 0xAA, 0x55]
        return Data(raw)
    }

    /// 实时数据读帧
    static func realtimeFrame(address: UInt8 = ChargerCommandConfig.defaultAddress) -> Data {
        frame(
            funcCode: ChargerCommandConfig.realtimeFunc,
            register: ChargerCommandConfig.realtimeRegister,
            readLength: ChargerCommandConfig.realtimeReadLength,
            address: address
        )
    }

    /// 历史监控数据读帧（ChargerHistoryTools.buildCommand：页大小 1 字节 + 起始序号 LE16，序号从 1 起）
    static func historyFrame(page: Int, pageSize: UInt8, address: UInt8 = ChargerCommandConfig.defaultAddress) -> Data {
        let start = UInt16(page * Int(pageSize) + 1)
        let payload: [UInt8] = [
            pageSize,
            UInt8(start & 0xFF),
            UInt8((start >> 8) & 0xFF)
        ]
        return frame(funcCode: ChargerCommandConfig.historyFunc, register: 0x0000, data: payload, address: address)
    }
}

/// 通知分片 → 子帧列表。头部 [0x7E, addr] 扫描，单包内按 FUNC+REG+LEN+CRC 串联子帧逐个解析，
/// 全部子帧 CRC 校验通过且以 0xAA 0x55 收尾才算完整包；失败则逐字节后移。
final class ChargerFrameDecoder {
    private var buffer: [UInt8] = []
    private let capacity = 4096

    /// 解析结果：半包等后续数据 / 校验不符逐字节后移 / 成功
    private enum ParseOutcome {
        case incomplete
        case invalid
        case success([ChargerFrame], Int)
    }

    func feed(_ chunk: Data) -> [ChargerFrame] {
        buffer.append(contentsOf: chunk)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }

        var frames: [ChargerFrame] = []
        var index = 0
        while index + 10 <= buffer.count {
            guard buffer[index] == 0x7E else {
                index += 1
                continue
            }
            switch Self.parsePacket(Array(buffer[index...])) {
            case .incomplete:
                // 等下一次 feed 拼包，保留从 index 起的数据
                if index > 0 { buffer.removeFirst(index) }
                return frames
            case .invalid:
                index += 1
            case .success(let parsed, let consumed):
                frames.append(contentsOf: parsed)
                index += consumed
            }
        }
        if index > 0 { buffer.removeFirst(min(index, buffer.count)) }
        return frames
    }

    /// 尝试解析一个完整包（可能含多个串联子帧）
    private static func parsePacket(_ bytes: [UInt8]) -> ParseOutcome {
        guard bytes.count >= 3 else { return .incomplete }
        let address = bytes[1]
        guard address != 0x7E, address != 0xAA, address != 0x55 else { return .invalid }

        var offset = 2
        var frames: [ChargerFrame] = []
        var firstSubframe = true
        while true {
            // 子帧：FUNC(1) + REG(2) + LEN(1) + DATA + CRC(2)，尾部再 2 字节 AA55
            guard offset + 6 <= bytes.count else { return .incomplete }
            let funcCode = bytes[offset]
            let register = UInt16(bytes[offset + 1]) | (UInt16(bytes[offset + 2]) << 8)
            let length = Int(bytes[offset + 3])
            let dataEnd = offset + 4 + length
            guard dataEnd + 2 <= bytes.count else { return .incomplete }

            let crcLow = UInt16(bytes[dataEnd])
            let crcHigh = UInt16(bytes[dataEnd + 1])
            let expected = crcLow | (crcHigh << 8)

            var crcRange: [UInt8] = [address]
            crcRange.append(contentsOf: bytes[offset..<dataEnd])
            if !firstSubframe { crcRange.removeFirst() } // 后续子帧 CRC 不含 addr 字节
            guard Int(BMSProtocol.crc16(crcRange)) == expected else { return .invalid }

            frames.append(ChargerFrame(
                funcCode: funcCode,
                register: register,
                data: Array(bytes[(offset + 4)..<dataEnd]),
                raw: []
            ))
            firstSubframe = false

            let next = dataEnd + 2
            guard next + 2 <= bytes.count else { return .incomplete }
            guard bytes[next] == 0xAA, bytes[next + 1] == 0x55 else {
                // 不是帧尾 → 同包还有下一个子帧，继续解析
                offset = next
                continue
            }
            return .success(frames, next + 2)
        }
    }
}

// MARK: - 历史监控数据记录（charger_log_analysis_1.0.0.js 实锤）

/// 历史记录 8 字节/条，低 4 bit = dataType：
/// 0=测量（输入/输出电压电流） 1=保护标志位（64bit 右移 4 位） 2=阶段变化（充电阶段/工作状态）
enum ChargerHistoryRecord: Equatable, Identifiable {
    case measure(inputCurrent: Double, inputVoltage: Double, outputVoltage: Double, outputCurrent: Double)
    case protection(flags: UInt64)
    case stageChange(chargeStage: UInt8, workStatus: UInt8)

    var id: String {
        switch self {
        case .measure(let i, let iv, let ov, let oc): return "m-\(i)-\(iv)-\(ov)-\(oc)"
        case .protection(let flags): return "p-\(flags)"
        case .stageChange(let a, let b): return "s-\(a)-\(b)"
        }
    }
}

extension ChargerProtocol {
    static func parseHistoryRecords(_ data: [UInt8]) -> [ChargerHistoryRecord] {
        var records: [ChargerHistoryRecord] = []
        var offset = 0
        while offset + 8 <= data.count {
            let s = Array(data[offset..<(offset + 8)])
            offset += 8
            let dataType = Int(s[0] & 0x0F)
            switch dataType {
            case 0:
                // readShort(s,0) >> 4：低 4 bit 是 dataType，剩余位是带符号电流
                let rawCurrent = Int16(bitPattern: u16(s, 0))
                records.append(.measure(
                    inputCurrent: Double(rawCurrent >> 4) / 10.0,
                    inputVoltage: Double(i16(s, 2)) / 10.0,
                    outputVoltage: Double(i16(s, 4)) / 10.0,
                    outputCurrent: Double(i16(s, 6)) / 10.0
                ))
            case 1:
                // 64bit 小端 → 右移 4 位（readLongRightShift4）
                var flags: UInt64 = 0
                for (i, byte) in s.enumerated() { flags |= UInt64(byte) << (8 * UInt64(i)) }
                records.append(.protection(flags: flags >> 4))
            case 2:
                records.append(.stageChange(chargeStage: s[1], workStatus: s[2]))
            default:
                continue
            }
        }
        return records
    }

    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func i16(_ bytes: [UInt8], _ offset: Int) -> Int16 {
        Int16(bitPattern: u16(bytes, offset))
    }
}

// MARK: - 保护标志位文案
// 顺序取自小程序 power.* i18n（index43~77）；页面逻辑在反编译产物中是桩，
// 位序按 i18n 序列排布，index56/70 为数字占位（对应保留位），联调日志可校准。

extension ChargerHistoryRecord {
    static let protectionFlags: [String] = [
        "母线输出过压(PFC输出)", "母线输出欠压(PFC输出)", "PFC过流保护", "交流输入过流",
        "交流输入过压", "交流输入欠压", "PFC过温(MOS,电感)", "交流频率高",
        "交流频率低", "输入缺相(三相)", "输入不平衡(三相)", "母线纹波过高",
        "保留位", "LLC过温(MOS,变压器)", "负载突变保护", "电池反接保护",
        "输出欠压保护1", "输出短路保护(LLC输出)", "输出过流保护(LLC输出)", "输出过压保护",
        "输出欠压保护2", "谐振腔过流", "LLC输入过流保护", "LLC输出过功率保护",
        "漏电保护", "系统错误", "保留位", "内部通信保护",
        "散热故障", "风扇故障", "环境温度高", "辅助电源异常",
        "升级固件", "自检失败"
    ]

    var protectionNames: [String] {
        guard case .protection(let flags) = self else { return [] }
        return BMSProtocol.flagNames(flags, table: Self.protectionFlags)
    }
}

// MARK: - 实时数据模型

/// 充电机实时快照：0x11 响应若与蚂蚁族字段布局兼容则展示结构化字段，
/// 否则只留原始帧（诊断面板可复制，供联调补寄存器表）。
struct ChargerRealtime {
    var voltage: Double = 0
    var current: Double = 0
    var power: Int = 0
    var soc: Int = 0
    var mosTemperature: Int = 0
    var cellTemperature: Int = 0
    var protectFlags: UInt64 = 0
    var warningFlags: UInt64 = 0
    var chargerVoltage: Double = 0
    var chargerCurrent: Double = 0
    var parsed: Bool = false
    var rawHex = ""
}

extension ChargerRealtime {
    /// 用蚂蚁 0x11 顺序游标尝试解析（与保护板同族布局）
    static func from(data: [UInt8]) -> ChargerRealtime? {
        guard let bms = BMSProtocol.parseRealtime(data) else { return nil }
        return ChargerRealtime(
            voltage: bms.totalVoltage,
            current: bms.current,
            power: bms.power,
            soc: bms.soc,
            mosTemperature: bms.mosTemperature,
            cellTemperature: bms.temperatures.first ?? 0,
            protectFlags: bms.protectFlags,
            warningFlags: bms.warningFlags,
            chargerVoltage: bms.chargerVoltage,
            chargerCurrent: bms.chargerCurrent,
            parsed: true,
            rawHex: bms.rawHex
        )
    }
}
