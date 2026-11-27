import Foundation

// MARK: - 灯具传输通道与识别
// 对齐调试工具源码 Protocol.java / BleController.java 的 LINKS 表：
// 按广播名分类传输方式，各类通道使用不同的服务/特征与帧校验。

enum LampTransport: String {
    /// 旧版认证：FFE0 / 写 FFE1 / 通知 FFE2
    case legacyAuth
    /// 新协议一：2760 长 UUID 服务 / 写 ...e0001 / 通知 ...e0002
    case gatt2760
    /// 新协议二：FFF0 / 写 FFF2 / 通知 FFF1
    case gattFFF0
    /// 网页端 UQ 透明传输：FFE0 / 写 FFE1 / 通知 FFE2（KVNWC 前缀）
    case uq
    /// 紧凑协议：FFE0 / 写 FFE1 / 通知 FFE1
    case compact

    var title: String {
        switch self {
        case .legacyAuth: return "旧版认证"
        case .gatt2760: return "2760 通道"
        case .gattFFF0: return "FFF0 通道"
        case .uq: return "UQ 通道"
        case .compact: return "紧凑协议"
        }
    }

    /// 识别规则与参考实现一致：KVNWC→UQ；长度 13→紧凑；
    /// 第 4 位为 W→FFF0；第 3 位不属于 P/N/C 或第 4 位为 E→2760；其余旧版认证。
    static func detect(name: String) -> LampTransport? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 7 else { return nil }
        if trimmed.uppercased().hasPrefix("KVNWC") { return .uq }
        if trimmed.count == 13 { return .compact }
        let chars = Array(trimmed)
        if chars[3] == "W" { return .gattFFF0 }
        let family = chars[2]
        return (family != "P" && family != "N" && family != "C") || chars[3] == "E"
            ? .gatt2760 : .legacyAuth
    }
}

/// 回包 TLV 字段
struct LampField {
    let command: UInt8
    let data: [UInt8]
}

/// 标准 5A A5 帧 / 紧凑 A1 帧（自动识别）+ TLV 解析
struct LampFrame {
    enum Kind {
        /// 标准 5A A5：parent + serial + TLV 列表
        case standard(parent: UInt8, serial: UInt16, fields: [LampField])
        /// 紧凑 A1：command + data
        case compact(command: UInt8, data: [UInt8])
    }
    let kind: Kind
    let raw: [UInt8]
}

enum LampProtocol {
    // MARK: 组帧

    /// 标准 5A A5 帧（2760 / FFF0 / 旧版认证）：
    /// 5A A5 01 03 lenLE16 parent serialLE16 [分区TLV] command len+1 payload checksum 5B B5
    /// 校验和 = Σ(偏移 2 .. 校验字节前) 低 8 位
    static func frame(
        parent: UInt8,
        command: UInt8,
        payload: [UInt8],
        serial: UInt16,
        partition: [UInt8]? = nil
    ) -> Data {
        precondition(payload.count <= 254, "指令长度无效")
        let hasPartition = !(partition ?? []).isEmpty && partition?[0] != 0xFF
        let size = 14 + payload.count + (hasPartition ? 2 + partition!.count : 0)
        var out = [UInt8](repeating: 0, count: size)
        out[0] = 0x5A; out[1] = 0xA5; out[2] = 0x01; out[3] = 0x03
        out[4] = UInt8((size - 4) & 0xFF); out[5] = UInt8(((size - 4) >> 8) & 0xFF)
        out[6] = parent
        out[7] = UInt8(serial & 0xFF); out[8] = UInt8((serial >> 8) & 0xFF)
        var pos = 9
        if hasPartition {
            out[pos] = 0x01
            out[pos + 1] = UInt8(partition!.count + 1)
            out.replaceSubrange((pos + 2)..<(pos + 2 + partition!.count), with: partition!)
            pos += 2 + partition!.count
        }
        out[pos] = command
        out[pos + 1] = UInt8(payload.count + 1)
        out.replaceSubrange((pos + 2)..<(pos + 2 + payload.count), with: payload)
        var sum: UInt32 = 0
        for index in 2..<(size - 3) { sum &+= UInt32(out[index]) }
        out[size - 3] = UInt8(sum & 0xFF)
        out[size - 2] = 0x5B
        out[size - 1] = 0xB5
        return Data(out)
    }

