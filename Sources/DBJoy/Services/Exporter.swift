import AppKit
import DBCore
import Foundation
import Observation

enum ExportKind: String, CaseIterable, Identifiable {
    case csv, json, sql, dump

    var id: String { rawValue }

    var title: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        case .sql: "SQL"
        case .dump: "Backup"
        }
    }

    var explanation: String {
        switch self {
        case .csv: "One .csv file per table with a header row. NULL is an empty field; empty strings are \"\"."
        case .json: "One .json file per table containing an array of row objects."
        case .sql: "One .sql file of INSERT statements (data only), ordered so foreign keys load cleanly, wrapped in a transaction."
        case .dump: "A complete, restorable .sql backup of the whole database (all schemas, types, functions and data) made with pg_dump."
        }
    }

    var format: ExportFormat? {
        switch self {
        case .csv: .csv
        case .json: .json
        case .sql: .sql
        case .dump: nil
        }
    }
}

/// Drives an export of tables from the current schema.
@MainActor @Observable
final class ExportModel: Identifiable {
    enum Phase: Equatable {
        case configuring, running, finished(String), failed(String)
    }

    let id = UUID()
    @ObservationIgnored weak var workspace: WorkspaceModel?
    let schema: String
    let objects: [SchemaObject]
    var selected: Set<ObjectRef>
    var kind: ExportKind = .csv
    var includeViews = false
    var phase: Phase = .configuring
    var currentTable = ""
    var tablesDone = 0
    var rowsExported = 0
    var outputURL: URL?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var process: Process?

    init(workspace: WorkspaceModel, preselect: [ObjectRef]? = nil) {
        self.workspace = workspace
        schema = workspace.currentSchema
        objects = workspace.objects.filter { $0.kind.hasRows }
        selected = Set(preselect ?? objects.filter { $0.kind == .table }.map(\.ref))
        if let preselect, preselect.contains(where: { $0.kind != .table }) { includeViews = true }
    }

