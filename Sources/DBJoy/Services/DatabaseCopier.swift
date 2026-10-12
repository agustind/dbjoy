import Darwin
import DBCore
import Foundation

/// Where a PostgreSQL command-line tool (pg_dump, psql) connects, and the libpq environment it needs.
struct PostgresToolEndpoint: Sendable {
    var host: String
    var port: Int
    var user: String
    var database: String
    var environment: [String: String]

    init(host: String, port: Int, user: String, database: String, environment: [String: String]) {
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.environment = environment
    }

    /// Through a tunnel, the tool connects to 127.0.0.1:<local port> while `host` keeps the real
    /// name for TLS verification.
    init(config: ConnectionConfig, tunnel: SSHTunnel?, password: String?, database: String) {
        var environment = ["PGSSLMODE": config.sslMode.rawValue, "PGCONNECT_TIMEOUT": "10", "PGAPPNAME": "DBJoy"]
        if tunnel != nil { environment["PGHOSTADDR"] = "127.0.0.1" }
        if let password, !password.isEmpty { environment["PGPASSWORD"] = password }
        self.init(host: config.host.isEmpty ? "localhost" : config.host, port: tunnel?.localPort ?? config.port,
                  user: config.user, database: database, environment: environment)
    }

    var arguments: [String] {
        ["--host", host, "--port", String(port), "--username", user, "--dbname", database, "--no-password"]
    }

    func configure(_ process: Process) {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    }
}

/// Replaces everything in one PostgreSQL database with a copy of another. pg_dump streams the
/// source into psql, which first drops every schema in the target. psql runs it all in one
/// transaction, so if anything fails or the copy is cancelled, the target stays as it was.
final class DatabaseCopier: @unchecked Sendable {
    struct Options: Sendable {
        var includeData = true
        /// Copy owners and grants. The roles must exist on the target server.
        var keepOwnership = false
    }

    struct Progress: Sendable {
        var step: String
        var bytes: Int64
    }

    private let lock = NSLock()
    private var running: [Process] = []
    private var isCancelled = false

    /// SQL that runs before the copy: drops every schema (with everything in it) and large object.
    static func wipeScript(recreatePublicSchema: Bool) -> String {
        var lines = [
            "-- DBJoy: delete everything in the target before loading the copy.",
            "SET client_min_messages = warning;",
            // Fail instead of waiting forever when another session holds a lock on the target.
            "SET lock_timeout = '10s';",
            "DO $dbjoy$",
            "DECLARE s name;",
            "BEGIN",
            "  FOR s IN SELECT nspname FROM pg_namespace WHERE nspname <> 'information_schema' AND nspname !~ '^pg_' LOOP",
            "    EXECUTE format('DROP SCHEMA %I CASCADE', s);",
            "  END LOOP;",
            "  PERFORM lo_unlink(oid) FROM pg_largeobject_metadata;",
            "END $dbjoy$;",
        ]
        if recreatePublicSchema {
            // pg_dump leaves out the public schema, which every database starts with. Recreate it
            // the way CREATE DATABASE makes it (owned by pg_database_owner since PostgreSQL 15).
            lines += [
                "CREATE SCHEMA public;",
                "GRANT USAGE ON SCHEMA public TO PUBLIC;",
                "DO $dbjoy$",
                "BEGIN",
                "  IF current_setting('server_version_num')::int >= 150000 THEN",
                "    ALTER SCHEMA public OWNER TO pg_database_owner;",
                "  END IF;",
                "EXCEPTION WHEN insufficient_privilege THEN NULL;",
                "END $dbjoy$;",
            ]
        }
        lines.append("SET lock_timeout = 0;")
        return lines.joined(separator: "\n") + "\n\n"
    }

    func run(from source: PostgresToolEndpoint, to target: PostgresToolEndpoint, recreatePublicSchema: Bool,
             options: Options, progress: @escaping @Sendable (Progress) -> Void) async throws {
        guard let pgDump = BundledTools.postgres("pg_dump"), let psql = BundledTools.postgres("psql") else {
            throw DatabaseError("pg_dump and psql weren't found. Install them with: brew install libpq")
        }
        try await withTaskCancellationHandler {
            try await copy(pgDump: pgDump, psql: psql, source: source, target: target,
                           recreatePublicSchema: recreatePublicSchema, options: options, progress: progress)
        } onCancel: {
            cancel()
        }
    }