    /// 网页端 UQ 透明帧（KVNWC）：
    /// 协议组固定 02；校验和不含命令字节 = Σ(帧[2..8] + 帧[10] + 载荷) 低 8 位；
    /// 分区控制时命令码置 01，载荷为 [通道号, 事件命令, 事件数据长度, 数据…]。
    static func uqFrame(command: UInt8, payload: [UInt8], serial: UInt16, channel: [UInt8]? = nil) -> Data {
        precondition(payload.count <= 250, "指令长度无效")
        let hasChannel = !(channel ?? []).isEmpty && channel?[0] != 0xFF
        var wireCommand = command
        var data = payload
        if hasChannel {
            data = [channel![0], command, UInt8(payload.count)] + payload
            wireCommand = 0x01
        }
        var out = [UInt8](repeating: 0, count: data.count + 14)
        out[0] = 0x5A; out[1] = 0xA5; out[2] = 0x01; out[3] = 0x03
        out[4] = UInt8((out.count - 4) & 0xFF); out[5] = UInt8(((out.count - 4) >> 8) & 0xFF)
        out[6] = 0x02
        out[7] = UInt8(serial & 0xFF); out[8] = UInt8((serial >> 8) & 0xFF)
        out[9] = wireCommand
        out[10] = UInt8(data.count + 1)
        out.replaceSubrange(11..<(11 + data.count), with: data)
        var sum: UInt32 = 0
        for index in 2...8 { sum &+= UInt32(out[index]) }
        sum &+= UInt32(out[10])
        for byte in data { sum &+= UInt32(byte) }
        out[out.count - 3] = UInt8(sum & 0xFF)
        out[out.count - 2] = 0x5B
        out[out.count - 1] = 0xB5
        return Data(out)
    }

    /// 紧凑协议帧：A1 | command | len | payload
    static func compactFrame(command: UInt8, payload: [UInt8]) -> Data {
        precondition(payload.count <= 255, "指令长度无效")
        return Data([0xA1, command, UInt8(payload.count)] + payload)
    }

    /// 通用命令映射：原命令 80/81/82/83/85/86
    /// 普通协议 → 02/03/04/09/08/05；紧凑协议 → 95/96/97/94/93
    static func genericCommand(_ original: UInt8, transport: LampTransport) -> UInt8? {
        if transport == .compact {
            switch original {
            case 0x80: return 0x95
            case 0x81: return 0x96
            case 0x82: return 0x97
            case 0x83: return 0x94
            case 0x85: return 0x93
            default: return nil
            }
        }
        switch original {
        case 0x80: return 0x02
        case 0x81: return 0x03
        case 0x82: return 0x04
        case 0x83: return 0x09
        case 0x85: return 0x08
        case 0x86: return 0x05
        default: return nil
        }
    }

    /// 通用命令语义（设置面板用）
    enum GenericCommand {
        static let rgbColor: UInt8 = 0x80
        static let brightness: UInt8 = 0x81
        static let modeSpeed: UInt8 = 0x82
        static let modeA: UInt8 = 0x83
        /// 灯效模式选择（映射后 0x08，载荷 1 字节模式号）
        static let mode: UInt8 = 0x85
    }

    /// 角度设置载荷：有符号角度 + 复位标志
    static func anglePayload(_ angle: Int8, reset: Bool) -> [UInt8] {
        [UInt8(bitPattern: angle), reset ? 1 : 0]
    }

    // MARK: 校验与 TLV 解析

