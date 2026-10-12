import Darwin
import DBCore
import Foundation

/// Where a PostgreSQL command-line tool (pg_dump, psql) connects, and the libpq environment it needs.
struct PostgresToolEndpoint: Sendable {
    var host: String
    var port: Int
    var user: String
    var database: String
    var environment: [String: String]

    init(host: String, port: Int, user: String, database: String, environment: [String: String]) {
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.environment = environment
    }

    /// Through a tunnel, the tool connects to 127.0.0.1:<local port> while `host` keeps the real
    /// name for TLS verification.
    init(config: ConnectionConfig, tunnel: SSHTunnel?, password: String?, database: String) {
        var environment = ["PGSSLMODE": config.sslMode.rawValue, "PGCONNECT_TIMEOUT": "10", "PGAPPNAME": "DBJoy"]
        if tunnel != nil { environment["PGHOSTADDR"] = "127.0.0.1" }
        if let password, !password.isEmpty { environment["PGPASSWORD"] = password }
        self.init(host: config.host.isEmpty ? "localhost" : config.host, port: tunnel?.localPort ?? config.port,
                  user: config.user, database: database, environment: environment)
    }

    var arguments: [String] {
        ["--host", host, "--port", String(port), "--username", user, "--dbname", database, "--no-password"]
    }

    func configure(_ process: Process) {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    }
}

/// Replaces everything in one PostgreSQL database with a copy of another. pg_dump streams the
/// source into psql, which first drops every schema in the target. psql runs it all in one
/// transaction, so if anything fails or the copy is cancelled, the target stays as it was.
final class DatabaseCopier: @unchecked Sendable {
    struct Options: Sendable {
        var includeData = true
        /// Copy owners and grants. The roles must exist on the target server.
        var keepOwnership = false
        /// Also replace the rows of tables in skipped schemas (`Plan.platformTables`), such as
        /// Supabase's auth.users. Off by default: the target keeps its users.
        var includePlatformData = false

        var copiesPlatformRows: Bool { includeData && includePlatformData }
    }

    struct Progress: Sendable {
        var step: String
        var bytes: Int64
    }

    private let lock = NSLock()
    private var running: [Process] = []
    private var isCancelled = false

    /// What the copy leaves alone or handles specially. Managed services (Supabase, RDS, …) keep
    /// schemas, extensions and tables owned by their own roles, which the connection's user can
    /// neither drop nor write to.
    struct Plan: Sendable, Equatable {
        struct Skipped: Sendable, Equatable {
            var schema: String
            var reason: String
        }

        struct Table: Sendable, Equatable, CustomStringConvertible {
            var schema: String
            var name: String
            var description: String { "\(schema).\(name)" }
        }

        /// Schemas left as they are in the target and left out of the copy.
        var skippedSchemas: [Skipped] = []
        /// Schemas the target's user owns but can't drop because they hold other roles' objects
        /// (on Supabase, public holds the vector extension). The copy empties them instead: it drops
        /// the user's own objects and leaves the others in place.
        var clearedSchemas: [String] = []
        /// Extensions in the target owned by other roles: left as they are and left out of the copy.
        var skippedExtensions: [String] = []
        /// Tables of extensions owned by other roles (such as pg_cron's cron.job). The extension is
        /// copied, but not these tables' rows: the target's user can't write to them.
        var skippedTableData: [Table] = []
        /// Whether the source has a public schema. pg_dump never creates it, so the wipe does.
        var sourceHasPublicSchema = true
        /// Tables in skipped schemas whose rows are copied (truncated in the target, then loaded),
        /// such as Supabase's auth.users: the schema belongs to the platform, but the rows are data.
        var platformTables: [Table] = []
        /// The source's triggers on tables in skipped schemas that call functions in copied schemas
        /// (such as Supabase's on_auth_user_created), recreated after the copy.
        var platformTriggers: [Statement] = []
        /// The source's row-level security policies on tables in skipped schemas. They replace the target's.
        var platformPolicies: [Statement] = []
        /// The source's event triggers that the target doesn't have. Event triggers aren't copied:
        /// only superusers can create them, and managed services install their own.
        var skippedEventTriggers: [String] = []
        /// Foreign keys from copied tables to tables in skipped schemas, such as public.profiles → auth.users.
        /// Unless the platform rows are copied too, they're added NOT VALID: existing rows may point at
        /// rows the target doesn't have.
        var foreignKeysIntoPlatform: [String] = []
        /// Publications in the target that belong to other roles and that the source also has. When
        /// there are any, publications aren't copied at all, since they can't be replaced.
        var keptPublications: [String] = []

        var skippedSchemaNames: [String] { skippedSchemas.map(\.schema) }
        var copiesPublications: Bool { keptPublications.isEmpty }
    }

    /// A statement the copy runs on its own, with a label for warnings.
    struct Statement: Sendable, Equatable {
        var label: String
        var sql: String
    }

