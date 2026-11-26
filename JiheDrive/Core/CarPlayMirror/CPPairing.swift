import Foundation
import CryptoKit
import Security
// BigInt 以源码形式编入 target，无需 import 模块

// MARK: - SRP-6a 服务端（RFC 5054 3072-bit 组，HomeKit/CarPlay 配对风格）

final class CPSRPServer {
    static let modulus = BigUInt(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF",
        radix: 16)!
    static let generator = BigUInt(5)

    static func hash(_ values: Data...) -> Data {
        Data(SHA512.hash(data: values.reduce(Data(), +)))
    }

    /// 左侧补零到 384 字节（3072-bit 组的标准长度）。
    static func pad(_ value: BigUInt) -> Data {
        let data = value.serialize()
        return Data(repeating: 0, count: max(0, 384 - data.count)) + data
    }

    static func secureRandom(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw CPError.malformed("安全随机数生成失败")
        }
        return Data(bytes)
    }

    let salt: Data
    let publicKey: Data
    private let verifier: BigUInt
    private let exponent: BigUInt
    private var consumed = false

    /// CarPlay 配对的固定 setup code：用户名 "Pair-Setup:3939"。
    init(salt: Data? = nil, privateBytes: Data? = nil) throws {
        let salt = try salt ?? Self.secureRandom(16)
        let privateBytes = try privateBytes ?? Self.secureRandom(32)
        guard salt.count == 16, privateBytes.count == 32, BigUInt(privateBytes) != 0 else {
            throw CPError.malformed("SRP 熵")
        }
        self.salt = salt
        exponent = BigUInt(privateBytes)
        let x = BigUInt(Self.hash(salt, Self.hash(Data("Pair-Setup:3939".utf8))))
        verifier = Self.generator.power(x, modulus: Self.modulus)
        let k = BigUInt(Self.hash(Self.pad(Self.modulus), Self.pad(Self.generator)))
        publicKey = Self.pad((k * verifier + Self.generator.power(exponent, modulus: Self.modulus)) % Self.modulus)
    }

    /// 校验 iPhone 的 A 值与 M1 证明，返回会话密钥与 M2 证明。
    func verify(publicKey peer: Data, proof: Data) throws -> (key: SymmetricKey, proof: Data) {
        guard !consumed else { throw CPError.malformed("SRP 证明被重放") }
        consumed = true
        guard peer.count == 384, proof.count == 64 else { throw CPError.malformed("SRP 证明/密钥长度") }
        let a = BigUInt(peer)
        let n = Self.modulus
        guard a > 0, a < n else { throw CPError.malformed("SRP 公钥") }
        let u = BigUInt(Self.hash(peer, publicKey))
        guard u != 0 else { throw CPError.malformed("SRP 混淆参数") }
        let shared = ((a * verifier.power(u, modulus: n)) % n).power(exponent, modulus: n)
        let key = Self.hash(shared.serialize())
        let xor = Data(zip(Self.hash(n.serialize()), Self.hash(Self.generator.serialize())).map { $0 ^ $1 })
        let expected = Self.hash(xor, Self.hash(Data("Pair-Setup".utf8)), salt, peer, publicKey, key)
        var difference: UInt8 = 0
        for (a, b) in zip(expected, proof) { difference |= a ^ b }
        guard difference == 0 else { throw CPError.malformed("SRP 认证证明") }
        return (SymmetricKey(data: key), Self.hash(peer, proof, key))
    }
}

// MARK: - 配对持久化（控制端 ID → 长期公钥）

enum CPPairingStore {
    private static let service = "com.qianxu.jihedrive.cp.pairing.v1"
    private static let accessGroup = "com.qianxu.jihedrive"

