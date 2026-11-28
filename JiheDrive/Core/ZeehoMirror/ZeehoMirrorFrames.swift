import Foundation

/// 极核仪表 PXC 投屏协议的帧编解码（对齐 CarWithin 参考实现）。
/// 控制通道（TCP 10922）：16 字节头 = u32 命令 + u32 长度 + u32 命令⊕长度 + u32 标识符。
/// 媒体通道（TCP 10921，视频通道 10920 同协议）：8 字节头 = u16 命令 + u16 长度 + u32 token。
/// 视频流：手机回 [u32 长度][H.264 Annex-B 访问单元]，仪表逐帧用 0x72 拉取。
enum ZeehoMirrorFrame {

    struct Control {
        let command: UInt32
        let identifier: UInt32
        let payload: Data
    }

    struct Auxiliary {
        let command: UInt16
        let token: UInt32
        let payload: Data
    }

    enum FrameError: LocalizedError {
        case truncated(String)
        case invalid(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .truncated(let what): return "仪表协议：\(what)不完整"
            case .invalid(let what): return "仪表协议：\(what)无效"
            case .tooLarge(let what): return "仪表协议：\(what)超长"
            }
        }
    }

    static let maxPayload = 65_536

    // MARK: - 控制帧

    static func encodeControl(command: UInt32, identifier: UInt32 = 0, payload: Data = Data()) throws -> Data {
        guard payload.count <= maxPayload - 16 else { throw FrameError.tooLarge("控制载荷") }
        let length = UInt32(16 + payload.count)
        var data = Data(capacity: Int(length))
        appendLE(&data, command)
        appendLE(&data, length)
        appendLE(&data, command ^ length)
        appendLE(&data, identifier)
        data.append(payload)
        return data
    }

    static func decodeControl(_ read: (Int) throws -> Data) throws -> Control {
        let head = try read(16)
        guard head.count == 16 else { throw FrameError.truncated("控制头") }
        let command = head.uint32LE(0)
        let length = Int(head.uint32LE(4))
        guard (16...maxPayload).contains(length) else { throw FrameError.invalid("控制帧长度 \(length)") }
        guard head.uint32LE(8) == command ^ UInt32(length) else { throw FrameError.invalid("控制帧校验") }
        let payload = length > 16 ? try read(length - 16) : Data()
        guard payload.count == length - 16 else { throw FrameError.truncated("控制载荷") }
        return Control(command: command, identifier: head.uint32LE(12), payload: payload)
    }

    // MARK: - 媒体帧

    static func encodeAuxiliary(command: UInt16, token: UInt32 = 0, payload: Data = Data()) throws -> Data {
        guard payload.count <= 8_192 else { throw FrameError.tooLarge("媒体载荷") }
        var data = Data(capacity: 8 + payload.count)
        appendLE(&data, command)
        appendLE(&data, UInt16(payload.count))
        appendLE(&data, token)
        data.append(payload)
        return data
    }

    static func decodeAuxiliary(_ read: (Int) throws -> Data) throws -> Auxiliary {
        let head = try read(8)
        guard head.count == 8 else { throw FrameError.truncated("媒体头") }
        let length = Int(head.uint16LE(2))
        guard length <= 8_192 else { throw FrameError.tooLarge("媒体载荷") }
        let payload = try read(length)
        guard payload.count == length else { throw FrameError.truncated("媒体载荷") }
        return Auxiliary(command: head.uint16LE(0), token: head.uint32LE(4), payload: payload)
    }

    // MARK: - 视频帧

    /// 每帧 = u32 长度 + H.264 访问单元（对齐参考实现 sendH264，无首帧前缀）。
    static func encodeVideo(_ accessUnit: Data) throws -> Data {
        guard accessUnit.count > 4, accessUnit.count <= 8 * 1_024 * 1_024 else {
            throw FrameError.invalid("H.264 帧长度")
        }
        var data = Data(capacity: 4 + accessUnit.count)
        appendLE(&data, UInt32(accessUnit.count))
        data.append(accessUnit)
        return data
    }

    // MARK: - JSON

    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        // 官方实现的部分 JSON 以 NUL 结尾，解码前剥掉。
        var payload = data
        while payload.last == 0 { payload.removeLast() }
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw FrameError.invalid("控制 JSON")
        }
        return object
    }

    // MARK: - 字节序助手

    static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

extension Data {
    func uint16LE(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32LE(_ offset: Int) -> UInt32 {
        UInt32(uint16LE(offset)) | UInt32(uint16LE(offset + 2)) << 16
    }
}
