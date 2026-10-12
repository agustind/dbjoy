import AppKit
import DBCore
import Foundation
import Observation
import UniformTypeIdentifiers

/// What a Compare Schemas window starts with: usually the connection, database and schema of the
/// window it was opened from, as the source.
struct CompareRequest: Codable, Hashable {
    var sourceID: UUID?
    var database: String?
    var schema: String?
}

/// One side of a comparison: a saved connection and one of its databases, with its own session.
@MainActor @Observable
final class CompareSide {
    enum State: Equatable {
        case empty
        case connecting
        case needsPassword(String?)
        case ready
        case failed(String)
    }

    private(set) var connectionID: UUID?
    private(set) var database = ""
    private(set) var databases: [String] = []
    private(set) var schemas: [String] = []
    private(set) var state: State = .empty
    @ObservationIgnored private var connection: (any DatabaseConnection)?
    @ObservationIgnored private var tunnel: SSHTunnel?
    @ObservationIgnored private var password: String?

    var config: ConnectionConfig? { connectionID.flatMap { ConnectionStore.shared.connection(id: $0) } }

    /// The open session, once `state` is `.ready`.
    var session: (any DatabaseConnection)? { state == .ready ? connection : nil }

    func select(_ id: UUID?, database: String? = nil) async {
        await close()
        connectionID = id
        databases = []
        schemas = []
        self.database = ""
        guard let config else {
            state = .empty
            return
        }
        password = ConnectionStore.shared.password(for: config)
        if !config.savePassword, password == nil {
            state = .needsPassword(nil)
            return
        }
        await connect(database: database)
    }

    func selectDatabase(_ name: String) async {
        guard name != database, config != nil else { return }
        await connection?.close()
        connection = nil
        await connect(database: name)
    }

    func submitPassword(_ value: String) async {
        password = value
        await connect(database: nil)
    }

    func close() async {
        await connection?.close()
        connection = nil
        tunnel?.close()
        tunnel = nil
    }

    private func connect(database: String?) async {
        guard let config else { return }
        state = .connecting
        do {
            if config.ssh.isEnabled, tunnel?.isRunning != true {
                tunnel?.close()
                tunnel = try await ConnectionOpener.openTunnel(for: config, secret: Keychain.password(for: config.id, ssh: true))
            }
            let wanted = database ?? (config.database.isEmpty ? nil : config.database)
            let connection = try await Drivers.driver(for: config.kind)
                .connect(ConnectionOpener.endpoint(for: config, tunnel: tunnel), password: password, database: wanted)
            // The user may have picked another connection meanwhile.
            guard config.id == connectionID else {
                await connection.close()
                return
            }
            self.connection = connection
            self.database = connection.databaseName
            databases = (try? await connection.listDatabases()) ?? [connection.databaseName]
            schemas = try await connection.listSchemas()
            state = .ready
        } catch {
            let message = (error as? DatabaseError)?.fullDescription ?? error.localizedDescription
            state = !message.hasPrefix("SSH ") && message.localizedCaseInsensitiveContains("password")
                ? .needsPassword(message) : .failed(message)
        }
    }
}

/// Compares a schema in two databases and builds the migration that makes the target match the source.
@MainActor @Observable
final class SchemaCompareModel {
    enum Phase: Equatable {
        case idle
        case comparing
        case compared
        case running
        case failed(String)
    }

    let source = CompareSide()
    let target = CompareSide()
    var schema = ""
    private(set) var phase: Phase = .idle
    private(set) var changes: [SchemaChange] = []
    /// Changes included in the migration.
    var included: Set<String> = []
    var selectedChangeID: String?
    /// Shown after a migration ran.
    private(set) var notice: String?
    var errorMessage: String?
    /// What the current results compare, e.g. "Andromeda (dev) · andromeda → Andromeda (prod) · andromeda".
    private(set) var comparedTitle = ""

    private let request: CompareRequest

    init(request: CompareRequest) {
        self.request = request
    }

    func start() async {
        guard source.connectionID == nil else { return }
        schema = request.schema ?? ""
        await source.select(request.sourceID, database: request.database)
        pickSchema()
    }

    func selectSource(_ id: UUID?) async {
        await source.select(id)
        pickSchema()
        reset()
    }

    func selectTarget(_ id: UUID?) async {
        await target.select(id)
        reset()
    }

    func selectDatabase(_ name: String, on side: CompareSide) async {
        await side.selectDatabase(name)
        if side === source { pickSchema() }
        reset()
    }

    func submitPassword(_ value: String, on side: CompareSide) async {
        await side.submitPassword(value)
        if side === source { pickSchema() }
    }

    /// Swaps source and target, keeping each side's database.
    func swap() async {
        let (sourceID, sourceDatabase) = (source.connectionID, source.database)
        let (targetID, targetDatabase) = (target.connectionID, target.database)
        await source.select(targetID, database: targetDatabase.isEmpty ? nil : targetDatabase)
        await target.select(sourceID, database: sourceDatabase.isEmpty ? nil : sourceDatabase)
        pickSchema()
        reset()
    }

    func close() async {
        await source.close()
        await target.close()
    }

    /// Keeps the schema if the source has it, else picks the connection's default.
    private func pickSchema() {
        guard !source.schemas.isEmpty, !source.schemas.contains(schema) else { return }
        schema = source.schemas.contains("public") ? "public" : source.schemas[0]
    }

