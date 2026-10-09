import Foundation

/// A tool the model may call. `schema` is a JSON Schema object for the input.
struct ToolSpec: Sendable {
    var name: String
    var description: String
    var schema: JSONValue
}

struct ToolCall: Sendable, Hashable {
    var id: String
    var name: String
    var input: JSONValue

    func string(_ key: String) -> String? { input[key]?.stringValue }
}

struct ToolOutput: Sendable {
    var callID: String
    var content: String
    var isError = false
}

/// One model response: its text and the tools it wants to run.
struct ModelTurn: Sendable {
    var text: String
    var toolCalls: [ToolCall]
    /// Set when the model declined or was cut off, explaining why.
    var problem: String?
}

struct LLMError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// A chat with tool use, kept in the provider's own message format so everything the API
/// returns (including thinking blocks) is sent back unchanged. History is append-only.
struct LLMConversation: Codable, Sendable {
    let provider: AIProvider
    /// Can change mid-chat; the history stays valid within one provider.
    var model: String
    private(set) var messages: [JSONValue] = []

    init(provider: AIProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    var isEmpty: Bool { messages.isEmpty }

    mutating func addUser(_ text: String) {
        messages.append(["role": "user", "content": .string(text)])
    }

    /// Answers every tool call of the previous turn, in one message (Anthropic) or one per call (OpenAI).
    mutating func addToolResults(_ results: [ToolOutput]) {
        guard !results.isEmpty else { return }
        switch provider {
        case .anthropic:
            messages.append(["role": "user", "content": .array(results.map { result in
                ["type": "tool_result", "tool_use_id": .string(result.callID), "content": .string(result.content),
                 "is_error": .bool(result.isError)]
            })])
        case .openai:
            for result in results {
                let content = result.isError ? "Error: \(result.content)" : result.content
                messages.append(["role": "tool", "tool_call_id": .string(result.callID), "content": .string(content)])
            }
        }
    }

    // MARK: Requests

    func request(system: String, tools: [ToolSpec], apiKey: String) throws -> URLRequest {
        var request: URLRequest
        let body: JSONValue
        switch provider {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var fields: [String: JSONValue] = [
                "model": .string(model),
                "max_tokens": 16000,
                "system": .string(system),
                // Caches the growing conversation prefix across the agent loop's requests.
                "cache_control": ["type": "ephemeral"],
                "tools": .array(tools.map { tool in
                    ["name": .string(tool.name), "description": .string(tool.description), "input_schema": tool.schema]
                }),
                "messages": .array(messages),
            ]
            if Self.supportsEffort(model) {
                fields["output_config"] = ["effort": "medium"]
            }
            if Self.supportsDefaultFallback(model) {
                // Re-runs a request a safety classifier declined on Anthropic's recommended fallback model.
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                fields["fallbacks"] = "default"
            }
            body = .object(fields)
        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": .string(model),
                "messages": .array([["role": "system", "content": .string(system)]] + messages),
                "tools": .array(tools.map { tool in
                    ["type": "function",
                     "function": ["name": .string(tool.name), "description": .string(tool.description),
                                  "parameters": tool.schema]]
                }),
            ]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 600
        request.httpBody = try body.encoded()
        return request
    }

    /// Claude 5-generation models take `output_config.effort`.
    static func supportsEffort(_ model: String) -> Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5"].contains { model.hasPrefix($0) }
    }

    /// Models that accept `fallbacks: "default"`.
    static func supportsDefaultFallback(_ model: String) -> Bool {
        model.hasPrefix("claude-opus-5") || model == "claude-fable-5-1" || model == "claude-sonnet-5-5"
    }

    // MARK: Responses

    /// Records the model's reply in the history and returns what it said and wants to do.
    mutating func receive(_ data: Data) throws -> ModelTurn {
        let response = try JSONValue.parse(data)
        switch provider {
        case .anthropic:
            guard let content = response["content"]?.arrayValue else { throw LLMError(message: "Unexpected response from Anthropic.") }
            let stopReason = response["stop_reason"]?.stringValue
            var text: [String] = []
            var calls: [ToolCall] = []
            for block in content {
                switch block["type"]?.stringValue {
                case "text": text.append(block["text"]?.stringValue ?? "")
                case "tool_use":
                    calls.append(ToolCall(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "",
                                          input: block["input"] ?? [:]))
                default: break
                }
            }
            var problem: String?
            // A refused turn, or one cut off mid tool call, is left out of the history: a tool call
            // without a result would make the next request invalid.
            var keepsTurn = !content.isEmpty
            switch stopReason {
            case "refusal":
                problem = "The model declined this request."
                if let explanation = response["stop_details"]?["explanation"]?.stringValue { problem! += " \(explanation)" }
                keepsTurn = false
                calls = []
            case "max_tokens":
                problem = "The reply hit the length limit and was cut off."
                if !calls.isEmpty { keepsTurn = false }
                calls = []
            default: break
            }
            if keepsTurn {
                messages.append(["role": "assistant", "content": .array(content)])
            }
            return ModelTurn(text: text.joined(separator: "\n\n"), toolCalls: calls, problem: problem)

        case .openai:
            guard let choice = response["choices"]?[0], let message = choice["message"] else {
                throw LLMError(message: "Unexpected response from OpenAI.")
            }
            if let refusal = message["refusal"]?.stringValue {
                return ModelTurn(text: "", toolCalls: [], problem: "The model declined this request. \(refusal)")
            }
            let text = message["content"]?.stringValue ?? ""
            let toolCalls = message["tool_calls"]?.arrayValue ?? []
            let calls = toolCalls.map { call in
                let arguments = call["function"]?["arguments"]?.stringValue ?? "{}"
                return ToolCall(id: call["id"]?.stringValue ?? "", name: call["function"]?["name"]?.stringValue ?? "",
                                input: (try? JSONValue.parse(Data(arguments.utf8))) ?? [:])
            }
            var assistant: [String: JSONValue] = ["role": "assistant", "content": message["content"] ?? .null]
            if !toolCalls.isEmpty { assistant["tool_calls"] = .array(toolCalls) }
            messages.append(.object(assistant))
            let problem = choice["finish_reason"]?.stringValue == "length" ? "The reply hit the length limit and was cut off." : nil
            return ModelTurn(text: text, toolCalls: calls, problem: problem)
        }
    }

    /// Sends a request and returns the body, turning HTTP errors into readable messages.
    static func send(_ request: URLRequest, provider: AIProvider) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONValue.parse(data))?["error"]?["message"]?.stringValue
            let message = switch http.statusCode {
            case 401: "\(provider.displayName) rejected the API key. Check it in Settings → AI Assistant."
            case 429: "\(provider.displayName) rate limit reached. Try again in a moment."
            default: "\(provider.displayName) returned an error (HTTP \(http.statusCode))."
            }
            throw LLMError(message: detail.map { "\(message)\n\($0)" } ?? message)
        }
        return data
    }
}
