import Foundation
import CryptoKit

/// CarPlay 视频流解帧：128 字节头 + 载荷的分帧协议，
/// 类型 0 = ChaChaPoly 加密帧（DataStream-Output-Encryption-Key），类型 1 = 编码配置记录。
/// 输出为 Annex-B 访问单元（含参数集单元）。
final class CPScreenStream {
    private let key: SymmetricKey
    private var buffer = Data()
    private var counter: UInt64 = 0
    private var failed = false
    private(set) var codec: CPVideoCodec = .h264

    init(secret: SymmetricKey, connectionID: UInt64) {
        key = CPPairVerify.derive(secret,
            salt: "DataStream-Salt\(connectionID)",
            info: "DataStream-Output-Encryption-Key")
    }

    func append(_ bytes: Data) throws -> [Data] {
        guard !failed else { throw CPError.closed("视频流") }
        do {
            guard buffer.count + bytes.count <= 8 * 1024 * 1024 + 128 + 65536 else {
                throw CPError.limitExceeded("视频缓冲")
            }
            buffer.append(bytes)
            var result: [Data] = []
            while buffer.count >= 128 {
                let length = Int(buffer.byte(0)) | Int(buffer.byte(1)) << 8
                    | Int(buffer.byte(2)) << 16 | Int(buffer.byte(3)) << 24
                guard length >= 0, length <= 8 * 1024 * 1024 else { throw CPError.limitExceeded("视频帧") }
                guard buffer.count >= 128 + length else { break }
                let header = Data(buffer.prefix(128))
                let body = Data(buffer.dropFirst(128).prefix(length))
                buffer = Data(buffer.dropFirst(128 + length))
                switch header.byte(4) {
                case 0:
                    guard body.count >= 16, counter < UInt64.max else { throw CPError.malformed("加密视频帧") }
                    var nonce = Data(count: 4)
                    for shift in stride(from: 0, through: 56, by: 8) {
                        nonce.append(UInt8(truncatingIfNeeded: counter >> shift))
                    }
                    let box = try ChaChaPoly.SealedBox(nonce: .init(data: nonce),
                                                       ciphertext: body.dropLast(16), tag: body.suffix(16))
                    let plain = try ChaChaPoly.open(box, using: key, authenticating: header)
                    counter += 1
                    result.append(try CPAnnexB.lengthPrefixedToAnnexB(plain))
                case 1:
                    let parsed = try CPCodecConfiguration.parse(body)
                    codec = parsed.0
                    result.append(parsed.1)
                default:
                    break // 时序/扩展记录，无画面数据
                }
            }
            return result
        } catch {
            failed = true
            buffer = Data()
            throw error
        }
    }
}

enum CPVideoCodec: String {
    case h264
    case h265

    var displayName: String { self == .h264 ? "H.264" : "H.265" }

    /// NAL 单元类型。
    func nalType(_ unit: Data) -> UInt8? {
        guard let first = unit.first else { return nil }
        return self == .h264 ? first & 0x1f : (first >> 1) & 0x3f
    }

    func isRandomAccess(_ unit: Data) -> Bool {
        guard let type = nalType(unit) else { return false }
        return self == .h264 ? type == 5 : (16...21).contains(type)
    }

    func parameterSet(_ unit: Data) -> CPParameterSet? {
        guard let type = nalType(unit) else { return nil }
        switch (self, type) {
        case (.h264, 7), (.h265, 33): return .sps
        case (.h264, 8), (.h265, 34): return .pps
        case (.h265, 32): return .vps
        default: return nil
        }
    }
}

enum CPParameterSet {
    case vps, sps, pps
}

/// avcC / hvcC 配置记录 → Annex-B 参数集（VPS/SPS/PPS）。
enum CPCodecConfiguration {
    static func parse(_ body: Data) throws -> (CPVideoCodec, Data) {
        if let marker = body.range(of: Data("hvcC".utf8)) {
            return (.h265, try hevc(Data(body[marker.upperBound...])))
        }
        if let marker = body.range(of: Data("avcC".utf8)) {
            return (.h264, try avc(Data(body[marker.upperBound...])))
        }
        // 裸 AVC 记录：8 字节头后紧跟 SPS（type 7）
        let looksAVC = body.count >= 9 && body.byte(5) & 0x1f >= 1 && body.byte(8) & 0x1f == 7
        return looksAVC ? (.h264, try avc(body)) : (.h265, try hevc(body))
    }

    private static func avc(_ data: Data) throws -> Data {
        guard data.count >= 7, data.byte(0) == 1, data.byte(4) & 3 == 3 else {
            throw CPError.malformed("不支持的 AVC 配置")
        }
        var offset = 6
        var output = Data()
        func readUnits(_ count: Int) throws {
            guard count > 0 else { throw CPError.malformed("缺少 H.264 参数集") }
            for _ in 0..<count {
                guard offset + 2 <= data.count else { throw CPError.malformed("AVC 参数长度") }
                let length = Int(data.be16(offset))
                offset += 2
                guard length > 0, length <= data.count - offset else { throw CPError.malformed("AVC 参数内容") }
                output.append(contentsOf: [0, 0, 0, 1])
                output.append(data.dropFirst(offset).prefix(length))
                offset += length
            }
        }
        try readUnits(Int(data.byte(5) & 31))
        guard offset < data.count else { throw CPError.malformed("缺少 AVC PPS 数量") }
        let count = Int(data.byte(offset))
        offset += 1
        try readUnits(count)
        return output
    }

    private static func hevc(_ data: Data) throws -> Data {
        guard data.count >= 23, data.byte(0) == 1, data.byte(21) & 3 == 3 else {
            throw CPError.malformed("不支持的 HEVC 配置")
        }
        var offset = 23
        var output = Data()
        var types = Set<UInt8>()
        for _ in 0..<Int(data.byte(22)) {
            guard offset + 3 <= data.count else { throw CPError.malformed("HEVC 参数数组") }
            let type = data.byte(offset) & 0x3f
            let count = Int(data.be16(offset + 1))
            offset += 3
            for _ in 0..<count {
                guard offset + 2 <= data.count else { throw CPError.malformed("HEVC 参数长度") }
                let length = Int(data.be16(offset))
                offset += 2
                guard length > 0, length <= data.count - offset else { throw CPError.malformed("HEVC 参数内容") }
                output.append(contentsOf: [0, 0, 0, 1])
                output.append(data.dropFirst(offset).prefix(length))
                offset += length
                types.insert(type)
            }
        }
        guard types.isSuperset(of: [32, 33, 34]) else { throw CPError.malformed("缺少 HEVC VPS/SPS/PPS") }
        return output
    }
}
