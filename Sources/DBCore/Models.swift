import Foundation

// MARK: - Connection configuration

public enum DatabaseKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case postgres

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .postgres: "PostgreSQL"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgres: 5432
        }
    }

    public var defaultUser: String {
        switch self {
        case .postgres: "postgres"
        }
    }
}

public enum ConnectionEnvironment: String, Codable, CaseIterable, Sendable, Identifiable {
    case local, development, testing, staging, production

    public var id: String { rawValue }

    public var displayName: String { rawValue.capitalized }

    /// Environments where writes need explicit confirmation.
    public var requiresWriteConfirmation: Bool { self == .production }
}

public enum SSLMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case disable, allow, prefer, require
    case verifyCA = "verify-ca"
    case verifyFull = "verify-full"

    public var id: String { rawValue }
}

/// Optional SSH tunnel: the database is reached through a local port forwarded by `ssh -L`.
public struct SSHTunnelConfig: Codable, Hashable, Sendable {
    public enum AuthMethod: String, Codable, CaseIterable, Sendable, Identifiable {
        case agent, privateKey, password

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .agent: "SSH agent"
            case .privateKey: "Private key"
            case .password: "Password"
            }
        }
    }

    public var isEnabled: Bool
    public var host: String
    public var port: Int
    public var user: String
    public var authMethod: AuthMethod
    /// Path to the private key (`~` allowed) when `authMethod == .privateKey`.
    public var privateKeyPath: String

    public init(isEnabled: Bool = false, host: String = "", port: Int = 22, user: String = "",
                authMethod: AuthMethod = .privateKey, privateKeyPath: String = "~/.ssh/id_ed25519") {
        self.isEnabled = isEnabled
        self.host = host
        self.port = port
        self.user = user
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            host: try c.decodeIfPresent(String.self, forKey: .host) ?? "",
            port: try c.decodeIfPresent(Int.self, forKey: .port) ?? 22,
            user: try c.decodeIfPresent(String.self, forKey: .user) ?? "",
            authMethod: try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .privateKey,
            privateKeyPath: try c.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? "~/.ssh/id_ed25519")
    }

    /// Whether enough is filled in to start a tunnel.
    public var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && (authMethod != .privateKey || !privateKeyPath.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}

public struct ConnectionConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: DatabaseKind
    public var environment: ConnectionEnvironment
    public var group: String
    public var host: String
    public var port: Int
    public var user: String
    public var database: String
    public var sslMode: SSLMode
    public var savePassword: Bool
    /// Server-enforced read-only sessions.
    public var readOnly: Bool
    /// Shown in the starred connections bar.
    public var isStarred: Bool
    /// SF Symbol shown for the connection; `nil` shows the name's initials.
    public var icon: String?
    public var ssh: SSHTunnelConfig
    /// Extra driver-specific connection options (e.g. libpq keywords).
    public var options: [String: String]

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: DatabaseKind = .postgres,
        environment: ConnectionEnvironment = .local,
        group: String = "",
        host: String = "localhost",
        port: Int? = nil,
        user: String? = nil,
        database: String = "",
        sslMode: SSLMode = .prefer,
        savePassword: Bool = true,
        readOnly: Bool = false,
        isStarred: Bool = false,
        icon: String? = nil,
        ssh: SSHTunnelConfig = SSHTunnelConfig(),
        options: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.environment = environment
        self.group = group
        self.host = host
        self.port = port ?? kind.defaultPort
        self.user = user ?? kind.defaultUser
        self.database = database
        self.sslMode = sslMode
        self.savePassword = savePassword
        self.readOnly = readOnly
        self.isStarred = isStarred
        self.icon = icon
        self.ssh = ssh
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(DatabaseKind.self, forKey: .kind) ?? .postgres
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            kind: kind,
            environment: try c.decodeIfPresent(ConnectionEnvironment.self, forKey: .environment) ?? .local,
            group: try c.decodeIfPresent(String.self, forKey: .group) ?? "",
            host: try c.decodeIfPresent(String.self, forKey: .host) ?? "localhost",
            port: try c.decodeIfPresent(Int.self, forKey: .port),
            user: try c.decodeIfPresent(String.self, forKey: .user),
            database: try c.decodeIfPresent(String.self, forKey: .database) ?? "",
            sslMode: try c.decodeIfPresent(SSLMode.self, forKey: .sslMode) ?? .prefer,
            savePassword: try c.decodeIfPresent(Bool.self, forKey: .savePassword) ?? true,
            readOnly: try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false,
            isStarred: try c.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false,
            icon: try c.decodeIfPresent(String.self, forKey: .icon),
            ssh: try c.decodeIfPresent(SSHTunnelConfig.self, forKey: .ssh) ?? SSHTunnelConfig(),
            options: try c.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
        )
    }

    public var displayName: String {
        name.isEmpty ? "\(user)@\(host)" : name
    }
}

