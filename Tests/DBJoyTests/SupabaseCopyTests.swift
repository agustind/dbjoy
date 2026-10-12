@testable import DBJoy
import DBCore
import Foundation
import PostgresDriver
import Testing

/// Copies between two Supabase Postgres containers, where `postgres` isn't a superuser and
/// supabase_admin owns the platform schemas. Enable with DBJOY_TEST_SUPABASE=1; the source listens
/// on DBJOY_TEST_SUPABASE_SOURCE_PORT (default 55441), the target on ..._TARGET_PORT (55442).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBJOY_TEST_SUPABASE"] != nil), .serialized)
struct SupabaseCopyTests {
    static let env = ProcessInfo.processInfo.environment
    static let sourcePort = Int(env["DBJOY_TEST_SUPABASE_SOURCE_PORT"] ?? "") ?? 55441
    static let targetPort = Int(env["DBJOY_TEST_SUPABASE_TARGET_PORT"] ?? "") ?? 55442

    func connect(port: Int) async throws -> any DatabaseConnection {
        let config = ConnectionConfig(name: "supabase", host: "localhost", port: port, user: "postgres", database: "postgres",
                                      sslMode: .disable)
        return try await PostgresDriver().connect(config, password: "secret", database: nil)
    }

    func endpoint(port: Int) -> PostgresToolEndpoint {
        PostgresToolEndpoint(host: "localhost", port: port, user: "postgres", database: "postgres",
                             environment: ["PGPASSWORD": "secret", "PGSSLMODE": "disable"])
    }

    func values(_ sql: String, port: Int) async throws -> [String] {
        let db = try await connect(port: port)
        defer { Task { await db.close() } }
        return try await db.query(sql).rows.map { $0.map { $0 ?? "NULL" }.joined(separator: "|") }
    }

    func run(_ statements: [String], port: Int) async throws {
        let db = try await connect(port: port)
        defer { Task { await db.close() } }
        for sql in statements { _ = try await db.query(sql) }
    }

    /// The source: an app in public and a custom schema, with vector in public, pg_cron with a job,
    /// users in auth, and a trigger and a policy of its own on auth.users. The target: another
    /// project with vector, its own user, a leftover table and a different policy.
    func setUp() async throws {
        try await run([
            "CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public",
            "CREATE EXTENSION IF NOT EXISTS pg_cron",
            "DELETE FROM auth.users",
            """
            INSERT INTO auth.users (id, email, aud, role) VALUES
              ('11111111-1111-1111-1111-111111111111', 'a@example.com', 'authenticated', 'authenticated'),
              ('22222222-2222-2222-2222-222222222222', 'b@example.com', 'authenticated', 'authenticated')
            """,
            "DROP TABLE IF EXISTS public.profiles, public.jobs",
            """
            CREATE TABLE public.profiles (id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
              name text, embedding public.vector(3))
            """,
            """
            INSERT INTO public.profiles VALUES
              ('11111111-1111-1111-1111-111111111111', 'Ana', '[1,2,3]'), ('22222222-2222-2222-2222-222222222222', 'Bo', '[3,2,1]')
            """,
            "CREATE TABLE public.jobs (id serial PRIMARY KEY, title text)",
            "INSERT INTO public.jobs (title) SELECT 'job ' || g FROM generate_series(1, 50) g",
            "ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY",
            "CREATE POLICY \"own profile\" ON public.profiles FOR SELECT USING (auth.uid() = id)",
            "CREATE SCHEMA IF NOT EXISTS app",
            "CREATE OR REPLACE FUNCTION app.hello() RETURNS text LANGUAGE sql AS $$ SELECT 'hi' $$",
            """
            CREATE OR REPLACE FUNCTION public.handle_new_user() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
            AS $$ BEGIN INSERT INTO public.profiles (id) VALUES (new.id); RETURN new; END $$
            """,
            "DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users",
            """
            CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
              FOR EACH ROW EXECUTE FUNCTION public.handle_new_user()
            """,
            "DROP POLICY IF EXISTS \"source policy\" ON auth.users",
            "CREATE POLICY \"source policy\" ON auth.users FOR SELECT TO authenticated USING (auth.uid() = id)",
            "SELECT cron.unschedule(jobid) FROM cron.job",
            "SELECT cron.schedule('nightly', '0 3 * * *', 'SELECT 1')",
        ], port: Self.sourcePort)
        try await run([
            "CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public",
            "CREATE TABLE IF NOT EXISTS public.stale (x int)",
            """
            INSERT INTO auth.users (id, email, aud, role)
            VALUES ('33333333-3333-3333-3333-333333333333', 'staging@example.com', 'authenticated', 'authenticated')
            ON CONFLICT DO NOTHING
            """,
            "DROP POLICY IF EXISTS \"target policy\" ON auth.users",
            "CREATE POLICY \"target policy\" ON auth.users FOR SELECT USING (false)",
        ], port: Self.targetPort)
    }

