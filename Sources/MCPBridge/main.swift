// dbjoy-mcp: a stdio MCP server that forwards every message to DBJoy's local HTTP server.
// Clients start it once per session and it never disconnects, so they keep working after DBJoy
// quits, restarts or updates. While DBJoy is closed, tool calls answer that it isn't running.
import Foundation

let token = ProcessInfo.processInfo.environment["DBJOY_MCP_TOKEN"] ?? ""
/// The last initialize and tools/list answers, so a client that starts while DBJoy is closed still gets the tools.
let cacheDirectory = ProcessInfo.processInfo.environment["DBJOY_MCP_CACHE"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "app.dbjoy.DBJoy/mcp-bridge", directoryHint: .isDirectory)
let notRunning = "DBJoy isn't running, or its MCP server is off. Open DBJoy, then try again."

/// The port set in DBJoy → Settings → MCP, read on every request so a change applies right away.
func endpoint() -> URL {
    let stored = ProcessInfo.processInfo.environment["DBJOY_MCP_PORT"].flatMap { Int($0) }
        ?? UserDefaults(suiteName: "app.dbjoy.DBJoy")?.integer(forKey: "mcp.port") ?? 0
    let port = (1024...65535).contains(stored) ? stored : 47821
    return URL(string: "http://127.0.0.1:\(port)/mcp")!
}

enum Reply {
    case body(Data?, session: String?)
    case unreachable
    case failed(String)
}

actor Bridge {
    /// The client's initialize request, sent again after DBJoy restarts so activity shows the client's name.
    private var initialize: Data?
    private var session: String?
    private var needsInitialize = false

    func handle(_ line: Data) async {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let method = message["method"] as? String ?? ""
        guard let id = message["id"] else {
            _ = await forward(line)   // a notification; nothing to answer
            return
        }
        if method == "initialize" { initialize = line }
        if method != "initialize", needsInitialize, let initialize { await reinitialize(initialize) }

        switch await forward(line) {
        case .body(let data, let newSession):
            if method == "initialize", let newSession { session = newSession }
            guard let data, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let result = reply["result"], ["initialize", "tools/list"].contains(method) {
                cache(result, as: method)
            }
            write(reply)
        case .unreachable:
            needsInitialize = true
            if ["initialize", "tools/list"].contains(method), var result = cached(method) {
                if method == "initialize", let version = (message["params"] as? [String: Any])?["protocolVersion"] {
                    result["protocolVersion"] = version
                }
                write(["jsonrpc": "2.0", "id": id, "result": result])
            } else if method == "initialize" {
                write(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": (message["params"] as? [String: Any])?["protocolVersion"] ?? "2025-06-18",
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "dbjoy", "title": "DBJoy", "version": "bridge"],
                ]])
            } else if method == "tools/call" {
                write(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": notRunning]], "isError": true]])
            } else {
                write(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": notRunning]])
            }
        case .failed(let text):
            write(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": text]])
        }
    }

    private func reinitialize(_ request: Data) async {
        guard case .body(_, let newSession) = await forward(request) else { return }
        session = newSession
        needsInitialize = false
        _ = await forward(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
    }

    private func forward(_ body: Data, retry: Bool = true) async -> Reply {
        var request = URLRequest(url: endpoint(), timeoutInterval: 300)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            guard let status = http?.statusCode, (200..<300).contains(status) else {
                return .failed(String(decoding: data, as: UTF8.self))
            }
            return .body(data.isEmpty ? nil : data, session: http?.value(forHTTPHeaderField: "Mcp-Session-Id"))
        } catch URLError.networkConnectionLost where retry {
            // A kept-alive connection to a DBJoy that has since restarted: try once on a fresh one.
            return await forward(body, retry: false)
        } catch {
            return .unreachable
        }
    }

    private func cache(_ result: Any, as method: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: result) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheDirectory.appending(path: method.replacingOccurrences(of: "/", with: "-") + ".json"))
    }

    private func cached(_ method: String) -> [String: Any]? {
        let url = cacheDirectory.appending(path: method.replacingOccurrences(of: "/", with: "-") + ".json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// One message per line; JSONSerialization escapes newlines inside strings.
    private func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

let bridge = Bridge()
// Messages are handled concurrently; when the client closes stdin, the group waits for replies in flight.
try await withThrowingTaskGroup(of: Void.self) { group in
    for try await line in FileHandle.standardInput.bytes.lines where !line.isEmpty {
        let data = Data(line.utf8)
        group.addTask { await bridge.handle(data) }
    }
}
