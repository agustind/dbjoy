import DBCore
import Foundation
import Network

struct HTTPRequest: Sendable {
    var method: String
    /// The path without the query string.
    var path: String
    /// Header values by lowercased name.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// HTTP/1.1 keeps the connection open unless the client says otherwise.
    var wantsClose: Bool { header("connection")?.lowercased() == "close" }
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ status: Int, _ body: Data, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: body)
    }

    static func text(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(message.utf8))
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }
}

struct HTTPParseError: Error, Equatable {
    var status: Int
    var message: String
}

/// Splits a byte stream into HTTP/1.1 requests. Bodies need a Content-Length; chunked uploads are refused.
struct HTTPRequestParser {
    static let maxHeaderBytes = 32 * 1024
    static let maxBodyBytes = 4 * 1024 * 1024

    private var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    /// The next complete request, or nil until more bytes arrive.
    mutating func next() throws(HTTPParseError) -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeaderBytes { throw HTTPParseError(status: 431, message: "Headers too large") }
            return nil
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            throw HTTPParseError(status: 400, message: "Headers aren't UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            throw HTTPParseError(status: 400, message: "Malformed request line")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError(status: 400, message: "Malformed header") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil {
            throw HTTPParseError(status: 411, message: "Send the body with a Content-Length")
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { throw HTTPParseError(status: 400, message: "Invalid Content-Length") }
        guard length <= Self.maxBodyBytes else { throw HTTPParseError(status: 413, message: "Body too large") }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return HTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: body)
    }
}

/// A small HTTP/1.1 server that only listens on 127.0.0.1, so nothing outside this Mac can reach it.
final class LocalHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "app.dbjoy.http")

    init(port: UInt16, handler: @escaping Handler) throws {
        guard let port = NWEndpoint.Port(rawValue: port), port != .any else { throw DatabaseError("Invalid port \(port)") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    /// Starts listening; `onState` gets nil once ready, or the reason it couldn't start.
    func start(onState: @escaping @Sendable (String?) -> Void) {
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready:
                onState(nil)
            case .failed(let error), .waiting(let error):
                onState(Self.describe(error))
                listener.cancel()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "The port is already in use. Choose another one."
        }
        return error.localizedDescription
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        let handler = handler
        Task {
            defer { connection.cancel() }
            var parser = HTTPRequestParser()
            while true {
                do {
                    while let request = try parser.next() {
                        var response = await handler(request)
                        if request.wantsClose { response.headers["Connection"] = "close" }
                        try await Self.send(response.serialized(), on: connection)
                        if request.wantsClose { return }
                    }
                } catch let error as HTTPParseError {
                    var response = HTTPResponse.text(error.status, error.message)
                    response.headers["Connection"] = "close"
                    try? await Self.send(response.serialized(), on: connection)
                    return
                } catch {
                    return
                }
                guard let data = try? await Self.receive(on: connection) else { return }
                parser.append(data)
            }
        }
    }

    /// The next bytes from the client, or nil once it has closed the connection.
    private static func receive(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