    func plan() async throws -> DatabaseCopier.Plan {
        let source = try await connect(port: Self.sourcePort)
        let target = try await connect(port: Self.targetPort)
        defer { Task { await source.close(); await target.close() } }
        return try await DatabaseCopier.plan(source: source, target: target)
    }

    /// The app's schemas and data, and its triggers and policies on auth.users. Same in both tests.
    func expectAppCopied() async throws {
        for query in ["SELECT id::text, name, embedding::text FROM public.profiles ORDER BY id",
                      "SELECT count(*) FROM public.jobs",
                      "SELECT app.hello()",
                      "SELECT polname FROM pg_policy WHERE polrelid = 'auth.users'::regclass ORDER BY 1",
                      "SELECT tgname FROM pg_trigger WHERE tgrelid = 'auth.users'::regclass AND NOT tgisinternal ORDER BY 1"] {
            #expect(try await values(query, port: Self.targetPort) == (try await values(query, port: Self.sourcePort)), "\(query)")
        }
        #expect(try await values("SELECT count(*) FROM pg_class WHERE relname = 'stale'", port: Self.targetPort) == ["0"])
        #expect(try await values("SELECT extname FROM pg_extension WHERE extname IN ('pg_cron', 'vector') ORDER BY 1",
                                 port: Self.targetPort) == ["pg_cron", "vector"])
        // Production's scheduled jobs don't come along.
        #expect(try await values("SELECT count(*) FROM cron.job", port: Self.targetPort) == ["0"])
    }

    static let usersQuery = "SELECT id::text, email FROM auth.users ORDER BY id"
    static let foreignKeyQuery = "SELECT convalidated::text FROM pg_constraint WHERE conname = 'profiles_id_fkey'"

    /// The default: tables and data, while the target keeps its own users.
    @Test func copiesTheAppAndKeepsTheTargetsUsers() async throws {
        try await setUp()
        let plan = try await plan()
        #expect(plan.clearedSchemas == ["public"])
        #expect(plan.skippedSchemaNames.contains("auth"))
        #expect(plan.platformTables.map(\.description).contains("auth.users"))
        #expect(!plan.platformTables.contains { $0.schema == "cron" })
        #expect(plan.foreignKeysIntoPlatform == ["public.profiles → auth.users"])
        // pg_cron's jobs stay behind: either its tables are skipped, or (when the target has pg_cron) its schema.
        #expect(plan.skippedTableData.map(\.description).contains("cron.job") || plan.skippedSchemaNames.contains("cron"))

        let usersBefore = try await values(Self.usersQuery, port: Self.targetPort)
        let warnings = try await DatabaseCopier().run(from: endpoint(port: Self.sourcePort), to: endpoint(port: Self.targetPort),
                                                      plan: plan, options: .init()) { _ in }
        #expect(warnings.isEmpty, "\(warnings)")
        try await expectAppCopied()
        #expect(try await values(Self.usersQuery, port: Self.targetPort) == usersBefore)
        // Profiles point at users the target doesn't have, so the key isn't checked against them.
        #expect(try await values(Self.foreignKeyQuery, port: Self.targetPort) == ["false"])
    }

    @Test func copiesThePlatformRowsWhenAsked() async throws {
        try await setUp()
        let warnings = try await DatabaseCopier().run(from: endpoint(port: Self.sourcePort), to: endpoint(port: Self.targetPort),
                                                      plan: try await plan(), options: .init(includePlatformData: true)) { _ in }
        #expect(warnings.isEmpty, "\(warnings)")
        try await expectAppCopied()
        #expect(try await values(Self.usersQuery, port: Self.targetPort) == (try await values(Self.usersQuery, port: Self.sourcePort)))
        #expect(try await values(Self.foreignKeyQuery, port: Self.targetPort) == ["true"])
    }
}