    /// Each schema in the target: whether the current user is a member of its owner, and whether
    /// it holds anything owned by a role the user isn't a member of. DROP SCHEMA … CASCADE fails on both.
    static let targetSchemasQuery = """
        SELECT n.nspname, pg_has_role(n.nspowner, 'MEMBER')::int,
          (EXISTS (SELECT 1 FROM pg_class c WHERE c.relnamespace = n.oid AND NOT pg_has_role(c.relowner, 'MEMBER'))
            OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = n.oid AND NOT pg_has_role(p.proowner, 'MEMBER'))
            OR EXISTS (SELECT 1 FROM pg_type t WHERE t.typnamespace = n.oid AND NOT pg_has_role(t.typowner, 'MEMBER'))
            OR EXISTS (SELECT 1 FROM pg_extension e WHERE e.extnamespace = n.oid AND NOT pg_has_role(e.extowner, 'MEMBER')))::int
        FROM pg_namespace n
        WHERE n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'
        ORDER BY 1
        """

    static let foreignExtensionsQuery = """
        SELECT extname FROM pg_extension WHERE extname <> 'plpgsql' AND NOT pg_has_role(extowner, 'MEMBER') ORDER BY 1
        """

    /// Tables that extensions owned by other roles keep their configuration in (pg_dump copies their rows).
    static let foreignExtensionTablesQuery = """
        SELECT n.nspname, c.relname
        FROM pg_extension e
        CROSS JOIN LATERAL unnest(e.extconfig) AS config(oid)
        JOIN pg_class c ON c.oid = config.oid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE NOT pg_has_role(e.extowner, 'MEMBER')
        ORDER BY 1, 2
        """

    /// Schemas pg_dump can't read: no USAGE, or a table or sequence without SELECT.
    static let unreadableSchemasQuery = """
        SELECT n.nspname FROM pg_namespace n
        WHERE n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'
          AND (NOT has_schema_privilege(n.oid, 'USAGE')
            OR EXISTS (SELECT 1 FROM pg_class c WHERE c.relnamespace = n.oid AND c.relkind IN ('r', 'p', 'm', 'S')
                       AND NOT has_table_privilege(c.oid, 'SELECT')))
        ORDER BY 1
        """

    /// Supabase Storage keeps its files outside the database: copying storage.objects rows would
    /// point the target at files it doesn't have.
    static let platformSchemasWithoutData: Set<String> = ["storage"]

    /// Tables in the given schemas, with their stored columns, that the current user can read
    /// (`privileges` = SELECT) or replace (INSERT and TRUNCATE).
    static func platformTablesQuery(privileges: [String]) -> String {
        let checks = privileges.map { "has_table_privilege(c.oid, '\($0)')" }.joined(separator: " AND ")
        return """
            SELECT n.nspname, c.relname, coalesce(string_agg(a.attname, ',' ORDER BY a.attname), '')
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''
            WHERE n.nspname = ANY($1::text[]) AND c.relkind = 'r' AND \(checks)
              -- pg_dump doesn't copy rows of extensions' own tables.
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid
                              AND d.deptype = 'e')
            GROUP BY 1, 2
            ORDER BY 1, 2
            """
    }

    /// Run with an empty search_path, so definitions come out schema-qualified.
    static let platformTriggersQuery = """
        SELECT format('trigger %s on %I.%I', t.tgname, n.nspname, c.relname), pg_get_triggerdef(t.oid)
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_proc p ON p.oid = t.tgfoid JOIN pg_namespace fn ON fn.oid = p.pronamespace
        WHERE NOT t.tgisinternal AND n.nspname = ANY($1::text[]) AND NOT fn.nspname = ANY($1::text[])
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
        ORDER BY 1
        """

    /// Run with an empty search_path, so expressions come out schema-qualified.
    static let platformPoliciesQuery = """
        SELECT format('policy %s on %I.%I', pol.polname, n.nspname, c.relname),
          format('CREATE POLICY %I ON %I.%I AS %s FOR %s TO %s', pol.polname, n.nspname, c.relname,
            CASE WHEN pol.polpermissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
            CASE pol.polcmd WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT' WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' ELSE 'ALL' END,
            (SELECT string_agg(CASE WHEN r = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(r)) END, ', ')
             FROM unnest(pol.polroles) AS r))
          || coalesce(' USING (' || pg_get_expr(pol.polqual, pol.polrelid) || ')', '')
          || coalesce(' WITH CHECK (' || pg_get_expr(pol.polwithcheck, pol.polrelid) || ')', '')
        FROM pg_policy pol JOIN pg_class c ON c.oid = pol.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = ANY($1::text[])
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
        ORDER BY 1
        """

