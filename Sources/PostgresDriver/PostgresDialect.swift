import DBCore
import Foundation

public struct PostgresDialect: SQLDialect {
    public init() {}

    // MARK: Browsing

    public func selectStatement(for ref: ObjectRef, request: RowRequest) -> String {
        var sql = "SELECT * FROM \(qualifiedName(ref))" + whereClause(for: request)
        if !request.sort.isEmpty {
            sql += " ORDER BY " + request.sort.map { "\(quoteIdentifier($0.column)) \($0.ascending ? "ASC" : "DESC")" }
                .joined(separator: ", ")
        }
        sql += " LIMIT \(request.limit)"
        if request.offset > 0 { sql += " OFFSET \(request.offset)" }
        return sql
    }

    public func countStatement(for ref: ObjectRef, request: RowRequest) -> String {
        "SELECT count(*) FROM \(qualifiedName(ref))" + whereClause(for: request)
    }

    private func whereClause(for request: RowRequest) -> String {
        let conditions = request.filters.filter(\.isEnabled).compactMap { filterExpression($0, columns: request.columns) }
        return conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
    }

    public func filterExpression(_ filter: RowFilter, columns: [String]) -> String? {
        if filter.op == .rawSQL {
            let raw = filter.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : "(\(raw))"
        }
        if let column = filter.column {
            return condition(column: column, op: filter.op, value: filter.value, compareAsText: false)
        }
        // Any column: match the text representation of every column.
        guard filter.op.takesValue, !filter.value.isEmpty, !columns.isEmpty else { return nil }
        let parts = columns.compactMap { condition(column: $0, op: filter.op, value: filter.value, compareAsText: true) }
        let negated: Set<FilterOperator> = [.notContains, .notEquals, .notLike, .notInList]
        return "(" + parts.joined(separator: negated.contains(filter.op) ? " AND " : " OR ") + ")"
    }

    private func condition(column: String, op: FilterOperator, value: String, compareAsText: Bool) -> String? {
        let col = quoteIdentifier(column)
        let text = "\(col)::text"
        switch op {
        case .equals, .notEquals, .less, .greater, .lessOrEqual, .greaterOrEqual:
            return "\(compareAsText ? text : col) \(op.rawValue) \(quoteLiteral(value))"
        case .contains: return "\(text) ILIKE \(quoteLiteral("%" + escapeLike(value) + "%"))"
        case .notContains: return "\(text) NOT ILIKE \(quoteLiteral("%" + escapeLike(value) + "%"))"
        case .startsWith: return "\(text) ILIKE \(quoteLiteral(escapeLike(value) + "%"))"
        case .endsWith: return "\(text) ILIKE \(quoteLiteral("%" + escapeLike(value)))"
        case .like: return "\(text) LIKE \(quoteLiteral(value))"
        case .notLike: return "\(text) NOT LIKE \(quoteLiteral(value))"
        case .inList, .notInList:
            let items = value.split(separator: ",").map { quoteLiteral($0.trimmingCharacters(in: .whitespaces)) }
            guard !items.isEmpty else { return nil }
            return "\(compareAsText ? text : col) \(op == .inList ? "IN" : "NOT IN") (\(items.joined(separator: ", ")))"
        case .isNull: return "\(col) IS NULL"
        case .isNotNull: return "\(col) IS NOT NULL"
        case .rawSQL: return nil
        }
    }

    private func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: Schema changes

