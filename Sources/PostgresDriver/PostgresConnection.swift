import DBCore
import Foundation

public struct PostgresDriver: DatabaseDriver {
    public init() {}

    public var kind: DatabaseKind { .postgres }

    public func connect(_ config: ConnectionConfig, password: String?, database: String?) async throws -> any DatabaseConnection {
        var dbname = database ?? config.database
        if dbname.isEmpty { dbname = "postgres" }
        var parameters = config.options
        parameters["host"] = config.host.isEmpty ? "localhost" : config.host
        parameters["port"] = String(config.port)
        parameters["user"] = config.user
        parameters["dbname"] = dbname
        parameters["sslmode"] = config.sslMode.rawValue
        parameters["application_name"] = parameters["application_name"] ?? "DBJoy"
        parameters["connect_timeout"] = parameters["connect_timeout"] ?? "10"
        if let password, !password.isEmpty { parameters["password"] = password }
        if config.readOnly {
            parameters["options"] = ((parameters["options"] ?? "") + " -c default_transaction_read_only=on")
                .trimmingCharacters(in: .whitespaces)
        }
        let pg = try await PGConnection.open(parameters: parameters)
        return PostgresConnection(pg: pg, databaseName: dbname)
    }
}

public final class PostgresConnection: DatabaseConnection {
    private let pg: PGConnection
    public let databaseName: String
    public let dialect: any SQLDialect = PostgresDialect()

    init(pg: PGConnection, databaseName: String) {
        self.pg = pg
        self.databaseName = databaseName
    }

    public var kind: DatabaseKind { .postgres }
    public var serverVersion: String { pg.serverVersion }

    // MARK: Execution

    public func execute(_ sql: String, maxRows: Int) async -> ExecutionResult {
        do {
            return try await pg.perform { pg, conn in pg.executeScript(conn, sql: sql, maxRows: maxRows) }
        } catch {
            return ExecutionResult(error: error as? DatabaseError ?? DatabaseError(error.localizedDescription))
        }
    }

    public func query(_ sql: String, parameters: [String?]) async throws -> QueryResult {
        try await pg.perform { pg, conn in try pg.exec(conn, sql, parameters: parameters) }
    }

    public func executeInTransaction(_ statements: [TransactionStatement]) async throws {
        try await pg.perform { pg, conn in try pg.runTransaction(conn, statements) }
    }

    public func transactionStatus() async -> TransactionStatus {
        (try? await pg.perform { pg, conn in pg.transactionStatus(conn) }) ?? .unknown
    }

    public func cancel() { pg.cancel() }

    public func close() async { await pg.close() }

    // MARK: Introspection

    public func listDatabases() async throws -> [String] {
        try await query("SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname")
            .rows.compactMap { $0[0] }
    }

    public func listSchemas() async throws -> [String] {
        try await query("""
            SELECT nspname FROM pg_namespace
            WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'
            ORDER BY nspname
            """).rows.compactMap { $0[0] }
    }

    public func defaultSchema() async throws -> String {
        try await query("SELECT current_schema()").rows.first?.first.flatMap { $0 } ?? "public"
    }

    public func listObjects(schema: String) async throws -> [SchemaObject] {
        let relations = try await query("""
            SELECT c.relname, c.relkind::text, obj_description(c.oid, 'pg_class')
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
            ORDER BY c.relname
            """, parameters: [schema])
        let routines = try await query("""
            SELECT p.proname, pg_get_function_identity_arguments(p.oid), p.prokind::text,
                   pg_get_function_result(p.oid), obj_description(p.oid, 'pg_proc')
            FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = $1 AND p.prokind IN ('f', 'p')
              AND NOT EXISTS (SELECT 1 FROM pg_depend d
                              WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
            ORDER BY p.proname, 2
            """, parameters: [schema])

        var objects = relations.rows.compactMap { row -> SchemaObject? in
            guard let name = row[0], let kind = row[1].flatMap(Self.relationKind) else { return nil }
            return SchemaObject(ref: ObjectRef(schema: schema, name: name, kind: kind), comment: row[2])
        }
        objects += routines.rows.compactMap { row -> SchemaObject? in
            guard let name = row[0] else { return nil }
            let kind: ObjectKind = row[2] == "p" ? .procedure : .function
            return SchemaObject(ref: ObjectRef(schema: schema, name: name, kind: kind, arguments: row[1] ?? ""),
                                comment: row[4], returnType: row[3])
        }
        return objects
    }

