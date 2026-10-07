import DBCore
import Foundation
import Observation

@MainActor @Observable
final class ConnectionStore {
    static let shared = ConnectionStore()

    private(set) var connections: [ConnectionConfig] = []
    private let fileName = "connections.json"

    private init() {
        connections = AppFiles.load([ConnectionConfig].self, from: fileName) ?? []
    }

    func connection(id: UUID) -> ConnectionConfig? {
        connections.first { $0.id == id }
    }

    /// Inserts or updates a connection. Pass `password` to update the stored password.
    func save(_ config: ConnectionConfig, password: String?) {
        if let index = connections.firstIndex(where: { $0.id == config.id }) {
            connections[index] = config
        } else {
            connections.append(config)
        }
        if config.savePassword {
            if let password { Keychain.setPassword(password, for: config.id) }
        } else {
            Keychain.setPassword(nil, for: config.id)
        }
        persist()
    }

    func delete(_ id: UUID) {
        connections.removeAll { $0.id == id }
        Keychain.setPassword(nil, for: id)
        Keychain.setPassword(nil, for: id, ssh: true)
        persist()
    }

    var starredConnections: [ConnectionConfig] {
        connections.filter(\.isStarred)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Saves SSH tunnel settings for a connection; `secret` (password or key passphrase) goes to the Keychain.
    func updateSSH(_ ssh: SSHTunnelConfig, secret: String?, for id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].ssh = ssh
        if let secret { Keychain.setPassword(secret.isEmpty ? nil : secret, for: id, ssh: true) }
        persist()
    }

    func toggleStar(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].isStarred.toggle()
        persist()
    }

    func duplicate(_ config: ConnectionConfig) {
        var copy = config
        copy.id = UUID()
        copy.isStarred = false
        copy.name = config.displayName + " copy"
        save(copy, password: config.savePassword ? Keychain.password(for: config.id) : nil)
    }

    func password(for config: ConnectionConfig) -> String? {
        config.savePassword ? Keychain.password(for: config.id) : nil
    }

    private func persist() {
        AppFiles.save(connections, to: fileName)
    }
}
