import Foundation
import Security

/// Stores connection passwords (and other DBJoy secrets) in the login keychain.
enum Keychain {
    private static let service = "app.dbjoy.connection"

    /// The database password, or with `ssh: true` the SSH password / key passphrase.
    static func password(for id: UUID, ssh: Bool = false) -> String? {
        read(service: service, account: account(id, ssh: ssh))
    }

    static func setPassword(_ password: String?, for id: UUID, ssh: Bool = false) {
        write(password, service: service, account: account(id, ssh: ssh),
              label: ssh ? "DBJoy SSH tunnel" : "DBJoy connection")
    }

    /// A generic password item as text.
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces a generic password item; nil or empty deletes it.
    static func write(_ value: String?, service: String, account: String, label: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = base
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrLabel as String] = label
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func account(_ id: UUID, ssh: Bool) -> String {
        ssh ? id.uuidString + "-ssh" : id.uuidString
    }
}
