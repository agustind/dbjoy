@testable import DBJoy
import DBCore
import Foundation
import PostgresDriver
import Testing

/// Copies the sample database over a scratch one with pg_dump and psql. Enable with DBJOY_TEST_PG=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBJOY_TEST_PG"] != nil), .serialized)
struct DatabaseCopierTests {
    static let env = ProcessInfo.processInfo.environment
    static let port = Int(env["DBJOY_TEST_PG_PORT"] ?? "") ?? 55432
    static let password = env["DBJOY_TEST_PG_PASSWORD"] ?? "secret"
    static let target = "dbjoy_copy_test"

    func connect(_ database: String) async throws -> any DatabaseConnection {
        let config = ConnectionConfig(name: "test", host: "localhost", port: Self.port, user: "postgres", database: database,
                                      sslMode: .disable)
        return try await PostgresDriver().connect(config, password: Self.password, database: nil)
    }

    func endpoint(_ database: String, environment: [String: String] = [:]) -> PostgresToolEndpoint {
        PostgresToolEndpoint(host: "localhost", port: Self.port, user: "postgres", database: database,
                             environment: ["PGPASSWORD": Self.password, "PGSSLMODE": "disable"].merging(environment) { $1 })
    }

    /// A fresh target holding leftovers that the copy must remove.
    func makeTarget() async throws {
        let admin = try await connect("postgres")
        _ = try await admin.query("DROP DATABASE IF EXISTS \(Self.target) WITH (FORCE)")
        _ = try await admin.query("CREATE DATABASE \(Self.target)")
        await admin.close()
        let db = try await connect(Self.target)
        for sql in ["CREATE SCHEMA junk", "CREATE TABLE junk.t (x int)", "CREATE TABLE public.extra (y int)",
                    "INSERT INTO public.extra VALUES (1)"] {
            _ = try await db.query(sql)
        }
        await db.close()
    }

    /// Schemas, relations, routines and row counts.
    func fingerprint(_ database: String) async throws -> [String] {
        let db = try await connect(database)
        defer { Task { await db.close() } }
        let user = "n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'"
        var lines = try await db.query("SELECT 'schema ' || nspname FROM pg_namespace n WHERE \(user) ORDER BY 1").rows
            .compactMap { $0[0] }
        let relations = try await db.query("""
            SELECT n.nspname, c.relname, c.relkind::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE \(user) ORDER BY 1, 2
            """).rows
        for row in relations {
            guard let schema = row[0], let name = row[1], let kind = row[2] else { continue }
            var line = "\(kind) \(schema).\(name)"
            if kind == "r" {
                let count = try await db.query("SELECT count(*) FROM \"\(schema)\".\"\(name)\"").rows.first?[0] ?? "?"
                line += " rows=\(count)"
            }
            lines.append(line)
        }
        lines += try await db.query("""
            SELECT 'routine ' || n.nspname || '.' || p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE \(user) ORDER BY 1
            """).rows.compactMap { $0[0] }
        return lines
    }

    func copy(from source: PostgresToolEndpoint, options: DatabaseCopier.Options = .init()) async throws -> [String] {
        let steps = Steps()
        try await DatabaseCopier().run(from: source, to: endpoint(Self.target), plan: .init(),
                                       options: options) { steps.append($0.step) }
        return steps.all
    }

    @Test func copiesEverythingAndRemovesLeftovers() async throws {
        try await SampleDatabaseLock.run {
            try await makeTarget()
            let steps = try await copy(from: endpoint("dbjoy_sample"))
            let copied = try await fingerprint(Self.target)
            #expect(copied == (try await fingerprint("dbjoy_sample")))
            #expect(!copied.contains("schema junk"))
            #expect(steps.contains { $0.hasPrefix("Copying ") })
            // The recreated public schema has the source's owner and grants.
            #expect(try await publicSchema(Self.target) == (try await publicSchema("dbjoy_sample")))
        }
    }

