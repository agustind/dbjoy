import Foundation
import Security

/// LLM service that powers the assistant.
enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case anthropic, openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openai: "gpt-5"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openai: "sk-…"
        }
    }

    var keysURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        }
    }
}

/// Assistant preferences. Choices live in UserDefaults; API keys live in the keychain.
enum AssistantSettings {
    static let providerKey = "assistant.provider"
    static let allowWritesKey = "assistant.allowWrites"
    static let confirmWritesKey = "assistant.confirmWrites"

    static func modelKey(_ provider: AIProvider) -> String { "assistant.model.\(provider.rawValue)" }

    static var provider: AIProvider {
        UserDefaults.standard.string(forKey: providerKey).flatMap(AIProvider.init) ?? .anthropic
    }

    static func model(for provider: AIProvider) -> String {
        let stored = UserDefaults.standard.string(forKey: modelKey(provider))?.trimmingCharacters(in: .whitespaces) ?? ""
        return stored.isEmpty ? provider.defaultModel : stored
    }

    /// Lets the assistant run INSERT/UPDATE/DELETE and DDL. Off by default.
    static var allowsWrites: Bool { UserDefaults.standard.bool(forKey: allowWritesKey) }

    /// Shows each change for approval before running it. On by default.
    static var confirmsWrites: Bool { UserDefaults.standard.object(forKey: confirmWritesKey) as? Bool ?? true }

    // MARK: API keys

    private static let service = "app.dbjoy.assistant"

    static func apiKey(for provider: AIProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func setAPIKey(_ key: String?, for provider: AIProvider) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var attributes = base
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrLabel as String] = "DBJoy \(provider.displayName) API key"
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
