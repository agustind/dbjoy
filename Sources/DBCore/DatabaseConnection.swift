import Foundation

/// Creates connections for one database engine. Each engine ships a driver module
/// (e.g. `PostgresDriver`) that conforms to this protocol.
public protocol DatabaseDriver: Sendable {
    var kind: DatabaseKind { get }

    /// Opens a connection. `database` overrides `config.database` when switching databases.
    func connect(_ config: ConnectionConfig, password: String?, database: String?) async throws -> any DatabaseConnection
}

/// A statement executed as part of a transaction, optionally guarded by an expected row count.
public struct TransactionStatement: Sendable, Hashable {
    public var sql: String
    /// When set, the transaction is rolled back unless exactly this many rows were affected.
    public var expectedRows: Int?

    public init(_ sql: String, expectedRows: Int? = nil) {
        self.sql = sql
        self.expectedRows = expectedRows
    }
}

/// A live session against a single database. Implementations serialize work internally,
/// so callers may issue requests concurrently; they will run one at a time.
public protocol DatabaseConnection: AnyObject, Sendable {
    var kind: DatabaseKind { get }
    var dialect: any SQLDialect { get }
    var serverVersion: String { get }
    var databaseName: String { get }

    // MARK: Execution

    /// Runs a (possibly multi-statement) script. Errors are reported in the result
    /// alongside any results produced before the failure.
    func execute(_ sql: String, maxRows: Int) async -> ExecutionResult

    /// Runs a single parameterized statement and throws on error.
    func query(_ sql: String, parameters: [String?]) async throws -> QueryResult

    /// Runs statements atomically: commits only if all succeed and row-count guards hold.
    func executeInTransaction(_ statements: [TransactionStatement]) async throws

    func transactionStatus() async -> TransactionStatus

    /// Requests cancellation of the statement currently running. Safe to call from any thread.
    func cancel()

    func close() async

    // MARK: Introspection

    func listDatabases() async throws -> [String]
    func listSchemas() async throws -> [String]
    func defaultSchema() async throws -> String
    func listObjects(schema: String) async throws -> [SchemaObject]
    func structure(of ref: ObjectRef) async throws -> TableStructure
    /// DDL / source for the object.
    func definition(of ref: ObjectRef) async throws -> String
    func relations(of ref: ObjectRef) async throws -> TableRelations
    /// All foreign keys between tables in a schema, for diagrams.
    func foreignKeys(schema: String) async throws -> [ForeignKeyInfo]
    /// Column names per table/view in a schema, for code completion and diagrams.
    func columnsByTable(schema: String) async throws -> [String: [ColumnInfo]]

    // MARK: Data

    func fetchRows(of ref: ObjectRef, request: RowRequest) async throws -> QueryResult
    /// Row count matching the request's filters. May be an estimate for large unfiltered tables,
    /// or `nil` when counting would take too long.
    func rowCount(of ref: ObjectRef, request: RowRequest) async throws -> RowCount?

    /// Streams every row of each object in batches, all from one consistent read-only snapshot.
    /// Throws `CancellationError` if the calling task is cancelled.
    func streamRows(of refs: [ObjectRef], batchSize: Int,
                    handler: @Sendable (RowStreamEvent) async throws -> Void) async throws
}

public struct RowCount: Hashable, Sendable {
    public var value: Int
    public var isEstimate: Bool

    public init(value: Int, isEstimate: Bool) {
        self.value = value
        self.isEstimate = isEstimate
    }
}

public extension DatabaseConnection {
    func query(_ sql: String) async throws -> QueryResult {
        try await query(sql, parameters: [])
    }
}
