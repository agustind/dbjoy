import DBCore
import Foundation
import Observation

struct SavedQuery: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var sql: String
    /// `nil` makes the query available to every connection.
    var connectionID: UUID?
    var updatedAt = Date()
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var sql: String
    var database: String
    var executedAt = Date()
    var duration: TimeInterval
    var rowCount: Int?
    var error: String?
}

/// Saved queries (global file) and per-connection query history.
@MainActor @Observable
final class QueryLibrary {
    static let shared = QueryLibrary()
    private static let historyLimit = 1000

    private(set) var savedQueries: [SavedQuery] = []
    /// Lazily loaded cache; not observed directly so reads during view updates don't mutate state.
    @ObservationIgnored private var histories: [UUID: [HistoryEntry]] = [:]
    private var historyVersion = 0

    private init() {
        savedQueries = AppFiles.load([SavedQuery].self, from: "saved-queries.json") ?? []
    }

    func savedQueries(for connectionID: UUID) -> [SavedQuery] {
        savedQueries.filter { $0.connectionID == nil || $0.connectionID == connectionID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ query: SavedQuery) {
        var query = query
        query.updatedAt = Date()
        if let index = savedQueries.firstIndex(where: { $0.id == query.id }) {
            savedQueries[index] = query
        } else {
            savedQueries.append(query)
        }
        AppFiles.save(savedQueries, to: "saved-queries.json")
    }

    func deleteSavedQuery(_ id: UUID) {
        savedQueries.removeAll { $0.id == id }
        AppFiles.save(savedQueries, to: "saved-queries.json")
    }

    func history(for connectionID: UUID) -> [HistoryEntry] {
        _ = historyVersion
        if let cached = histories[connectionID] { return cached }
        let loaded = AppFiles.load([HistoryEntry].self, from: historyFile(connectionID)) ?? []
        histories[connectionID] = loaded
        return loaded
    }

    func record(_ entry: HistoryEntry, connectionID: UUID) {
        var entries = history(for: connectionID)
        entries.insert(entry, at: 0)
        if entries.count > Self.historyLimit { entries.removeLast(entries.count - Self.historyLimit) }
        histories[connectionID] = entries
        historyVersion += 1
        AppFiles.save(entries, to: historyFile(connectionID))
    }

    func clearHistory(for connectionID: UUID) {
        histories[connectionID] = []
        historyVersion += 1
        AppFiles.save([HistoryEntry](), to: historyFile(connectionID))
    }

    private func historyFile(_ id: UUID) -> String { "history-\(id.uuidString).json" }
}
