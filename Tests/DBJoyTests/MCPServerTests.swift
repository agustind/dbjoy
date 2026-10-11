@testable import DBJoy
import DBCore
import Foundation
import Testing

struct HTTPRequestParserTests {
    @Test func parsesARequestOnceItsBodyArrives() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4\r\n\r\nab".utf8))
        #expect(try parser.next() == nil)
        parser.append(Data("cd".utf8))
        let request = try #require(try parser.next())
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.header("HOST") == "127.0.0.1")
        #expect(request.body == Data("abcd".utf8))
        #expect(try parser.next() == nil)
    }

    @Test func splitsPipelinedRequests() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("GET /a HTTP/1.1\r\n\r\nPOST /b HTTP/1.1\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8))
        #expect(try parser.next()?.path == "/a")
        let second = try #require(try parser.next())
        #expect(second.path == "/b")
        #expect(second.wantsClose)
    }

    @Test func refusesChunkedAndMalformedRequests() {
        var chunked = HTTPRequestParser()
        chunked.append(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        #expect(throws: HTTPParseError.self) { try chunked.next() }

        var garbage = HTTPRequestParser()
        garbage.append(Data("hello\r\n\r\n".utf8))
        #expect(throws: HTTPParseError.self) { try garbage.next() }
    }
}

@MainActor
struct MCPServerTests {
    static let token = "test-token"

    private func server(_ connections: [ConnectionConfig] = []) -> MCPServer {
        MCPServer(connections: { connections }, password: { _ in nil }, token: Self.token)
    }

    private func post(_ body: JSONValue, to server: MCPServer, headers: [String: String] = [:]) async -> HTTPResponse {
        var all = ["host": "127.0.0.1:47821", "authorization": "Bearer \(Self.token)", "content-type": "application/json"]
        all.merge(headers) { $1 }
        return await server.handle(HTTPRequest(method: "POST", path: "/mcp", headers: all, body: (try? body.encoded()) ?? Data()))
    }

    @Test func requiresTheToken() async {
        let server = server()
        let missing = await post(["jsonrpc": "2.0", "id": 1, "method": "ping"], to: server, headers: ["authorization": ""])
        #expect(missing.status == 401)
        let wrong = await post(["jsonrpc": "2.0", "id": 1, "method": "ping"], to: server, headers: ["authorization": "Bearer nope"])
        #expect(wrong.status == 401)
    }

    @Test func refusesOtherHostsAndOrigins() async {
        let server = server()
        let rebound = await post(["jsonrpc": "2.0", "id": 1, "method": "ping"], to: server, headers: ["host": "evil.example:47821"])
        #expect(rebound.status == 403)
        let page = await post(["jsonrpc": "2.0", "id": 1, "method": "ping"], to: server, headers: ["origin": "https://evil.example"])
        #expect(page.status == 403)
        let local = await post(["jsonrpc": "2.0", "id": 1, "method": "ping"], to: server, headers: ["origin": "http://localhost:3000"])
        #expect(local.status == 200)
        #expect(MCPServer.isLoopback(host: "[::1]:47821"))
        #expect(!MCPServer.isLoopback(host: "127.0.0.1.evil.example"))
    }

    @Test func initializesASession() async throws {
        let response = await post(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                   "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                                              "clientInfo": ["name": "claude-code", "version": "1"]]], to: server())
        #expect(response.status == 200)
        #expect(response.headers["Mcp-Session-Id"] != nil)
        let json = try JSONValue.parse(response.body)
        #expect(json["id"] == 1)
        #expect(json["result"]?["protocolVersion"] == "2025-06-18")
        #expect(json["result"]?["capabilities"]?["tools"] != nil)
    }

    @Test func answersNotificationsWithAccepted() async {
        let response = await post(["jsonrpc": "2.0", "method": "notifications/initialized"], to: server())
        #expect(response.status == 202)
        #expect(response.body.isEmpty)
    }

    @Test func listsReadOnlyTools() async throws {
        let response = await post(["jsonrpc": "2.0", "id": "a", "method": "tools/list"], to: server())
        let tools = try #require(try JSONValue.parse(response.body)["result"]?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue }
                == [MCPServer.listConnections, MCPServer.listTables, MCPServer.describeTable, MCPServer.runQuery])
        #expect(tools.allSatisfy { $0["annotations"]?["readOnlyHint"] == true })
    }

    @Test func rejectsUnknownMethodsAndGET() async throws {
        let response = await post(["jsonrpc": "2.0", "id": 7, "method": "resources/list"], to: server())
        #expect(try JSONValue.parse(response.body)["error"]?["code"] == -32601)
        let get = await server().handle(HTTPRequest(method: "GET", path: "/mcp",
                                                    headers: ["host": "localhost", "authorization": "Bearer \(Self.token)"], body: Data()))
        #expect(get.status == 405)
    }

