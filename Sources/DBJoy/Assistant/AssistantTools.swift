import DBCore
import Foundation

/// Tool definitions the assistant can call, and the SQL checks behind them.
enum AssistantTools {
    static let listTables = "list_tables"
    static let describeTable = "describe_table"
    static let runQuery = "run_query"
    static let executeSQL = "execute_sql"
    static let openInEditor = "open_in_editor"

    static func specs(allowWrites: Bool) -> [ToolSpec] {
        var specs = [
            ToolSpec(name: listTables,
                     description: "List the tables, views and routines in a schema of the connected database.",
                     schema: object(["schema": string("Schema name. Defaults to the current schema.")], required: [])),
            ToolSpec(name: describeTable,
                     description: "Show a table's or view's columns (types, nullability, defaults, primary key), "
                        + "indexes, constraints and foreign keys.",
                     schema: object(["table": string("Table or view name."),
                                     "schema": string("Schema name. Defaults to the current schema.")],
                                    required: ["table"])),
            ToolSpec(name: runQuery,
                     description: "Run read-only SQL (SELECT, WITH, EXPLAIN, SHOW, VALUES) in a read-only transaction "
                        + "and return the rows. The user sees the full result in the chat. Use LIMIT when exploring.",
                     schema: object(["sql": string("The query to run.")], required: ["sql"])),
            ToolSpec(name: openInEditor,
                     description: "Open SQL in a new query tab of the editor, without running it, so the user can "
                        + "review, edit, run or save it. Use this when the user asks you to write a query.",
                     schema: object(["sql": string("The SQL to put in the editor."),
                                     "title": string("Short tab title, e.g. 'Top customers'.")],
                                    required: ["sql"])),
        ]
        if allowWrites {
            specs.append(ToolSpec(
                name: executeSQL,
                description: "Run SQL that changes data or schema (INSERT, UPDATE, DELETE, CREATE, ALTER, …) in a "
                    + "single transaction that is rolled back if any statement fails. The user may be asked to "
                    + "approve it first. Only use this when the user asked for the change.",
                schema: object(["sql": string("The statements to run."),
                                "summary": string("One sentence describing what the change does, shown to the user.")],
                               required: ["sql", "summary"])))
        }
        return specs
    }

    private static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    private static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }

    // MARK: SQL checks

    private static let readOnlyKeywords: Set<String> = ["SELECT", "WITH", "EXPLAIN", "SHOW", "VALUES", "TABLE"]
    private static let transactionKeywords: Set<String> = ["BEGIN", "START", "COMMIT", "ROLLBACK", "END", "ABORT",
                                                           "SAVEPOINT", "RELEASE", "PREPARE"]

    /// Why `sql` can't run as a read-only query, or nil. The query also runs in a read-only
    /// transaction, which catches writes hidden in CTEs, EXPLAIN ANALYZE or functions.
    static func readOnlyViolation(in sql: String) -> String? {
        let statements = SQLSplitter.split(sql)
        if statements.isEmpty { return "The query is empty." }
        for statement in statements {
            let keyword = SQLLexer.firstKeyword(in: statement.text) ?? ""
            if !readOnlyKeywords.contains(keyword) {
                return "run_query only runs read-only statements (SELECT, WITH, EXPLAIN, SHOW, VALUES); got \(keyword.isEmpty ? "an unknown statement" : keyword)."
            }
        }
        return nil
    }

    /// Why `sql` can't run inside the assistant's transaction, or nil.
    static func writeViolation(in sql: String) -> String? {
        let statements = SQLSplitter.split(sql)
        if statements.isEmpty { return "The SQL is empty." }
        for statement in statements {
            if let keyword = SQLLexer.firstKeyword(in: statement.text), transactionKeywords.contains(keyword) {
                return "Don't include transaction control (\(keyword)); execute_sql already runs everything in one transaction."
            }
        }
        return nil
    }

    // MARK: Formatting for the model

    static let maxRowsForModel = 100
    private static let maxCellLength = 300

    /// Rows as pipe-separated text, capped so large results don't flood the context.
    static func describe(_ result: QueryResult) -> String {
        guard result.returnsRows else {
            return result.commandTag + (result.rowsAffected.map { " (\($0) row(s) affected)" } ?? "")
        }
        let shown = result.rows.prefix(maxRowsForModel)
        var lines = ["\(result.rows.count)\(result.truncated ? "+" : "") row(s)"
                     + (shown.count < result.rows.count ? ", showing the first \(shown.count)" : "")]
        lines.append(result.columns.map { "\($0.name) (\($0.typeName))" }.joined(separator: " | "))
        for row in shown {
            lines.append(row.map { cell in
                guard let cell else { return "NULL" }
                let flat = cell.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "|", with: "\\|")
                return flat.count > maxCellLength ? String(flat.prefix(maxCellLength)) + "…" : flat
            }.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ structure: TableStructure, relations: TableRelations?) -> String {
        var lines = ["\(structure.ref.kind.displayName) \(structure.ref)"]
        if let comment = structure.comment, !comment.isEmpty { lines.append("Comment: \(comment)") }
        lines.append("Columns:")
        for column in structure.columns {
            var line = "- \(column.name) \(column.dataType)"
            if column.isPrimaryKey { line += " PRIMARY KEY" }
            if !column.isNullable { line += " NOT NULL" }
            if let value = column.defaultValue { line += " DEFAULT \(value)" }
            if column.isIdentity { line += " IDENTITY" }
            if column.isGenerated { line += " GENERATED" }
            if let values = column.allowedValues { line += " (one of: \(values.joined(separator: ", ")))" }
            if let comment = column.comment, !comment.isEmpty { line += " -- \(comment)" }
            lines.append(line)
        }
        let constraints = structure.constraints.filter { $0.type != .primaryKey && $0.type != .foreignKey }
        if !constraints.isEmpty {
            lines.append("Constraints:")
            lines += constraints.map { "- \($0.name): \($0.definition)" }
        }
        let indexes = structure.indexes.filter { !$0.isPrimary }
        if !indexes.isEmpty {
            lines.append("Indexes:")
            lines += indexes.map { "- \($0.definition)" }
        }
        if let relations {
            if !relations.outgoing.isEmpty {
                lines.append("References:")
                lines += relations.outgoing.map {
                    "- (\($0.columns.joined(separator: ", "))) → \($0.referencedTable)(\($0.referencedColumns.joined(separator: ", ")))"
                }
            }
            if !relations.incoming.isEmpty {
                lines.append("Referenced by:")
                lines += relations.incoming.map {
                    "- \($0.table)(\($0.columns.joined(separator: ", "))) → (\($0.referencedColumns.joined(separator: ", ")))"
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
