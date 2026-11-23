import Foundation

// MARK: - 协议错误

enum CPError: LocalizedError, CustomStringConvertible {
    case malformed(String)
    case limitExceeded(String)
    case timeout(String)
    case closed(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let what): return "CarPlay 协议错误：\(what)"
        case .limitExceeded(let what): return "CarPlay 数据超限：\(what)"
        case .timeout(let what): return "CarPlay 等待超时：\(what)"
        case .closed(let what): return "CarPlay 会话关闭：\(what)"
        case .rejected(let what): return "CarPlay 被拒绝：\(what)"
        }
    }
    var description: String { errorDescription ?? "CarPlay 错误" }
}

// MARK: - Data 小助手

extension Data {
    func byte(_ offset: Int) -> UInt8 { self[startIndex + offset] }
    func be16(_ offset: Int) -> UInt16 { UInt16(byte(offset)) << 8 | UInt16(byte(offset + 1)) }
    func be32(_ offset: Int) -> UInt32 { UInt32(be16(offset)) << 16 | UInt32(be16(offset + 2)) }
    mutating func putBE16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
    mutating func putBE32(_ value: UInt32) {
        putBE16(UInt16(truncatingIfNeeded: value >> 16))
        putBE16(UInt16(truncatingIfNeeded: value))
    }
}

// MARK: - TLV8（HomeKit 风格配对字段）

enum CPTLV8 {
    static func encode(_ fields: [(UInt8, Data)]) -> Data {
        var result = Data()
        for (type, value) in fields {
            if value.isEmpty {
                result.append(contentsOf: [type, 0])
                continue
            }
            for offset in stride(from: 0, to: value.count, by: 255) {
                let chunk = value.dropFirst(offset).prefix(255)
                result.append(contentsOf: [type, UInt8(chunk.count)])
                result.append(chunk)
            }
        }
        return result
    }

    static func decode(_ data: Data) throws -> [UInt8: Data] {
        guard data.count <= 65536 else { throw CPError.limitExceeded("配对 TLV") }
        var result: [UInt8: Data] = [:]
        var offset = 0
        var previousType: UInt8?
        var previousLength = 0
        while offset < data.count {
            guard offset + 2 <= data.count else { throw CPError.malformed("TLV 头") }
            let type = data.byte(offset)
            let length = Int(data.byte(offset + 1))
            offset += 2
            guard offset + length <= data.count else { throw CPError.malformed("TLV 长度") }
            if result[type] != nil, !(previousType == type && previousLength == 255) {
                throw CPError.malformed("TLV 重复字段")
            }
            result[type, default: Data()].append(data.dropFirst(offset).prefix(length))
            previousType = type
            previousLength = length
            offset += length
        }
        return result
    }
}

// MARK: - H.264 Annex-B

enum CPAnnexB {
    /// 把 AVCC（4 字节长度前缀）转成 Annex-B 起始码形式。
    static func lengthPrefixedToAnnexB(_ data: Data) throws -> Data {
        if data.starts(with: [0, 0, 0, 1]) {
            _ = try units(in: data)
            return data
        }
        var offset = 0
        var output = Data()
        while offset < data.count {
            guard offset + 4 <= data.count else { throw CPError.malformed("NAL 长度") }
            let length = Int(data.be32(offset))
            offset += 4
            guard length > 0, length <= data.count - offset else { throw CPError.malformed("NAL 内容") }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(data.dropFirst(offset).prefix(length))
            offset += length
        }
        return output
    }

    /// NAL 单元数组 → AVCC（4 字节长度前缀），供 AVSampleBufferDisplayLayer / VideoToolbox 使用。
    static func lengthPrefixed(_ units: [Data]) -> Data {
        var output = Data()
        for unit in units {
            output.putBE32(UInt32(unit.count))
            output.append(unit)
        }
        return output
    }

