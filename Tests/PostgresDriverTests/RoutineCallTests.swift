import DBCore
import Foundation
import PostgresDriver
import Testing

/// Reads routine parameters and runs the call SQL that the Run function sheet builds.
/// Enable with DBJOY_TEST_PG=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBJOY_TEST_PG"] != nil), .serialized)
struct RoutineCallTests {
    static let env = ProcessInfo.processInfo.environment

    func connect() async throws -> any DatabaseConnection {
        let config = ConnectionConfig(name: "test", host: "localhost", port: Int(Self.env["DBJOY_TEST_PG_PORT"] ?? "") ?? 55432,
                                      user: "postgres", database: "dbjoy_sample", sslMode: .disable)
        return try await PostgresDriver().connect(config, password: Self.env["DBJOY_TEST_PG_PASSWORD"] ?? "secret", database: nil)
    }

    /// Finds the routine in the sidebar listing, reads its parameters and runs the generated call.
    func call(_ name: String, _ arguments: [RoutineArgument], on db: any DatabaseConnection) async throws -> (String, [[String?]]) {
        let ref = try #require(try await db.listObjects(schema: "routine_scratch").first { $0.name == name }?.ref)
        let sql = db.dialect.callStatement(for: ref, parameters: try await db.parameters(of: ref), arguments: arguments)
        return (sql, try await db.query(sql).rows)
    }

    @Test func runsFunctionsAndProcedures() async throws {
        let db = try await connect()
        defer { Task { await db.close() } }
        _ = try await db.query("DROP SCHEMA IF EXISTS routine_scratch CASCADE")
        _ = try await db.query("CREATE SCHEMA routine_scratch")
        for ddl in [
            "CREATE FUNCTION routine_scratch.greet(who text, times int DEFAULT 2, punct text DEFAULT '!') RETURNS text "
                + "LANGUAGE sql AS $$ SELECT repeat('hi ' || who || punct, times) $$",
            "CREATE FUNCTION routine_scratch.add(int, int DEFAULT 10) RETURNS int LANGUAGE sql AS $$ SELECT $1 + $2 $$",
            "CREATE FUNCTION routine_scratch.total(VARIADIC nums int[]) RETURNS int LANGUAGE sql AS $$ SELECT sum(n)::int FROM unnest(nums) n $$",
            "CREATE FUNCTION routine_scratch.pairs(n int, OUT a int, OUT b text) RETURNS SETOF record "
                + "LANGUAGE sql AS $$ SELECT g, 'x' || g FROM generate_series(1, n) g $$",
            "CREATE FUNCTION routine_scratch.now_ish() RETURNS int LANGUAGE sql AS $$ SELECT 42 $$",
            "CREATE PROCEDURE routine_scratch.double(x int, INOUT y int, OUT z text) LANGUAGE plpgsql AS $$ BEGIN y := x * 2; z := 'done'; END $$",
        ] { _ = try await db.query(ddl) }

        let greet = try #require(try await db.listObjects(schema: "routine_scratch").first { $0.name == "greet" }?.ref)
        #expect(try await db.parameters(of: greet) == [
            RoutineParameter(name: "who", type: "text"),
            RoutineParameter(name: "times", type: "integer", defaultValue: "2"),
            RoutineParameter(name: "punct", type: "text", defaultValue: "'!'::text"),
        ])

        // Named notation skips the middle default.
        let (sql, rows) = try await call("greet", [.value("Ana"), .useDefault, .value("?")], on: db)
        #expect(sql == #"SELECT * FROM "routine_scratch"."greet"("who" => 'Ana'::text, "punct" => '?'::text);"#)
        #expect(rows == [["hi Ana?hi Ana?"]])
        #expect(try await call("greet", [.value("it's"), .value("1"), .null], on: db).1 == [[nil]])
        // Unnamed parameters go by position.
        #expect(try await call("add", [.value("5"), .useDefault], on: db).1 == [["15"]])
        #expect(try await call("total", [.value("{1,2,3}")], on: db).1 == [["6"]])
        #expect(try await call("pairs", [.value("2")], on: db).1 == [["1", "x1"], ["2", "x2"]])
        #expect(try await call("now_ish", [], on: db).1 == [["42"]])
        #expect(try await call("double", [.value("4"), .null], on: db).1 == [["8", "done"]])

        let gone = ObjectRef(schema: "routine_scratch", name: "greet", kind: .function, arguments: "who text")
        await #expect(throws: DatabaseError.self) { try await db.parameters(of: gone) }
        _ = try await db.query("DROP SCHEMA routine_scratch CASCADE")
    }
}