    static func valid(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 14 else { return false }
        let n = frame.count
        guard frame[0] == 0x5A, frame[1] == 0xA5, frame[n - 2] == 0x5B, frame[n - 1] == 0xB5 else { return false }
        let length = UInt16(frame[4]) | (UInt16(frame[5]) << 8)
        guard Int(length) == n - 4 else { return false }
        var legacySum: UInt32 = 0
        var uqSum: UInt32 = 0
        for index in 2...8 {
            legacySum &+= UInt32(frame[index])
            uqSum &+= UInt32(frame[index])
        }
        for index in 9..<(n - 3) { legacySum &+= UInt32(frame[index]) }
        uqSum &+= UInt32(frame[10])
        for index in 11..<(n - 3) { uqSum &+= UInt32(frame[index]) }
        let checksum = UInt32(frame[n - 3])
        return (legacySum & 0xFF) == checksum || (uqSum & 0xFF) == checksum
    }

    /// 标准 5A A5 回包 TLV：从偏移 9 到校验字节前，[command, len(=n+1), data] 逐段解析
    static func fields(_ frame: [UInt8]) -> [LampField]? {
        guard valid(frame) else { return nil }
        var result: [LampField] = []
        var pos = 9
        let end = frame.count - 3
        while pos < end {
            guard pos + 2 <= end else { return nil }
            let length = Int(frame[pos + 1])
            guard length >= 1, pos + 1 + length <= end else { return nil }
            result.append(LampField(command: frame[pos], data: Array(frame[(pos + 2)..<(pos + 1 + length)])))
            pos += 1 + length
        }
        return result
    }
}

/// 通知分片 → 完整帧。兼容标准 5A A5 与紧凑 A1 两种包。
final class LampFrameDecoder {
    private var buffer: [UInt8] = []
    private let capacity = 16384

    func feed(_ chunk: Data) -> [LampFrame] {
        buffer.append(contentsOf: chunk)
        if buffer.count > capacity { buffer.removeAll(keepingCapacity: true) }

        var frames: [LampFrame] = []
        var pos = 0
        let bytes = buffer
        while pos < bytes.count {
            if bytes[pos] == 0xA1 {
                guard bytes.count - pos >= 3 else { break }
                let count = 3 + Int(bytes[pos + 2])
                guard bytes.count - pos >= count else { break }
                frames.append(LampFrame(
                    kind: .compact(command: bytes[pos + 1], data: Array(bytes[(pos + 3)..<(pos + count)])),
                    raw: Array(bytes[pos..<(pos + count)])
                ))
                pos += count
            } else if bytes[pos] == 0x5A {
                guard bytes.count - pos >= 2 else { break }
                guard bytes[pos + 1] == 0xA5 else { pos += 1; continue }
                guard bytes.count - pos >= 6 else { break }
                let count = 4 + Int(bytes[pos + 4]) + (Int(bytes[pos + 5]) << 8)
                guard count >= 14, count <= 4096 else { pos += 1; continue }
                guard bytes.count - pos >= count else { break }
                let raw = Array(bytes[pos..<(pos + count)])
                if LampProtocol.valid(raw) {
                    if let fields = LampProtocol.fields(raw) {
                        let serial = UInt16(raw[7]) | (UInt16(raw[8]) << 8)
                        frames.append(LampFrame(
                            kind: .standard(parent: raw[6], serial: serial, fields: fields),
                            raw: raw
                        ))
                    }
                    pos += count
                } else {
                    pos += 1
                }
            } else {
                pos += 1
            }
        }
        if pos > 0 { buffer.removeFirst(min(pos, buffer.count)) }
        return frames
    }
}

// MARK: - 灯效模式表
// 真值来源：调试工具 assets/mode-library-seed.json 的产品 154/400/430
// （极核 AE4/5 前位置灯二代，广播前缀 NWC3154/400/430，与 KVNWC 同源）。
// 模式名与通道绑定：同一编号在行车/转向/开机下是不同模式，不能混排。
// 固件把模式号钳制在 1...0x6A(106)，只收录该范围。