    @Test func onlySharedConnectionsAreVisible() async throws {
        let shared = ConnectionConfig(name: "Andromeda (dev)", environment: .development, database: "andromeda", allowsMCP: true)
        let hidden = ConnectionConfig(name: "Billing (prod)", environment: .production, database: "billing")
        let server = server([shared, hidden])
        let (text, isError) = await server.callTool(MCPServer.listConnections, arguments: [:], client: "test")
        #expect(!isError)
        #expect(text.contains("Andromeda (dev)"))
        #expect(!text.contains("Billing"))

        let (missing, failed) = await server.callTool(MCPServer.listTables, arguments: ["connection": "Billing (prod)"], client: "test")
        #expect(failed)
        #expect(missing.contains("No shared connection named Billing (prod)"))
    }

    @Test func resolvesConnectionsByNameOrAlone() throws {
        let a = ConnectionConfig(name: "Andromeda (dev)", allowsMCP: true)
        let b = ConnectionConfig(name: "Orion", allowsMCP: true)
        #expect(try MCPServer.resolve(nil, in: [a]).get().id == a.id)
        #expect(try MCPServer.resolve("andromeda (DEV)", in: [a, b]).get().id == a.id)
        #expect(try MCPServer.resolve(b.id.uuidString, in: [a, b]).get().id == b.id)
        #expect((try? MCPServer.resolve(nil, in: [a, b]).get()) == nil)
    }
}

/// Talks to a running server over HTTP, against the sample database.
/// Enable with DBJOY_TEST_PG=1 (see PostgresIntegrationTests).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBJOY_TEST_PG"] != nil), .serialized)
@MainActor
struct MCPServerIntegrationTests {
    static let env = ProcessInfo.processInfo.environment
    static let token = "integration-token"

    private func runningServer() async throws -> (MCPServer, Int) {
        let config = ConnectionConfig(name: "Sample", host: "localhost", port: Int(Self.env["DBJOY_TEST_PG_PORT"] ?? "") ?? 55432,
                                      user: "postgres", database: "dbjoy_sample", sslMode: .disable, allowsMCP: true)
        let password = Self.env["DBJOY_TEST_PG_PASSWORD"] ?? "secret"
        let server = MCPServer(connections: { [config] }, password: { _ in password }, token: Self.token)
        let port = Int.random(in: 49152...60000)
        server.start(port: port)
        for _ in 0..<50 where server.status != .running(port: port) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(server.status == .running(port: port))
        return (server, port)
    }

    private func call(_ tool: String, _ arguments: JSONValue, port: Int, id: Int = 1) async throws -> (text: String, isError: Bool) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": "tools/call",
                               "params": ["name": .string(tool), "arguments": arguments]]
        request.httpBody = try body.encoded()
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let result = try #require(try JSONValue.parse(data)["result"])
        return (result["content"]?[0]?["text"]?.stringValue ?? "", result["isError"] == true)
    }

    @Test func answersQuestionsOverHTTP() async throws {
        let (server, port) = try await runningServer()
        defer { server.stop() }

        let tables = try await call(MCPServer.listTables, [:], port: port)
        #expect(!tables.isError)
        #expect(tables.text.contains("customers (table)"))
        #expect(tables.text.contains("other schemas: sales"))

        let structure = try await call(MCPServer.describeTable, ["table": "orders"], port: port)
        #expect(structure.text.contains("References:"))

        let count = try await call(MCPServer.runQuery, ["sql": "SELECT count(*) AS n FROM customers"], port: port)
        #expect(!count.isError)
        #expect(count.text.contains("n (bigint)"))

        let write = try await call(MCPServer.runQuery, ["sql": "DELETE FROM audit_log"], port: port)
        #expect(write.isError)
        // A write hidden where the keyword check can't see it is stopped by the read-only transaction.
        let hidden = try await call(MCPServer.runQuery,
                                    ["sql": "WITH gone AS (DELETE FROM audit_log RETURNING 1) SELECT count(*) FROM gone"], port: port)
        #expect(hidden.isError)
        #expect(hidden.text.contains("read-only"))

        #expect(server.activity.count == 5)
        #expect(server.activity.first?.error != nil)
    }

    @Test func serializesConcurrentQueriesOnOneConnection() async throws {
        let (server, port) = try await runningServer()
        defer { server.stop() }
        let results = try await withThrowingTaskGroup(of: (String, Bool).self) { group in
            for i in 0..<8 {
                group.addTask { try await self.call(MCPServer.runQuery, ["sql": .string("SELECT \(i) AS i, pg_sleep(0.05)")], port: port, id: i) }
            }
            var results: [(String, Bool)] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { !$0.1 })
    }

    @Test func appliesTheStatementTimeout() async throws {
        let (server, port) = try await runningServer()
        defer { server.stop() }
        let setting = try await call(MCPServer.runQuery, ["sql": "SHOW statement_timeout"], port: port)
        #expect(setting.text.contains(MCPServer.statementTimeout))
    }
}