    /// 切分 Annex-B 流里的 NAL 单元（保留起始码前的去重逻辑由调用方处理）。
    static func units(in data: Data) throws -> [Data] {
        var units: [Data] = []
        var start: Int? = nil
        var index = 0
        let count = data.count
        var scannable = data
        while index + 3 <= count {
            if scannable[index] == 0, scannable[index + 1] == 0 {
                var pattern = 3
                if scannable[index + 2] == 1 { pattern = 3 }
                else if index + 3 < count, scannable[index + 2] == 0, scannable[index + 3] == 1 { pattern = 4 }
                else { index += 1; continue }
                if let s = start {
                    units.append(Data(data.dropFirst(s).prefix(index - s)))
                }
                start = index + pattern
                index += pattern
            } else {
                index += 1
            }
        }
        if let s = start, s < count {
            units.append(Data(data.dropFirst(s)))
        }
        guard !units.isEmpty else { throw CPError.malformed("Annex-B 无 NAL") }
        return units
    }

    /// 是否包含随机访问单元（H.264 IDR / H.265 IRAP）。
    static func containsRandomAccess(_ accessUnit: Data) -> Bool {
        guard let units = try? units(in: accessUnit) else { return false }
        return units.contains { unit in
            guard let first = unit.first else { return false }
            return first & 0x1f == 5
        }
    }
}

// MARK: - RTSP 请求解析 / 响应编码

struct CPRTSPRequest {
    let method: String
    let target: String
    let version: String
    let headers: [String: String]
    let body: Data
}

struct CPRTSPParser {
    private var buffer = Data()
    private let allowResponses: Bool
    static let maximumBody = 2 * 1024 * 1024

    init(allowResponses: Bool = false) { self.allowResponses = allowResponses }

    mutating func takeBufferedData() -> Data {
        let data = buffer
        buffer = Data()
        return data
    }

    mutating func append(_ data: Data, maximumRequests: Int = .max) throws -> [CPRTSPRequest] {
        guard buffer.count + data.count <= Self.maximumBody + 32768 else {
            throw CPError.limitExceeded("RTSP 缓冲")
        }
        buffer.append(data)
        var output: [CPRTSPRequest] = []
        while let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let headerSize = buffer.distance(from: buffer.startIndex, to: boundary.lowerBound)
            guard headerSize <= 16384 else { throw CPError.limitExceeded("RTSP 头") }
            guard let headerText = String(data: buffer.prefix(headerSize), encoding: .utf8) else {
                throw CPError.malformed("RTSP 头编码")
            }
            var lines = headerText.components(separatedBy: "\r\n")
            let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
            let isResponse = allowResponses && parts.count >= 3
                && ["RTSP/1.0", "HTTP/1.1"].contains(String(parts[0]))
            guard isResponse || (parts.count == 3 && ["RTSP/1.0", "HTTP/1.1"].contains(String(parts[2]))) else {
                throw CPError.malformed("RTSP 请求行")
            }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { throw CPError.malformed("RTSP 头字段") }
                let name = line[..<colon].lowercased()
                guard !name.isEmpty, headers[name] == nil else { continue }
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil else { throw CPError.malformed("chunked 传输不支持") }
            let lengthText = headers["content-length"] ?? "0"
            guard !lengthText.isEmpty, lengthText.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let length = Int(lengthText), length <= Self.maximumBody else {
                throw CPError.malformed("RTSP 内容长度")
            }
            let total = headerSize + 4 + length
            guard buffer.count >= total else { return output }
            output.append(CPRTSPRequest(
                method: String(parts[0]), target: String(parts[1]),
                version: String(parts[isResponse ? 0 : 2]),
                headers: headers, body: Data(buffer.dropFirst(headerSize + 4).prefix(length))))
            buffer = Data(buffer.dropFirst(total))
            if output.count >= maximumRequests { return output }
        }
        if buffer.count > 16384 { throw CPError.limitExceeded("未结束的 RTSP 头") }
        return output
    }
}

struct CPRTSPResponse {
    var status: Int
    var reason: String
    var body: Data
    var contentType: String

    init(status: Int = 200, reason: String = "OK", body: Data = Data(),
         contentType: String = "application/octet-stream") {
        self.status = status
        self.reason = reason
        self.body = body
        self.contentType = contentType
    }

    func encoded(for request: CPRTSPRequest) -> Data {
        var lines = ["\(request.version) \(status) \(reason)",
                     "Server: JiheDrive/1.0",
                     "Content-Length: \(body.count)",
                     "Content-Type: \(contentType)"]
        if let sequence = request.headers["cseq"] { lines.append("CSeq: \(sequence)") }
        if request.method == "OPTIONS" {
            lines.append("Public: OPTIONS, GET, POST, SETUP, RECORD, TEARDOWN")
        }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }
}