enum LampChannel: Int, CaseIterable, Identifiable {
    /// 行车灯效（0x01 通道值 0）
    case driving = 0
    /// 开机灯效
    case welcome = 1
    /// 转向灯效
    case turn = 2
    /// 急刹（无独立表，沿用行车）
    case brake = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .driving: return "行车"
        case .welcome: return "开机"
        case .turn: return "转向"
        case .brake: return "急刹"
        }
    }

    var modes: [Int: String] {
        switch self {
        case .welcome: return Self.welcomeModes
        case .turn: return Self.turnModes
        default: return Self.drivingModes
        }
    }

    /// 行车通道 70 项
    static let drivingModes: [Int: String] = [
        1: "彩虹渐变", 2: "粉色呼吸", 3: "黄色呼吸1", 4: "黄色呼吸2", 5: "黄色呼吸3",
        6: "青色呼吸", 7: "蓝色呼吸1", 8: "蓝色呼吸2", 9: "蓝色呼吸3",
        16: "紫色呼吸1", 17: "紫色呼吸2", 18: "紫色呼吸3", 19: "紫色呼吸4", 20: "彩虹呼吸",
        21: "粉色流水", 22: "黄色流水1", 23: "黄色流水2", 24: "黄色流水3", 25: "青色流水",
        32: "蓝色流水1", 33: "蓝色流水2", 34: "蓝色流水3", 35: "紫色流水1", 36: "紫色流水2",
        37: "紫色流水3", 38: "紫色流水4", 39: "彩虹流水", 40: "粉黄律动", 41: "黄蓝律动1",
        48: "黄蓝律动2", 49: "黄蓝律动3", 50: "青蓝律动", 51: "蓝紫律动1", 52: "蓝紫律动2",
        53: "蓝紫律动3", 54: "紫粉律动1", 55: "紫粉律动2", 56: "紫黄律动1", 57: "紫黄律动2",
        64: "彩虹律动", 65: "粉蓝追逐", 66: "黄蓝追逐1", 67: "黄蓝追逐2", 68: "黄紫追逐",
        69: "青紫追逐1", 70: "青紫追逐2", 71: "青紫追逐3", 72: "蓝黄追逐1", 73: "蓝黄追逐2",
        80: "紫黄追逐", 81: "紫青追逐1", 82: "紫青追逐2", 83: "彩虹追逐", 84: "粉色渐变",
        85: "黄色渐变1", 86: "黄色渐变2", 87: "黄色渐变3", 88: "青色渐变", 89: "蓝色渐变1",
        96: "蓝色渐变2", 97: "蓝色渐变3", 98: "紫色渐变1", 99: "紫色渐变2", 100: "紫色渐变3",
        101: "紫色渐变4", 102: "彩虹渐变2", 103: "粉色拖影", 104: "黄色拖影1", 105: "黄色拖影2",
        106: "黄色拖影3",
    ]

    /// 开机通道 5 项
    static let welcomeModes: [Int: String] = [
        1: "自适应1", 2: "流水1", 3: "流水2", 4: "自适应2", 5: "关灯",
    ]

    /// 转向通道 2 项
    static let turnModes: [Int: String] = [
        1: "规律爆闪", 2: "变速爆闪",
    ]
}

// MARK: - 产品专用参数状态机（LampState.java 对齐）