    public func statements(for change: TableSchemaChange) -> [String] {
        let table = qualifiedName(change.table)
        var statements: [String] = []
        let originals = Dictionary(change.original.compactMap { c in c.originalName.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        let keptNames = Set(change.columns.compactMap(\.originalName))

        for constraint in change.droppedConstraints {
            statements.append("ALTER TABLE \(table) DROP CONSTRAINT \(quoteIdentifier(constraint));")
        }
        for index in change.droppedIndexes {
            statements.append("DROP INDEX \(quoteIdentifier(change.table.schema)).\(quoteIdentifier(index));")
        }
        for original in change.original where !keptNames.contains(original.originalName ?? "") {
            statements.append("ALTER TABLE \(table) DROP COLUMN \(quoteIdentifier(original.originalName ?? original.name));")
        }

        for column in change.columns {
            let name = column.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let col = quoteIdentifier(name)
            guard let originalName = column.originalName, let original = originals[originalName] else {
                // New column.
                var def = "ALTER TABLE \(table) ADD COLUMN \(col) \(column.dataType)"
                if !column.defaultValue.isEmpty { def += " DEFAULT \(column.defaultValue)" }
                if !column.isNullable { def += " NOT NULL" }
                statements.append(def + ";")
                if !column.comment.isEmpty {
                    statements.append("COMMENT ON COLUMN \(table).\(col) IS \(quoteLiteral(column.comment));")
                }
                continue
            }
            if name != originalName {
                statements.append("ALTER TABLE \(table) RENAME COLUMN \(quoteIdentifier(originalName)) TO \(col);")
            }
            if column.dataType.trimmingCharacters(in: .whitespaces) != original.dataType {
                statements.append("ALTER TABLE \(table) ALTER COLUMN \(col) TYPE \(column.dataType) USING \(col)::\(column.dataType);")
            }
            if column.isNullable != original.isNullable {
                statements.append("ALTER TABLE \(table) ALTER COLUMN \(col) \(column.isNullable ? "DROP" : "SET") NOT NULL;")
            }
            if column.defaultValue != original.defaultValue {
                statements.append(column.defaultValue.isEmpty
                    ? "ALTER TABLE \(table) ALTER COLUMN \(col) DROP DEFAULT;"
                    : "ALTER TABLE \(table) ALTER COLUMN \(col) SET DEFAULT \(column.defaultValue);")
            }
            if column.comment != original.comment {
                statements.append("COMMENT ON COLUMN \(table).\(col) IS \(column.comment.isEmpty ? "NULL" : quoteLiteral(column.comment));")
            }
        }

        for index in change.newIndexes {
            let cols = index.columns.map(quoteIdentifier).joined(separator: ", ")
            let name = index.name.isEmpty ? "" : quoteIdentifier(index.name) + " "
            statements.append("CREATE \(index.isUnique ? "UNIQUE " : "")INDEX \(name)ON \(table) USING \(index.method) (\(cols));")
        }
        for fk in change.newForeignKeys {
            statements.append(foreignKeyClause(fk, table: table))
        }
        return statements
    }

    private func foreignKeyClause(_ fk: ForeignKeyDefinition, table: String) -> String {
        let name = fk.name.isEmpty ? "" : "CONSTRAINT \(quoteIdentifier(fk.name)) "
        return "ALTER TABLE \(table) ADD \(name)FOREIGN KEY (\(fk.columns.map(quoteIdentifier).joined(separator: ", "))) "
            + "REFERENCES \(qualifiedName(fk.referencedTable)) (\(fk.referencedColumns.map(quoteIdentifier).joined(separator: ", "))) "
            + "ON UPDATE \(fk.onUpdate) ON DELETE \(fk.onDelete);"
    }

    public func statements(for request: CreateTableRequest) -> [String] {
        let table = quoteIdentifier(request.schema) + "." + quoteIdentifier(request.name)
        let columns = request.columns.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        var lines = columns.map { column -> String in
            var def = "  \(quoteIdentifier(column.name)) \(column.dataType)"
            if !column.defaultValue.isEmpty { def += " DEFAULT \(column.defaultValue)" }
            if !column.isNullable { def += " NOT NULL" }
            return def
        }
        let pk = columns.filter(\.isPrimaryKey).map { quoteIdentifier($0.name) }
        if !pk.isEmpty { lines.append("  PRIMARY KEY (\(pk.joined(separator: ", ")))") }
        var statements = ["CREATE TABLE \(table) (\n\(lines.joined(separator: ",\n"))\n);"]
        if !request.comment.isEmpty {
            statements.append("COMMENT ON TABLE \(table) IS \(quoteLiteral(request.comment));")
        }
        for column in columns where !column.comment.isEmpty {
            statements.append("COMMENT ON COLUMN \(table).\(quoteIdentifier(column.name)) IS \(quoteLiteral(column.comment));")
        }
        return statements
    }

    public func dropStatement(for ref: ObjectRef, cascade: Bool) -> String {
        let suffix = cascade ? " CASCADE;" : ";"
        switch ref.kind {
        case .table: return "DROP TABLE \(qualifiedName(ref))" + suffix
        case .view: return "DROP VIEW \(qualifiedName(ref))" + suffix
        case .materializedView: return "DROP MATERIALIZED VIEW \(qualifiedName(ref))" + suffix
        case .foreignTable: return "DROP FOREIGN TABLE \(qualifiedName(ref))" + suffix
        case .function: return "DROP FUNCTION \(qualifiedName(ref))(\(ref.arguments ?? ""))" + suffix
        case .procedure: return "DROP PROCEDURE \(qualifiedName(ref))(\(ref.arguments ?? ""))" + suffix
        }
    }

    public func resetSequenceStatements(for structure: TableStructure) -> [String] {
        let table = qualifiedName(structure.ref)
        return structure.columns
            .filter { $0.isIdentity || ($0.defaultValue?.contains("nextval(") ?? false) }
            .map { column in
                let col = quoteIdentifier(column.name)
                return "SELECT setval(pg_get_serial_sequence(\(quoteLiteral(table)), \(quoteLiteral(column.name))), "
                    + "COALESCE(MAX(\(col)), 1), MAX(\(col)) IS NOT NULL) FROM \(table);"
            }
    }

    public func truncateStatement(for ref: ObjectRef, cascade: Bool) -> String {
        "TRUNCATE TABLE \(qualifiedName(ref))\(cascade ? " CASCADE" : "");"
    }

    // MARK: Vocabulary

    public var keywords: [String] { SQLKeywords.list }

    public var functions: [String] {
        ["abs", "age", "array_agg", "array_length", "avg", "bool_and", "bool_or", "cast", "ceil", "coalesce",
         "concat", "concat_ws", "count", "current_date", "current_timestamp", "date_part", "date_trunc",
         "extract", "floor", "format", "gen_random_uuid", "generate_series", "greatest", "json_agg",
         "json_build_object", "jsonb_agg", "jsonb_build_object", "jsonb_set", "least", "left", "length",
         "lower", "lpad", "ltrim", "max", "min", "now", "nullif", "random", "regexp_replace", "replace",
         "right", "round", "row_number", "rank", "dense_rank", "lag", "lead", "rpad", "rtrim", "split_part",
         "string_agg", "substring", "sum", "to_char", "to_date", "to_timestamp", "trim", "unnest", "upper"]
    }

    public var dataTypes: [String] {
        ["bigint", "bigserial", "boolean", "bytea", "char(1)", "character varying(255)", "cidr", "date",
         "double precision", "inet", "integer", "interval", "json", "jsonb", "macaddr", "money", "numeric",
         "numeric(10,2)", "real", "serial", "smallint", "text", "time", "time with time zone",
         "timestamp without time zone", "timestamp with time zone", "tsvector", "uuid", "xml",
         "integer[]", "text[]"]
    }
}