// MARK: - Schema objects

public enum ObjectKind: String, Codable, CaseIterable, Sendable {
    case table, view, materializedView, foreignTable, function, procedure

    public var displayName: String {
        switch self {
        case .table: "Table"
        case .view: "View"
        case .materializedView: "Materialized View"
        case .foreignTable: "Foreign Table"
        case .function: "Function"
        case .procedure: "Procedure"
        }
    }

    /// Objects whose rows can be browsed.
    public var hasRows: Bool {
        switch self {
        case .table, .view, .materializedView, .foreignTable: true
        case .function, .procedure: false
        }
    }

    public var isRoutine: Bool { self == .function || self == .procedure }
}

public struct ObjectRef: Codable, Hashable, Sendable, CustomStringConvertible {
    public var schema: String
    public var name: String
    public var kind: ObjectKind
    /// Identity arguments for routines, used to disambiguate overloads.
    public var arguments: String?

    public init(schema: String, name: String, kind: ObjectKind, arguments: String? = nil) {
        self.schema = schema
        self.name = name
        self.kind = kind
        self.arguments = arguments
    }

    public var description: String {
        if let arguments { return "\(schema).\(name)(\(arguments))" }
        return "\(schema).\(name)"
    }
}

public struct SchemaObject: Identifiable, Hashable, Sendable {
    public var ref: ObjectRef
    public var comment: String?
    /// Return type for routines.
    public var returnType: String?

    public var id: ObjectRef { ref }
    public var name: String { ref.name }
    public var kind: ObjectKind { ref.kind }

    public init(ref: ObjectRef, comment: String? = nil, returnType: String? = nil) {
        self.ref = ref
        self.comment = comment
        self.returnType = returnType
    }
}

// MARK: - Structure

public struct ColumnInfo: Identifiable, Hashable, Sendable {
    public var name: String
    public var dataType: String
    public var isNullable: Bool
    public var defaultValue: String?
    public var comment: String?
    public var ordinal: Int
    public var isPrimaryKey: Bool
    /// Identity or generated column; not writable directly.
    public var isGenerated: Bool
    /// Identity column (GENERATED ... AS IDENTITY).
    public var isIdentity: Bool
    /// Closed set of valid values (enum labels, or a CHECK ... IN list), if any.
    public var allowedValues: [String]?

    public var id: String { name }

    public init(name: String, dataType: String, isNullable: Bool = true, defaultValue: String? = nil,
                comment: String? = nil, ordinal: Int = 0, isPrimaryKey: Bool = false, isGenerated: Bool = false,
                isIdentity: Bool = false, allowedValues: [String]? = nil) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.comment = comment
        self.ordinal = ordinal
        self.isPrimaryKey = isPrimaryKey
        self.isGenerated = isGenerated
        self.isIdentity = isIdentity
        self.allowedValues = allowedValues
    }
}

public struct IndexInfo: Identifiable, Hashable, Sendable {
    public var name: String
    public var columns: [String]
    public var isUnique: Bool
    public var isPrimary: Bool
    public var method: String
    public var definition: String
    /// Set when the index backs a constraint (primary key, unique, exclusion).
    public var constraintName: String?

    public var id: String { name }

    public init(name: String, columns: [String], isUnique: Bool, isPrimary: Bool, method: String,
                definition: String, constraintName: String? = nil) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.method = method
        self.definition = definition
        self.constraintName = constraintName
    }
}

public enum ConstraintType: String, Codable, Sendable {
    case primaryKey, foreignKey, unique, check, exclusion, other

    public var displayName: String {
        switch self {
        case .primaryKey: "PRIMARY KEY"
        case .foreignKey: "FOREIGN KEY"
        case .unique: "UNIQUE"
        case .check: "CHECK"
        case .exclusion: "EXCLUDE"
        case .other: "OTHER"
        }
    }
}

public struct ConstraintInfo: Identifiable, Hashable, Sendable {
    public var name: String
    public var type: ConstraintType
    public var definition: String

    public var id: String { name }

    public init(name: String, type: ConstraintType, definition: String) {
        self.name = name
        self.type = type
        self.definition = definition
    }
}

public struct ForeignKeyInfo: Identifiable, Hashable, Sendable {
    public var name: String
    public var table: ObjectRef
    public var columns: [String]
    public var referencedTable: ObjectRef
    public var referencedColumns: [String]
    public var onUpdate: String
    public var onDelete: String

    public var id: String { "\(table).\(name)" }