    /// Stops both tools. psql exits before it reaches the end of its input, so nothing is committed.
    func cancel() {
        lock.lock()
        isCancelled = true
        let processes = running
        lock.unlock()
        // psql first: once pg_dump stops, its output ends, and psql must not see that as the end of the copy.
        for process in processes.reversed() where process.isRunning { process.terminate() }
    }

    private func setRunning(_ processes: [Process]) {
        lock.withLock { running = processes }
    }

    private var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    private func copy(pgDump: URL, psql: URL, source: PostgresToolEndpoint, target: PostgresToolEndpoint,
                      recreatePublicSchema: Bool, options: Options,
                      progress: @escaping @Sendable (Progress) -> Void) async throws {
        let dump = Process()
        dump.executableURL = pgDump
        dump.arguments = source.arguments + ["--format=plain", "--verbose"]
            + (options.keepOwnership ? [] : ["--no-owner", "--no-privileges"])
            + (options.includeData ? [] : ["--schema-only"])
        source.configure(dump)
        let dumpOutput = Pipe()
        dump.standardInput = FileHandle.nullDevice
        dump.standardOutput = dumpOutput

        let load = Process()
        load.executableURL = psql
        load.arguments = target.arguments
            + ["--no-psqlrc", "--quiet", "--single-transaction", "--set", "ON_ERROR_STOP=1", "--file", "-"]
        target.configure(load)
        let loadInput = Pipe()
        load.standardInput = loadInput
        load.standardOutput = FileHandle.nullDevice

        let step = StepTracker(progress)
        let dumpErrors = OutputTail(for: dump) { line in
            if let table = Self.table(inVerboseLine: line) {
                step.set("Copying \(table)")
            } else if line.contains("reading") || line.contains("identifying") {
                step.set("Reading the source")
            }
        }
        let loadErrors = OutputTail(for: load)
        let dumpExit = ProcessExit(dump)
        let loadExit = ProcessExit(load)

        step.set("Connecting")
        setRunning([dump, load])
        defer { setRunning([]) }
        try load.run()
        do {
            try dump.run()
        } catch {
            load.terminate()
            await loadExit.wait()
            throw error
        }

        let script = Data(Self.wipeScript(recreatePublicSchema: recreatePublicSchema).utf8)
        let reachedEnd = await Self.pump(script, from: dumpOutput.fileHandleForReading.fileDescriptor,
                                         to: loadInput.fileHandleForWriting.fileDescriptor) { step.setBytes($0) }
        // psql stopped reading (it failed); pg_dump may be blocked writing to the full pipe.
        if !reachedEnd { dump.terminate() }
        await dumpExit.wait()
        let dumpSucceeded = dump.terminationReason == .exit && dump.terminationStatus == 0

        guard reachedEnd, dumpSucceeded, !cancelled else {
            load.terminate()
            await loadExit.wait()
            if cancelled { throw CancellationError() }
            if !dumpSucceeded, reachedEnd {
                throw Self.failure("Couldn't read the source database.", output: await dumpErrors.finalText())
            }
            throw Self.failure("Couldn't write to the target database.", output: await loadErrors.finalText())
        }

        // The end of psql's input: it commits.
        step.set("Finishing on the target")
        try? loadInput.fileHandleForWriting.close()
        await loadExit.wait()
        if cancelled { throw CancellationError() }
        guard load.terminationReason == .exit, load.terminationStatus == 0 else {
            throw Self.failure("Couldn't write to the target database.", output: await loadErrors.finalText())
        }
    }

