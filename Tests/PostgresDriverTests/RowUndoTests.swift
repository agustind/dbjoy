import DBCore
import Foundation
import PostgresDriver
import Testing

/// Commits row changes the way a table tab does, then reverts them with the captured undo SQL.
/// Enable with DBJOY_TEST_PG=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBJOY_TEST_PG"] != nil), .serialized)
struct RowUndoTests {
    static let env = ProcessInfo.processInfo.environment
    let ref = ObjectRef(schema: "public", name: "undo_scratch", kind: .table)

    func connect() async throws -> any DatabaseConnection {
        let config = ConnectionConfig(name: "test", host: "localhost", port: Int(Self.env["DBJOY_TEST_PG_PORT"] ?? "") ?? 55432,
                                      user: "postgres", database: "dbjoy_sample", sslMode: .disable)
        return try await PostgresDriver().connect(config, password: Self.env["DBJOY_TEST_PG_PASSWORD"] ?? "secret", database: nil)
    }

    func setUp(_ db: any DatabaseConnection) async throws {
        _ = try await db.query("DROP TABLE IF EXISTS public.undo_scratch")
        _ = try await db.query("""
            CREATE TABLE public.undo_scratch (
                id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                label text, doc json, flag boolean, tags text[],
                label_upper text GENERATED ALWAYS AS (upper(label)) STORED)
            """)
        _ = try await db.query("""
            INSERT INTO public.undo_scratch (label, doc, flag, tags) VALUES
              ('one', '{"a": 1}', true, '{x,"y z"}'), ('it''s two', NULL, false, NULL), ('three', '[1, 2]', NULL, '{}')
            """)
    }

    func snapshot(_ db: any DatabaseConnection) async throws -> [[String?]] {
        try await db.query("SELECT * FROM public.undo_scratch ORDER BY id").rows
    }

    /// Commits like TableTabModel.commit and returns the undo statements, newest first.
    func commit(_ changes: [RowChange], on db: any DatabaseConnection) async throws -> [String] {
        let d = db.dialect
        let groups = changes.map { d.capturingStatements(for: $0, in: ref) }
        var results = try await db.executeInTransaction(groups.flatMap { $0 })[...]
        var undo: [String] = []
        for (change, group) in zip(changes, groups) {
            let own = Array(results.prefix(group.count))
            results = results.dropFirst(group.count)
            undo.append(try #require(d.undoStatement(for: change, in: ref, primaryKey: ["id"], generated: ["label_upper"], results: own)))
        }
        return undo.reversed()
    }

    @Test func revertRestoresTheTable() async throws {
        let db = try await connect()
        defer { Task { await db.close() } }
        try await setUp(db)
        let before = try await snapshot(db)

        let undo = try await commit([
            .delete(key: [ColumnValue("id", .value("2"))]),
            .update(key: [ColumnValue("id", .value("1"))],
                    values: [ColumnValue("label", .value("uno")), ColumnValue("doc", .null), ColumnValue("flag", .expression("NOT flag"))]),
            .insert(values: [ColumnValue("label", .value("four")), ColumnValue("doc", .value("{\"b\": 2}"))]),
        ], on: db)
        #expect(try await snapshot(db) != before)

        try await db.executeInTransaction(undo.map { TransactionStatement($0, expectedRows: 1) })
        #expect(try await snapshot(db) == before)
    }

    @Test func revertRefusesARowEditedSince() async throws {
        let db = try await connect()
        defer { Task { await db.close() } }
        try await setUp(db)

        let undo = try await commit([.update(key: [ColumnValue("id", .value("3"))], values: [ColumnValue("label", .value("drei"))])], on: db)
        _ = try await db.query("UPDATE public.undo_scratch SET label = 'someone else' WHERE id = 3")

        await #expect(throws: DatabaseError.self) {
            try await db.executeInTransaction(undo.map { TransactionStatement($0, expectedRows: 1) })
        }
        #expect(try await db.query("SELECT label FROM public.undo_scratch WHERE id = 3").rows == [["someone else"]])
        _ = try await db.query("DROP TABLE public.undo_scratch")
    }
}
