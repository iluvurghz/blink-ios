import Foundation
import Security
import BlinkCore

/// Сессия входа в Keychain: переживает перезапуск и не попадает в обычные резервные копии.
final class KeychainSessionStore: SessionStore, @unchecked Sendable {
    private let service = "app.blink.player"
    private let account = "session"

    private func base() -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> String? {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String?) {
        SecItemDelete(base() as CFDictionary)
        guard let value = value, let data = value.data(using: .utf8) else { return }
        var item = base()
        item[kSecValueData as String] = data
        // Доступна после первой разблокировки, но не переезжает на другой телефон.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Маленькие настройки (дата Blink+ и подобное) в UserDefaults.
final class DefaultsKeyValue: KeyValue, @unchecked Sendable {
    private let defaults: UserDefaults

    init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func get(_ key: String) -> String? {
        return defaults.string(forKey: key)
    }

    func put(_ key: String, _ value: String?) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