    /// Writes `prefix`, then everything from `input`, to `output`. Returns false if writing fails
    /// (the reader went away) and true once `input` ends.
    private static func pump(_ prefix: Data, from input: Int32, to output: Int32,
                             onBytes: @escaping @Sendable (Int64) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                // A closed pipe returns EPIPE instead of killing the app with SIGPIPE.
                _ = fcntl(output, F_SETNOSIGPIPE, 1)
                guard prefix.withUnsafeBytes({ writeAll($0, to: output) }) else {
                    continuation.resume(returning: false)
                    return
                }
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                var total: Int64 = 0
                var reported: Int64 = 0
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 {
                        onBytes(total)
                        continuation.resume(returning: true)
                        return
                    }
                    guard buffer.withUnsafeBytes({ writeAll(UnsafeRawBufferPointer(rebasing: $0[..<count]), to: output) }) else {
                        continuation.resume(returning: false)
                        return
                    }
                    total += Int64(count)
                    if total - reported >= 1 << 18 {
                        reported = total
                        onBytes(total)
                    }
                }
            }
        }
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to output: Int32) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(output, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    /// The table in a pg_dump --verbose line such as `pg_dump: dumping contents of table "public.orders"`.
    static func table(inVerboseLine line: String) -> String? {
        guard let range = line.range(of: "dumping contents of table ") else { return nil }
        return line[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    private static func failure(_ title: String, output: String) -> DatabaseError {
        DatabaseError(title + "\n\n" + errorDetail(output))
    }

    /// The error lines of a tool's output, without psql's `psql:<stdin>:123: ` prefixes.
    static func errorDetail(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { line -> String in
            var line = String(line)
            if line.hasPrefix("psql:"), let range = line.range(of: #"^psql:[^:]*:\d+: "#, options: .regularExpression) {
                line.removeSubrange(range)
            }
            return line
        }
        let markers = ["error:", "ERROR:", "FATAL:", "DETAIL:", "HINT:", "CONTEXT:", "LINE "]
        let start = lines.firstIndex { line in markers.prefix(3).contains { line.contains($0) } }
        let relevant = start.map { Array(lines[$0...]).filter { line in markers.contains { line.contains($0) } || line.hasPrefix(" ") } }
            ?? Array(lines.suffix(8))
        var detail = relevant.prefix(12).joined(separator: "\n")
        if detail.contains("lock timeout") {
            detail += "\n\nAnother session is using the target database. Close it (or its open transaction) and try again."
        }
        return detail.isEmpty ? "The tool exited without saying why." : detail
    }
}

/// Reports the current step, keeping the byte count.
private final class StepTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = DatabaseCopier.Progress(step: "", bytes: 0)
    private let report: @Sendable (DatabaseCopier.Progress) -> Void

    init(_ report: @escaping @Sendable (DatabaseCopier.Progress) -> Void) {
        self.report = report
    }

    func set(_ step: String) {
        lock.lock()
        guard progress.step != step else { return lock.unlock() }
        progress.step = step
        let current = progress
        lock.unlock()
        report(current)
    }

    func setBytes(_ bytes: Int64) {
        lock.lock()
        progress.bytes = bytes
        let current = progress
        lock.unlock()
        report(current)
    }
}

/// Collects a process's stderr (the last 64 KB), passing each line to `onLine`.
private final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = Data()
    private let closed = Latch()

    init(for process: Process, onLine: (@Sendable (String) -> Void)? = nil) {
        let pipe = Pipe()
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                closed.open()
                return
            }
            lock.lock()
            data.append(chunk)
            if data.count > 1 << 16 { data.removeFirst(data.count - (1 << 16)) }
            pending.append(chunk)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            lock.unlock()
            if let onLine { lines.forEach(onLine) }
        }
    }

    /// Everything collected, once the process has closed its end (call after it exits).
    func finalText() async -> String {
        await closed.wait()
        return text
    }

    private var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Opens once; any number of callers can wait for it.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        isOpen = true
        let waiting = waiters
        waiters = []
        lock.unlock()
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Lets several callers await a process's exit.
private final class ProcessExit: Sendable {
    private let latch = Latch()

    init(_ process: Process) {
        process.terminationHandler = { [latch] _ in latch.open() }
    }

    func wait() async { await latch.wait() }
}