    static func publicKey(for identifier: String) -> Curve25519.Signing.PublicKey? {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "ctl-" + identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    static func save(identifier: String, publicKey: Curve25519.Signing.PublicKey) throws {
        let data = publicKey.rawRepresentation
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "ctl-" + identifier,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                [kSecClass as String: kSecClassGenericPassword,
                 kSecAttrService as String: service,
                 kSecAttrAccount as String: "ctl-" + identifier] as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw CPError.rejected("保存配对失败 \(status)") }
    }

    /// 本机配对签名密钥（Ed25519/Curve25519 signing）。
    /// Keychain 自定义访问组不可用（免费证书 / 重签后团队前缀变化，-34018）时
    /// 必须退回默认组：拿不到这把钥匙 SessionState.setup 就是 nil，
    /// iPhone 一发 /pair-setup 就报「pair-setup 不可用」，CarPlay 永远配不上对。
    static func localSigningKey() throws -> Curve25519.Signing.PrivateKey {
        let account = "local-signing-key"
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        var status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess, status != errSecDuplicateItem {
            // 访问组不可用：清掉自定义组用默认组重试
            add.removeValue(forKey: kSecAttrAccessGroup as String)
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecDuplicateItem, SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let existing = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return existing
        }
        guard status == errSecSuccess else { throw CPError.rejected("保存配对签名密钥失败 \(status)") }
        return key
    }

    static func localIdentifier() -> String {
        // 配对身份用稳定的 UUID
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "cp.pairing.identifier") { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: "cp.pairing.identifier")
        return fresh
    }
}

// MARK: - Pair-Setup（SRP 三步握手，TLV8）

final class CPPairSetup {
    private let identifier: Data
    private let signingKey: Curve25519.Signing.PrivateKey
    private var srp: CPSRPServer?
    private var key: SymmetricKey?
    private var expectedState: UInt8 = 1
    private(set) var complete = false

    init(identifier: String, signingKey: Curve25519.Signing.PrivateKey) {
        self.identifier = Data(identifier.utf8)
        self.signingKey = signingKey
    }

    func handle(_ body: Data) throws -> Data {
        do {
            let fields = try CPTLV8.decode(body)
            guard let state = fields[6], state.count == 1, state.first == expectedState, !complete else {
                throw CPError.malformed("pair-setup 顺序")
            }
            switch expectedState {
            case 1:
                guard fields[0] == Data([0]), fields[19] == nil else {
                    throw CPError.malformed("不支持的 pair-setup 方法/标志")
                }
                let session = try CPSRPServer()
                srp = session
                expectedState = 3
                return CPTLV8.encode([(6, Data([2])), (3, session.publicKey), (2, session.salt)])
            case 3:
                guard let srp, let peer = fields[3], let proof = fields[4] else {
                    throw CPError.malformed("缺少 SRP 证明")
                }
                let result = try srp.verify(publicKey: peer, proof: proof)
                key = result.key
                self.srp = nil
                expectedState = 5
                return CPTLV8.encode([(6, Data([4])), (4, result.proof)])
            case 5:
                guard let key, let encrypted = fields[5], encrypted.count >= 16 else {
                    throw CPError.malformed("缺少加密的配对身份")
                }
                let encryption = CPPairVerify.derive(key, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
                let box = try ChaChaPoly.SealedBox(nonce: try CPPairVerify.nonce("PS-Msg05"),
                                                   ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
                let sub = try CPTLV8.decode(try ChaChaPoly.open(box, using: encryption))
                guard let id = sub[1], (1...256).contains(id.count),
                      let idString = String(data: id, encoding: .utf8),
                      let peer = sub[3], peer.count == 32,
                      let signature = sub[10], signature.count == 64 else {
                    throw CPError.malformed("配对身份字段")
                }
                let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: peer)
                let controllerKey = CPPairVerify.derive(key, salt: "Pair-Setup-Controller-Sign-Salt",
                                                        info: "Pair-Setup-Controller-Sign-Info")
                let signed = controllerKey.withUnsafeBytes { Data($0) } + id + peer
                guard publicKey.isValidSignature(signature, for: signed) else {
                    throw CPError.malformed("配对身份签名")
                }
                let accessoryKey = CPPairVerify.derive(key, salt: "Pair-Setup-Accessory-Sign-Salt",
                                                       info: "Pair-Setup-Accessory-Sign-Info")
                let local = signingKey.publicKey.rawRepresentation
                let localSignature = try signingKey.signature(
                    for: accessoryKey.withUnsafeBytes { Data($0) } + identifier + local)
                let response = CPTLV8.encode([(1, identifier), (3, local), (10, localSignature)])
                let sealed = try ChaChaPoly.seal(response, using: encryption,
                                                 nonce: try CPPairVerify.nonce("PS-Msg06"))
                try CPPairingStore.save(identifier: idString, publicKey: publicKey)
                complete = true
                self.key = nil
                expectedState = 0
                return CPTLV8.encode([(6, Data([6])), (5, sealed.ciphertext + sealed.tag)])
            default:
                throw CPError.malformed("pair-setup 状态")
            }
        } catch {
            srp = nil
            key = nil
            expectedState = 0
            throw error
        }
    }
}

// MARK: - Pair-Verify（每次会话的快速验证）+ 控制通道加密

final class CPPairVerify {
    struct Keys {
        let read: SymmetricKey
        let write: SymmetricKey
    }

