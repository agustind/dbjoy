import AppKit
import DBCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum WorkspaceTab: Identifiable {
    case table(TableTabModel)
    case query(QueryTabModel)
    case diagram(DiagramModel)

    nonisolated var id: UUID {
        switch self {
        case .table(let model): model.id
        case .query(let model): model.id
        case .diagram(let model): model.id
        }
    }

    var title: String {
        switch self {
        case .table(let model): model.ref.name
        case .query(let model): model.title
        case .diagram(let model): "Diagram: \(model.schema)"
        }
    }

    var systemImage: String {
        switch self {
        case .table(let model): model.ref.kind.systemImage
        case .query: "terminal"
        case .diagram: "point.3.connected.trianglepath.dotted"
        }
    }

    var hasUnsavedChanges: Bool {
        switch self {
        case .table(let model): model.hasChanges || (model.structureEditor?.hasChanges ?? false)
        case .query(let model): model.transactionStatus.isInTransaction
        case .diagram: false
        }
    }
}

struct ConfirmationRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var actionTitle: String
    var isDestructive: Bool
    var action: @MainActor () async -> Void
}

/// A batch of statements shown for review before running.
struct SQLPreviewRequest: Identifiable {
    let id = UUID()
    var title: String
    var statements: [String]
    var actionTitle: String
    var action: @MainActor () async -> Void
}

/// State for one connection window: the live session, schema browser and open tabs.
@MainActor @Observable
final class WorkspaceModel {
    enum Phase: Equatable {
        case connecting
        case needsPassword(String?)
        case connected
        case failed(String)
    }

    let config: ConnectionConfig
    private var password: String?
    var phase: Phase = .connecting
    private(set) var connection: (any DatabaseConnection)?

    var databases: [String] = []
    private(set) var currentDatabase = ""
    var schemas: [String] = []
    private(set) var currentSchema = ""
    var objects: [SchemaObject] = []
    var isLoadingObjects = false
    var catalogColumns: [String: [ColumnInfo]] = [:]
    var allObjects: [SchemaObject] = []

    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?

    var errorMessage: String?
    var confirmation: ConfirmationRequest?
    var sqlPreview: SQLPreviewRequest?
    var createTable: CreateTableModel?
    var export: ExportModel?
    var isQuickOpenPresented = false

    init(config: ConnectionConfig) {
        self.config = config
        self.password = ConnectionStore.shared.password(for: config)
    }

    var dialect: (any SQLDialect)? { connection?.dialect }

    var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var windowTitle: String {
        currentDatabase.isEmpty ? config.displayName : "\(config.displayName) — \(currentDatabase)"
    }

    // MARK: Connection lifecycle

    func start() async {
        guard connection == nil else { return }
        if !config.savePassword, password == nil {
            phase = .needsPassword(nil)
            return
        }
        await connect(database: nil)
    }

    func submitPassword(_ value: String) async {
        password = value
        await connect(database: nil)
    }

    private func connect(database: String?) async {
        phase = .connecting
        do {
            let connection = try await Drivers.driver(for: config.kind).connect(config, password: password, database: database)
            self.connection = connection
            currentDatabase = connection.databaseName
            databases = (try? await connection.listDatabases()) ?? [currentDatabase]
            schemas = try await connection.listSchemas()
            let preferred = try await connection.defaultSchema()
            currentSchema = schemas.contains(preferred) ? preferred : (schemas.first ?? preferred)
            phase = .connected
            await reloadObjects()
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("password") {
                phase = .needsPassword(message)
            } else {
                phase = .failed(message)
            }
        }
    }

    func retry() async {
        await connect(database: currentDatabase.isEmpty ? nil : currentDatabase)
    }

    func disconnect() async {
        for tab in tabs {
            if case .query(let query) = tab { await query.closeConnection() }
        }
        await connection?.close()
        connection = nil
    }

    func switchDatabase(_ name: String) {
        guard name != currentDatabase else { return }
        let perform: @MainActor () async -> Void = { [self] in
            for tab in tabs {
                if case .query(let query) = tab { await query.closeConnection() }
            }
            tabs = []
            selectedTabID = nil
            await connection?.close()
            connection = nil
            objects = []
            await connect(database: name)
        }
        if tabs.contains(where: \.hasUnsavedChanges) {
            confirm("Switch database?", message: "Open tabs have unsaved changes or open transactions that will be discarded.",
                    actionTitle: "Switch", destructive: true, action: perform)
        } else {
            Task { await perform() }
        }
    }

    /// Runs `action` (which replaces this window's connection) after confirming that unsaved
    /// changes and open transactions may be discarded.
    func confirmLeaving(to name: String, action: @escaping @MainActor () -> Void) {
        guard tabs.contains(where: \.hasUnsavedChanges) else {
            action()
            return
        }
        confirm("Switch to \(name)?",
                message: "Open tabs have unsaved changes or open transactions that will be discarded.",
                actionTitle: "Switch", destructive: true) { action() }
    }

