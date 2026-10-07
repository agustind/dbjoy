import Foundation
import Security

/// Stores connection passwords in the login keychain.
enum Keychain {
    private static let service = "app.dbjoy.connection"

    /// The database password, or with `ssh: true` the SSH password / key passphrase.
    static func password(for id: UUID, ssh: Bool = false) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id, ssh: ssh),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String?, for id: UUID, ssh: Bool = false) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id, ssh: ssh),
        ]
        SecItemDelete(base as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var attributes = base
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrLabel as String] = ssh ? "DBJoy SSH tunnel" : "DBJoy connection"
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func account(_ id: UUID, ssh: Bool) -> String {
        ssh ? id.uuidString + "-ssh" : id.uuidString
    }
}