    private let identifier: Data
    private let signingKey: Curve25519.Signing.PrivateKey
    private var localEphemeral: Data?
    private var peerEphemeral: Data?
    private var secret: SymmetricKey?
    private var encryptionKey: SymmetricKey?
    private(set) var keys: Keys?
    private(set) var controllerID: String?
    /// 会话级媒体密钥（SETUP 派生事件/视频流加密密钥用）。
    private(set) var mediaSecret: SymmetricKey?

    init(identifier: String, signingKey: Curve25519.Signing.PrivateKey) {
        self.identifier = Data(identifier.utf8)
        self.signingKey = signingKey
    }

    static func derive(_ secret: SymmetricKey, salt: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: secret, salt: Data(salt.utf8),
                               info: Data(info.utf8), outputByteCount: 32)
    }

    static func nonce(_ label: String) throws -> ChaChaPoly.Nonce {
        guard label.utf8.count == 8 else { throw CPError.malformed("配对 nonce") }
        return try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + Data(label.utf8))
    }

    func handle(_ body: Data) throws -> Data {
        do {
            let fields = try CPTLV8.decode(body)
            guard let state = fields[6], state.count == 1 else { throw CPError.malformed("pair-verify 状态") }
            switch state.first! {
            case 1:
                reset()
                guard let peerBytes = fields[3], peerBytes.count == 32 else { throw CPError.malformed("对端密钥") }
                let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerBytes)
                let ephemeral = Curve25519.KeyAgreement.PrivateKey()
                let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
                let secret = shared.withUnsafeBytes { SymmetricKey(data: $0) }
                let encryption = Self.derive(secret, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
                let local = ephemeral.publicKey.rawRepresentation
                let signature = try signingKey.signature(for: local + identifier + peerBytes)
                let sub = CPTLV8.encode([(1, identifier), (10, signature)])
                let box = try ChaChaPoly.seal(sub, using: encryption, nonce: try Self.nonce("PV-Msg02"))
                self.secret = secret
                encryptionKey = encryption
                localEphemeral = local
                peerEphemeral = peerBytes
                return CPTLV8.encode([(6, Data([2])), (3, local), (5, box.ciphertext + box.tag)])
            case 3:
                guard let encrypted = fields[5], encrypted.count >= 16,
                      let encryptionKey, let secret, let localEphemeral, let peerEphemeral, keys == nil else {
                    throw CPError.malformed("pair-verify 顺序")
                }
                let box = try ChaChaPoly.SealedBox(nonce: try Self.nonce("PV-Msg03"),
                                                   ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
                let sub = try CPTLV8.decode(try ChaChaPoly.open(box, using: encryptionKey))
                guard let idData = sub[1], let id = String(data: idData, encoding: .utf8),
                      let signature = sub[10],
                      let trustedKey = CPPairingStore.publicKey(for: id),
                      trustedKey.isValidSignature(signature, for: peerEphemeral + idData + localEphemeral) else {
                    throw CPError.rejected("未配对的控制端或签名无效")
                }
                keys = Keys(
                    read: Self.derive(secret, salt: "Control-Salt", info: "Control-Write-Encryption-Key"),
                    write: Self.derive(secret, salt: "Control-Salt", info: "Control-Read-Encryption-Key"))
                controllerID = id
                mediaSecret = secret
                self.secret = nil
                self.encryptionKey = nil
                return CPTLV8.encode([(6, Data([4]))])
            default:
                throw CPError.malformed("不支持的 pair-verify 状态")
            }
        } catch {
            reset()
            throw error
        }
    }

    private func reset() {
        keys = nil
        controllerID = nil
        mediaSecret = nil
        secret = nil
        encryptionKey = nil
        localEphemeral = nil
        peerEphemeral = nil
    }
}

