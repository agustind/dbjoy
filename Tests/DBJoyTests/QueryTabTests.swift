@testable import DBJoy
import DBCore
import Foundation
import Testing

@MainActor
struct QueryTabFormatTests {
    @Test func formatsTheStatementUnderTheCursor() {
        let config = ConnectionConfig(name: "test", host: "localhost", user: "postgres", database: "shop", sslMode: .disable, savePassword: false)
        let model = QueryTabModel(workspace: WorkspaceModel(config: config), title: "Query 1", sql: "select 1;\nselect a, b from t;")
        model.selection = NSRange(location: 12, length: 0)
        #expect(model.formatSQL())
        #expect(model.requestedReplacement?.range == NSRange(location: 10, length: 18))
        #expect(model.requestedReplacement?.text == "SELECT\n    a,\n    b\nFROM t")

        model.sql = "SELECT 1"
        model.selection = NSRange(location: 0, length: 0)
        #expect(!model.formatSQL())
    }
}

/// Explain against the sample database. Enable with DBJOY_TEST_PG=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBJOY_TEST_PG"] != nil), .serialized)
@MainActor
struct QueryTabIntegrationTests {
    static let env = ProcessInfo.processInfo.environment

    private func connectedWorkspace() async throws -> WorkspaceModel {
        let config = ConnectionConfig(name: "test", host: "localhost", port: Int(Self.env["DBJOY_TEST_PG_PORT"] ?? "") ?? 55432,
                                      user: "postgres", database: "dbjoy_sample", sslMode: .disable, savePassword: false)
        let workspace = WorkspaceModel(config: config)
        await workspace.submitPassword(Self.env["DBJOY_TEST_PG_PASSWORD"] ?? "secret")
        try #require(workspace.phase == .connected)
        return workspace
    }

    @Test func explainRunsReadsWithAnalyze() async throws {
        let workspace = try await connectedWorkspace()
        defer { Task { await workspace.disconnect() } }
        let model = QueryTabModel(workspace: workspace, title: "Query",
                                  sql: "SELECT c.id, count(*) FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.id")
        await model.explain()?.value
        let plan = try #require(model.plan)
        #expect(plan.isAnalyzed)
        #expect(plan.executionTime != nil)
        #expect(plan.nodes.contains { $0.title.contains("orders o") })
        #expect(abs(plan.nodes.map(\.share).reduce(0, +) - 1) < 0.001)
        await model.closeConnection()
    }

    @Test func explainDoesNotRunWrites() async throws {
        try await SampleDatabaseLock.run {
            let workspace = try await connectedWorkspace()
            defer { Task { await workspace.disconnect() } }
            let before = try await workspace.connection?.query("SELECT count(*) FROM orders").rows.first?.first ?? nil
            let model = QueryTabModel(workspace: workspace, title: "Query", sql: "DELETE FROM orders")
            await model.explain()?.value
            let plan = try #require(model.plan)
            #expect(!plan.isAnalyzed)
            #expect(plan.nodes.first?.title == "Delete on orders")
            #expect(try await workspace.connection?.query("SELECT count(*) FROM orders").rows.first?.first ?? nil == before)
            await model.closeConnection()
        }
    }
}
