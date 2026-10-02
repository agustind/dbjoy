import CLibPQ
import DBCore
import Foundation

struct PGTypeInfo: Sendable {
    var name: String
    var category: ValueCategory
}

/// Thin wrapper around a libpq connection. All libpq calls for a connection happen on its
/// serial queue; `cancel()` is the only call made from other threads.
final class PGConnection: @unchecked Sendable {
    private let queue: DispatchQueue
    private var conn: OpaquePointer?
    private let cancelLock = NSLock()
    private var cancelHandle: OpaquePointer?
    private var notices: [String] = []
    private var types: [UInt32: PGTypeInfo] = [:]

    private(set) var serverVersion = ""

    private init(conn: OpaquePointer, queue: DispatchQueue) {
        self.conn = conn
        self.queue = queue
    }

    deinit {
        if let cancelHandle { PQfreeCancel(cancelHandle) }
        if let conn { PQfinish(conn) }
    }

    static func open(parameters: [String: String]) async throws -> PGConnection {
        let queue = DispatchQueue(label: "dbjoy.pg.connection", qos: .userInitiated)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let keys = Array(parameters.keys)
                let conn = withCStringArray(keys) { keyPtrs in
                    withCStringArray(keys.map { parameters[$0] }) { valuePtrs in
                        PQconnectdbParams(keyPtrs, valuePtrs, 0)
                    }
                }
                guard let conn else {
                    continuation.resume(throwing: DatabaseError("Out of memory while connecting"))
                    return
                }
                guard PQstatus(conn) == CONNECTION_OK else {
                    let message = String(cString: PQerrorMessage(conn)).trimmingCharacters(in: .whitespacesAndNewlines)
                    PQfinish(conn)
                    continuation.resume(throwing: DatabaseError(message.isEmpty ? "Connection failed" : message))
                    return
                }
                let connection = PGConnection(conn: conn, queue: queue)
                connection.didConnect()
                continuation.resume(returning: connection)
            }
        }
    }

    /// Runs on the connection queue right after (re)connecting.
    private func didConnect() {
        guard let conn else { return }
        cancelLock.withLock {
            if let cancelHandle { PQfreeCancel(cancelHandle) }
            cancelHandle = PQgetCancel(conn)
        }
        PQsetNoticeReceiver(conn, { arg, result in
            guard let arg, let result else { return }
            let connection = Unmanaged<PGConnection>.fromOpaque(arg).takeUnretainedValue()
            let message = String(cString: PQresultErrorMessage(result)).trimmingCharacters(in: .whitespacesAndNewlines)
            connection.notices.append(message)
        }, Unmanaged.passUnretained(self).toOpaque())
        if let version = PQparameterStatus(conn, "server_version") {
            serverVersion = String(cString: version)
        }
        loadTypes(conn)
    }

    private func loadTypes(_ conn: OpaquePointer) {
        guard let res = PQexec(conn, "SELECT oid::int8, format_type(oid, NULL), typcategory FROM pg_type") else { return }
        defer { PQclear(res) }
        guard PQresultStatus(res) == PGRES_TUPLES_OK else { return }
        var map: [UInt32: PGTypeInfo] = [:]
        for row in 0..<PQntuples(res) {
            guard let oid = UInt32(String(cString: PQgetvalue(res, row, 0))) else { continue }
            let name = String(cString: PQgetvalue(res, row, 1))
            let category = String(cString: PQgetvalue(res, row, 2))
            map[oid] = PGTypeInfo(name: name, category: Self.category(oid: oid, typcategory: category))
        }
        types = map
    }

    private static func category(oid: UInt32, typcategory: String) -> ValueCategory {
        switch oid {
        case 114, 3802: return .json
        case 17: return .binary
        default: break
        }
        switch typcategory {
        case "N": return .number
        case "B": return .boolean
        case "S": return .text
        case "D", "T": return .temporal
        default: return .other
        }
    }

    // MARK: Execution plumbing

    /// Runs `body` on the connection queue with a live connection, reconnecting if the link dropped.
    func perform<T: Sendable>(_ body: @escaping @Sendable (PGConnection, OpaquePointer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let conn = try self.liveConnection()
                    continuation.resume(returning: try body(self, conn))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func liveConnection() throws -> OpaquePointer {
        guard let conn else { throw DatabaseError("Connection is closed") }
        if PQstatus(conn) == CONNECTION_BAD {
            PQreset(conn)
            guard PQstatus(conn) == CONNECTION_OK else {
                throw DatabaseError("Lost connection to server: " + String(cString: PQerrorMessage(conn)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            didConnect()
        }
        return conn
    }

    func cancel() {
        cancelLock.withLock {
            guard let cancelHandle else { return }
            var buffer = [CChar](repeating: 0, count: 256)
            _ = PQcancel(cancelHandle, &buffer, Int32(buffer.count))
        }
    }

    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.cancelLock.withLock {
                    if let handle = self.cancelHandle { PQfreeCancel(handle) }
                    self.cancelHandle = nil
                }
                if let conn = self.conn { PQfinish(conn) }
                self.conn = nil
                continuation.resume()
            }
        }
    }

    // MARK: Queue-confined operations (call only inside `perform`)

    func transactionStatus(_ conn: OpaquePointer) -> TransactionStatus {
        switch PQtransactionStatus(conn) {
        case PQTRANS_IDLE: .idle
        case PQTRANS_ACTIVE: .active
        case PQTRANS_INTRANS: .inTransaction
        case PQTRANS_INERROR: .failedTransaction
        default: .unknown
        }
    }

    /// Executes a script with the simple query protocol, streaming rows in single-row mode
    /// so at most `maxRows` rows per result are kept in memory.
    func executeScript(_ conn: OpaquePointer, sql: String, maxRows: Int) -> ExecutionResult {
        notices = []
        let start = Date()
        let statements = SQLSplitter.split(sql)
        var results: [QueryResult] = []
        var error: DatabaseError?

        guard PQsendQuery(conn, sql) == 1 else {
            return ExecutionResult(error: connectionError(conn), transactionStatus: transactionStatus(conn))
        }
        PQsetSingleRowMode(conn)

        var columns: [ResultColumn]?
        var rows: [[String?]] = []
        var truncated = false

        func statementText() -> String? {
            results.count < statements.count ? statements[results.count].text : nil
        }

        while let res = PQgetResult(conn) {
            defer { PQclear(res) }
            switch PQresultStatus(res) {
            case PGRES_SINGLE_TUPLE:
                if columns == nil { columns = describe(res) }
                if rows.count < maxRows { rows.append(readRow(res, 0)) } else { truncated = true }
            case PGRES_TUPLES_OK:
                let cols = columns ?? describe(res)
                for row in 0..<PQntuples(res) {
                    if rows.count < maxRows { rows.append(readRow(res, row)) } else { truncated = true }
                }
                results.append(QueryResult(columns: cols, rows: rows, commandTag: commandTag(res),
                                           rowsAffected: rowsAffected(res), truncated: truncated, statement: statementText()))
                columns = nil
                rows = []
                truncated = false
            case PGRES_COMMAND_OK:
                results.append(QueryResult(commandTag: commandTag(res), rowsAffected: rowsAffected(res), statement: statementText()))
            case PGRES_EMPTY_QUERY:
                break
            case PGRES_COPY_OUT:
                var buffer: UnsafeMutablePointer<CChar>?
                while PQgetCopyData(conn, &buffer, 0) > 0 {
                    PQfreemem(buffer)
                }
                error = DatabaseError("COPY ... TO STDOUT is not supported in the query editor")
            case PGRES_COPY_IN, PGRES_COPY_BOTH:
                PQputCopyEnd(conn, "COPY FROM STDIN is not supported in the query editor")
            default:
                error = resultError(res, conn: conn)
            }
        }
        return ExecutionResult(results: results, error: error, notices: notices,
                               duration: Date().timeIntervalSince(start), transactionStatus: transactionStatus(conn))
    }

    /// Executes one statement with text parameters using the extended protocol.
    func exec(_ conn: OpaquePointer, _ sql: String, parameters: [String?] = []) throws -> QueryResult {
        let res = withCStringArray(parameters) { values in
            PQexecParams(conn, sql, Int32(parameters.count), nil, values, nil, nil, 0)
        }
        guard let res else { throw connectionError(conn) }
        defer { PQclear(res) }
        switch PQresultStatus(res) {
        case PGRES_TUPLES_OK:
            let rows = (0..<PQntuples(res)).map { readRow(res, $0) }
            return QueryResult(columns: describe(res), rows: rows, commandTag: commandTag(res), rowsAffected: rowsAffected(res), statement: sql)
        case PGRES_COMMAND_OK, PGRES_EMPTY_QUERY:
            return QueryResult(commandTag: commandTag(res), rowsAffected: rowsAffected(res), statement: sql)
        default:
            throw resultError(res, conn: conn) ?? DatabaseError("Unexpected result")
        }
    }

    func runTransaction(_ conn: OpaquePointer, _ statements: [TransactionStatement]) throws {
        let wasInTransaction = transactionStatus(conn).isInTransaction
        // Inside an open transaction, use a savepoint so we only roll back our own work.
        _ = try exec(conn, wasInTransaction ? "SAVEPOINT dbjoy_apply" : "BEGIN")
        do {
            for statement in statements {
                let result = try exec(conn, statement.sql)
                if let expected = statement.expectedRows, let affected = result.rowsAffected, affected != expected {
                    throw DatabaseError(
                        "Expected \(expected) row(s) to be affected but \(affected) were. All changes were rolled back.",
                        detail: statement.sql)
                }
            }
            _ = try exec(conn, wasInTransaction ? "RELEASE SAVEPOINT dbjoy_apply" : "COMMIT")
        } catch {
            _ = try? exec(conn, wasInTransaction ? "ROLLBACK TO SAVEPOINT dbjoy_apply" : "ROLLBACK")
            throw error
        }
    }

    // MARK: Result helpers

    private func describe(_ res: OpaquePointer) -> [ResultColumn] {
        (0..<PQnfields(res)).map { i in
            let oid = UInt32(PQftype(res, i))
            let info = types[oid]
            return ResultColumn(name: String(cString: PQfname(res, i)),
                                typeName: info?.name ?? "oid:\(oid)",
                                category: info?.category ?? .other)
        }
    }

    private static let boolOID: UInt32 = 16

    /// Reads a row as text. Booleans are spelled out as `true`/`false` rather than libpq's `t`/`f`.
    private func readRow(_ res: OpaquePointer, _ row: Int32) -> [String?] {
        let count = PQnfields(res)
        var values: [String?] = []
        values.reserveCapacity(Int(count))
        for col in 0..<count {
            if PQgetisnull(res, row, col) == 1 {
                values.append(nil)
            } else if UInt32(PQftype(res, col)) == Self.boolOID {
                values.append(PQgetvalue(res, row, col).pointee == CChar(UInt8(ascii: "t")) ? "true" : "false")
            } else {
                values.append(String(cString: PQgetvalue(res, row, col)))
            }
        }
        return values
    }

    private func commandTag(_ res: OpaquePointer) -> String {
        String(cString: PQcmdStatus(res))
    }

    private func rowsAffected(_ res: OpaquePointer) -> Int? {
        Int(String(cString: PQcmdTuples(res)))
    }

    private func connectionError(_ conn: OpaquePointer) -> DatabaseError {
        let message = String(cString: PQerrorMessage(conn)).trimmingCharacters(in: .whitespacesAndNewlines)
        return DatabaseError(message.isEmpty ? "Unknown error" : message)
    }

    private func resultError(_ res: OpaquePointer, conn: OpaquePointer) -> DatabaseError? {
        func field(_ code: Character) -> String? {
            guard let value = PQresultErrorField(res, Int32(code.asciiValue!)) else { return nil }
            return String(cString: value)
        }
        guard let message = field("M") else {
            let fallback = String(cString: PQresultErrorMessage(res)).trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? connectionError(conn) : DatabaseError(fallback)
        }
        return DatabaseError(message, detail: field("D"), hint: field("H"), sqlState: field("C"),
                             position: field("P").flatMap { Int($0) })
    }
}

/// Bridges Swift strings to a temporary `const char *const *` array.
private func withCStringArray<R>(_ strings: [String?], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    let pointers: [UnsafeMutablePointer<CChar>?] = strings.map { $0.flatMap { strdup($0) } } + [nil]
    defer { pointers.forEach { free($0) } }
    let constPointers = pointers.map { $0.map { UnsafePointer($0) } }
    return constPointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
