import Foundation
import Security

final class KeychainStore {
    static let shared = KeychainStore()

    enum Key: String {
        case token = "zeeho_token"
        case userId = "zeeho_user_id"
    }

    private let service = "com.liruixin.jihedrive"
    private let accessGroup = "com.liruixin.jihedrive"

    func value(for key: Key) -> String? {
        if let value = read(key, group: accessGroup) { return value }
        return read(key, group: nil)
    }

    func set(_ value: String?, for key: Key) {
        write(value, key: key, group: nil)
        write(value, key: key, group: accessGroup)
    }

    private func read(_ key: Key, group: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String?, key: Key, group: String?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
