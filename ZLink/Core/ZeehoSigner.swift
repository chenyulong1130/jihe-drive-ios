import CryptoKit
import Foundation

/// 极核接口签名：sign = md5(sha1(query + bodyJson + appParam + secret))
enum ZeehoSigner {
    static let appId = "S7qPWPU1"
    static let appSecret = "c5e0da7f4da28df805694ec3dd1fc6792e9df99d"

    struct Params {
        let sign: String
        let appParam: String
        let timestamp: String
        let nonce: String
    }

    static func sign(query: String = "", bodyJSON: String = "") -> Params {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = timestamp + randomAlphanumeric(16)
        let appParam = "appId=\(appId)&nonce=\(nonce)&timestamp=\(timestamp)"
        let raw = query + bodyJSON + appParam + appSecret
        return Params(
            sign: digest(raw),
            appParam: appParam,
            timestamp: timestamp,
            nonce: nonce
        )
    }

    static func digest(_ raw: String) -> String {
        let sha = Insecure.SHA1.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return Insecure.MD5.hash(data: Data(sha.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func randomAlphanumeric(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count, using: &rng)] })
    }

    static func uuid() -> String {
        UUID().uuidString.lowercased()
    }

    static func appInfoHeader() -> String {
        "MOBILE|unknown|0|ZEEHO_APP|2.6.15|unknown|unknown|0*0|\(uuid())|unknown|unknown"
    }
}