/// 控制通道 ChaCha20-Poly1305 记录加密：16KB 分帧 + u16 长度头 + 16B tag，计数器 nonce。
final class CPControlCipher {
    private let readKey: SymmetricKey
    private let writeKey: SymmetricKey
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0
    private var buffer = Data()
    private var failed = false

    init(readKey: SymmetricKey, writeKey: SymmetricKey) {
        self.readKey = readKey
        self.writeKey = writeKey
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        for shift in stride(from: 0, through: 56, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: counter >> shift))
        }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    func encrypt(_ plaintext: Data) throws -> Data {
        guard !failed else { throw CPError.malformed("控制加密已关闭") }
        var result = Data()
        for offset in stride(from: 0, to: max(plaintext.count, 1), by: 16384) {
            guard writeCounter < UInt64.max else {
                failed = true
                throw CPError.limitExceeded("控制 nonce")
            }
            let chunk = Data(plaintext.dropFirst(offset).prefix(16384))
            let header = Data([UInt8(truncatingIfNeeded: chunk.count), UInt8(truncatingIfNeeded: chunk.count >> 8)])
            let box = try ChaChaPoly.seal(chunk, using: writeKey, nonce: Self.nonce(writeCounter),
                                          authenticating: header)
            result.append(header)
            result.append(box.ciphertext)
            result.append(box.tag)
            writeCounter += 1
        }
        return result
    }

    func receive(_ bytes: Data) throws -> Data {
        guard !failed else { throw CPError.malformed("控制加密已关闭") }
        do {
            guard buffer.count + bytes.count <= 4 * 1024 * 1024 else {
                throw CPError.limitExceeded("加密控制缓冲")
            }
            buffer.append(bytes)
            var plaintext = Data()
            while buffer.count >= 2 {
                let count = Int(buffer.byte(0)) | Int(buffer.byte(1)) << 8
                guard count <= 16384 else { throw CPError.limitExceeded("加密控制帧") }
                guard buffer.count >= count + 18 else { break }
                guard readCounter < UInt64.max else { throw CPError.limitExceeded("控制 nonce") }
                let box = try ChaChaPoly.SealedBox(
                    nonce: Self.nonce(readCounter),
                    ciphertext: buffer.dropFirst(2).prefix(count),
                    tag: buffer.dropFirst(count + 2).prefix(16))
                plaintext.append(try ChaChaPoly.open(box, using: readKey, authenticating: buffer.prefix(2)))
                readCounter += 1
                buffer = Data(buffer.dropFirst(count + 18))
            }
            return plaintext
        } catch {
            failed = true
            buffer = Data()
            throw error
        }
    }
}
