import Foundation
import CryptoKit
import CommonCrypto

// MARK: - iAP2 链路帧

/// iAP2 链路包：FF 5A [长度BE16] [control] [sequence] [ack] [session] [校验和] [载荷+载荷校验和]。
/// 配件在线探测串：FF 55 02 00 EE 10。
enum CPIAP2 {

    static let presence = Data([0xff, 0x55, 0x02, 0x00, 0xee, 0x10])

    struct Packet: Equatable {
        let control: UInt8
        let sequence: UInt8
        let acknowledgement: UInt8
        let session: UInt8
        let payload: Data

        func encoded() throws -> Data {
            let count = 9 + (payload.isEmpty ? 0 : payload.count + 1)
            guard count <= 65535 else { throw CPError.limitExceeded("iAP2 包") }
            var result = Data([0xff, 0x5a])
            result.putBE16(UInt16(count))
            result.append(contentsOf: [control, sequence, acknowledgement, session])
            result.append(Self.checksum(result))
            if !payload.isEmpty {
                result.append(payload)
                result.append(Self.checksum(payload))
            }
            return result
        }
    }

    static func checksum(_ bytes: Data) -> UInt8 { 0 &- bytes.reduce(UInt8(0), &+) }

    enum Event: Equatable {
        case presence
        case packet(Packet)
    }

    /// 有界增量解析器。
    struct Parser {
        private var bytes = Data()
        mutating func append(_ data: Data) throws -> [Event] {
            guard bytes.count + data.count <= 131072 else { throw CPError.limitExceeded("iAP2 输入缓冲") }
            bytes.append(data)
            var result: [Event] = []
            while bytes.count >= 2 {
                if bytes.prefix(2) == presence.prefix(2) {
                    guard bytes.count >= 6 else { break }
                    guard bytes.prefix(6) == presence else { throw CPError.malformed("iAP2 在线探测串") }
                    bytes = Data(bytes.dropFirst(6))
                    result.append(.presence)
                    continue
                }
                guard bytes.prefix(2) == Data([0xff, 0x5a]) else { throw CPError.malformed("iAP2 同步字") }
                guard bytes.count >= 9 else { break }
                let length = Int(bytes.be16(2))
                guard length >= 9, length != 10 else { throw CPError.malformed("iAP2 长度") }
                guard Packet.checksum(Data(bytes.prefix(9))) == 0 else { throw CPError.malformed("iAP2 头校验和") }
                guard bytes.count >= length else { break }
                let payload = length > 9 ? Data(bytes.dropFirst(9).prefix(length - 10)) : Data()
                if length > 9, Packet.checksum(payload) != bytes.byte(length - 1) {
                    throw CPError.malformed("iAP2 载荷校验和")
                }
                result.append(.packet(Packet(control: bytes.byte(4), sequence: bytes.byte(5),
                                             acknowledgement: bytes.byte(6), session: bytes.byte(7),
                                             payload: payload)))
                bytes = Data(bytes.dropFirst(length))
            }
            return result
        }
    }

    // MARK: - iAP2 控制消息（0x40 40 [总长BE16] [消息ID BE16] 参数…）

    struct Parameter {
        let id: UInt16
        let value: Data
        func encoded() throws -> Data {
            guard value.count <= 65531 else { throw CPError.limitExceeded("iAP2 参数") }
            var data = Data()
            data.putBE16(UInt16(value.count + 4))
            data.putBE16(id)
            data.append(value)
            return data
        }
        static func parse(_ data: Data) throws -> [Parameter] {
            var rest = data
            var values: [Parameter] = []
            while !rest.isEmpty {
                guard rest.count >= 4 else { throw CPError.malformed("iAP2 参数头") }
                let count = Int(rest.be16(0))
                guard count >= 4, count <= rest.count else { throw CPError.malformed("iAP2 参数长度") }
                values.append(Parameter(id: rest.be16(2), value: Data(rest.dropFirst(4).prefix(count - 4))))
                rest = Data(rest.dropFirst(count))
            }
            return values
        }
    }

    struct Message {
        let id: UInt16
        let parameters: [Parameter]
        func encoded() throws -> Data {
            var body = Data()
            for parameter in parameters { body.append(try parameter.encoded()) }
            guard body.count <= 65529 else { throw CPError.limitExceeded("iAP2 消息") }
            var data = Data([0x40, 0x40])
            data.putBE16(UInt16(body.count + 6))
            data.putBE16(id)
            data.append(body)
            return data
        }
        static func parse(_ data: Data) throws -> Message {
            guard data.count >= 6, data.prefix(2) == Data([0x40, 0x40]), Int(data.be16(2)) == data.count else {
                throw CPError.malformed("iAP2 消息头")
            }
            return Message(id: data.be16(4), parameters: try Parameter.parse(Data(data.dropFirst(6))))
        }
    }

    // MARK: - 配件识别与 CarPlay 会话请求