    func publicSchema(_ database: String) async throws -> [String?] {
        let db = try await connect(database)
        defer { Task { await db.close() } }
        return try await db.query("""
            SELECT pg_get_userbyid(nspowner), nspacl::text FROM pg_namespace WHERE nspname = 'public'
            """).rows.first ?? []
    }

    @Test func copiesStructureOnly() async throws {
        try await SampleDatabaseLock.run {
            try await makeTarget()
            _ = try await copy(from: endpoint("dbjoy_sample"), options: .init(includeData: false))
            let copied = try await fingerprint(Self.target)
            let tables = copied.filter { $0.hasPrefix("r ") }
            #expect(!tables.isEmpty)
            #expect(tables.allSatisfy { $0.hasSuffix(" rows=0") })
            #expect(!copied.contains("schema junk"))
        }
    }

    /// Customers come without rows, so the key from orders can't check the orders copied with them.
    @Test func copiesSomeTablesWithoutRows() async throws {
        try await SampleDatabaseLock.run {
            try await makeTarget()
            let source = try await connect("dbjoy_sample")
            let target = try await connect(Self.target)
            let plan = try await DatabaseCopier.plan(source: source, target: target)
            await source.close()
            await target.close()
            let customers = DatabaseCopier.Plan.Table(schema: "public", name: "customers")
            let listed = plan.dataTables(platformRows: false)
            #expect(listed.map(\.table).contains(customers))
            #expect(listed.allSatisfy { $0.bytes > 0 })

            try await DatabaseCopier().run(from: endpoint("dbjoy_sample"), to: endpoint(Self.target), plan: plan,
                                           options: .init(tablesWithoutData: [customers])) { _ in }
            let copied = try await fingerprint(Self.target)
            let sample = try await fingerprint("dbjoy_sample")
            #expect(copied.contains("r public.customers rows=0"))
            let others = { (lines: [String]) in lines.filter { !$0.hasPrefix("r public.customers ") } }
            #expect(others(copied) == others(sample))
            let db = try await connect(Self.target)
            let keys = try await db.query("""
                SELECT conname || ' ' || convalidated::text FROM pg_constraint WHERE contype = 'f' ORDER BY 1
                """).rows.compactMap { $0[0] }
            await db.close()
            #expect(keys == ["order_items_order_id_fkey true", "order_items_product_id_fkey true",
                             "orders_customer_id_fkey false"])
        }
    }

    @Test func unreadableSourceLeavesTargetAsItWas() async throws {
        try await SampleDatabaseLock.run {
            try await makeTarget()
            let before = try await fingerprint(Self.target)
            await #expect(throws: DatabaseError.self) {
                _ = try await copy(from: endpoint("dbjoy_no_such_database"))
            }
            #expect(try await fingerprint(Self.target) == before)
        }
    }

    @Test func failureOnTargetRollsBack() async throws {
        try await SampleDatabaseLock.run {
            try await makeTarget()
            let before = try await fingerprint(Self.target)
            // Every statement on the target fails, starting with the first DROP SCHEMA.
            let readOnly = endpoint(Self.target, environment: ["PGOPTIONS": "-c default_transaction_read_only=on"])
            do {
                try await DatabaseCopier().run(from: endpoint("dbjoy_sample"), to: readOnly, plan: .init(),
                                               options: .init()) { _ in }
                Issue.record("The copy should have failed")
            } catch let error as DatabaseError {
                #expect(error.fullDescription.contains("read-only transaction"))
            }
            #expect(try await fingerprint(Self.target) == before)
        }
    }

    @Test func cancellingLeavesTargetAsItWas() async throws {
        try await SampleDatabaseLock.run {
            try await makeTarget()
            let before = try await fingerprint(Self.target)
            // Another session holds a lock, so the copy waits at DROP SCHEMA junk until it's cancelled.
            let blocker = try await connect(Self.target)
            _ = try await blocker.query("BEGIN")
            _ = try await blocker.query("LOCK TABLE junk.t")
            let copy = Task {
                try await DatabaseCopier().run(from: endpoint("dbjoy_sample"), to: endpoint(Self.target), plan: .init(),
                                               options: .init()) { _ in }
            }
            try await Task.sleep(for: .seconds(1))
            let cancelledAt = Date()
            copy.cancel()
            await #expect(throws: CancellationError.self) { try await copy.value }
            #expect(Date().timeIntervalSince(cancelledAt) < 3)
            _ = try await blocker.query("ROLLBACK")
            await blocker.close()
            #expect(try await fingerprint(Self.target) == before)
        }
    }

    /// Like a managed service: the connection's user isn't a superuser, and the target holds a schema
    /// and an extension that belong to other roles.
    @Test func leavesOtherRolesSchemasAlone() async throws {
        try await SampleDatabaseLock.run {
            let admin = try await connect("postgres")
            for sql in ["DROP DATABASE IF EXISTS \(Self.target) WITH (FORCE)",
                        "DO $$ BEGIN CREATE ROLE dbjoy_copier LOGIN PASSWORD 'secret'; EXCEPTION WHEN duplicate_object THEN NULL; END $$",
                        "DO $$ BEGIN CREATE ROLE dbjoy_platform; EXCEPTION WHEN duplicate_object THEN NULL; END $$",
                        "CREATE DATABASE \(Self.target) OWNER dbjoy_copier"] {
                _ = try await admin.query(sql)
            }
            await admin.close()
            let superuser = try await connect(Self.target)
            for sql in ["CREATE SCHEMA platform AUTHORIZATION dbjoy_platform",
                        "CREATE TABLE platform.settings (key text)",
                        "ALTER TABLE platform.settings OWNER TO dbjoy_platform",
                        "CREATE SCHEMA tools AUTHORIZATION dbjoy_copier",
                        "CREATE EXTENSION pgcrypto SCHEMA tools",
                        "CREATE SCHEMA junk AUTHORIZATION dbjoy_copier"] {
                _ = try await superuser.query(sql)
            }
            await superuser.close()

            let config = ConnectionConfig(name: "copier", host: "localhost", port: Self.port, user: "dbjoy_copier",
                                          database: Self.target, sslMode: .disable)
            let target = try await PostgresDriver().connect(config, password: "secret", database: nil)
            let source = try await connect("dbjoy_sample")
            let plan = try await DatabaseCopier.plan(source: source, target: target)
            await target.close()
            await source.close()
            #expect(plan.skippedSchemaNames == ["platform", "tools"])
            #expect(plan.skippedExtensions == ["pgcrypto"])

            let copier = PostgresToolEndpoint(host: "localhost", port: Self.port, user: "dbjoy_copier", database: Self.target,
                                              environment: ["PGPASSWORD": "secret", "PGSSLMODE": "disable"])
            try await DatabaseCopier().run(from: endpoint("dbjoy_sample"), to: copier, plan: plan, options: .init()) { _ in }

            let copied = try await fingerprint(Self.target)
            #expect(copied.contains("schema platform"))
            #expect(copied.contains("r platform.settings rows=0"))
            #expect(copied.contains("schema tools"))
            #expect(!copied.contains("schema junk"))
            let skipped = ["platform", "tools"]
            let isSkipped = { (line: String) in skipped.contains { line.contains(" \($0)") || line.contains(" \($0).") } }
            #expect(copied.filter { !isSkipped($0) } == (try await fingerprint("dbjoy_sample")))
        }
    }

    @Test func exclusionsAreQuotedLiterally() {
        var plan = DatabaseCopier.Plan()
        plan.skippedSchemas = [.init(schema: "Auth*", reason: "")]
        plan.skippedExtensions = ["pg_stat_statements"]
        #expect(DatabaseCopier.exclusionArguments(plan)
            == ["--exclude-schema=\"Auth*\"", "--exclude-extension=\"pg_stat_statements\"", "--no-subscriptions"])
        #expect(DatabaseCopier.wipeScript(plan).contains("AND nspname NOT IN ('Auth*')"))
    }

    @Test func filterDropsEventTriggersButNotData() {
        let dump = """
            --
            -- Name: watch; Type: EVENT TRIGGER; Schema: -; Owner: -
            --

            CREATE EVENT TRIGGER watch ON ddl_command_end
               EXECUTE FUNCTION public.log();

            --
            -- Data for Name: notes; Type: TABLE DATA; Schema: public; Owner: -
            --

            COPY public.notes (body) FROM stdin;
            -- Name: watch; Type: EVENT TRIGGER; Schema: -; Owner: -
            CREATE EVENT TRIGGER x
            \\.

            \\unrestrict abc

            """
        let filter = DumpFilter()
        let bytes = Array(dump.utf8)
        // Split mid-line to check that lines are put back together across chunks.
        var output = bytes[..<37].withUnsafeBytes { filter.process($0) }
        output += bytes[37...].withUnsafeBytes { filter.process($0) }
        output += filter.finish()
        let text = String(decoding: output, as: UTF8.self)
        #expect(!text.contains("ON ddl_command_end"))
        #expect(text.contains("COPY public.notes (body) FROM stdin;\n-- Name: watch; Type: EVENT TRIGGER;"))
        #expect(text.contains("CREATE EVENT TRIGGER x\n\\.\n"))
        #expect(text.contains("\\unrestrict abc"))
    }

    @Test func filterRelaxesForeignKeysIntoSkippedSchemas() {
        let dump = """
            --
            -- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
            --

            ALTER TABLE ONLY public.profiles
                ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


            --
            -- Name: orders orders_customer_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
            --

            ALTER TABLE ONLY public.orders
                ADD CONSTRAINT orders_customer_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);

            """
        let filter = DumpFilter(.init(relaxingReferencesTo: ["auth"]))
        var output = Array(dump.utf8).withUnsafeBytes { filter.process($0) }
        output += filter.finish()
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("REFERENCES auth.users(id) ON DELETE CASCADE NOT VALID;\n"))
        #expect(text.contains("REFERENCES public.customers(id);\n"))
        #expect(text.count == dump.count + " NOT VALID".count)
    }

    @Test func filterRelaxesForeignKeysIntoTablesWithoutRows() {
        let dump = """
            -- Name: a a_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
            ALTER TABLE ONLY public.a
                ADD CONSTRAINT a_fkey FOREIGN KEY (b) REFERENCES public.customers(id);
            -- Name: c c_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
            ALTER TABLE ONLY public.c
                ADD CONSTRAINT c_fkey FOREIGN KEY (b) REFERENCES public.customers_archive(id);
            -- Name: d d_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
            ALTER TABLE ONLY public.d
                ADD CONSTRAINT d_fkey FOREIGN KEY (b) REFERENCES "Sales"."Order"(id);

            """
        let filter = DumpFilter(.init(relaxingReferencesToTables: [.init(schema: "public", name: "customers"),
                                                                    .init(schema: "Sales", name: "Order")]))
        var output = Array(dump.utf8).withUnsafeBytes { filter.process($0) }
        output += filter.finish()
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("REFERENCES public.customers(id) NOT VALID;\n"))
        #expect(text.contains("REFERENCES public.customers_archive(id);\n"))
        #expect(text.contains("REFERENCES \"Sales\".\"Order\"(id) NOT VALID;\n"))
    }

    @Test func errorDetailDropsPsqlPrefixes() {
        let output = """
            psql:<stdin>:12: ERROR:  relation "x" already exists
            psql:<stdin>:12: NOTICE:  something
            """
        #expect(DatabaseCopier.errorDetail(output) == "ERROR:  relation \"x\" already exists")
        #expect(DatabaseCopier.table(inVerboseLine: "pg_dump: dumping contents of table \"public.orders\"") == "public.orders")
    }
}

private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []

    func append(_ step: String) { lock.withLock { steps.append(step) } }
    var all: [String] { lock.withLock { steps } }
}
