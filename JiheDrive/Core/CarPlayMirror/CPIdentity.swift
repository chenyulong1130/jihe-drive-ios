import Foundation
import CryptoKit
import Security

/// CarPlay 配件身份：苹果签发的配件证书链 + 对应 EC P-256 私钥（X9.63 编码 97 字节）。
/// 同机 CarPlay 的配件认证（iAP2 0xAA00-0xAA05 与 RTSP /auth-setup）都依赖这份身份。
///
/// 来源优先级：
/// 1. Keychain（首次导入后持久化）
/// 2. App 内置资源 Certificate.p7b / Leaf.cer / Private.x963
/// 3. 「文件」App → JiheDrive → IdentityImport/ 目录下的三件套（导入后删除私钥暂存）
struct CPAccessoryIdentity {

    let certificateChain: Data
    let leafCertificate: Data
    private let key: SecKey

    enum IdentityError: LocalizedError, CustomStringConvertible {
        case missing(String)
        case invalid(String)
        case security(String, Int32)

        var errorDescription: String? {
            switch self {
            case .missing(let what): return "缺少配件身份：\(what)"
            case .invalid(let what): return "配件身份无效：\(what)"
            case .security(let what, let code): return "\(what)失败（OSStatus \(code)）"
            }
        }
        var description: String { errorDescription ?? "身份错误" }
    }