    static func plan(source: any DatabaseConnection, target: any DatabaseConnection) async throws -> Plan {
        let rows: (any DatabaseConnection, String) async throws -> [[String]] = { db, sql in
            try await db.query(sql).rows.map { $0.map { $0 ?? "" } }
        }
        var plan = Plan()
        let unreadable = Set(try await rows(source, unreadableSchemasQuery).map { $0[0] })
        var skipped: [String: String] = [:]
        for row in try await rows(target, targetSchemasQuery) {
            let (schema, owned, holdsOthers) = (row[0], row[1] == "1", row[2] == "1")
            if !owned {
                skipped[schema] = "belongs to another role in the target"
            } else if holdsOthers, schema == "public" {
                plan.clearedSchemas.append(schema)
            } else if holdsOthers {
                skipped[schema] = "holds objects of another role in the target"
            }
        }
        for schema in unreadable where skipped[schema] == nil {
            skipped[schema] = "isn't readable in the source"
        }
        plan.clearedSchemas.removeAll { skipped[$0] != nil }
        plan.skippedSchemas = skipped.keys.sorted().map { .init(schema: $0, reason: skipped[$0]!) }
        plan.skippedExtensions = try await rows(target, foreignExtensionsQuery).map { $0[0] }
        plan.skippedTableData = try await rows(source, foreignExtensionTablesQuery)
            .map { Plan.Table(schema: $0[0], name: $0[1]) }
            .filter { !skipped.keys.contains($0.schema) }
        plan.sourceHasPublicSchema = try await source.listSchemas().contains("public")

        let targetEventTriggers = Set(try await rows(target, "SELECT evtname FROM pg_event_trigger").map { $0[0] })
        plan.skippedEventTriggers = try await rows(source, "SELECT evtname FROM pg_event_trigger ORDER BY 1")
            .map { $0[0] }.filter { !targetEventTriggers.contains($0) }

        let platform = plan.skippedSchemaNames
        guard !platform.isEmpty else { return plan }
        let schemas = [arrayLiteral(platform)]
        let withColumns: (any DatabaseConnection, [String]) async throws -> [String: Set<String>] = { db, privileges in
            var tables: [String: Set<String>] = [:]
            for row in try await db.query(platformTablesQuery(privileges: privileges), parameters: schemas).rows {
                let key = "\(row[0] ?? "")\u{0}\(row[1] ?? "")"
                tables[key] = Set((row[2] ?? "").split(separator: ",").map(String.init))
            }
            return tables
        }
        let readable = try await withColumns(source, ["SELECT"])
        let writable = try await withColumns(target, ["INSERT", "TRUNCATE"])
        plan.platformTables = readable.keys.sorted().compactMap { key in
            let parts = key.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
            guard let columns = writable[key], readable[key]!.isSubset(of: columns),
                  !platformSchemasWithoutData.contains(parts[0]) else { return nil }
            return Plan.Table(schema: parts[0], name: parts[1])
        }

        plan.foreignKeysIntoPlatform = try await source.query("""
            SELECT format('%I.%I → %I.%I', n.nspname, c.relname, rn.nspname, rc.relname)
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_class rc ON rc.oid = con.confrelid JOIN pg_namespace rn ON rn.oid = rc.relnamespace
            WHERE con.contype = 'f' AND rn.nspname = ANY($1::text[]) AND NOT n.nspname = ANY($1::text[])
            ORDER BY 1
            """, parameters: schemas).rows.compactMap { $0.first ?? nil }

        // Definitions come out schema-qualified with an empty search_path.
        _ = try await source.query("SET search_path = ''")
        defer { Task { _ = try? await source.query("RESET search_path") } }
        let statements: (String) async throws -> [Statement] = { sql in
            try await source.query(sql, parameters: schemas).rows.map { Statement(label: $0[0] ?? "", sql: $0[1] ?? "") }
        }
        plan.platformTriggers = try await statements(platformTriggersQuery)
        plan.platformPolicies = try await statements(platformPoliciesQuery)
        _ = try await source.query("RESET search_path")

        let sourcePublications = Set(try await rows(source, "SELECT pubname FROM pg_publication").map { $0[0] })
        plan.keptPublications = try await rows(target, """
            SELECT pubname FROM pg_publication WHERE NOT pg_has_role(pubowner, 'MEMBER') ORDER BY 1
            """).map { $0[0] }.filter(sourcePublications.contains)
        return plan
    }

    /// A text[] literal, such as {"auth","storage"}.
    static func arrayLiteral(_ values: [String]) -> String {
        "{" + values.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            .joined(separator: ",") + "}"
    }

