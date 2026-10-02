import DBCore
import Foundation
import PostgresDriver
import Testing

/// Runs against the sample database (scripts/sample-db.sql).
/// Enable with DBJOY_TEST_PG=1; override the port with DBJOY_TEST_PG_PORT (default 55432).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBJOY_TEST_PG"] != nil), .serialized)
struct PostgresIntegrationTests {
    static let env = ProcessInfo.processInfo.environment
    let config = ConnectionConfig(
        name: "test", host: "localhost", port: Int(env["DBJOY_TEST_PG_PORT"] ?? "") ?? 55432,
        user: "postgres", database: "dbjoy_sample", sslMode: .disable)

    func connect() async throws -> any DatabaseConnection {
        try await PostgresDriver().connect(config, password: Self.env["DBJOY_TEST_PG_PASSWORD"] ?? "secret", database: nil)
    }

    @Test func badPasswordFails() async {
        await #expect(throws: DatabaseError.self) {
            _ = try await PostgresDriver().connect(config, password: "wrong", database: nil)
        }
    }

    @Test func introspection() async throws {
        let db = try await connect()
        defer { Task { await db.close() } }
        #expect(!db.serverVersion.isEmpty)
        #expect(try await db.listDatabases().contains("dbjoy_sample"))
        #expect(try await db.listSchemas() == ["public", "sales"])
        #expect(try await db.defaultSchema() == "public")

        let objects = try await db.listObjects(schema: "public")
        let names = Dictionary(objects.map { ($0.name, $0.kind) }, uniquingKeysWith: { a, _ in a })
        #expect(names["customers"] == .table)
        #expect(names["customer_order_totals"] == .view)
        #expect(names["daily_sales"] == .materializedView)
        #expect(names["order_total"] == .function)
        #expect(names["cancel_order"] == .procedure)
        #expect(objects.first { $0.name == "order_total" }?.ref.arguments == "p_order_id integer")

        let items = try await db.structure(of: ObjectRef(schema: "public", name: "order_items", kind: .table))
        #expect(items.primaryKey == ["order_id", "product_id"])
        #expect(items.columns.first { $0.name == "quantity" }?.defaultValue == "1")
        #expect(items.indexes.first?.isPrimary == true)
        #expect(items.indexes.first?.columns == ["order_id", "product_id"])
        #expect(items.constraints.filter { $0.type == .foreignKey }.count == 2)

        let products = try await db.structure(of: ObjectRef(schema: "public", name: "products", kind: .table))
        #expect(products.columns.first { $0.name == "id" }?.isGenerated == true)

        let orders = try await db.relations(of: ObjectRef(schema: "public", name: "orders", kind: .table))
        #expect(orders.outgoing.map(\.referencedTable.name) == ["customers"])
        #expect(orders.incoming.map(\.table.name) == ["order_items"])
        #expect(orders.incoming.first?.onDelete == "CASCADE")
        #expect(Set(orders.dependents.map(\.object.name)) == ["customer_order_totals", "daily_sales"])

        let view = try await db.relations(of: ObjectRef(schema: "public", name: "customer_order_totals", kind: .view))
        #expect(Set(view.dependencies.map(\.object.name)) == ["customers", "orders", "order_items"])

        #expect(try await db.foreignKeys(schema: "public").count == 3)
        #expect(try await db.columnsByTable(schema: "public")["customers"]?.first?.isPrimaryKey == true)

        let fn = try await db.definition(of: ObjectRef(schema: "public", name: "order_total", kind: .function, arguments: "p_order_id integer"))
        #expect(fn.contains("CREATE OR REPLACE FUNCTION public.order_total"))
        let ddl = try await db.definition(of: ObjectRef(schema: "public", name: "orders", kind: .table))
        #expect(ddl.contains("CREATE INDEX orders_customer_idx"))
    }

    @Test func browsingRows() async throws {
        let db = try await connect()
        defer { Task { await db.close() } }
        let ref = ObjectRef(schema: "public", name: "customers", kind: .table)
        let request = RowRequest(filters: [RowFilter(column: "country", op: .equals, value: "GB")],
                                 sort: [SortKey(column: "id", ascending: false)], limit: 10,
                                 columns: ["id", "name", "email", "country", "created_at", "metadata"])
        let page = try await db.fetchRows(of: ref, request: request)
        #expect(page.rows.count == 10)
        #expect(page.columns.first?.category == .number)
        #expect(page.columns.last?.category == .json)
        #expect(page.rows.allSatisfy { $0[3] == "GB" })
        #expect(try await db.rowCount(of: ref, request: request) == RowCount(value: 167, isEstimate: false))

        var search = request
        search.filters = [RowFilter(column: nil, op: .contains, value: "customer999@")]
        #expect(try await db.fetchRows(of: ref, request: search).rows.count == 1)
    }

    @Test func scriptsWithMultipleResultsNoticesAndErrors() async throws {
        let db = try await connect()
        defer { Task { await db.close() } }
        let result = await db.execute("""
            SELECT 1 AS a, NULL::text AS b;
            DO $$ BEGIN RAISE NOTICE 'hello'; END $$;
            SELECT generate_series(1, 50);
            SELECT 1/0;
            SELECT 'never';
            """, maxRows: 20)
        #expect(result.results.count == 3)
        #expect(result.results[0].rows == [["1", nil]])
        #expect(result.results[1].commandTag == "DO")
        #expect(result.results[2].rows.count == 20)
        #expect(result.results[2].truncated)
        #expect(result.results[2].statement == "SELECT generate_series(1, 50)")
        #expect(result.notices.contains { $0.contains("hello") })
        #expect(result.error?.sqlState == "22012")
        #expect(result.transactionStatus == .idle)
    }

    @Test func manualTransactionsAndCancel() async throws {
        let db = try await connect()
        defer { Task { await db.close() } }
        _ = await db.execute("BEGIN; CREATE TEMP TABLE t(x int); INSERT INTO t VALUES (1);", maxRows: 10)
        #expect(await db.transactionStatus() == .inTransaction)
        let failed = await db.execute("SELECT nope", maxRows: 10)
        #expect(failed.transactionStatus == .failedTransaction)
        _ = await db.execute("ROLLBACK", maxRows: 10)
        #expect(await db.transactionStatus() == .idle)

        async let slow = db.execute("SELECT pg_sleep(10)", maxRows: 10)
        try await Task.sleep(for: .milliseconds(300))
        db.cancel()
        let cancelled = await slow
        #expect(cancelled.error?.sqlState == "57014")
    }

    @Test func guardedTransactionRollsBack() async throws {
        let db = try await connect()
        defer { Task { await db.close() } }
        let ref = ObjectRef(schema: "sales", name: "regions", kind: .table)
        let d = db.dialect
        await #expect(throws: DatabaseError.self) {
            try await db.executeInTransaction([
                TransactionStatement(d.statement(for: .insert(values: [ColumnValue("code", .value("apac")), ColumnValue("name", .value("Asia Pacific"))]), in: ref), expectedRows: 1),
                TransactionStatement(d.statement(for: .update(key: [ColumnValue("code", .value("missing"))], values: [ColumnValue("name", .value("x"))]), in: ref), expectedRows: 1),
            ])
        }
        #expect(try await db.query("SELECT count(*) FROM sales.regions").rows == [["2"]])

        try await db.executeInTransaction([
            TransactionStatement(d.statement(for: .update(key: [ColumnValue("code", .value("emea"))], values: [ColumnValue("name", .value("EMEA"))]), in: ref), expectedRows: 1),
        ])
        #expect(try await db.query("SELECT name FROM sales.regions WHERE code = $1", parameters: ["emea"]).rows == [["EMEA"]])
        try await db.executeInTransaction([TransactionStatement("UPDATE sales.regions SET name = 'Europe, Middle East & Africa' WHERE code = 'emea'")])
    }

    @Test func schemaChangesApply() async throws {
        let db = try await connect()
        defer { Task { await db.close() } }
        let d = db.dialect
        _ = try await db.query("DROP TABLE IF EXISTS public.scratch")
        try await db.executeInTransaction(d.statements(for: CreateTableRequest(schema: "public", name: "scratch", columns: [
            ColumnDefinition(name: "id", dataType: "serial", isNullable: false, isPrimaryKey: true),
            ColumnDefinition(name: "label", dataType: "text"),
        ])).map { TransactionStatement($0) })
        let ref = ObjectRef(schema: "public", name: "scratch", kind: .table)
        let original = try await db.structure(of: ref).columns.map(ColumnDefinition.init)
        var edited = original
        edited[1].name = "title"
        edited[1].isNullable = false
        edited[1].defaultValue = "'untitled'"
        edited.append(ColumnDefinition(name: "score", dataType: "integer"))
        let change = TableSchemaChange(table: ref, original: original, columns: edited,
                                       newIndexes: [IndexDefinition(name: "scratch_score_idx", columns: ["score"], isUnique: true)])
        try await db.executeInTransaction(d.statements(for: change).map { TransactionStatement($0) })
        let after = try await db.structure(of: ref)
        #expect(after.columns.map(\.name) == ["id", "title", "score"])
        #expect(after.columns[1].isNullable == false)
        #expect(after.indexes.contains { $0.name == "scratch_score_idx" && $0.isUnique })
        _ = try await db.query(d.dropStatement(for: ref, cascade: false))
    }
}

