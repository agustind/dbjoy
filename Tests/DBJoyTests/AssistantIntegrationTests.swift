@testable import DBJoy
import DBCore
import Foundation
import PostgresDriver
import Testing

/// Answers Anthropic API requests with scripted responses and records what was sent.
final class ScriptedLLM: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String] = []
    nonisolated(unsafe) static var requests: [JSONValue] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.anthropic.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol sees the body as a stream.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            if let json = try? JSONValue.parse(data) { Self.requests.append(json) }
        }
        let body = Self.responses.isEmpty
            ? #"{"content": [{"type": "text", "text": "out of script"}], "stop_reason": "end_turn"}"#
            : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func toolUse(_ calls: [(id: String, name: String, input: JSONValue)]) -> String {
        let content: JSONValue = .array(calls.map { ["type": "tool_use", "id": .string($0.id), "name": .string($0.name), "input": $0.input] })
        return (["content": content, "stop_reason": "tool_use"] as JSONValue).jsonString
    }

    static func reply(_ text: String) -> String {
        (["content": [["type": "text", "text": .string(text)]], "stop_reason": "end_turn"] as JSONValue).jsonString
    }

    /// The tool results sent back in the last request, by tool_use id.
    static func lastToolResults() -> [String: (content: String, isError: Bool)] {
        var results: [String: (String, Bool)] = [:]
        for message in requests.last?["messages"]?.arrayValue ?? [] {
            for block in message["content"]?.arrayValue ?? [] where block["type"] == "tool_result" {
                results[block["tool_use_id"]?.stringValue ?? ""] =
                    (block["content"]?.stringValue ?? "", block["is_error"] == .bool(true))
            }
        }
        return results
    }
}

/// Drives the assistant against the sample database with a scripted model.
/// Enable with DBJOY_TEST_PG=1 (see PostgresIntegrationTests).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBJOY_TEST_PG"] != nil), .serialized)
@MainActor
struct AssistantIntegrationTests {
    static let env = ProcessInfo.processInfo.environment

    private func connectedAssistant(library: ChatLibrary = ChatLibrary(directory: temporaryDirectory()))
        async throws -> (WorkspaceModel, AssistantModel) {
        URLProtocol.registerClass(ScriptedLLM.self)
        ScriptedLLM.requests = []
        let config = ConnectionConfig(name: "test", host: "localhost", port: Int(Self.env["DBJOY_TEST_PG_PORT"] ?? "") ?? 55432,
                                      user: "postgres", database: "dbjoy_sample", sslMode: .disable, savePassword: false)
        let workspace = WorkspaceModel(config: config)
        await workspace.submitPassword(Self.env["DBJOY_TEST_PG_PASSWORD"] ?? "secret")
        try #require(workspace.phase == .connected)
        workspace.chatLibrary = library
        workspace.toggleAssistant()
        let assistant = try #require(workspace.assistant)
        assistant.apiKey = { _ in "test-key" }
        return (workspace, assistant)
    }

    private func ask(_ assistant: AssistantModel, _ text: String) async {
        assistant.draft = text
        assistant.send()
        await assistant.waitUntilIdle()
    }

    private func count(_ workspace: WorkspaceModel, _ sql: String) async throws -> String? {
        try await workspace.connection?.query(sql).rows.first?.first ?? nil
    }