    /// SQL that runs before the copy. It drops every schema the plan doesn't skip or clear, with
    /// everything in it, empties the cleared ones, and removes the user's large objects.
    static func wipeScript(_ plan: Plan, copyPlatformRows: Bool = false) -> String {
        let literal = { (name: String) in "'" + name.replacingOccurrences(of: "'", with: "''") + "'" }
        let kept = (plan.skippedSchemaNames + plan.clearedSchemas).map(literal)
        let keep = kept.isEmpty ? "" : " AND nspname NOT IN (\(kept.joined(separator: ", ")))"
        var lines = [
            "-- DBJoy: delete everything in the target before loading the copy.",
            "SET client_min_messages = warning;",
            // Names below come out schema-qualified.
            "SELECT pg_catalog.set_config('search_path', '', false);",
            // Fail instead of waiting forever when another session holds a lock on the target.
            "SET lock_timeout = '10s';",
            "DO $dbjoy$",
            "DECLARE s name;",
            "BEGIN",
            "  FOR s IN SELECT nspname FROM pg_namespace WHERE nspname <> 'information_schema' AND nspname !~ '^pg_'\(keep) LOOP",
            "    EXECUTE format('DROP SCHEMA %I CASCADE', s);",
            "  END LOOP;",
            "  PERFORM lo_unlink(oid) FROM pg_largeobject_metadata WHERE pg_has_role(lomowner, 'MEMBER');",
            "END $dbjoy$;",
        ]
        if !plan.skippedSchemas.isEmpty {
            // The source's policies replace these after the copy.
            let skipped = plan.skippedSchemaNames.map(literal).joined(separator: ", ")
            lines.append("""
                DO $dbjoy$
                DECLARE r record;
                BEGIN
                  FOR r IN SELECT pol.polname, n.nspname, c.relname FROM pg_policy pol
                           JOIN pg_class c ON c.oid = pol.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                           WHERE n.nspname IN (\(skipped))
                             -- Extensions (pg_cron) keep their own tables' policies.
                             AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
                  LOOP
                    BEGIN
                      EXECUTE format('DROP POLICY %I ON %I.%I', r.polname, r.nspname, r.relname);
                    EXCEPTION WHEN insufficient_privilege THEN
                      RAISE WARNING 'DBJoy: kept the target''s policy % on %.%: %', r.polname, r.nspname, r.relname, SQLERRM;
                    END;
                  END LOOP;
                END $dbjoy$;
                """)
        }
        if plan.copiesPublications {
            lines.append("""
                DO $dbjoy$
                DECLARE r record;
                BEGIN
                  FOR r IN SELECT pubname FROM pg_publication WHERE pg_has_role(pubowner, 'MEMBER') LOOP
                    EXECUTE format('DROP PUBLICATION %I', r.pubname);
                  END LOOP;
                END $dbjoy$;
                """)
        }
        for schema in plan.clearedSchemas {
            lines.append(clearScript(schema: schema))
        }
        let publicKept = plan.skippedSchemaNames.contains("public") || plan.clearedSchemas.contains("public")
        if plan.sourceHasPublicSchema, !publicKept {
            // pg_dump leaves out the public schema, which every database starts with. Recreate it
            // the way CREATE DATABASE makes it (owned by pg_database_owner since PostgreSQL 15).
            lines += [
                "CREATE SCHEMA public;",
                "GRANT USAGE ON SCHEMA public TO PUBLIC;",
                "DO $dbjoy$",
                "BEGIN",
                "  IF current_setting('server_version_num')::int >= 150000 THEN",
                "    ALTER SCHEMA public OWNER TO pg_database_owner;",
                "  END IF;",
                "EXCEPTION WHEN insufficient_privilege THEN NULL;",
                "END $dbjoy$;",
            ]
        }
        if copyPlatformRows, !plan.platformTables.isEmpty {
            lines.append("TRUNCATE " + plan.platformTables.map { quoteIdentifier($0.schema) + "." + quoteIdentifier($0.name) }
                .joined(separator: ", ") + ";")
            // Load the platform rows without firing triggers or checking foreign keys, where allowed
            // (Supabase lets postgres do this; it's how its own restores work).
            lines.append("""
                DO $dbjoy$
                BEGIN
                  SET session_replication_role = replica;
                EXCEPTION WHEN insufficient_privilege THEN NULL;
                END $dbjoy$;
                """)
        }
        lines.append("SET lock_timeout = 0;")
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// SQL that runs after the copy: the source's triggers and policies on the platform tables.
    /// Each one that fails becomes a warning, so a single platform quirk doesn't undo the copy.
    static func finishScript(_ plan: Plan) -> String {
        let literal = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        var lines = ["SELECT pg_catalog.set_config('search_path', '', false);"]
        for statement in plan.platformTriggers + plan.platformPolicies {
            lines.append("""
                DO $dbjoy$
                BEGIN
                  EXECUTE \(literal(statement.sql));
                EXCEPTION WHEN OTHERS THEN
                  RAISE WARNING 'DBJoy: couldn''t create %: %', \(literal(statement.label)), SQLERRM;
                END $dbjoy$;
                """)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Drops what the current user owns in a schema, one object at a time: extensions, relations,
    /// routines, types, collations, text search configurations and operators. Objects that belong
    /// to an extension go with it; other roles' objects stay.
    static func clearScript(schema: String) -> String {
        let literal = "'" + schema.replacingOccurrences(of: "'", with: "''") + "'"
        return """
            DO $dbjoy$
            DECLARE
              target oid := (SELECT oid FROM pg_namespace WHERE nspname = \(literal));
              r record;
            BEGIN
              FOR r IN SELECT extname FROM pg_extension WHERE extnamespace = target AND pg_has_role(extowner, 'MEMBER') LOOP
                EXECUTE format('DROP EXTENSION IF EXISTS %I CASCADE', r.extname);
              END LOOP;
              FOR r IN SELECT c.oid, c.relkind, format('%I.%I', n.nspname, c.relname) AS name
                       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                       WHERE c.relnamespace = target AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f', 'c')
                         AND pg_has_role(c.relowner, 'MEMBER')
                         AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
                                         AND d.objid = c.oid AND d.deptype = 'e')
              LOOP
                -- An earlier CASCADE (or the parent table) may have dropped it already.
                CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = r.oid);
                EXECUTE format('DROP %s %s CASCADE', CASE r.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW'
                  WHEN 'S' THEN 'SEQUENCE' WHEN 'f' THEN 'FOREIGN TABLE' WHEN 'c' THEN 'TYPE' ELSE 'TABLE' END, r.name);
              END LOOP;
              FOR r IN SELECT p.oid, p.prokind, p.oid::regprocedure::text AS name FROM pg_proc p
                       WHERE p.pronamespace = target AND pg_has_role(p.proowner, 'MEMBER')
                         AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass
                                         AND d.objid = p.oid AND d.deptype = 'e')
              LOOP
                CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.oid);
                EXECUTE format('DROP %s %s CASCADE', CASE r.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE'
                  ELSE 'FUNCTION' END, r.name);
              END LOOP;
              FOR r IN SELECT t.oid, t.typtype, t.oid::regtype::text AS name FROM pg_type t
                       WHERE t.typnamespace = target AND t.typtype IN ('e', 'd', 'r', 'c') AND t.typrelid = 0
                         AND pg_has_role(t.typowner, 'MEMBER')
                         AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass
                                         AND d.objid = t.oid AND d.deptype = 'e')
              LOOP
                CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_type WHERE oid = r.oid);
                EXECUTE format('DROP %s %s CASCADE', CASE r.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END, r.name);
              END LOOP;
              FOR r IN SELECT format('%I.%I', n.nspname, c.collname) AS name FROM pg_collation c
                       JOIN pg_namespace n ON n.oid = c.collnamespace
                       WHERE c.collnamespace = target AND pg_has_role(c.collowner, 'MEMBER')
                         AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_collation'::regclass
                                         AND d.objid = c.oid AND d.deptype = 'e')
              LOOP
                EXECUTE format('DROP COLLATION IF EXISTS %s CASCADE', r.name);
              END LOOP;
              FOR r IN SELECT format('%I.%I', n.nspname, c.cfgname) AS name FROM pg_ts_config c
                       JOIN pg_namespace n ON n.oid = c.cfgnamespace
                       WHERE c.cfgnamespace = target AND pg_has_role(c.cfgowner, 'MEMBER')
                         AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_ts_config'::regclass
                                         AND d.objid = c.oid AND d.deptype = 'e')
              LOOP
                EXECUTE format('DROP TEXT SEARCH CONFIGURATION IF EXISTS %s CASCADE', r.name);
              END LOOP;
              FOR r IN SELECT o.oid, o.oid::regoperator::text AS name FROM pg_operator o
                       WHERE o.oprnamespace = target AND pg_has_role(o.oprowner, 'MEMBER')
                         AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_operator'::regclass
                                         AND d.objid = o.oid AND d.deptype = 'e')
              LOOP
                CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_operator WHERE oid = r.oid);
                EXECUTE format('DROP OPERATOR %s CASCADE', r.name);
              END LOOP;
            END $dbjoy$;
            """
    }

    /// pg_dump arguments that leave out what the plan skips. Names are quoted so pg_dump takes them
    /// literally rather than as patterns.
    static func exclusionArguments(_ plan: Plan) -> [String] {
        plan.skippedSchemaNames.map { "--exclude-schema=" + quoteIdentifier($0) }
            + plan.skippedExtensions.map { "--exclude-extension=" + quoteIdentifier($0) }
            + plan.skippedTableData.map { "--exclude-table-data=" + quoteIdentifier($0.schema) + "." + quoteIdentifier($0.name) }
            + (plan.copiesPublications ? [] : ["--no-publications"])
            + ["--no-subscriptions"]
    }

    /// One part of what psql reads, in order: SQL written by DBJoy, or a pg_dump run's output.
    enum Segment: Equatable {
        case sql(String)
        /// pg_dump's arguments, and the `DumpFilter` its output goes through, if any.
        case dump([String], filter: DumpFilter.Settings?)
    }

    static func segments(_ plan: Plan, options: Options) -> [Segment] {
        var segments: [Segment] = [.sql(wipeScript(plan, copyPlatformRows: options.copiesPlatformRows))]
        if options.copiesPlatformRows, !plan.platformTables.isEmpty {
            segments.append(.dump(["--data-only", "--no-owner", "--no-privileges", "--verbose"]
                + plan.platformTables.map { "--table=" + quoteIdentifier($0.schema) + "." + quoteIdentifier($0.name) },
                filter: nil))
            segments.append(.sql("SET session_replication_role = origin;\n"))
        }
        segments.append(.dump(["--format=plain", "--verbose"]
            + (options.keepOwnership ? [] : ["--no-owner", "--no-privileges"])
            + (options.includeData ? [] : ["--schema-only"])
            + exclusionArguments(plan),
            filter: .init(relaxingReferencesTo: options.copiesPlatformRows ? [] : plan.skippedSchemaNames)))
        if !plan.platformTriggers.isEmpty || !plan.platformPolicies.isEmpty {
            segments.append(.sql(finishScript(plan)))
        }
        return segments
    }

    /// Copies the source into the target. Returns the warnings DBJoy raised along the way, such as
    /// a policy it couldn't replace.
    @discardableResult
    func run(from source: PostgresToolEndpoint, to target: PostgresToolEndpoint, plan: Plan,
             options: Options, progress: @escaping @Sendable (Progress) -> Void) async throws -> [String] {
        guard let pgDump = BundledTools.postgres("pg_dump"), let psql = BundledTools.postgres("psql") else {
            throw DatabaseError("pg_dump and psql weren't found. Install them with: brew install libpq")
        }
        return try await withTaskCancellationHandler {
            try await copy(pgDump: pgDump, psql: psql, source: source, target: target, plan: plan, options: options,
                           progress: progress)
        } onCancel: {
            cancel()
        }
    }

    /// Stops both tools. psql exits before it reaches the end of its input, so nothing is committed.
    func cancel() {
        lock.lock()
        isCancelled = true
        let processes = running
        lock.unlock()
        // psql first: once pg_dump stops, its output ends, and psql must not see that as the end of the copy.
        for process in processes.reversed() where process.isRunning { process.terminate() }
    }

    private func setRunning(_ processes: [Process]) {
        lock.withLock { running = processes }
    }

    private var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    private func copy(pgDump: URL, psql: URL, source: PostgresToolEndpoint, target: PostgresToolEndpoint,
                      plan: Plan, options: Options,
                      progress: @escaping @Sendable (Progress) -> Void) async throws -> [String] {
        let load = Process()
        load.executableURL = psql
        load.arguments = target.arguments
            + ["--no-psqlrc", "--quiet", "--single-transaction", "--set", "ON_ERROR_STOP=1", "--file", "-"]
        target.configure(load)
        let loadInput = Pipe()
        load.standardInput = loadInput
        load.standardOutput = FileHandle.nullDevice
        let warnings = Warnings()
        let loadErrors = OutputTail(for: load) { line in
            if let range = line.range(of: "WARNING:  DBJoy: ") { warnings.append(String(line[range.upperBound...])) }
        }
        let loadExit = ProcessExit(load)
        let input = loadInput.fileHandleForWriting.fileDescriptor
        let step = StepTracker(progress)

        /// Stops psql before it reaches the end of its input, so it commits nothing.
        func abandon() async {
            load.terminate()
            await loadExit.wait()
        }

        step.set("Connecting")
        setRunning([load])
        defer { setRunning([]) }
        try load.run()

        for segment in Self.segments(plan, options: options) {
            switch segment {
            case .sql(let sql):
                guard await Self.pump(Data(sql.utf8), from: nil, to: input, onBytes: { _ in }), !cancelled else {
                    await abandon()
                    if cancelled { throw CancellationError() }
                    throw Self.failure("Couldn't write to the target database.", output: await loadErrors.finalText())
                }
            case .dump(let arguments, let filterSettings):
                let dump = Process()
                dump.executableURL = pgDump
                dump.arguments = source.arguments + arguments
                source.configure(dump)
                let dumpOutput = Pipe()
                dump.standardInput = FileHandle.nullDevice
                dump.standardOutput = dumpOutput
                let dumpErrors = OutputTail(for: dump) { line in
                    if let table = Self.table(inVerboseLine: line) {
                        step.set("Copying \(table)")
                    } else if line.contains("reading") || line.contains("identifying") {
                        step.set("Reading the source")
                    }
                }
                let dumpExit = ProcessExit(dump)
                setRunning([dump, load])
                do {
                    try dump.run()
                } catch {
                    await abandon()
                    throw error
                }
                let offset = step.bytes
                let reachedEnd = await Self.pump(Data(), from: dumpOutput.fileHandleForReading.fileDescriptor, to: input,
                                                 filter: filterSettings.map(DumpFilter.init)) {
                    step.setBytes(offset + $0)
                }
                // psql stopped reading (it failed); pg_dump may be blocked writing to the full pipe.
                if !reachedEnd { dump.terminate() }
                await dumpExit.wait()
                let dumpSucceeded = dump.terminationReason == .exit && dump.terminationStatus == 0
                guard reachedEnd, dumpSucceeded, !cancelled else {
                    await abandon()
                    if cancelled { throw CancellationError() }
                    if !dumpSucceeded, reachedEnd {
                        throw Self.failure("Couldn't read the source database.", output: await dumpErrors.finalText())
                    }
                    throw Self.failure("Couldn't write to the target database.", output: await loadErrors.finalText())
                }
                setRunning([load])
            }
        }

        // The end of psql's input: it commits.
        step.set("Finishing on the target")
        try? loadInput.fileHandleForWriting.close()
        await loadExit.wait()
        if cancelled { throw CancellationError() }
        guard load.terminationReason == .exit, load.terminationStatus == 0 else {
            throw Self.failure("Couldn't write to the target database.", output: await loadErrors.finalText())
        }
        _ = await loadErrors.finalText()
        return warnings.all
    }

    /// Writes `prefix`, then everything from `input` (if any), to `output`. Returns false if
    /// writing fails (the reader went away) and true once `input` ends.
    private static func pump(_ prefix: Data, from input: Int32?, to output: Int32, filter: DumpFilter? = nil,
                             onBytes: @escaping @Sendable (Int64) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                // A closed pipe returns EPIPE instead of killing the app with SIGPIPE.
                _ = fcntl(output, F_SETNOSIGPIPE, 1)
                guard prefix.withUnsafeBytes({ writeAll($0, to: output) }) else {
                    continuation.resume(returning: false)
                    return
                }
                guard let input else {
                    continuation.resume(returning: true)
                    return
                }
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                var total: Int64 = 0
                var reported: Int64 = 0
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 {
                        let rest = filter?.finish() ?? []
                        let ok = rest.withUnsafeBytes { writeAll($0, to: output) }
                        onBytes(total)
                        continuation.resume(returning: ok)
                        return
                    }
                    let written = buffer.withUnsafeBytes { bytes in
                        let chunk = UnsafeRawBufferPointer(rebasing: bytes[..<count])
                        guard let filter else { return writeAll(chunk, to: output) }
                        return filter.process(chunk).withUnsafeBytes { writeAll($0, to: output) }
                    }
                    guard written else {
                        continuation.resume(returning: false)
                        return
                    }
                    total += Int64(count)
                    if total - reported >= 1 << 18 {
                        reported = total
                        onBytes(total)
                    }
                }
            }
        }
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to output: Int32) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(output, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    /// The table in a pg_dump --verbose line such as `pg_dump: dumping contents of table "public.orders"`.
    static func table(inVerboseLine line: String) -> String? {
        guard let range = line.range(of: "dumping contents of table ") else { return nil }
        return line[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    private static func failure(_ title: String, output: String) -> DatabaseError {
        DatabaseError(title + "\n\n" + errorDetail(output))
    }

    /// The error lines of a tool's output, without psql's `psql:<stdin>:123: ` prefixes.
    static func errorDetail(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { line -> String in
            var line = String(line)
            if line.hasPrefix("psql:"), let range = line.range(of: #"^psql:[^:]*:\d+: "#, options: .regularExpression) {
                line.removeSubrange(range)
            }
            return line
        }
        let markers = ["error:", "ERROR:", "FATAL:", "DETAIL:", "HINT:", "CONTEXT:", "LINE "]
        let start = lines.firstIndex { line in markers.prefix(3).contains { line.contains($0) } }
        let relevant = start.map { Array(lines[$0...]).filter { line in markers.contains { line.contains($0) } || line.hasPrefix(" ") } }
            ?? Array(lines.suffix(8))
        var detail = relevant.prefix(12).joined(separator: "\n")
        if detail.contains("lock timeout") {
            detail += "\n\nAnother session is using the target database. Close it (or its open transaction) and try again."
        }
        return detail.isEmpty ? "The tool exited without saying why." : detail
    }
}

/// Edits pg_dump's plain output as it streams. Each object in the output starts with a
/// `-- Name: …; Type: …` comment. The filter drops event triggers (from their header to the next
/// header) and adds NOT VALID to foreign keys that reference tables whose rows aren't copied.
/// COPY data passes through untouched.
final class DumpFilter: @unchecked Sendable {
    struct Settings: Equatable {
        /// Schemas whose rows aren't copied; foreign keys into them become NOT VALID.
        var relaxingReferencesTo: [String] = []
    }

    private var pending: [UInt8] = []
    private var inCopy = false
    private var skipping = false
    private var inForeignKey = false
    /// A foreign key statement being collected, up to its semicolon.
    private var statement: [UInt8] = []
    private let references: [[UInt8]]

    init(_ settings: Settings = .init()) {
        references = settings.relaxingReferencesTo
            .flatMap { ["REFERENCES \($0).", "REFERENCES \(DatabaseCopier.quoteIdentifier($0))."] }
            .map { Array($0.utf8) }
    }

    func process(_ chunk: UnsafeRawBufferPointer) -> [UInt8] {
        pending.append(contentsOf: chunk)
        var output: [UInt8] = []
        output.reserveCapacity(pending.count)
        var start = 0
        pending.withUnsafeBufferPointer { bytes in
            while let end = bytes[start...].firstIndex(of: 0x0A) {
                handle(UnsafeBufferPointer(rebasing: bytes[start...end]), into: &output)
                start = end + 1
            }
        }
        pending.removeFirst(start)
        return output
    }

    func finish() -> [UInt8] {
        var output: [UInt8] = []
        if !pending.isEmpty { pending.withUnsafeBufferPointer { handle($0, into: &output) } }
        output += statement
        pending = []
        statement = []
        return output
    }

    private static let header = Array("-- Name: ".utf8)
    private static let dataHeader = Array("-- Data for Name: ".utf8)
    private static let copy = Array("COPY ".utf8)
    private static let fromStdin = Array("FROM stdin;\n".utf8)
    private static let endOfCopy = Array("\\.\n".utf8)
    private static let statementEnd = Array(";\n".utf8)
    private static let notValid = Array(" NOT VALID;\n".utf8)

    private func handle(_ line: UnsafeBufferPointer<UInt8>, into output: inout [UInt8]) {
        if inCopy {
            if line.elementsEqual(Self.endOfCopy) { inCopy = false }
            if !skipping { output.append(contentsOf: line) }
            return
        }
        if line.starts(with: Self.header) || line.starts(with: Self.dataHeader) {
            output += statement
            statement = []
            let text = String(decoding: line, as: UTF8.self)
            skipping = text.contains("; Type: EVENT TRIGGER;") || text.hasPrefix("-- Name: EVENT TRIGGER ")
            inForeignKey = text.contains("; Type: FK CONSTRAINT;")
            if !skipping { output.append(contentsOf: line) }
            return
        }
        // psql meta-commands (\restrict, \unrestrict) always stay.
        if line.first == UInt8(ascii: "\\") {
            output.append(contentsOf: line)
            return
        }
        if skipping { return }
        if inForeignKey, !references.isEmpty {
            statement.append(contentsOf: line)
            guard line.reversed().starts(with: Self.statementEnd.reversed()) else { return }
            if references.contains(where: { statement.contains(subsequence: $0) }) {
                statement.removeLast(Self.statementEnd.count)
                statement += Self.notValid
            }
            output += statement
            statement = []
            return
        }
        if line.starts(with: Self.copy), line.reversed().starts(with: Self.fromStdin.reversed()) { inCopy = true }
        output.append(contentsOf: line)
    }
}

private extension Array where Element == UInt8 {
    func contains(subsequence needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return needle.isEmpty }
        return (0...(count - needle.count)).contains { start in self[start..<start + needle.count].elementsEqual(needle) }
    }
}

/// Warnings collected from psql's output.
private final class Warnings: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// Reports the current step, keeping the byte count.
private final class StepTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = DatabaseCopier.Progress(step: "", bytes: 0)
    private let report: @Sendable (DatabaseCopier.Progress) -> Void

    init(_ report: @escaping @Sendable (DatabaseCopier.Progress) -> Void) {
        self.report = report
    }

    func set(_ step: String) {
        lock.lock()
        guard progress.step != step else { return lock.unlock() }
        progress.step = step
        let current = progress
        lock.unlock()
        report(current)
    }

    var bytes: Int64 { lock.withLock { progress.bytes } }

    func setBytes(_ bytes: Int64) {
        lock.lock()
        progress.bytes = bytes
        let current = progress
        lock.unlock()
        report(current)
    }
}

/// Collects a process's stderr (the last 64 KB), passing each line to `onLine`.
private final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = Data()
    private let closed = Latch()

    init(for process: Process, onLine: (@Sendable (String) -> Void)? = nil) {
        let pipe = Pipe()
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                closed.open()
                return
            }
            lock.lock()
            data.append(chunk)
            if data.count > 1 << 16 { data.removeFirst(data.count - (1 << 16)) }
            pending.append(chunk)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            lock.unlock()
            if let onLine { lines.forEach(onLine) }
        }
    }

    /// Everything collected, once the process has closed its end (call after it exits).
    func finalText() async -> String {
        await closed.wait()
        return text
    }

    private var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Opens once; any number of callers can wait for it.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        isOpen = true
        let waiting = waiters
        waiters = []
        lock.unlock()
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Lets several callers await a process's exit.
private final class ProcessExit: Sendable {
    private let latch = Latch()

    init(_ process: Process) {
        process.terminationHandler = { [latch] _ in latch.open() }
    }

    func wait() async { await latch.wait() }
}