extension PostgresIntegrationTests {
    @Test func readOnlyConnectionsRejectWrites() async throws {
        var readOnly = config
        readOnly.readOnly = true
        let db = try await PostgresDriver().connect(readOnly, password: Self.env["DBJOY_TEST_PG_PASSWORD"] ?? "secret", database: nil)
        defer { Task { await db.close() } }
        let result = await db.execute("UPDATE sales.regions SET name = name", maxRows: 10)
        #expect(result.error?.sqlState == "25006")
    }
}

extension PostgresIntegrationTests {
    @Test func typeShowcaseMetadataAndValues() async throws {
        let db = try await connect()
        defer { Task { await db.close() } }
        let ref = ObjectRef(schema: "public", name: "type_showcase", kind: .table)
        let columns = Dictionary(uniqueKeysWithValues: try await db.structure(of: ref).columns.map { ($0.name, $0) })
        #expect(columns["c_enum"]?.allowedValues == ["happy", "ok", "sad"])
        #expect(columns["c_check_list"]?.allowedValues == ["draft", "published", "archived"])
        #expect(columns["c_check_numbers"]?.allowedValues == ["1", "2", "3"])
        #expect(columns["c_text"]?.allowedValues == nil)
        #expect(columns["c_generated"]?.isGenerated == true)
        #expect(columns["c_boolean_strict"]?.isNullable == false)

        let rows = try await db.fetchRows(of: ref, request: RowRequest(sort: [SortKey(column: "id")], limit: 3))
        let boolIndex = rows.columns.firstIndex { $0.name == "c_boolean" }!
        #expect(rows.columns[boolIndex].category == .boolean)
        #expect(rows.rows.map { $0[boolIndex] } == ["true", "false", nil])

        // Dropdown values round-trip through an update.
        try await db.executeInTransaction([TransactionStatement(
            db.dialect.statement(for: .update(key: [ColumnValue("id", .value("3"))],
                                              values: [ColumnValue("c_boolean", .value("true")), ColumnValue("c_enum", .value("ok")),
                                                       ColumnValue("c_check_list", .value("archived"))]), in: ref),
            expectedRows: 1)])
        let updated = try await db.query("SELECT c_boolean, c_enum::text, c_check_list FROM type_showcase WHERE id = 3")
        #expect(updated.rows == [["true", "ok", "archived"]])
        try await db.executeInTransaction([TransactionStatement(
            "UPDATE type_showcase SET c_boolean = NULL, c_enum = NULL, c_check_list = NULL WHERE id = 3", expectedRows: 1)])
    }
}

