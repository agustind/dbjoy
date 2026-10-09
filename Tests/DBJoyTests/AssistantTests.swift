@testable import DBJoy
import Foundation
import Testing

struct AssistantSQLTests {
    @Test func allowsReadOnlyStatements() {
        #expect(AssistantTools.readOnlyViolation(in: "SELECT * FROM users LIMIT 5") == nil)
        #expect(AssistantTools.readOnlyViolation(in: "-- count\nWITH t AS (SELECT 1) SELECT * FROM t;") == nil)
        #expect(AssistantTools.readOnlyViolation(in: "EXPLAIN SELECT 1; SHOW search_path") == nil)
    }

    @Test func rejectsWritesAndSessionChanges() {
        #expect(AssistantTools.readOnlyViolation(in: "DELETE FROM users") != nil)
        #expect(AssistantTools.readOnlyViolation(in: "SELECT 1; DROP TABLE users") != nil)
        #expect(AssistantTools.readOnlyViolation(in: "COMMIT; DELETE FROM users") != nil)
        #expect(AssistantTools.readOnlyViolation(in: "SET default_transaction_read_only = off") != nil)
        #expect(AssistantTools.readOnlyViolation(in: "  -- nothing\n") != nil)
    }

    @Test func writesMustNotControlTheTransaction() {
        #expect(AssistantTools.writeViolation(in: "UPDATE users SET name = 'a' WHERE id = 1") == nil)
        #expect(AssistantTools.writeViolation(in: "UPDATE users SET name = 'a'; COMMIT") != nil)
        #expect(AssistantTools.writeViolation(in: "BEGIN; DELETE FROM users; END") != nil)
    }

    @Test func toolListDependsOnWriteSetting() {
        #expect(!AssistantTools.specs(allowWrites: false).map(\.name).contains(AssistantTools.executeSQL))
        #expect(AssistantTools.specs(allowWrites: true).map(\.name).contains(AssistantTools.executeSQL))
    }
}

struct LLMConversationTests {
    private func body(of request: URLRequest) throws -> JSONValue {
        try JSONValue.parse(try #require(request.httpBody))
    }

    @Test func anthropicToolLoopKeepsBlocksUnchanged() throws {
        var conversation = LLMConversation(provider: .anthropic, model: "claude-opus-5-5")
        conversation.addUser("How many users?")
        let response = """
            {"content": [
              {"type": "thinking", "thinking": "", "signature": "sig"},
              {"type": "text", "text": "Let me count."},
              {"type": "tool_use", "id": "toolu_1", "name": "run_query", "input": {"sql": "SELECT count(*) FROM users"}}
            ], "stop_reason": "tool_use"}
            """
        let turn = try conversation.receive(Data(response.utf8))
        #expect(turn.text == "Let me count.")
        #expect(turn.toolCalls == [ToolCall(id: "toolu_1", name: "run_query", input: ["sql": "SELECT count(*) FROM users"])])
        conversation.addToolResults([ToolOutput(callID: "toolu_1", content: "42")])

        let request = try conversation.request(system: "sys", tools: AssistantTools.specs(allowWrites: false), apiKey: "k")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let json = try body(of: request)
        #expect(json["fallbacks"] == "default")
        #expect(json["output_config"]?["effort"] == "medium")
        let messages = try #require(json["messages"]?.arrayValue)
        #expect(messages.count == 3)
        #expect(messages[1]["content"]?[0]?["signature"] == "sig")
        #expect(messages[2]["content"]?[0]?["type"] == "tool_result")
        #expect(messages[2]["content"]?[0]?["tool_use_id"] == "toolu_1")
        #expect(json["max_tokens"] == 16000)
    }

    @Test func olderClaudeModelsGetNoNewParameters() throws {
        let conversation = LLMConversation(provider: .anthropic, model: "claude-haiku-4-5")
        let request = try conversation.request(system: "sys", tools: [], apiKey: "k")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        let json = try body(of: request)
        #expect(json["fallbacks"] == nil)
        #expect(json["output_config"] == nil)
    }

    @Test func anthropicRefusalIsLeftOutOfHistory() throws {
        var conversation = LLMConversation(provider: .anthropic, model: "claude-opus-5-5")
        conversation.addUser("hi")
        let turn = try conversation.receive(Data(#"{"content": [], "stop_reason": "refusal"}"#.utf8))
        #expect(turn.problem != nil)
        #expect(conversation.messages.count == 1)
    }

    @Test func openAIToolCalls() throws {
        var conversation = LLMConversation(provider: .openai, model: "gpt-5")
        conversation.addUser("Describe orders")
        let response = """
            {"choices": [{"finish_reason": "tool_calls", "message": {"role": "assistant", "content": null,
              "tool_calls": [{"id": "call_1", "type": "function",
                "function": {"name": "describe_table", "arguments": "{\\"table\\": \\"orders\\"}"}}]}}]}
            """
        let turn = try conversation.receive(Data(response.utf8))
        #expect(turn.toolCalls.first?.string("table") == "orders")
        conversation.addToolResults([ToolOutput(callID: "call_1", content: "no such table", isError: true)])

        let request = try conversation.request(system: "sys", tools: AssistantTools.specs(allowWrites: false), apiKey: "k")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let json = try body(of: request)
        let messages = try #require(json["messages"]?.arrayValue)
        #expect(messages.map { $0["role"]?.stringValue } == ["system", "user", "assistant", "tool"])
        #expect(messages[3]["tool_call_id"] == "call_1")
        #expect(messages[3]["content"] == "Error: no such table")
        #expect(json["tools"]?[0]?["function"]?["name"] == "list_tables")
    }
}

@MainActor
struct MarkdownSegmentTests {
    @Test func splitsFencedCode() {
        let text = """
            Here you go:

            ```sql
            SELECT 1;
            ```
            Done.
            """
        #expect(MarkdownView.segments(text) == [.text("Here you go:"), .code("SELECT 1;"), .text("Done.")])
    }
}