    func reset() {
        changes = []
        included = []
        selectedChangeID = nil
        notice = nil
        if phase != .comparing, phase != .running { phase = .idle }
    }

    // MARK: Comparing

    var sameDatabase: Bool {
        source.connectionID != nil && source.connectionID == target.connectionID && source.database == target.database
    }

    var canCompare: Bool {
        source.session != nil && target.session != nil && !schema.isEmpty && !sameDatabase
            && phase != .comparing && phase != .running
    }

    func compare() async {
        guard canCompare, let from = source.session, let to = target.session,
              let sourceConfig = source.config, let targetConfig = target.config else { return }
        phase = .comparing
        notice = nil
        do {
            async let a = from.schemaSnapshot(schema: schema)
            async let b = to.schemaSnapshot(schema: schema)
            let (sourceSnapshot, targetSnapshot) = try await (a, b)
            let previous = changes.isEmpty ? nil : included
            changes = from.dialect.schemaChanges(from: sourceSnapshot, to: targetSnapshot)
            // Data-losing changes start unchecked; after a recompare, keep what the user chose.
            included = Set(changes.filter { change in
                guard !change.steps.isEmpty else { return false }
                if let previous, previous.contains(change.id) { return true }
                return previous == nil && !change.isDestructive
            }.map(\.id))
            if let selectedChangeID, !changes.contains(where: { $0.id == selectedChangeID }) { self.selectedChangeID = nil }
            comparedTitle = "\(sourceConfig.displayName) · \(source.database) → \(targetConfig.displayName) · \(target.database)"
            phase = .compared
        } catch {
            phase = .failed((error as? DatabaseError)?.fullDescription ?? error.localizedDescription)
        }
    }

    var selectedChange: SchemaChange? { changes.first { $0.id == selectedChangeID } }

    /// Changes that come with statements, i.e. that can be part of the migration.
    var actionableChanges: [SchemaChange] { changes.filter { !$0.steps.isEmpty } }

    var includedChanges: [SchemaChange] { changes.filter { included.contains($0.id) && !$0.steps.isEmpty } }

    var statements: [String] { SchemaChange.migration(includedChanges) }

    func setIncluded(_ value: Bool, for change: SchemaChange) {
        if value { included.insert(change.id) } else { included.remove(change.id) }
    }

    func includeAll(_ value: Bool) {
        included = value ? Set(actionableChanges.map(\.id)) : []
    }

    // MARK: The migration

    /// The migration as a script, with a header saying what it was generated from.
    var script: String {
        let header = [
            "-- Migration generated by DBJoy on \(Date.now.formatted(date: .abbreviated, time: .shortened))",
            "-- From: \(source.config?.displayName ?? "") · \(source.database)",
            "-- To:   \(target.config?.displayName ?? "") · \(target.database)",
            "-- Schema: \(schema)",
            "",
        ]
        return (header + ["BEGIN;", ""] + statements.map { $0 + "\n" } + ["COMMIT;", ""]).joined(separator: "\n")
    }

    var targetIsReadOnly: Bool { target.config?.readOnly ?? false }

    func copyScript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
    }

    func saveScript() {
        guard FilePanels.available() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "migrate-\(target.database)-\(schema)-\(stamp).sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn't save the script: \(error.localizedDescription)"
        }
    }

    /// Opens the script in a query tab of the target connection's window (opening the window if needed).
    func openInQueryTab(using openWindow: (UUID) -> Void) {
        guard let id = target.connectionID else { return }
        QueryHandoff.send(.init(connectionID: id, database: target.database, sql: script,
                                title: "Migrate \(schema)"))
        openWindow(id)
    }

    /// Runs the included changes on the target in one transaction, then compares again.
    func run() async {
        guard let connection = target.session, !statements.isEmpty else { return }
        let count = statements.count
        phase = .running
        do {
            try await connection.executeInTransaction(statements.map { TransactionStatement($0) })
        } catch {
            phase = .compared
            errorMessage = "The migration failed and was rolled back.\n\n"
                + ((error as? DatabaseError)?.fullDescription ?? error.localizedDescription)
            return
        }
        phase = .compared
        await compare()
        let left = actionableChanges.count
        notice = "Ran \(count) statement\(count == 1 ? "" : "s") on \(target.config?.displayName ?? "the target")."
            + (left == 0 ? " The schemas match." : " \(left) difference\(left == 1 ? "" : "s") left.")
    }
}

/// SQL handed to a connection's window from elsewhere (e.g. a migration to review in a query tab).
@MainActor
enum QueryHandoff {
    struct Item {
        var connectionID: UUID
        var database: String
        var sql: String
        var title: String
    }

    static let notification = Notification.Name("DBJoyQueryHandoff")
    private static var pending: [Item] = []

    static func send(_ item: Item) {
        pending.append(item)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// Removes and returns the items waiting for a connection.
    static func take(for connectionID: UUID) -> [Item] {
        let items = pending.filter { $0.connectionID == connectionID }
        pending.removeAll { $0.connectionID == connectionID }
        return items
    }

    static func putBack(_ items: [Item]) {
        pending.insert(contentsOf: items, at: 0)
    }
}