private actor EventLog {
    var events: [String] = []
    var rows = 0
    func add(_ event: RowStreamEvent) {
        switch event {
        case .begin(let ref, let columns): events.append("begin \(ref.name) \(columns.count)")
        case .rows(_, let batch): rows += batch.count
        case .end(let ref, let count): events.append("end \(ref.name) \(count)")
        }
    }
}

extension PostgresIntegrationTests {
    @Test func streamsTablesInBatches() async throws {
        let db = try await connect()
        defer { Task { await db.close() } }
        let log = EventLog()
        let refs = ["customers", "audit_log"].map { ObjectRef(schema: "public", name: $0, kind: .table) }
        try await db.streamRows(of: refs, batchSize: 300) { await log.add($0) }
        #expect(await log.events == ["begin customers 6", "end customers 1000", "begin audit_log 2", "end audit_log 2"])
        #expect(await log.rows == 1002)
        #expect(await db.transactionStatus() == .idle)

        let structure = try await db.structure(of: ObjectRef(schema: "public", name: "products", kind: .table))
        #expect(structure.columns.first?.isIdentity == true)
        let reset = db.dialect.resetSequenceStatements(for: structure)
        #expect(reset.count == 1)
        _ = try await db.query(reset[0])
    }
}

extension PostgresIntegrationTests {
    @Test func expressionValuesAreEvaluatedByTheServer() async throws {
        let db = try await connect()
        defer { Task { await db.close() } }
        let ref = ObjectRef(schema: "public", name: "type_showcase", kind: .table)
        let before = try await db.query("SELECT c_timestamptz, c_date, c_uuid, c_text FROM type_showcase WHERE id = 3").rows
        try await db.executeInTransaction([TransactionStatement(db.dialect.statement(for: .update(
            key: [ColumnValue("id", .value("3"))],
            values: [ColumnValue("c_timestamptz", CellValue.parseInput("NOW()", category: .temporal)),
                     ColumnValue("c_date", CellValue.parseInput("CURRENT_DATE", category: .temporal)),
                     ColumnValue("c_uuid", CellValue.parseInput("gen_random_uuid()", category: .other)),
                     ColumnValue("c_text", CellValue.parseInput("=upper('abc')", category: .text))]), in: ref),
            expectedRows: 1)])
        let check = try await db.query("""
            SELECT now() - c_timestamptz < interval '1 minute', c_date = current_date, c_uuid IS NOT NULL, c_text
            FROM type_showcase WHERE id = 3
            """)
        #expect(check.rows == [["true", "true", "true", "ABC"]])
        // Restore the all-NULL showcase row.
        _ = try await db.query("UPDATE type_showcase SET c_timestamptz = NULL, c_date = NULL, c_uuid = NULL, c_text = NULL WHERE id = 3")
        #expect(before == [[nil, nil, nil, nil]])
    }
}