/// 灯具调试类型与参数快照：改动只覆盖目标字节，其余字节原样保留
final class LampState {
    enum Profile: String, CaseIterable, Identifiable {
        case angle = "ANGLE"
        case ae7 = "AE7"
        case m5 = "M5"
        case fx = "FX"
        case rgb = "RGB"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .angle: return "灯光角度"
            case .ae7: return "AE7"
            case .m5: return "M5"
            case .fx: return "FX"
            case .rgb: return "通用 RGB"
            }
        }
    }

    private(set) var profile: Profile = .angle
    /// 设备回包快照；nil = 尚未同步
    private(set) var snapshot: [UInt8]?
    private(set) var minAngle = -60
    private(set) var maxAngle = 60
    private(set) var step = 1

    var synced: Bool { snapshot != nil }

    func select(_ value: Profile) {
        profile = value
        snapshot = nil
        minAngle = -60
        maxAngle = 60
        step = 1
    }

    /// 专用参数命令：角度 1F，其余 20
    var command: UInt8 { profile == .angle ? 0x1F : 0x20 }

    /// 专用查询载荷：角度 [01]，其余 [02]
    var queryPayload: [UInt8] { [profile == .angle ? 1 : 2] }

    /// 回包校验并更新快照（保留未触及字节）
    func accept(command: UInt8, data: [UInt8]) -> Bool {
        guard profile != .rgb, command == self.command else { return false }
        if profile == .angle {
            guard data.count >= 10 else { return false }
            let nextMax = Int(data[1])
            let nextMin = Int(data[2])
            let nextStep = Int(data[3])
            guard nextMin <= nextMax,
                  nextStep != 0, nextStep <= nextMax - nextMin,
                  Int(data[0]) >= nextMin, Int(data[0]) <= nextMax else { return false }
            minAngle = nextMin
            maxAngle = nextMax
            step = nextStep
            snapshot = data
            return true
        }
        guard data.count == 12 else { return false }
        snapshot = data
        return true
    }

    /// 角度设置载荷（需已同步，且在设备允许范围内）
    func setAnglePayload(_ angle: Int, reset: Bool) throws -> [UInt8] {
        guard synced, profile == .angle else { throw LampError.notSupported("此产品不支持角度调节") }
        guard angle >= minAngle, angle <= maxAngle else { throw LampError.angleRange(minAngle, maxAngle) }
        return LampProtocol.anglePayload(Int8(clamping: angle), reset: reset)
    }

    /// 修改 12 字节配置快照（AE7/M5/FX），返回新快照
    func changePayload(kind: String, value: Int) throws -> [UInt8] {
        guard synced else { throw LampError.notSynced }
        switch profile {
        case .angle, .rgb: throw LampError.notSupported("请使用对应产品控件")
        default: break
        }
        var out = snapshot!
        switch kind {
        case "rgbOn":
            guard profile != .fx else { throw LampError.notSupported("此产品未适配 RGB") }
            guard value == 0 || value == 1 else { throw LampError.invalidValue("开关值无效") }
            out[0] = 1
            out[6] = UInt8(value)
        case "rgbBrightness":
            guard profile != .fx else { throw LampError.notSupported("此产品未适配 RGB") }
            guard (0...255).contains(value) else { throw LampError.invalidValue("亮度值无效") }
            out[10] = UInt8(value)
        case "highWhite":
            guard profile == .m5 else { throw LampError.notSupported("此产品未适配该远光通道") }
            guard value == 0 || value == 1 else { throw LampError.invalidValue("开关值无效") }
            out[4] = UInt8(value)
        case "highYellow":
            guard profile == .m5 else { throw LampError.notSupported("此产品未适配该远光通道") }
            guard value == 0 || value == 1 else { throw LampError.invalidValue("开关值无效") }
            out[5] = UInt8(value)
        case "daytime":
            guard profile == .fx else { throw LampError.notSupported("此产品未适配日行灯") }
            guard value == 0 || value == 1 else { throw LampError.invalidValue("开关值无效") }
            out[0] = 0
            out[1] = UInt8(value)
        case "temperature":
            guard profile == .m5 || profile == .fx else { throw LampError.notSupported("此产品未适配近光色温") }
            guard (0...100).contains(value) else { throw LampError.invalidValue("色温值无效") }
            out[2] = UInt8(value * 255 / 100)
            out[3] = UInt8((100 - value) * 255 / 100)
        default:
            throw LampError.notSupported("未适配的调试项")
        }
        return out
    }

    /// RGB 颜色写入 M5/AE7 快照字节 7-9
    func colorPayload(rgb: Int) throws -> [UInt8] {
        guard synced else { throw LampError.notSynced }
        guard profile == .m5 || profile == .ae7 else { throw LampError.notSupported("此产品未适配 RGB") }
        var out = snapshot!
        out[7] = UInt8((rgb >> 16) & 0xFF)
        out[8] = UInt8((rgb >> 8) & 0xFF)
        out[9] = UInt8(rgb & 0xFF)
        return out
    }
}

enum LampError: LocalizedError {
    case notSynced
    case notSupported(String)
    case invalidValue(String)
    case angleRange(Int, Int)

    var errorDescription: String? {
        switch self {
        case .notSynced: return "请先读取设备参数，成功后再调节"
        case .notSupported(let text): return text
        case .invalidValue(let text): return text
        case .angleRange(let min, let max): return "角度需在 \(min) ~ \(max) 范围内"
        }
    }
}