    func switchSchema(_ name: String) {
        guard name != currentSchema else { return }
        currentSchema = name
        Task { await reloadObjects() }
    }

    func reloadObjects() async {
        guard let connection else { return }
        isLoadingObjects = true
        defer { isLoadingObjects = false }
        do {
            objects = try await connection.listObjects(schema: currentSchema)
            catalogColumns = try await connection.columnsByTable(schema: currentSchema)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshAll() async {
        guard let connection else { return }
        databases = (try? await connection.listDatabases()) ?? databases
        schemas = (try? await connection.listSchemas()) ?? schemas
        allObjects = []
        await reloadObjects()
    }

    /// Objects in every schema, for quick open.
    func loadAllObjects() async {
        guard let connection, allObjects.isEmpty else { return }
        var result: [SchemaObject] = []
        for schema in schemas {
            result += (try? await connection.listObjects(schema: schema)) ?? []
        }
        allObjects = result
    }

    /// Opens a dedicated connection to the current database (used by query tabs).
    func openSession() async throws -> any DatabaseConnection {
        try await Drivers.driver(for: config.kind).connect(config, password: password, database: currentDatabase)
    }

    /// libpq environment for command-line tools such as pg_dump.
    func dumpEnvironment() -> [String: String] {
        var environment = ["PGSSLMODE": config.sslMode.rawValue, "PGCONNECT_TIMEOUT": "10", "PGAPPNAME": "DBJoy"]
        if let password, !password.isEmpty { environment["PGPASSWORD"] = password }
        return environment
    }

    func startExport(_ refs: [ObjectRef]? = nil) {
        export = ExportModel(workspace: self, preselect: refs)
    }

    var completionCatalog: CompletionCatalog {
        CompletionCatalog(
            tables: objects.filter { $0.kind.hasRows }.map(\.name),
            columns: catalogColumns.mapValues { $0.map(\.name) },
            schemas: schemas,
            keywords: dialect?.keywords ?? SQLKeywords.list,
            functions: (dialect?.functions ?? []) + objects.filter { $0.kind.isRoutine }.map(\.name))
    }

    // MARK: Tabs

    func open(_ ref: ObjectRef, mode: TableMode = .data) {
        if ref.kind.isRoutine {
            openDefinition(of: ref)
            return
        }
        for tab in tabs {
            if case .table(let model) = tab, model.ref == ref {
                if model.mode != mode, mode != .data { model.mode = mode }
                selectedTabID = model.id
                return
            }
        }
        let model = TableTabModel(ref: ref, workspace: self, mode: mode)
        tabs.append(.table(model))
        selectedTabID = model.id
    }

    func openDefinition(of ref: ObjectRef) {
        guard let connection else { return }
        Task {
            do {
                let sql = try await connection.definition(of: ref)
                newQuery(sql: sql, title: ref.name)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func newQuery(sql: String = "", title: String? = nil, savedQuery: SavedQuery? = nil) {
        let count = tabs.filter { if case .query = $0 { true } else { false } }.count
        let model = QueryTabModel(workspace: self, title: title ?? savedQuery?.name ?? "Query \(count + 1)",
                                  sql: savedQuery?.sql ?? sql, savedQueryID: savedQuery?.id)
        tabs.append(.query(model))
        selectedTabID = model.id
    }

    // MARK: SQL files

    private static let runAfterOpeningKey = "runSQLFilesAfterOpening"

    /// Asks for one or more .sql files and opens each in a query tab. `run` forces running
    /// (Run SQL File…); otherwise the dialog's "Run immediately" checkbox decides.
    func openSQLFiles(run: Bool? = nil) {
        let panel = NSOpenPanel()
        panel.title = run == true ? "Run SQL File" : "Open SQL File"
        panel.prompt = run == true ? "Run" : "Open"
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        var checkbox: NSButton?
        if run == nil {
            let box = NSButton(checkboxWithTitle: "Run immediately", target: nil, action: nil)
            box.state = UserDefaults.standard.bool(forKey: Self.runAfterOpeningKey) ? .on : .off
            panel.accessoryView = box
            panel.isAccessoryViewDisclosed = true
            checkbox = box
        }
        guard panel.runModal() == .OK else { return }
        let shouldRun = run ?? (checkbox?.state == .on)
        if run == nil { UserDefaults.standard.set(shouldRun, forKey: Self.runAfterOpeningKey) }
        for url in panel.urls { openSQLFile(url, run: shouldRun) }
    }

    /// Loads a SQL file into the current empty query tab or a new one, optionally running it.
    func openSQLFile(_ url: URL, run: Bool) {
        let tab: QueryTabModel
        if case .query(let current) = selectedTab, current.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !current.isRunning {
            tab = current
        } else {
            newQuery()
            guard case .query(let created) = selectedTab else { return }
            tab = created
        }
        do {
            try tab.load(contentsOf: url)
        } catch {
            errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        if run { tab.run(.all) }
    }

    func openDiagram() {
        for tab in tabs {
            if case .diagram(let model) = tab, model.schema == currentSchema {
                selectedTabID = model.id
                return
            }
        }
        let model = DiagramModel(workspace: self, schema: currentSchema)
        tabs.append(.diagram(model))
        selectedTabID = model.id
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        let perform: @MainActor () async -> Void = { [self] in
            if case .query(let query) = tab { await query.closeConnection() }
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
            tabs.remove(at: index)
            if selectedTabID == id {
                selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            }
        }
        if tab.hasUnsavedChanges {
            let message = if case .query = tab {
                "This tab has an open transaction. Closing it will roll the transaction back."
            } else {
                "This tab has unsaved changes that will be discarded."
            }
            confirm("Close \(tab.title)?", message: message, actionTitle: "Close", destructive: true, action: perform)
        } else {
            Task { await perform() }
        }
    }

    func closeSelectedTab() -> Bool {
        guard let selectedTabID else { return false }
        closeTab(selectedTabID)
        return true
    }

    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectedTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    // MARK: Object actions

    func truncate(_ ref: ObjectRef) {
        guard let dialect else { return }
        let sql = dialect.truncateStatement(for: ref, cascade: false)
        confirm("Truncate \(ref.name)?", message: "This deletes every row in \(ref).\n\n\(sql)",
                actionTitle: "Truncate", destructive: true) { [self] in
            await runStatements([sql])
            refreshTabs(for: ref)
        }
    }

    func drop(_ ref: ObjectRef) {
        guard let dialect else { return }
        let sql = dialect.dropStatement(for: ref, cascade: false)
        confirm("Drop \(ref.kind.displayName.lowercased()) \(ref.name)?", message: "This cannot be undone.\n\n\(sql)",
                actionTitle: "Drop", destructive: true) { [self] in
            guard await runStatements([sql]) else { return }
            for tab in tabs {
                if case .table(let model) = tab, model.ref == ref {
                    tabs.removeAll { $0.id == model.id }
                }
            }
            if selectedTab == nil { selectedTabID = tabs.last?.id }
            await reloadObjects()
        }
    }

    func refreshMaterializedView(_ ref: ObjectRef) {
        guard let dialect else { return }
        Task {
            await runStatements(["REFRESH MATERIALIZED VIEW \(dialect.qualifiedName(ref));"])
            refreshTabs(for: ref)
        }
    }

    /// Runs statements in a transaction on the browsing connection. Returns success.
    @discardableResult
    func runStatements(_ statements: [String], expectedRows: Int? = nil) async -> Bool {
        guard let connection else { return false }
        do {
            try await connection.executeInTransaction(statements.map { TransactionStatement($0, expectedRows: expectedRows) })
            return true
        } catch {
            errorMessage = (error as? DatabaseError)?.fullDescription ?? error.localizedDescription
            return false
        }
    }

    private func refreshTabs(for ref: ObjectRef) {
        for tab in tabs {
            if case .table(let model) = tab, model.ref == ref { Task { await model.reloadData() } }
        }
    }

    // MARK: Safety

    func confirm(_ title: String, message: String, actionTitle: String, destructive: Bool,
                 action: @escaping @MainActor () async -> Void) {
        confirmation = ConfirmationRequest(title: title, message: message, actionTitle: actionTitle,
                                           isDestructive: destructive, action: action)
    }

    /// Runs `action` directly, or after confirmation when the connection is marked as production.
    func guardWrite(_ sql: String, action: @escaping @MainActor () async -> Void) {
        guard config.environment.requiresWriteConfirmation, dialect?.isWriteStatement(sql) ?? true else {
            Task { await action() }
            return
        }
        let preview = sql.count > 600 ? String(sql.prefix(600)) + "…" : sql
        confirm("Run on \(config.environment.displayName.uppercased())?",
                message: "This query modifies data on \(config.displayName) (\(currentDatabase)).\n\n\(preview)",
                actionTitle: "Run", destructive: true, action: action)
    }
}

extension ObjectKind {
    var systemImage: String {
        switch self {
        case .table: "tablecells"
        case .view: "eye"
        case .materializedView: "square.stack.3d.up"
        case .foreignTable: "externaldrive.connected.to.line.below"
        case .function: "function"
        case .procedure: "gearshape"
        }
    }
}