    public init(name: String, table: ObjectRef, columns: [String], referencedTable: ObjectRef,
                referencedColumns: [String], onUpdate: String = "NO ACTION", onDelete: String = "NO ACTION") {
        self.name = name
        self.table = table
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }
}

public struct TableStructure: Sendable {
    public var ref: ObjectRef
    public var columns: [ColumnInfo]
    public var indexes: [IndexInfo]
    public var constraints: [ConstraintInfo]
    public var comment: String?

    public init(ref: ObjectRef, columns: [ColumnInfo], indexes: [IndexInfo] = [],
                constraints: [ConstraintInfo] = [], comment: String? = nil) {
        self.ref = ref
        self.columns = columns
        self.indexes = indexes
        self.constraints = constraints
        self.comment = comment
    }

    public var primaryKey: [String] {
        columns.filter(\.isPrimaryKey).map(\.name)
    }
}

/// An object that depends on another (e.g. a view selecting from a table).
public struct DependencyInfo: Identifiable, Hashable, Sendable {
    public var object: ObjectRef
    public var dependencyType: String

    public var id: String { "\(object.kind.rawValue):\(object)" }

    public init(object: ObjectRef, dependencyType: String) {
        self.object = object
        self.dependencyType = dependencyType
    }
}

public struct TableRelations: Sendable {
    /// Foreign keys declared on this table.
    public var outgoing: [ForeignKeyInfo]
    /// Foreign keys on other tables that reference this table.
    public var incoming: [ForeignKeyInfo]
    /// Objects that depend on this one.
    public var dependents: [DependencyInfo]
    /// Objects this one depends on (e.g. tables a view reads).
    public var dependencies: [DependencyInfo]

    public init(outgoing: [ForeignKeyInfo] = [], incoming: [ForeignKeyInfo] = [],
                dependents: [DependencyInfo] = [], dependencies: [DependencyInfo] = []) {
        self.outgoing = outgoing
        self.incoming = incoming
        self.dependents = dependents
        self.dependencies = dependencies
    }
}

// MARK: - Query results

public enum ValueCategory: Sendable {
    case number, boolean, text, temporal, json, binary, other
}

public struct ResultColumn: Hashable, Sendable {
    public var name: String
    public var typeName: String
    public var category: ValueCategory

    public init(name: String, typeName: String, category: ValueCategory) {
        self.name = name
        self.typeName = typeName
        self.category = category
    }
}

public struct QueryResult: Identifiable, Sendable {
    public let id = UUID()
    public var columns: [ResultColumn]
    public var rows: [[String?]]
    public var commandTag: String
    public var rowsAffected: Int?
    /// True when the row limit was hit and further rows were discarded.
    public var truncated: Bool
    public var statement: String?

    public init(columns: [ResultColumn] = [], rows: [[String?]] = [], commandTag: String = "",
                rowsAffected: Int? = nil, truncated: Bool = false, statement: String? = nil) {
        self.columns = columns
        self.rows = rows
        self.commandTag = commandTag
        self.rowsAffected = rowsAffected
        self.truncated = truncated
        self.statement = statement
    }

    public var returnsRows: Bool { !columns.isEmpty }
}

public enum TransactionStatus: Sendable, Equatable {
    case idle, active, inTransaction, failedTransaction, unknown

    public var isInTransaction: Bool { self == .inTransaction || self == .failedTransaction }
}

public struct ExecutionResult: Sendable {
    public var results: [QueryResult]
    public var error: DatabaseError?
    public var notices: [String]
    public var duration: TimeInterval
    public var transactionStatus: TransactionStatus

    public init(results: [QueryResult] = [], error: DatabaseError? = nil, notices: [String] = [],
                duration: TimeInterval = 0, transactionStatus: TransactionStatus = .unknown) {
        self.results = results
        self.error = error
        self.notices = notices
        self.duration = duration
        self.transactionStatus = transactionStatus
    }
}

public struct DatabaseError: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public var detail: String?
    public var hint: String?
    public var sqlState: String?
    /// 1-based character offset into the statement, when reported by the server.
    public var position: Int?

    public init(_ message: String, detail: String? = nil, hint: String? = nil, sqlState: String? = nil, position: Int? = nil) {
        self.message = message
        self.detail = detail
        self.hint = hint
        self.sqlState = sqlState
        self.position = position
    }

    public var errorDescription: String? { message }

    public var fullDescription: String {
        var parts = [message]
        if let detail, !detail.isEmpty { parts.append("DETAIL: \(detail)") }
        if let hint, !hint.isEmpty { parts.append("HINT: \(hint)") }
        return parts.joined(separator: "\n")
    }
}
