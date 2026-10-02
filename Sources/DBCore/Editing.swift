import Foundation

// MARK: - Browsing rows

public enum FilterOperator: String, CaseIterable, Codable, Sendable, Identifiable {
    case equals = "="
    case notEquals = "<>"
    case less = "<"
    case greater = ">"
    case lessOrEqual = "<="
    case greaterOrEqual = ">="
    case contains = "contains"
    case notContains = "not contains"
    case startsWith = "starts with"
    case endsWith = "ends with"
    case like = "LIKE"
    case notLike = "NOT LIKE"
    case inList = "IN"
    case notInList = "NOT IN"
    case isNull = "IS NULL"
    case isNotNull = "IS NOT NULL"
    case rawSQL = "SQL"

    public var id: String { rawValue }

    public var takesValue: Bool { self != .isNull && self != .isNotNull }
}

public struct RowFilter: Identifiable, Hashable, Codable, Sendable {
    public var id = UUID()
    /// Column to filter on; `nil` means any column.
    public var column: String?
    public var op: FilterOperator
    public var value: String
    public var isEnabled: Bool

    public init(column: String? = nil, op: FilterOperator = .contains, value: String = "", isEnabled: Bool = true) {
        self.column = column
        self.op = op
        self.value = value
        self.isEnabled = isEnabled
    }
}

public struct SortKey: Hashable, Codable, Sendable {
    public var column: String
    public var ascending: Bool

    public init(column: String, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

public struct RowRequest: Hashable, Sendable {
    public var filters: [RowFilter]
    public var sort: [SortKey]
    public var limit: Int
    public var offset: Int
    /// All column names of the object, used for "any column" filters.
    public var columns: [String]

    public init(filters: [RowFilter] = [], sort: [SortKey] = [], limit: Int = 300, offset: Int = 0, columns: [String] = []) {
        self.filters = filters
        self.sort = sort
        self.limit = limit
        self.offset = offset
        self.columns = columns
    }
}

// MARK: - Row edits

public enum CellValue: Hashable, Sendable {
    case value(String)
    case null
    case defaultValue

    public init(_ string: String?) {
        self = string.map(CellValue.value) ?? .null
    }
}

public struct ColumnValue: Hashable, Sendable {
    public var column: String
    public var value: CellValue

    public init(_ column: String, _ value: CellValue) {
        self.column = column
        self.value = value
    }
}

/// A single staged change to a table row.
public enum RowChange: Hashable, Sendable {
    /// `key` identifies the row (primary key columns and their current values).
    case update(key: [ColumnValue], values: [ColumnValue])
    case insert(values: [ColumnValue])
    case delete(key: [ColumnValue])

    /// Number of rows the generated statement must affect.
    public var expectedRows: Int { 1 }
}

// MARK: - Schema edits

public struct ColumnDefinition: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var dataType: String
    public var isNullable: Bool
    /// Raw SQL expression, empty for none.
    public var defaultValue: String
    public var comment: String
    public var isPrimaryKey: Bool
    /// Name of the column in the database, `nil` for columns not yet created.
    public var originalName: String?

    public init(name: String = "", dataType: String = "text", isNullable: Bool = true, defaultValue: String = "",
                comment: String = "", isPrimaryKey: Bool = false, originalName: String? = nil) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.comment = comment
        self.isPrimaryKey = isPrimaryKey
        self.originalName = originalName
    }

    public init(_ info: ColumnInfo) {
        self.init(name: info.name, dataType: info.dataType, isNullable: info.isNullable,
                  defaultValue: info.defaultValue ?? "", comment: info.comment ?? "",
                  isPrimaryKey: info.isPrimaryKey, originalName: info.name)
    }
}

public struct IndexDefinition: Hashable, Sendable {
    public var name: String
    public var columns: [String]
    public var isUnique: Bool
    public var method: String

    public init(name: String, columns: [String], isUnique: Bool = false, method: String = "btree") {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.method = method
    }
}

public struct ForeignKeyDefinition: Hashable, Sendable {
    public var name: String
    public var columns: [String]
    public var referencedTable: ObjectRef
    public var referencedColumns: [String]
    public var onUpdate: String
    public var onDelete: String

    public init(name: String, columns: [String], referencedTable: ObjectRef, referencedColumns: [String],
                onUpdate: String = "NO ACTION", onDelete: String = "NO ACTION") {
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    public static let actions = ["NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"]
}

/// Changes to apply to an existing table, produced by diffing the structure editor
/// against the loaded structure.
public struct TableSchemaChange: Hashable, Sendable {
    public var table: ObjectRef
    public var original: [ColumnDefinition]
    public var columns: [ColumnDefinition]
    public var newIndexes: [IndexDefinition]
    public var droppedIndexes: [String]
    public var newForeignKeys: [ForeignKeyDefinition]
    public var droppedConstraints: [String]

