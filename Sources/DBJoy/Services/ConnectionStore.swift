import DBCore
import Foundation
import Observation

@MainActor @Observable
final class ConnectionStore {
    static let shared = ConnectionStore()

    private(set) var connections: [ConnectionConfig] = []
    /// Order of the starred bar once the user has dragged in it; starred connections not in it follow by name.
    private(set) var starredOrder: [UUID] = []
    private let fileName = "connections.json"
    private let starredOrderKey = "starredOrder"

    private init() {
        connections = AppFiles.load([ConnectionConfig].self, from: fileName) ?? []
        starredOrder = (UserDefaults.standard.stringArray(forKey: starredOrderKey) ?? []).compactMap(UUID.init)
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
        ChatLibrary.shared.deleteChats(for: id)
        persist()
    }

    var starredConnections: [ConnectionConfig] {
        let rank = Dictionary(starredOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return connections.filter(\.isStarred).sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (x?, y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
        }
    }

    /// Moves a starred connection to where `target` is in the starred bar.
    func moveStarred(_ id: UUID, to target: UUID) {
        var ids = starredConnections.map(\.id)
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target), from != to else { return }
        ids.insert(ids.remove(at: from), at: to)
        setStarredOrder(ids)
    }

    /// Moves a starred connection up (negative) or down (positive) in the starred bar.
    func moveStarred(_ id: UUID, by offset: Int) {
        let ids = starredConnections.map(\.id)
        guard let from = ids.firstIndex(of: id), ids.indices.contains(from + offset) else { return }
        moveStarred(id, to: ids[from + offset])
    }

    private func setStarredOrder(_ ids: [UUID]) {
        starredOrder = ids
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: starredOrderKey)
    }

    /// Saves SSH tunnel settings for a connection; `secret` (password or key passphrase) goes to the Keychain.
    func updateSSH(_ ssh: SSHTunnelConfig, secret: String?, for id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].ssh = ssh
        if let secret { Keychain.setPassword(secret.isEmpty ? nil : secret, for: id, ssh: true) }
        persist()
    }

    func setAllowsMCP(_ allowed: Bool, for id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].allowsMCP = allowed
        persist()
    }

    func toggleStar(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].isStarred.toggle()
        // Once the bar has an order, new stars go to the end and unstarred ones leave it.
        if !starredOrder.isEmpty { setStarredOrder(starredConnections.map(\.id)) }
        persist()
    }

    func duplicate(_ config: ConnectionConfig) {
        var copy = config
        copy.id = UUID()
        copy.isStarred = false
        copy.allowsMCP = false
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
