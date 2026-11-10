import DBCore
import Foundation
import Observation

/// Commits made from table tabs, per connection, with the SQL that reverts each one.
/// Stored next to the query history; the files hold row values, so they go when the connection does.
@MainActor @Observable
final class EditHistory {
    static let shared = EditHistory()
    private static let limit = 200

    @ObservationIgnored private var cache: [UUID: [EditRecord]] = [:]
    private var version = 0

    func records(for connectionID: UUID) -> [EditRecord] {
        _ = version
        if let cached = cache[connectionID] { return cached }
        let loaded = AppFiles.load([EditRecord].self, from: file(connectionID)) ?? []
        cache[connectionID] = loaded
        return loaded
    }

    func record(_ record: EditRecord, connectionID: UUID) {
        var records = records(for: connectionID)
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        store(records, connectionID)
    }

    func markReverted(_ id: UUID, connectionID: UUID) {
        var records = records(for: connectionID)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].revertedAt = Date()
        store(records, connectionID)
    }

    func clear(for connectionID: UUID) {
        cache[connectionID] = []
        version += 1
        try? FileManager.default.removeItem(at: AppFiles.url(file(connectionID)))
    }

    private func store(_ records: [EditRecord], _ connectionID: UUID) {
        cache[connectionID] = records
        version += 1
        AppFiles.save(records, to: file(connectionID))
    }

    private func file(_ id: UUID) -> String { "edits-\(id.uuidString).json" }
}
