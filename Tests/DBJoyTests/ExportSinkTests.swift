@testable import DBJoy
import DBCore
import Foundation
import PostgresDriver
import Testing

/// Exports the sample database with the real sink. Enable with DBJOY_TEST_PG=1.
/// Set DBJOY_EXPORT_DIR to keep the output (used for restore round-trips).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBJOY_TEST_PG"] != nil), .serialized)
struct ExportSinkTests {
    static let env = ProcessInfo.processInfo.environment

    func connect() async throws -> any DatabaseConnection {
        let config = ConnectionConfig(name: "test", host: "localhost", port: Int(Self.env["DBJOY_TEST_PG_PORT"] ?? "") ?? 55432,
                                      user: "postgres", database: "dbjoy_sample", sslMode: .disable)
        return try await PostgresDriver().connect(config, password: Self.env["DBJOY_TEST_PG_PASSWORD"] ?? "secret", database: nil)
    }

    func export(_ format: ExportFormat, to url: URL) async throws {
        let db = try await connect()
        defer { Task { await db.close() } }
        let tables = try await db.listObjects(schema: "public").filter { $0.kind == .table }.map(\.ref)
        var structures: [ObjectRef: TableStructure] = [:]
        var refs = tables
        if format == .sql {
            refs = ExportEncoding.dependencyOrder(tables, foreignKeys: try await db.foreignKeys(schema: "public"))
            for ref in refs { structures[ref] = try await db.structure(of: ref) }
        }
        let sink = try ExportSink(format: format, destination: url, dialect: db.dialect, structures: structures, header: "test")
        try await db.streamRows(of: refs, batchSize: 700) { try sink.handle($0) }
        try sink.finish()
    }

    var outputDirectory: URL {
        let base = Self.env["DBJOY_EXPORT_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("dbjoy-export-test", isDirectory: true)
    }

    @Test func csvAndJSON() async throws {
        let csvDir = outputDirectory.appendingPathComponent("csv")
        let jsonDir = outputDirectory.appendingPathComponent("json")
        try? FileManager.default.removeItem(at: csvDir)
        try? FileManager.default.removeItem(at: jsonDir)
        try await export(.csv, to: csvDir)
        try await export(.json, to: jsonDir)

        let customers = try String(contentsOf: csvDir.appendingPathComponent("customers.csv"), encoding: .utf8)
        let lines = customers.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.first == "id,name,email,country,created_at,metadata")
        #expect(lines.count == 1001)

        let data = try Data(contentsOf: jsonDir.appendingPathComponent("type_showcase.json"))
        let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(rows.count == 3)
        #expect(rows[0]["c_boolean"] as? Bool == true)
        #expect(rows[0]["c_integer"] as? Int == 42)
        #expect((rows[0]["c_jsonb"] as? [String: Any])?["tags"] as? [String] == ["x", "y"])
        #expect(rows[0]["c_money"] as? String == "$19.99")
        #expect(rows[2]["c_text"] is NSNull)
        let empty = try String(contentsOf: jsonDir.appendingPathComponent("audit_log.json"), encoding: .utf8)
        #expect(empty.hasPrefix("[\n  {"))
    }

    @Test func sqlInserts() async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let file = outputDirectory.appendingPathComponent("data.sql")
        try await export(.sql, to: file)
        let sql = try String(contentsOf: file, encoding: .utf8)
        #expect(sql.hasPrefix("-- test\n\nBEGIN;"))
        #expect(sql.hasSuffix("COMMIT;\n"))
        let customers = try #require(sql.range(of: "-- public.customers"))
        let orders = try #require(sql.range(of: "-- public.orders\n"))
        #expect(customers.lowerBound < orders.lowerBound)
        #expect(sql.contains("INSERT INTO \"public\".\"products\" (\"id\", \"sku\", \"title\", \"price\", \"active\", \"tags\") OVERRIDING SYSTEM VALUE VALUES"))
        #expect(!sql.contains("\"c_generated\""))
        #expect(sql.contains("SELECT setval(pg_get_serial_sequence('\"public\".\"customers\"', 'id')"))
    }
}