    init(certificateChain: Data, leafCertificate: Data, privateKey: SecKey) throws {
        guard !certificateChain.isEmpty, certificateChain.count <= 65536 else {
            throw IdentityError.invalid("证书链长度")
        }
        guard let certificate = SecCertificateCreateWithData(nil, leafCertificate as CFData) else {
            throw IdentityError.invalid("叶子证书 DER")
        }
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            throw IdentityError.invalid("叶子证书公钥")
        }
        self.certificateChain = certificateChain
        self.leafCertificate = leafCertificate
        self.key = privateKey
        // 自检：证书公钥必须与私钥配对
        let challenge = Data(repeating: 0x5a, count: 32)
        do {
            let signature = try sign(challenge: challenge)
            var error: Unmanaged<CFError>?
            guard SecKeyVerifySignature(publicKey, .ecdsaSignatureRFC4754,
                                        challenge as CFData, signature as CFData, &error) else {
                throw IdentityError.invalid("证书与私钥不配对")
            }
        } catch let error as IdentityError { throw error }
        catch { throw IdentityError.invalid("签名自检失败") }
    }

    init(certificateChain: Data, leafCertificate: Data, privateKeyX963: Data) throws {
        guard privateKeyX963.count == 97, privateKeyX963.first == 0x04 else {
            throw IdentityError.invalid("X9.63 私钥编码（应为 97 字节 P-256）")
        }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(privateKeyX963 as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ] as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? IdentityError.invalid("私钥解码")
        }
        try self.init(certificateChain: certificateChain, leafCertificate: leafCertificate, privateKey: key)
    }

    /// MFi 认证签名：ECDSA RFC4754，对 32 字节挑战签名。
    func sign(challenge: Data) throws -> Data {
        guard challenge.count == 32 else { throw IdentityError.invalid("挑战长度") }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureRFC4754,
                                                    challenge as CFData, &error) else {
            throw error?.takeRetainedValue() ?? IdentityError.invalid("ECDSA 签名")
        }
        return signature as Data
    }

    // MARK: - 持久化

    private static let service = "com.qianxu.jihedrive.cp.identity.v1"
    private static let chainAccount = "certificate-chain"
    private static let leafAccount = "leaf-certificate"
    private static let keyAccount = "private-key-x963"
    private static let accessGroup = "com.qianxu.jihedrive"

    static func load() throws -> CPAccessoryIdentity {
        if let (chain, leaf, keyData) = readKeychain() {
            return try CPAccessoryIdentity(certificateChain: chain, leafCertificate: leaf, privateKeyX963: keyData)
        }
        if let (chain, leaf, keyData) = readBundle() {
            let identity = try CPAccessoryIdentity(certificateChain: chain, leafCertificate: leaf, privateKeyX963: keyData)
            persist(chain: chain, leaf: leaf, key: keyData)
            return identity
        }
        if let (chain, leaf, keyData) = try importFromDocuments() {
            let identity = try CPAccessoryIdentity(certificateChain: chain, leafCertificate: leaf, privateKeyX963: keyData)
            persist(chain: chain, leaf: leaf, key: keyData)
            return identity
        }
        throw IdentityError.missing("未找到身份。请把 certificate.p7b、leaf.cer、private.x963 放入「文件」App 的 JiheDrive/IdentityImport/ 目录，或联系构建者内置身份。")
    }

    static func deleteStoredIdentity() {
        for account in [chainAccount, leafAccount, keyAccount] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service,
                           kSecAttrAccount as String: account] as CFDictionary)
        }
    }

    static func hasIdentity() -> Bool {
        readKeychain() != nil || readBundle() != nil || hasStagedFiles()
    }

    /// 「文件」App 暂存目录里是否放了任意一个身份文件（可能不完整）。
    /// hasIdentity 要把它算进去：用户照报错提示把文件放进 IdentityImport/ 后
    /// 重进页面，预检必须走 load() 真正导入，而不是继续报「未找到」。
    static func hasStagedFiles() -> Bool {
        guard let directory = try? stagingDirectory(),
              FileManager.default.fileExists(atPath: directory.path) else { return false }
        let names = ["certificate.p7b", "leaf.cer", "private.x963"]
        return names.contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// 诊断摘要：构建号 + 三个身份来源的文件级状态，不触发导入。
    /// 用于预检失败时定位「包太旧没内置身份」还是「文件在但导入失败」。
    static func diagnosticSummary() -> String {
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        let bundled = [
            Bundle.main.url(forResource: "certificate", withExtension: "p7b"),
            Bundle.main.url(forResource: "leaf", withExtension: "cer"),
            Bundle.main.url(forResource: "private", withExtension: "x963"),
        ].filter { $0 != nil && (try? Data(contentsOf: $0!)) != nil }.count
        let keychain = readKeychain() != nil
        return "构建 \(build) · 内置身份 \(bundled)/3 · Keychain \(keychain ? "已有" : "空") · 暂存目录 \(hasStagedFiles() ? "有文件" : "空")"
    }

    private static func query(account: String, returnData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if returnData { query[kSecReturnData as String] = true }
        return query
    }

    private static func readKeychain() -> (Data, Data, Data)? {
        func read(_ account: String) -> Data? {
            var item: CFTypeRef?
            guard SecItemCopyMatching(query(account: account, returnData: true) as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, !data.isEmpty else { return nil }
            return data
        }
        guard let chain = read(chainAccount), let leaf = read(leafAccount), let key = read(keyAccount) else {
            return nil
        }
        return (chain, leaf, key)
    }

    private static func persist(chain: Data, leaf: Data, key: Data) {
        func write(_ account: String, _ value: Data) {
            var add = query(account: account, returnData: false)
            add[kSecValueData as String] = value
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrAccessGroup as String] = accessGroup
            var status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                SecItemUpdate(query(account: account, returnData: false) as CFDictionary,
                              [kSecValueData as String: value] as CFDictionary)
                status = errSecSuccess
            }
            if status != errSecSuccess {
                // 访问组不可用时退回默认组
                add.removeValue(forKey: kSecAttrAccessGroup as String)
                SecItemDelete(query(account: account, returnData: false) as CFDictionary)
                _ = SecItemAdd(add as CFDictionary, nil)
            }
        }
        write(chainAccount, chain)
        write(leafAccount, leaf)
        write(keyAccount, key)
    }

    private static func readBundle() -> (Data, Data, Data)? {
        guard let chainURL = Bundle.main.url(forResource: "certificate", withExtension: "p7b"),
              let leafURL = Bundle.main.url(forResource: "leaf", withExtension: "cer"),
              let keyURL = Bundle.main.url(forResource: "private", withExtension: "x963"),
              let chain = try? Data(contentsOf: chainURL),
              let leaf = try? Data(contentsOf: leafURL),
              let key = try? Data(contentsOf: keyURL) else { return nil }
        return (chain, leaf, key)
    }

    private static func stagingDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw IdentityError.missing("沙盒文档目录")
        }
        return documents.appendingPathComponent("IdentityImport", isDirectory: true)
    }

    /// 从 Documents/IdentityImport/ 读取三件套；成功后删除暂存文件（私钥不再以文件形式存在）。
    private static func importFromDocuments() throws -> (Data, Data, Data)? {
        let directory = try stagingDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let chainURL = directory.appendingPathComponent("certificate.p7b")
        let leafURL = directory.appendingPathComponent("leaf.cer")
        let keyURL = directory.appendingPathComponent("private.x963")
        let chain = try? Data(contentsOf: chainURL)
        let leaf = try? Data(contentsOf: leafURL)
        let key = try? Data(contentsOf: keyURL)
        guard let chain, let leaf, let key else {
            let hasAny = FileManager.default.fileExists(atPath: chainURL.path)
                || FileManager.default.fileExists(atPath: leafURL.path)
                || FileManager.default.fileExists(atPath: keyURL.path)
            if hasAny { throw IdentityError.invalid("IdentityImport 目录中的三件套不完整（需要 certificate.p7b / leaf.cer / private.x963）") }
            return nil
        }
        // 有效性由构造器自检；这里先删掉文件（无论成功与否都不留私钥副本）
        try? FileManager.default.removeItem(at: keyURL)
        try? FileManager.default.removeItem(at: chainURL)
        try? FileManager.default.removeItem(at: leafURL)
        try? FileManager.default.removeItem(at: directory)
        return (chain, leaf, key)
    }
}