    static func relationKind(_ relkind: String) -> ObjectKind? {
        switch relkind {
        case "r", "p": .table
        case "v": .view
        case "m": .materializedView
        case "f": .foreignTable
        default: nil
        }
    }

    private func regclass(_ ref: ObjectRef) -> String {
        dialect.qualifiedName(ref)
    }

    public func structure(of ref: ObjectRef) async throws -> TableStructure {
        let rel = regclass(ref)
        let columns = try await query("""
            SELECT a.attname, format_type(a.atttypid, a.atttypmod), NOT a.attnotnull,
                   CASE a.attidentity
                     WHEN 'a' THEN 'GENERATED ALWAYS AS IDENTITY'
                     WHEN 'd' THEN 'GENERATED BY DEFAULT AS IDENTITY'
                     ELSE pg_get_expr(d.adbin, d.adrelid) END,
                   col_description(a.attrelid, a.attnum), a.attnum,
                   EXISTS (SELECT 1 FROM pg_index i
                           WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY(i.indkey)),
                   a.attidentity = 'a' OR a.attgenerated <> '',
                   (SELECT array_to_string(ARRAY(SELECT e.enumlabel FROM pg_enum e
                                                 WHERE e.enumtypid = CASE t.typtype WHEN 'd' THEN t.typbasetype ELSE t.oid END
                                                 ORDER BY e.enumsortorder), E'\\x1f')),
                   (SELECT pg_get_constraintdef(c.oid, true) FROM pg_constraint c
                    WHERE c.conrelid = a.attrelid AND c.contype = 'c' AND c.conkey = ARRAY[a.attnum]
                    ORDER BY c.conname LIMIT 1),
                   a.attidentity <> ''
            FROM pg_attribute a
            JOIN pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = $1::regclass AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """, parameters: [rel])
        let indexes = try await query("""
            SELECT i.relname, ix.indisunique, ix.indisprimary, am.amname, pg_get_indexdef(ix.indexrelid),
                   array_to_string(ARRAY(SELECT pg_get_indexdef(ix.indexrelid, k, true)
                                         FROM generate_series(1, ix.indnkeyatts) k), E'\\x1f'),
                   con.conname
            FROM pg_index ix
            JOIN pg_class i ON i.oid = ix.indexrelid
            JOIN pg_am am ON am.oid = i.relam
            LEFT JOIN pg_constraint con ON con.conindid = ix.indexrelid AND con.conrelid = ix.indrelid
                                       AND con.contype IN ('p', 'u', 'x')
            WHERE ix.indrelid = $1::regclass
            ORDER BY ix.indisprimary DESC, i.relname
            """, parameters: [rel])
        let constraints = try await query("""
            SELECT conname, contype::text, pg_get_constraintdef(oid, true)
            FROM pg_constraint WHERE conrelid = $1::regclass
            ORDER BY CASE contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'f' THEN 2 ELSE 3 END, conname
            """, parameters: [rel])
        let comment = try await query("SELECT obj_description($1::regclass, 'pg_class')", parameters: [rel])

        return TableStructure(
            ref: ref,
            columns: columns.rows.map { row in
                ColumnInfo(name: row[0] ?? "", dataType: row[1] ?? "", isNullable: row[2] == "true",
                           defaultValue: row[3], comment: row[4], ordinal: Int(row[5] ?? "") ?? 0,
                           isPrimaryKey: row[6] == "true", isGenerated: row[7] == "true",
                           isIdentity: row[10] == "true",
                           allowedValues: Self.allowedValues(enumLabels: row[8], checkDefinition: row[9]))
            },
            indexes: indexes.rows.map { row in
                IndexInfo(name: row[0] ?? "", columns: (row[5] ?? "").split(separator: "\u{1f}").map(String.init),
                          isUnique: row[1] == "true", isPrimary: row[2] == "true", method: row[3] ?? "",
                          definition: row[4] ?? "", constraintName: row[6])
            },
            constraints: constraints.rows.map { row in
                ConstraintInfo(name: row[0] ?? "", type: Self.constraintType(row[1] ?? ""), definition: row[2] ?? "")
            },
            comment: comment.rows.first?.first.flatMap { $0 }
        )
    }