    public init(table: ObjectRef, original: [ColumnDefinition], columns: [ColumnDefinition],
                newIndexes: [IndexDefinition] = [], droppedIndexes: [String] = [],
                newForeignKeys: [ForeignKeyDefinition] = [], droppedConstraints: [String] = []) {
        self.table = table
        self.original = original
        self.columns = columns
        self.newIndexes = newIndexes
        self.droppedIndexes = droppedIndexes
        self.newForeignKeys = newForeignKeys
        self.droppedConstraints = droppedConstraints
    }
}

public struct CreateTableRequest: Hashable, Sendable {
    public var schema: String
    public var name: String
    public var columns: [ColumnDefinition]
    public var comment: String

    public init(schema: String, name: String, columns: [ColumnDefinition], comment: String = "") {
        self.schema = schema
        self.name = name
        self.columns = columns
        self.comment = comment
    }
}

// MARK: - Dialect

/// Engine-specific SQL generation.
public protocol SQLDialect: Sendable {
    func quoteIdentifier(_ identifier: String) -> String
    func quoteLiteral(_ value: String) -> String
    func qualifiedName(_ ref: ObjectRef) -> String

    func selectStatement(for ref: ObjectRef, request: RowRequest) -> String
    /// `SELECT count(*)` honoring the request's filters.
    func countStatement(for ref: ObjectRef, request: RowRequest) -> String
    func filterExpression(_ filter: RowFilter, columns: [String]) -> String?

    func statement(for change: RowChange, in table: ObjectRef) -> String
    func statements(for change: TableSchemaChange) -> [String]
    func statements(for request: CreateTableRequest) -> [String]
    func dropStatement(for ref: ObjectRef, cascade: Bool) -> String
    func truncateStatement(for ref: ObjectRef, cascade: Bool) -> String

    /// Whether a statement may modify data or schema (used for production safety prompts).
    func isWriteStatement(_ sql: String) -> Bool

    /// Statements that move auto-increment sequences past the existing data, run after
    /// importing rows with explicit key values.
    func resetSequenceStatements(for structure: TableStructure) -> [String]

    var keywords: [String] { get }
    var functions: [String] { get }
    var dataTypes: [String] { get }
}

public extension SQLDialect {
    func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func quoteLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    func qualifiedName(_ ref: ObjectRef) -> String {
        quoteIdentifier(ref.schema) + "." + quoteIdentifier(ref.name)
    }

    func sqlValue(_ value: CellValue) -> String {
        switch value {
        case .value(let string): quoteLiteral(string)
        case .null: "NULL"
        case .defaultValue: "DEFAULT"
        }
    }

    func whereClause(_ key: [ColumnValue]) -> String {
        key.map { kv in
            switch kv.value {
            case .null, .defaultValue: "\(quoteIdentifier(kv.column)) IS NULL"
            case .value: "\(quoteIdentifier(kv.column)) = \(sqlValue(kv.value))"
            }
        }.joined(separator: " AND ")
    }

    func statement(for change: RowChange, in table: ObjectRef) -> String {
        let name = qualifiedName(table)
        switch change {
        case let .update(key, values):
            let assignments = values.map { "\(quoteIdentifier($0.column)) = \(sqlValue($0.value))" }
            return "UPDATE \(name) SET \(assignments.joined(separator: ", ")) WHERE \(whereClause(key));"
        case let .insert(values):
            let explicit = values.filter { $0.value != .defaultValue }
            if explicit.isEmpty { return "INSERT INTO \(name) DEFAULT VALUES;" }
            let cols = explicit.map { quoteIdentifier($0.column) }.joined(separator: ", ")
            let vals = explicit.map { sqlValue($0.value) }.joined(separator: ", ")
            return "INSERT INTO \(name) (\(cols)) VALUES (\(vals));"
        case let .delete(key):
            return "DELETE FROM \(name) WHERE \(whereClause(key));"
        }
    }

    func resetSequenceStatements(for structure: TableStructure) -> [String] { [] }

    func isWriteStatement(_ sql: String) -> Bool {
        let readOnly: Set<String> = ["SELECT", "SHOW", "EXPLAIN", "WITH", "VALUES", "TABLE", "BEGIN", "START",
                                     "COMMIT", "ROLLBACK", "END", "SET", "RESET", "DESCRIBE", "DESC"]
        for statement in SQLSplitter.split(sql) {
            guard let first = SQLLexer.firstKeyword(in: statement.text) else { continue }
            if !readOnly.contains(first) { return true }
            // Data-modifying CTEs, e.g. WITH x AS (DELETE ...).
            if first == "WITH" || first == "EXPLAIN" {
                let words = Set(SQLLexer.tokens(in: statement.text).compactMap { $0.kind == .keyword ? $0.text.uppercased() : nil })
                if !words.isDisjoint(with: ["INSERT", "UPDATE", "DELETE", "MERGE", "TRUNCATE", "DROP", "ALTER", "CREATE"]) {
                    return true
                }
            }
        }
        return false
    }
}
