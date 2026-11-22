import Foundation
import Security

/// 极核仪表 PXC 投屏协议的本机身份：RSA-2048 密钥对 + 设备 UUID。
/// 协议要求：公钥以 X.509 SubjectPublicKeyInfo（DER）回传，HUID 用
/// PKCS#1 v1.5 原始摘要填充签名（.rsaSignatureDigestPKCS1v15Raw）。
/// 密钥在本机 Keychain 里生成并长期保存，App 与投屏扩展共用同一身份。
enum ZeehoMirrorIdentity {

    struct Identity {
        let key: SecKey
        let phoneID: String
    }

    enum IdentityError: LocalizedError {
        case system(String, Int32)
        case corrupt
        case keyUnavailable

        var errorDescription: String? {
            switch self {
            case .system(let action, let code): return "本机身份\(action)失败（\(code)）"
            case .corrupt: return "本机身份存储损坏，请重置投屏身份"
            case .keyUnavailable: return "无法读取本机投屏密钥"
            }
        }
    }

    private static let service = "com.liruixin.jihedrive.mirror.identity.v1"
    private static let account = "identity"

    /// 读取（或首次生成）本机身份。并发调用时保证只有一个身份落地。
    static func load() throws -> Identity {
        let query = baseQuery() as CFDictionary
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query, &item)
        if status == errSecSuccess {
            guard let data = item as? Data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let id = object["phoneID"], UUID(uuidString: id) != nil,
                  let encoded = object["key"], let bytes = Data(base64Encoded: encoded) else {
                throw IdentityError.corrupt
            }
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateWithData(bytes as CFData,
                [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary,
                &error) else {
                throw error?.takeRetainedValue() ?? IdentityError.keyUnavailable
            }
            return Identity(key: key, phoneID: id)
        }
        guard status == errSecItemNotFound else { throw IdentityError.system("读取", status) }

        let fresh = try generate()
        var error: Unmanaged<CFError>?
        guard let bytes = SecKeyCopyExternalRepresentation(fresh.key, &error) else {
            throw error?.takeRetainedValue() ?? IdentityError.keyUnavailable
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "phoneID": fresh.phoneID,
            "key": (bytes as Data).base64EncodedString(),
        ])
        var add = baseQuery()
        add[kSecValueData as String] = payload
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(add as CFDictionary, nil)
        // 两个进程（App / 投屏扩展）同时首启会撞车：撞车方改为读对方保存的身份。
        if saved == errSecDuplicateItem { return try load() }
        guard saved == errSecSuccess else { throw IdentityError.system("保存", saved) }
        return fresh
    }

    /// 删除本机身份（调试用：下次启动重新生成）。
    static func reset() {
        SecItemDelete(baseQuery() as CFDictionary)    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }

    private static func generate() throws -> Identity {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ] as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? IdentityError.keyUnavailable
        }
        return Identity(key: key, phoneID: UUID().uuidString)
    }

    /// X.509 SubjectPublicKeyInfo（DER）编码的公钥——协议线上格式。
    static func publicKeyDER(_ identity: Identity) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(identity.key),
              let raw = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw error?.takeRetainedValue() ?? IdentityError.keyUnavailable
        }
        // SecKeyCopyExternalRepresentation 导出 PKCS#1，外面包一层 SPKI 头。
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d,
                              0x01, 0x01, 0x01, 0x05, 0x00])
        let bitString = der(0x03, Data([0]) + (raw as Data))
        return der(0x30, algorithm + bitString)
    }

    /// 对 HUID 做原始 PKCS#1 v1.5 签名（非 SHA 摘要签名）。
    static func signHUID(_ identity: Identity, _ huid: String) throws -> Data {
        let message = Data(huid.utf8)
        guard !message.isEmpty, message.count <= SecKeyGetBlockSize(identity.key) - 11 else {
            throw IdentityError.keyUnavailable
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(identity.key, .rsaSignatureDigestPKCS1v15Raw,
                                                    message as CFData, &error) else {
            throw error?.takeRetainedValue() ?? IdentityError.keyUnavailable
        }
        return signature as Data
    }

    /// 校验仪表回显的签名（防串台：回显必须等于我们自己签出的内容）。
    static func verifyEcho(_ identity: Identity, signature: Data, huid: String) -> Bool {
        guard let publicKey = SecKeyCopyPublicKey(identity.key) else { return false }
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(publicKey, .rsaSignatureDigestPKCS1v15Raw,
                                     Data(huid.utf8) as CFData, signature as CFData, &error)
    }

    private static func der(_ tag: UInt8, _ payload: Data) -> Data {
        var header = Data([tag])
        if payload.count < 128 {
            header.append(UInt8(payload.count))
        } else if payload.count < 256 {
            header.append(contentsOf: [0x81, UInt8(payload.count)])
        } else {
            header.append(contentsOf: [0x82, UInt8(payload.count >> 8), UInt8(payload.count & 255)])
        }
        return header + payload
    }
}