    static func allowedValues(enumLabels: String?, checkDefinition: String?) -> [String]? {
        if let enumLabels, !enumLabels.isEmpty {
            return enumLabels.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        }
        return checkDefinition.flatMap(checkConstraintValues)
    }

    /// Extracts the value list from a single-column check such as `CHECK (status IN ('a', 'b'))`,
    /// which Postgres reports as `CHECK (status = ANY (ARRAY['a'::text, 'b'::text]))`.
    public static func checkConstraintValues(_ definition: String) -> [String]? {
        guard let arrayStart = definition.range(of: "= ANY (ARRAY["),
              let arrayEnd = definition.range(of: "])", options: .backwards),
              arrayStart.upperBound < arrayEnd.lowerBound else { return nil }
        // Anything beyond a plain list (AND/OR, other conditions) isn't a closed set.
        let prefix = definition[..<arrayStart.lowerBound]
        if prefix.range(of: " AND ", options: .caseInsensitive) != nil || prefix.range(of: " OR ", options: .caseInsensitive) != nil {
            return nil
        }
        var values: [String] = []
        for token in SQLLexer.tokens(in: String(definition[arrayStart.upperBound..<arrayEnd.lowerBound])) {
            switch token.kind {
            case .string:
                guard token.text.hasPrefix("'") else { return nil }
                values.append(String(token.text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
            case .number:
                values.append(token.text)
            case .punctuation, .op, .identifier, .keyword:
                continue // separators and ::type casts
            default:
                return nil
            }
        }
        return values.isEmpty ? nil : values
    }

    static func constraintType(_ contype: String) -> ConstraintType {
        switch contype {
        case "p": .primaryKey
        case "f": .foreignKey
        case "u": .unique
        case "c": .check
        case "x": .exclusion
        default: .other
        }
    }

    public func definition(of ref: ObjectRef) async throws -> String {
        switch ref.kind {
        case .view, .materializedView:
            let def = try await query("SELECT pg_get_viewdef($1::regclass, true)", parameters: [regclass(ref)])
                .rows.first?.first.flatMap { $0 } ?? ""
            let create = ref.kind == .view ? "CREATE OR REPLACE VIEW" : "CREATE MATERIALIZED VIEW"
            return "\(create) \(regclass(ref)) AS\n\(def)"
        case .function, .procedure:
            let result = try await query("""
                SELECT pg_get_functiondef(p.oid)
                FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = $1 AND p.proname = $2 AND pg_get_function_identity_arguments(p.oid) = $3
                """, parameters: [ref.schema, ref.name, ref.arguments ?? ""])
            return result.rows.first?.first.flatMap { $0 } ?? ""
        case .table, .foreignTable:
            return tableDDL(try await structure(of: ref))
        }
    }

    private func tableDDL(_ structure: TableStructure) -> String {
        let d = dialect
        let table = d.qualifiedName(structure.ref)
        var lines = structure.columns.map { column -> String in
            var line = "  \(d.quoteIdentifier(column.name)) \(column.dataType)"
            if let def = column.defaultValue {
                line += def.hasPrefix("GENERATED") ? " \(def)" : " DEFAULT \(def)"
            }
            if !column.isNullable { line += " NOT NULL" }
            return line
        }
        lines += structure.constraints.map { "  CONSTRAINT \(d.quoteIdentifier($0.name)) \($0.definition)" }
        var ddl = "CREATE TABLE \(table) (\n\(lines.joined(separator: ",\n"))\n);"
        for index in structure.indexes where index.constraintName == nil {
            ddl += "\n\n\(index.definition);"
        }
        if let comment = structure.comment {
            ddl += "\n\nCOMMENT ON TABLE \(table) IS \(d.quoteLiteral(comment));"
        }
        for column in structure.columns {
            if let comment = column.comment {
                ddl += "\nCOMMENT ON COLUMN \(table).\(d.quoteIdentifier(column.name)) IS \(d.quoteLiteral(comment));"
            }
        }
        return ddl
    }

    // MARK: Relationships

    private static let foreignKeySelect = """
        SELECT con.conname, sn.nspname, sc.relname, tn.nspname, tc.relname,
               array_to_string(ARRAY(SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY k(n, o)
                                     JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.n
                                     ORDER BY k.o), E'\\x1f'),
               array_to_string(ARRAY(SELECT a.attname FROM unnest(con.confkey) WITH ORDINALITY k(n, o)
                                     JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.n
                                     ORDER BY k.o), E'\\x1f'),
               con.confupdtype::text, con.confdeltype::text
        FROM pg_constraint con
        JOIN pg_class sc ON sc.oid = con.conrelid JOIN pg_namespace sn ON sn.oid = sc.relnamespace
        JOIN pg_class tc ON tc.oid = con.confrelid JOIN pg_namespace tn ON tn.oid = tc.relnamespace
        WHERE con.contype = 'f'
        """

    private func foreignKeys(where condition: String, parameter: String) async throws -> [ForeignKeyInfo] {
        let result = try await query(Self.foreignKeySelect + " AND " + condition + " ORDER BY sc.relname, con.conname",
                                     parameters: [parameter])
        return result.rows.map { row in
            ForeignKeyInfo(
                name: row[0] ?? "",
                table: ObjectRef(schema: row[1] ?? "", name: row[2] ?? "", kind: .table),
                columns: (row[5] ?? "").split(separator: "\u{1f}").map(String.init),
                referencedTable: ObjectRef(schema: row[3] ?? "", name: row[4] ?? "", kind: .table),
                referencedColumns: (row[6] ?? "").split(separator: "\u{1f}").map(String.init),
                onUpdate: Self.foreignKeyAction(row[7]), onDelete: Self.foreignKeyAction(row[8]))
        }
    }

    static func foreignKeyAction(_ code: String?) -> String {
        switch code {
        case "r": "RESTRICT"
        case "c": "CASCADE"
        case "n": "SET NULL"
        case "d": "SET DEFAULT"
        default: "NO ACTION"
        }
    }

    public func foreignKeys(schema: String) async throws -> [ForeignKeyInfo] {
        try await foreignKeys(where: "sn.nspname = $1", parameter: schema)
    }

    public func relations(of ref: ObjectRef) async throws -> TableRelations {
        guard !ref.kind.isRoutine else { return TableRelations() }
        let rel = regclass(ref)
        let outgoing = try await foreignKeys(where: "con.conrelid = $1::regclass", parameter: rel)
        let incoming = try await foreignKeys(where: "con.confrelid = $1::regclass", parameter: rel)
        let dependents = try await query("""
            SELECT DISTINCT vn.nspname, v.relname, v.relkind::text
            FROM pg_depend d
            JOIN pg_rewrite r ON r.oid = d.objid
            JOIN pg_class v ON v.oid = r.ev_class
            JOIN pg_namespace vn ON vn.oid = v.relnamespace
            WHERE d.classid = 'pg_rewrite'::regclass AND d.refclassid = 'pg_class'::regclass
              AND d.refobjid = $1::regclass AND v.oid <> $1::regclass
            ORDER BY 1, 2
            """, parameters: [rel])
        let dependencies = try await query("""
            SELECT DISTINCT tn.nspname, t.relname, t.relkind::text
            FROM pg_rewrite r
            JOIN pg_depend d ON d.objid = r.oid AND d.classid = 'pg_rewrite'::regclass
                            AND d.refclassid = 'pg_class'::regclass
            JOIN pg_class t ON t.oid = d.refobjid
            JOIN pg_namespace tn ON tn.oid = t.relnamespace
            WHERE r.ev_class = $1::regclass AND t.oid <> $1::regclass
            ORDER BY 1, 2
            """, parameters: [rel])

        func deps(_ result: QueryResult, _ type: String) -> [DependencyInfo] {
            result.rows.compactMap { row in
                guard let schema = row[0], let name = row[1], let kind = row[2].flatMap(Self.relationKind) else { return nil }
                return DependencyInfo(object: ObjectRef(schema: schema, name: name, kind: kind), dependencyType: type)
            }
        }
        return TableRelations(outgoing: outgoing, incoming: incoming,
                              dependents: deps(dependents, "uses this"),
                              dependencies: deps(dependencies, "used by this"))
    }

    public func columnsByTable(schema: String) async throws -> [String: [ColumnInfo]] {
        let result = try await query("""
            SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod), NOT a.attnotnull, a.attnum,
                   EXISTS (SELECT 1 FROM pg_index i
                           WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY(i.indkey))
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY c.relname, a.attnum
            """, parameters: [schema])
        var map: [String: [ColumnInfo]] = [:]
        for row in result.rows {
            guard let table = row[0], let name = row[1] else { continue }
            map[table, default: []].append(ColumnInfo(name: name, dataType: row[2] ?? "", isNullable: row[3] == "true",
                                                      ordinal: Int(row[4] ?? "") ?? 0, isPrimaryKey: row[5] == "true"))
        }
        return map
    }

    // MARK: Data

    public func fetchRows(of ref: ObjectRef, request: RowRequest) async throws -> QueryResult {
        try await query(dialect.selectStatement(for: ref, request: request))
    }

    public func streamRows(of refs: [ObjectRef], batchSize: Int,
                           handler: @Sendable (RowStreamEvent) async throws -> Void) async throws {
        // Reuse the caller's transaction if one is open; otherwise take a consistent snapshot.
        let ownsTransaction = await transactionStatus() == .idle
        if ownsTransaction { _ = try await query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY") }
        do {
            for ref in refs {
                try Task.checkCancellation()
                _ = try await query("DECLARE dbjoy_export NO SCROLL CURSOR FOR SELECT * FROM \(regclass(ref))")
                var total = 0
                var began = false
                while true {
                    try Task.checkCancellation()
                    let batch = try await query("FETCH FORWARD \(batchSize) FROM dbjoy_export")
                    if !began {
                        try await handler(.begin(ref, batch.columns))
                        began = true
                    }
                    if batch.rows.isEmpty { break }
                    total += batch.rows.count
                    try await handler(.rows(ref, batch.rows))
                }
                _ = try await query("CLOSE dbjoy_export")
                try await handler(.end(ref, rowCount: total))
            }
            if ownsTransaction { _ = try await query("COMMIT") }
        } catch {
            if ownsTransaction { _ = try? await query("ROLLBACK") }
            throw error
        }
    }

    public func rowCount(of ref: ObjectRef, request: RowRequest) async throws -> RowCount? {
        let hasFilters = request.filters.contains { $0.isEnabled }
        if !hasFilters, ref.kind == .table {
            let estimate = try await query("SELECT reltuples::int8 FROM pg_class WHERE oid = $1::regclass",
                                           parameters: [regclass(ref)]).rows.first?.first.flatMap { $0 }.flatMap { Int($0) }
            if let estimate, estimate > 1_000_000 {
                return RowCount(value: estimate, isEstimate: true)
            }
        }
        let sql = dialect.countStatement(for: ref, request: request)
        return try await pg.perform { pg, conn in
            let wasInTransaction = pg.transactionStatus(conn).isInTransaction
            _ = try pg.exec(conn, wasInTransaction ? "SAVEPOINT dbjoy_count" : "BEGIN")
            defer { _ = try? pg.exec(conn, wasInTransaction ? "ROLLBACK TO SAVEPOINT dbjoy_count" : "ROLLBACK") }
            _ = try pg.exec(conn, "SET LOCAL statement_timeout = '5s'")
            guard let result = try? pg.exec(conn, sql), let value = result.rows.first?.first.flatMap({ $0 }).flatMap({ Int($0) }) else {
                return nil
            }
            return RowCount(value: value, isEstimate: false)
        }
    }
}
