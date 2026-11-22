import Foundation
import Security

final class KeychainStore {
    static let shared = KeychainStore()

    enum Key: String {
        case token = "zeeho_token"
        case userId = "zeeho_user_id"
        case selectedVin = "widget_selected_vin"
        case widgetSnap = "widget_snap_json"
        case widgetImage = "widget_vehicle_image"
    }

    private let service = "com.liruixin.jihedrive"
    private let accessGroup = "com.liruixin.jihedrive"

    func value(for key: Key) -> String? {
        if let data = data(for: key) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    func set(_ value: String?, for key: Key) {
        setData(value?.data(using: .utf8), for: key)
    }

    func data(for key: Key) -> Data? {
        if let data = read(key, group: accessGroup), !data.isEmpty { return data }
        return read(key, group: nil)
    }

    func setData(_ value: Data?, for key: Key) {
        write(value, key: key, group: nil)
        write(value, key: key, group: accessGroup)
    }

    private func read(_ key: Key, group: String?) -> Data? {
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
        return data
    }

    private func write(_ value: Data?, key: Key, group: String?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