    static let pgDumpURL: URL? = {
        var directories = ["/opt/homebrew/opt/libpq/bin", "/opt/homebrew/bin", "/usr/local/opt/libpq/bin", "/usr/local/bin",
                           "/Applications/Postgres.app/Contents/Versions/latest/bin"]
        if let prefix = ProcessInfo.processInfo.environment["LIBPQ_PREFIX"] { directories.insert(prefix + "/bin", at: 0) }
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent("pg_dump") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    var visibleObjects: [SchemaObject] {
        includeViews ? objects : objects.filter { $0.kind == .table }
    }

    var selectedRefs: [ObjectRef] {
        visibleObjects.map(\.ref).filter(selected.contains)
    }

    var isRunning: Bool { phase == .running }

    func selectAll(_ on: Bool) {
        selected = on ? Set(visibleObjects.map(\.ref)) : []
    }

    // MARK: Running

    /// Asks for a destination, then exports.
    func chooseDestinationAndStart() {
        guard let workspace, kind == .dump || !selectedRefs.isEmpty else { return }
        let stamp = Self.timestamp()
        switch kind {
        case .csv, .json:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.message = "A new folder will be created for the exported files."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let destination = folder.appendingPathComponent("\(workspace.currentDatabase)-\(schema)-\(stamp)", isDirectory: true)
            start(destination: destination)
        case .sql, .dump:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = kind == .dump
                ? "\(workspace.currentDatabase)-backup-\(stamp).sql"
                : "\(workspace.currentDatabase)-\(schema)-data-\(stamp).sql"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let file = panel.url else { return }
            start(destination: file)
        }
    }

    func start(destination: URL) {
        phase = .running
        tablesDone = 0
        rowsExported = 0
        outputURL = destination
        task = Task {
            do {
                if kind == .dump {
                    try await runDump(to: destination)
                    phase = .finished("Backup written with pg_dump.")
                } else {
                    try await exportRows(to: destination)
                    phase = .finished("Exported \(rowsExported.formatted()) rows from \(tablesDone) table(s).")
                }
            } catch is CancellationError {
                phase = .failed("Export cancelled. Partial files may remain at \(destination.path).")
            } catch {
                phase = .failed((error as? DatabaseError)?.fullDescription ?? error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        process?.terminate()
    }

    func revealInFinder() {
        guard let outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    private func exportRows(to destination: URL) async throws {
        guard let workspace, let format = kind.format else { return }
        let session = try await workspace.openSession()
        defer { Task { await session.close() } }

        var refs = selectedRefs
        var structures: [ObjectRef: TableStructure] = [:]
        if format == .sql {
            refs = ExportEncoding.dependencyOrder(refs, foreignKeys: try await session.foreignKeys(schema: schema))
            for ref in refs { structures[ref] = try await session.structure(of: ref) }
        }
        let sink = try ExportSink(format: format, destination: destination, dialect: session.dialect, structures: structures,
                                  header: "Exported by DBJoy from \(workspace.currentDatabase) (\(schema)) on \(Date().formatted())")
        try await session.streamRows(of: refs, batchSize: 2000) { [self] event in
            try sink.handle(event)
            switch event {
            case .begin(let ref, _): await MainActor.run { currentTable = ref.name }
            case .rows(_, let rows): await MainActor.run { rowsExported += rows.count }
            case .end: await MainActor.run { tablesDone += 1 }
            }
        }
        try sink.finish()
    }

    private func runDump(to file: URL) async throws {
        guard let workspace, let tool = Self.pgDumpURL else {
            throw DatabaseError("pg_dump was not found. Install it with: brew install libpq")
        }
        let config = workspace.config
        let arguments = ["--host", config.host.isEmpty ? "localhost" : config.host, "--port", String(workspace.effectivePort),
                         "--username", config.user, "--dbname", workspace.currentDatabase,
                         "--file", file.path, "--no-password", "--format=plain"]
        currentTable = "pg_dump"

        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(workspace.dumpEnvironment()) { $1 }
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        self.process = process
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume()
            }
        }
        self.process = nil
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw DatabaseError("pg_dump failed (exit \(process.terminationStatus))",
                                detail: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// Writes streamed rows to disk. Events arrive sequentially from a single stream.
final class ExportSink: @unchecked Sendable {
    private let format: ExportFormat
    private let destination: URL
    private let dialect: any SQLDialect
    private let structures: [ObjectRef: TableStructure]
    private var handle: FileHandle?
    private var buffer = Data()
    private var columns: [ResultColumn] = []
    private var isFirstRow = true
    // SQL: columns to insert (stored generated columns are skipped) and identity override.
    private var insertIndexes: [Int] = []
    private var overridingSystemValue = false

    init(format: ExportFormat, destination: URL, dialect: any SQLDialect, structures: [ObjectRef: TableStructure], header: String) throws {
        self.format = format
        self.destination = destination
        self.dialect = dialect
        self.structures = structures
        if format == .sql {
            try open(destination)
            write("-- \(header)\n\nBEGIN;\n\n")
        } else {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
    }

    func handle(_ event: RowStreamEvent) throws {
        switch event {
        case .begin(let ref, let columns):
            self.columns = columns
            isFirstRow = true
            switch format {
            case .csv:
                try open(destination.appendingPathComponent(Self.fileName(ref.name, "csv")))
                write(ExportEncoding.csvLine(columns.map(\.name)))
            case .json:
                try open(destination.appendingPathComponent(Self.fileName(ref.name, "json")))
                write("[\n")
            case .sql:
                let info = structures[ref]?.columns ?? []
                insertIndexes = columns.indices.filter { index in
                    let column = info.first { $0.name == columns[index].name }
                    return !((column?.isGenerated ?? false) && !(column?.isIdentity ?? false))
                }
                overridingSystemValue = info.contains { $0.isGenerated && $0.isIdentity }
                write("-- \(ref.description)\n")
            }
        case .rows(let ref, let rows):
            switch format {
            case .csv:
                for row in rows { write(ExportEncoding.csvLine(row)) }
            case .json:
                for row in rows {
                    write((isFirstRow ? "  " : ",\n  ") + ExportEncoding.jsonObject(columns: columns, row: row))
                    isFirstRow = false
                }
            case .sql:
                let names = insertIndexes.map { columns[$0].name }
                for start in stride(from: 0, to: rows.count, by: 100) {
                    let chunk = rows[start..<min(start + 100, rows.count)].map { row in insertIndexes.map { row[$0] } }
                    write(ExportEncoding.insertStatement(table: ref, columns: names, rows: chunk, dialect: dialect,
                                                         overridingSystemValue: overridingSystemValue))
                }
            }
            if buffer.count > 1 << 20 { try flush() }
        case .end(let ref, _):
            switch format {
            case .csv:
                try close()
            case .json:
                write(isFirstRow ? "]\n" : "\n]\n")
                try close()
            case .sql:
                if let structure = structures[ref] {
                    for statement in dialect.resetSequenceStatements(for: structure) { write(statement + "\n") }
                }
                write("\n")
            }
        }
    }

    func finish() throws {
        if format == .sql {
            write("COMMIT;\n")
            try close()
        }
    }

    private static func fileName(_ table: String, _ ext: String) -> String {
        table.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") + "." + ext
    }

    private func open(_ url: URL) throws {
        try close()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    private func write(_ string: String) {
        buffer.append(contentsOf: string.utf8)
    }

    private func flush() throws {
        guard let handle, !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private func close() throws {
        try flush()
        try handle?.close()
        handle = nil
    }
}