    @Test func readOnlyQueriesCannotWrite() async throws {
        UserDefaults.standard.set(false, forKey: AssistantSettings.allowWritesKey)
        let (workspace, assistant) = try await connectedAssistant()
        defer { Task { await workspace.disconnect() } }
        let before = try await count(workspace, "SELECT count(*) FROM customers")

        ScriptedLLM.responses = [
            ScriptedLLM.toolUse([("t1", "run_query", ["sql": "DELETE FROM customers"])]),
            ScriptedLLM.toolUse([("t2", "run_query",
                                  ["sql": "WITH d AS (DELETE FROM customers RETURNING 1) SELECT count(*) FROM d"])]),
            ScriptedLLM.toolUse([("t3", "describe_table", ["table": "customers"]),
                                 ("t4", "run_query", ["sql": "SELECT count(*) AS n FROM customers"])]),
            ScriptedLLM.reply("There are \(before ?? "?") customers."),
        ]
        await ask(assistant, "How many customers are there?")

        // Each request carries the previous step's tool results.
        #expect(ScriptedLLM.requests.count == 4)
        let first = ScriptedLLM.requests[1]["messages"]?.arrayValue?.last?["content"]?[0]
        #expect(first?["is_error"] == .bool(true))
        #expect(first?["content"]?.stringValue?.contains("read-only") == true)
        let second = ScriptedLLM.requests[2]["messages"]?.arrayValue?.last?["content"]?[0]
        #expect(second?["is_error"] == .bool(true))
        #expect(second?["content"]?.stringValue?.contains("read-only transaction") == true)
        let results = ScriptedLLM.lastToolResults()
        #expect(results["t3"]?.content.contains("PRIMARY KEY") == true)
        #expect(results["t4"]?.content.contains(before ?? "-") == true)
        #expect(ScriptedLLM.requests[0]["tools"]?.arrayValue?.contains { $0["name"] == "execute_sql" } == false)

        #expect(try await count(workspace, "SELECT count(*) FROM customers") == before)
        if case .reply(let text) = assistant.items.last?.kind { #expect(text.contains("customers")) } else { Issue.record("no reply") }
    }

    @Test func chatsAreSavedAndContinueAfterReopening() async throws {
        UserDefaults.standard.set(false, forKey: AssistantSettings.allowWritesKey)
        let library = ChatLibrary(directory: temporaryDirectory())
        let (workspace, assistant) = try await connectedAssistant(library: library)
        defer { Task { await workspace.disconnect() } }

        ScriptedLLM.responses = [
            ScriptedLLM.toolUse([("c1", "run_query", ["sql": "SELECT count(*) AS n FROM customers"])]),
            ScriptedLLM.reply("You have some customers."),
        ]
        await ask(assistant, "How many customers do we have?")
        let id = try #require(assistant.chatID)
        let summary = try #require(library.summary(id))
        #expect(summary.title == "How many customers do we have?")
        #expect(summary.connectionID == workspace.config.id)

        // A new chat, then back to the saved one.
        assistant.reset()
        #expect(assistant.items.isEmpty)
        assistant.open(id)
        #expect(assistant.items.count == 3)
        if case .step(let step) = assistant.items[1].kind {
            #expect(step.state == .done)
            #expect(step.result?.rows.count == 1)
        } else { Issue.record("expected a step") }

        // Continuing sends the earlier history along.
        ScriptedLLM.requests = []
        ScriptedLLM.responses = [ScriptedLLM.reply("Same as before.")]
        await ask(assistant, "And now?")
        let messages = try #require(ScriptedLLM.requests.first?["messages"]?.arrayValue)
        #expect(messages.count == 5)
        #expect(messages.first?["content"] == "How many customers do we have?")
        #expect(library.load(id)?.items.count == 5)
    }

    @Test func writesAreAtomicAndOpenInEditorAddsATab() async throws {
        UserDefaults.standard.set(true, forKey: AssistantSettings.allowWritesKey)
        UserDefaults.standard.set(false, forKey: AssistantSettings.confirmWritesKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AssistantSettings.allowWritesKey)
            UserDefaults.standard.removeObject(forKey: AssistantSettings.confirmWritesKey)
        }
        let (workspace, assistant) = try await connectedAssistant()
        defer { Task { await workspace.disconnect() } }
        _ = await workspace.runStatements(["DROP TABLE IF EXISTS assistant_probe"])

        ScriptedLLM.responses = [
            ScriptedLLM.toolUse([("w1", "execute_sql", ["sql": "CREATE TABLE assistant_probe (x int); INSERT INTO assistant_probe VALUES (1)",
                                                         "summary": "Create a probe table"])]),
            ScriptedLLM.toolUse([("w2", "execute_sql", ["sql": "INSERT INTO assistant_probe VALUES (2); INSERT INTO no_such_table VALUES (1)",
                                                         "summary": "Half-failing insert"])]),
            ScriptedLLM.toolUse([("w3", "execute_sql", ["sql": "INSERT INTO assistant_probe VALUES (3); COMMIT",
                                                         "summary": "Escaping the transaction"])]),
            ScriptedLLM.toolUse([("w4", "open_in_editor", ["sql": "SELECT * FROM assistant_probe", "title": "Probe"])]),
            ScriptedLLM.reply("Done."),
        ]
        await ask(assistant, "Make a probe table")

        #expect(try await count(workspace, "SELECT string_agg(x::text, ',') FROM assistant_probe") == "1")
        #expect(ScriptedLLM.requests.count == 5)
        #expect(ScriptedLLM.requests[2]["messages"]?.arrayValue?.last?["content"]?[0]?["content"]?.stringValue?
            .contains("rolled back") == true)
        #expect(workspace.objects.contains { $0.name == "assistant_probe" })
        guard case .query(let tab) = workspace.selectedTab else { Issue.record("no query tab"); return }
        #expect(tab.title == "Probe")
        #expect(tab.sql == "SELECT * FROM assistant_probe")
        _ = await workspace.runStatements(["DROP TABLE assistant_probe"])
    }
}