    /// 0x1D01 配件识别：声明 USBHost / Bluetooth / WiFiCarPlay 三个传输通道组。
    static func identification(name: String, deviceID: String) throws -> Message {
        let mac = deviceID.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard mac.count == 6 else { throw CPError.malformed("配件 deviceID（应为 MAC 形式）") }
        func string(_ id: UInt16, _ value: String) -> Parameter {
            Parameter(id: id, value: Data(value.utf8) + Data([0]))
        }
        func group(_ id: UInt16, _ values: [Parameter]) throws -> Parameter {
            Parameter(id: id, value: try values.reduce(into: Data()) { $0.append(try $1.encoded()) })
        }
        var fields = [
            string(0, name), string(1, "CP-Receiver-1"), string(2, "JiheDrive"),
            string(3, "SN000001"), string(4, "1.0.0"), string(5, "1.0.0"),
            Parameter(id: 6, value: Data([0x43, 1])), Parameter(id: 7, value: Data([0x43, 0])),
            Parameter(id: 8, value: Data([0])), Parameter(id: 9, value: Data([0, 0])),
            string(12, "zh"), string(13, "zh"),
        ]
        fields.append(try group(16, [
            Parameter(id: 0, value: Data([0, 1])), string(1, "USBHost"),
            Parameter(id: 2, value: Data()), Parameter(id: 3, value: Data([1])), Parameter(id: 4, value: Data()),
        ]))
        fields.append(try group(17, [
            Parameter(id: 0, value: Data([0, 2])), string(1, "Bluetooth"),
            Parameter(id: 2, value: Data()), Parameter(id: 3, value: Data(mac)),
        ]))
        fields.append(try group(24, [
            Parameter(id: 0, value: Data([0, 3])), string(1, "WiFiCarPlay"),
            Parameter(id: 2, value: Data()), Parameter(id: 4, value: Data()),
        ]))
        return Message(id: 0x1d01, parameters: fields)
    }

    struct WiFiInfo {
        let ssid: String
        let password: String
        let channel: UInt8
    }

    /// 0x4301 CarPlay StartSession：告知 iPhone 到 address:port 建立 CarPlay 控制。
    static func carPlayStartSession(address: String, port: UInt16, deviceID: String, wifi: WiFiInfo?) throws -> Message {
        let portBytes = Data([0, 0, UInt8(truncatingIfNeeded: port >> 8), UInt8(truncatingIfNeeded: port)])
        func string(_ id: UInt16, _ value: String) -> Parameter {
            Parameter(id: id, value: Data(value.utf8) + Data([0]))
        }
        var fields = [try { () throws -> Parameter in
            let inner = string(0, address)
            return Parameter(id: 0, value: try inner.encoded())
        }()]
        if let wifi {
            let group1 = try [
                string(0, wifi.ssid), string(1, wifi.password),
                Parameter(id: 2, value: Data([wifi.channel])), string(3, address),
                Parameter(id: 4, value: Data([wifi.password.isEmpty ? 0 : 2])),
            ].reduce(into: Data()) { $0.append(try $1.encoded()) }
            fields.append(Parameter(id: 1, value: group1))
        }
        fields += [
            Parameter(id: 2, value: portBytes), string(3, deviceID), string(4, ""),
            string(5, "509.11"),
        ]
        return Message(id: 0x4301, parameters: fields)
    }
}

// MARK: - MFi 认证应答（RTSP /auth-setup 与 iAP2 认证共用底层）

enum CPMFiSAP {
    /// 33 字节挑战（版本 1 + 32 字节 X25519 公钥）→ 证书链 + AES-CTR 加密的签名。
    static func respond(to request: Data, identity: CPAccessoryIdentity) throws -> Data {
        guard request.count == 33, request.first == 1 else { throw CPError.malformed("MFi 挑战格式") }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.dropFirst())
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
        let secret = shared.withUnsafeBytes { Data($0) }
        guard secret.contains(where: { $0 != 0 }) else { throw CPError.malformed("MFi 零共享密钥") }
        let publicKey = ephemeral.publicKey.rawRepresentation
        let key = Data(Insecure.SHA1.hash(data: Data("AES-KEY".utf8) + secret).prefix(16))
        let iv = Data(Insecure.SHA1.hash(data: Data("AES-IV".utf8) + secret).prefix(16))
        let digest = Data(SHA256.hash(data: publicKey + peer.rawRepresentation))
        let signature = try identity.sign(challenge: digest)
        let encrypted = try aesCTR(key: key, iv: iv, data: signature)
        var response = publicKey
        response.putBE32(UInt32(identity.certificateChain.count))
        response.append(identity.certificateChain)
        response.putBE32(UInt32(encrypted.count))
        response.append(encrypted)
        return response
    }

    /// AES-128-CTR（MFi 会话密钥派生后对签名做流加密）。
    static func aesCTR(key: Data, iv: Data, data: Data) throws -> Data {
        guard key.count == 16, iv.count == 16 else { throw CPError.malformed("AES 参数") }
        guard !data.isEmpty else { return Data() }
        var cryptor: CCCryptorRef?
        let createStatus = data.withUnsafeBytes { _ in
            CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES,
                                    kCCModeOptionCTR_BE,
                                    (iv as NSData).bytes, (key as NSData).bytes, key.count,
                                    nil, 0, 0, &cryptor)
        }
        guard createStatus == kCCSuccess, let cryptor else {
            throw CPError.malformed("AES-CTR 初始化失败")
        }
        defer { CCCryptorRelease(cryptor) }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let updateStatus = data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                CCCryptorUpdate(cryptor, input.baseAddress, data.count,
                                output.baseAddress, output.count, &moved)
            }
        }
        guard updateStatus == kCCSuccess else { throw CPError.malformed("AES-CTR 更新失败") }
        out.removeSubrange(moved..<out.count)
        return out
    }
}
