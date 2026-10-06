import DBCore
import Foundation
import Observation

struct QueryMessage: Identifiable, Hashable {
    enum Kind { case info, notice, error }

    let id = UUID()
    var kind: Kind
    var text: String
}

/// A SQL editor tab. Each tab owns its own connection so transactions and long-running
/// queries don't interfere with browsing or other tabs.
@MainActor @Observable
final class QueryTabModel: Identifiable {
    enum Scope { case current, all }

    static let maxRows = 50_000

    let id = UUID()
    @ObservationIgnored weak var workspace: WorkspaceModel?
    var title: String
    var sql: String
    var savedQueryID: UUID?
    /// The .sql file this tab was opened from, if any.
    var fileURL: URL?
    /// Current editor selection (UTF-16), kept in sync by the editor.
    var selection = NSRange(location: 0, length: 0)
    /// Set to move the editor selection, e.g. to an error position.
    var requestedSelection: NSRange?

    private var connection: (any DatabaseConnection)?
    var isRunning = false
    var results: [QueryResult] = []
    var selectedResultID: QueryResult.ID?
    var messages: [QueryMessage] = []
    var transactionStatus: TransactionStatus = .idle
    var lastDuration: TimeInterval?
    var isSaveSheetPresented = false
    /// Share of the tab's height given to the editor; results get the rest.
    var editorFraction: CGFloat = 0.4

    init(workspace: WorkspaceModel, title: String, sql: String, savedQueryID: UUID? = nil) {
        self.workspace = workspace
        self.title = title
        self.sql = sql
        self.savedQueryID = savedQueryID
    }

    var selectedResult: QueryResult? {
        results.first { $0.id == selectedResultID } ?? results.first
    }

    // MARK: Running

    /// The SQL that a run would execute: the selection, the statement under the cursor, or everything.
    func sqlToRun(_ scope: Scope) -> (sql: String, offset: Int)? {
        let ns = sql as NSString
        if selection.length > 0, NSMaxRange(selection) <= ns.length {
            return (ns.substring(with: selection), selection.location)
        }
        switch scope {
        case .all:
            return sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (sql, 0)
        case .current:
            guard let statement = SQLSplitter.statement(at: selection.location, in: sql) else { return nil }
            return (statement.text, statement.range.lowerBound)
        }
    }

    func run(_ scope: Scope) {
        guard !isRunning, let (text, offset) = sqlToRun(scope), let workspace else { return }
        if let (line, command) = Self.psqlMetaCommand(in: text) {
            results = []
            messages = [QueryMessage(kind: .error, text:
                "Line \(line) is a psql command (\(command)). DBJoy talks to the server directly and can't run "
                + "psql commands such as \\connect, \\copy, \\set or COPY … FROM stdin data. "
                + "Remove them, or run this file with psql.")]
            return
        }
        workspace.guardWrite(text) { [self] in
            await execute(text, offset: offset, recordHistory: true)
        }
    }

    func execute(_ text: String, offset: Int = 0, recordHistory: Bool) async {
        guard let workspace else { return }
        isRunning = true
        defer { isRunning = false }
        let connection: any DatabaseConnection
        do {
            connection = try await session()
        } catch {
            messages = [QueryMessage(kind: .error, text: error.localizedDescription)]
            return
        }
        let result = await connection.execute(text, maxRows: Self.maxRows)
        lastDuration = result.duration
        transactionStatus = result.transactionStatus

        var messages: [QueryMessage] = []
        for item in result.results {
            if item.returnsRows {
                var text = "\(item.rows.count) row(s)"
                if item.truncated { text += " — truncated to the first \(Self.maxRows)" }
                messages.append(QueryMessage(kind: .info, text: text))
            } else {
                let affected = item.rowsAffected.map { " — \($0) row(s) affected" } ?? ""
                messages.append(QueryMessage(kind: .info, text: item.commandTag + affected))
            }
        }
        messages += result.notices.map { QueryMessage(kind: .notice, text: $0) }
        if let error = result.error {
            messages.append(QueryMessage(kind: .error, text: error.fullDescription))
            if let position = error.position {
                // Server positions are 1-based character offsets into the submitted text.
                let prefix = String(text.prefix(max(position - 1, 0)))
                requestedSelection = NSRange(location: offset + prefix.utf16.count, length: 0)
            }
        }
        self.messages = messages
        let rowResults = result.results.filter(\.returnsRows)
        if !rowResults.isEmpty || result.error == nil {
            results = rowResults
            selectedResultID = rowResults.last?.id
        }

        if recordHistory {
            QueryLibrary.shared.record(
                HistoryEntry(sql: text, database: workspace.currentDatabase, duration: result.duration,
                             rowCount: rowResults.last?.rows.count, error: result.error?.message),
                connectionID: workspace.config.id)
        }
        // Keep the sidebar in sync after DDL.
        let ddl: Set<String> = ["CREATE", "ALTER", "DROP", "COMMENT"]
        if SQLSplitter.split(text).contains(where: { ddl.contains(SQLLexer.firstKeyword(in: $0.text) ?? "") }) {
            await workspace.reloadObjects()
        }
    }

    func cancel() {
        connection?.cancel()
    }

    // MARK: Files

    /// Replaces the editor contents with a SQL file.
    func load(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw DatabaseError("\(url.lastPathComponent) isn't a text file.")
        }
        sql = text
        fileURL = url
        title = url.lastPathComponent
        savedQueryID = nil
        selection = NSRange(location: 0, length: 0)
        results = []
        messages = []
    }

    /// The first line starting with a psql backslash command, which the server can't execute.
    static func psqlMetaCommand(in sql: String) -> (line: Int, command: String)? {
        for (index, line) in sql.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\\") {
                let command = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
                return (index + 1, command)
            }
        }
        return nil
    }

    func begin() { Task { await execute("BEGIN", recordHistory: false) } }

    func commitTransaction() {
        guard let workspace else { return }
        workspace.guardWrite("COMMIT -- pending changes") { [self] in
            await execute("COMMIT", recordHistory: false)
        }
    }

    func rollback() { Task { await execute("ROLLBACK", recordHistory: false) } }

    private func session() async throws -> any DatabaseConnection {
        if let connection { return connection }
        guard let workspace else { throw DatabaseError("Workspace closed") }
        let connection = try await workspace.openSession()
        self.connection = connection
        return connection
    }

    func closeConnection() async {
        await connection?.close()
        connection = nil
    }

    // MARK: Saving

    func save(name: String, shared: Bool) {
        guard let workspace else { return }
        let query = SavedQuery(id: savedQueryID ?? UUID(), name: name, sql: sql,
                               connectionID: shared ? nil : workspace.config.id)
        QueryLibrary.shared.save(query)
        savedQueryID = query.id
        title = name
    }

    var savedQuery: SavedQuery? {
        QueryLibrary.shared.savedQueries.first { $0.id == savedQueryID }
    }
}
