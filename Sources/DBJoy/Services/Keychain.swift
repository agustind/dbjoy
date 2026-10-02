import Foundation
import Security

/// Stores connection passwords in the login keychain.
enum Keychain {
    private static let service = "app.dbjoy.connection"

    static func password(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String?, for id: UUID) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(base as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var attributes = base
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrLabel as String] = "DBJoy connection"
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
