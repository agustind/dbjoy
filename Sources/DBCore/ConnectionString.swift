import Foundation

/// A parsed PostgreSQL connection string: a URL (`postgres://user:pass@host:5432/db?sslmode=require`)
/// or a libpq keyword/value string (`host=localhost dbname=app user=me`).
public struct ConnectionString: Equatable, Sendable {
    public var host: String?
    public var port: Int?
    public var user: String?
    public var password: String?
    public var database: String?
    public var sslMode: SSLMode?
    /// Other libpq options that DBJoy passes through (e.g. `application_name`, `sslrootcert`).
    public var options: [String: String] = [:]
    /// Parameters that were recognized as unsupported and skipped (e.g. `pgbouncer`, extra hosts).
    public var ignored: [String] = []

    public init() {}

    public struct ParseError: Error, LocalizedError, Equatable, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// libpq keywords forwarded as connection options.
    static let passThroughKeywords: Set<String> = [
        "application_name", "connect_timeout", "options", "client_encoding", "channel_binding",
        "target_session_attrs", "keepalives", "keepalives_idle", "keepalives_interval", "keepalives_count",
        "tcp_user_timeout", "sslcert", "sslkey", "sslrootcert", "sslcrl", "sslcrldir", "sslpassword",
        "sslcompression", "sslsni", "sslnegotiation", "ssl_min_protocol_version", "ssl_max_protocol_version",
        "gssencmode", "krbsrvname", "gsslib", "gssdelegation", "require_auth", "service", "passfile",
        "hostaddr", "load_balance_hosts",
    ]

    /// True for text that looks like a connection string (used to offer clipboard contents).
    public static func looksLikeConnectionString(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("postgres://") || trimmed.hasPrefix("postgresql://") || trimmed.hasPrefix("jdbc:postgresql://") {
            return true
        }
        return !trimmed.contains("\n") && trimmed.range(of: #"(^|\s)(host|dbname|user)\s*="#, options: .regularExpression) != nil
    }

    public static func parse(_ input: String) throws -> ConnectionString {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError(message: "The connection string is empty.") }
        if text.lowercased().hasPrefix("jdbc:") { text.removeFirst(5) }
        let lower = text.lowercased()
        if lower.hasPrefix("postgres://") || lower.hasPrefix("postgresql://") {
            return try parseURL(text)
        }
        if lower.contains("://") {
            throw ParseError(message: "Only postgres:// and postgresql:// URLs are supported.")
        }
        return try parseKeywordValue(text)
    }

    // MARK: URL form

    private static func parseURL(_ text: String) throws -> ConnectionString {
        var result = ConnectionString()
        var rest = Substring(text[text.range(of: "://")!.upperBound...])

        // Fragment and query.
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        var query = ""
        if let mark = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: mark)...])
            rest = rest[..<mark]
        }
        // Path = database.
        if let slash = rest.firstIndex(of: "/") {
            let path = String(rest[rest.index(after: slash)...])
            if !path.isEmpty { result.database = try decode(path) }
            rest = rest[..<slash]
        }
        // Userinfo. The last "@" separates it, since passwords may contain "@" when unencoded.
        if let at = rest.lastIndex(of: "@") {
            let userInfo = rest[..<at]
            rest = rest[rest.index(after: at)...]
            if let colon = userInfo.firstIndex(of: ":") {
                result.user = try decode(String(userInfo[..<colon]))
                result.password = try decode(String(userInfo[userInfo.index(after: colon)...]))
            } else if !userInfo.isEmpty {
                result.user = try decode(String(userInfo))
            }
        }
        // Hosts: host[:port][,host[:port]…]; only the first is used.
        let hosts = rest.split(separator: ",", omittingEmptySubsequences: false)
        if let first = hosts.first, !first.isEmpty {
            let (host, port) = try splitHostPort(String(first))
            result.host = try host.map(decode)
            result.port = port
        }
        if hosts.count > 1 {
            result.ignored.append("additional hosts (\(hosts.dropFirst().joined(separator: ",")))")
        }

        for pair in query.split(separator: "&") where !pair.isEmpty {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = try decode(String(parts[0]))
            let value = parts.count > 1 ? try decode(String(parts[1])) : ""
            try result.apply(key: key, value: value)
        }
        return result
    }

    private static func splitHostPort(_ text: String) throws -> (String?, Int?) {
        var host = text
        var port: Int?
        if text.hasPrefix("[") {
            // IPv6 literal: [::1]:5432
            guard let close = text.firstIndex(of: "]") else { throw ParseError(message: "Unterminated IPv6 address.") }
            host = String(text[text.index(after: text.startIndex)..<close])
            let after = text[text.index(after: close)...]
            if after.hasPrefix(":") { port = try parsePort(String(after.dropFirst())) }
        } else if let colon = text.lastIndex(of: ":") {
            host = String(text[..<colon])
            port = try parsePort(String(text[text.index(after: colon)...]))
        }
        return (host.isEmpty ? nil : host, port)
    }

    private static func parsePort(_ text: String) throws -> Int? {
        if text.isEmpty { return nil }
        guard let port = Int(text), (1...65535).contains(port) else {
            throw ParseError(message: "Invalid port “\(text)”.")
        }
        return port
    }

    private static func decode(_ text: String) throws -> String {
        guard let decoded = text.removingPercentEncoding else {
            throw ParseError(message: "Invalid percent-encoding in “\(text)”.")
        }
        return decoded
    }

    // MARK: Keyword/value form

    private static func parseKeywordValue(_ text: String) throws -> ConnectionString {
        var result = ConnectionString()
        let chars = Array(text)
        var i = 0
        func skipSpaces() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        while true {
            skipSpaces()
            guard i < chars.count else { break }
            var key = ""
            while i < chars.count, chars[i] != "=", !chars[i].isWhitespace { key.append(chars[i]); i += 1 }
            skipSpaces()
            guard i < chars.count, chars[i] == "=" else {
                throw ParseError(message: "Expected “=” after “\(key)”. Use a postgres:// URL or key=value pairs.")
            }
            i += 1
            skipSpaces()
            var value = ""
            if i < chars.count, chars[i] == "'" {
                i += 1
                var closed = false
                while i < chars.count {
                    if chars[i] == "\\", i + 1 < chars.count { value.append(chars[i + 1]); i += 2; continue }
                    if chars[i] == "'" { closed = true; i += 1; break }
                    value.append(chars[i]); i += 1
                }
                guard closed else { throw ParseError(message: "Unterminated quoted value for “\(key)”.") }
            } else {
                while i < chars.count, !chars[i].isWhitespace {
                    if chars[i] == "\\", i + 1 < chars.count { value.append(chars[i + 1]); i += 2; continue }
                    value.append(chars[i]); i += 1
                }
            }
            try result.apply(key: key, value: value)
        }
        guard result.host != nil || result.database != nil || result.user != nil else {
            throw ParseError(message: "No host, database or user found.")
        }
        return result
    }

    // MARK: Parameters

    private mutating func apply(key: String, value: String) throws {
        switch key.lowercased() {
        case "host":
            let first = value.split(separator: ",").first.map(String.init) ?? value
            host = first.isEmpty ? nil : first
            if value.contains(",") { ignored.append("additional hosts") }
        case "port":
            let first = value.split(separator: ",").first.map(String.init) ?? value
            port = try Self.parsePort(first)
        case "user": user = value
        case "password": password = value
        case "dbname", "database": database = value
        case "sslmode", "ssl":
            if key.lowercased() == "ssl", value == "true" || value == "1" {
                sslMode = .require
            } else if let mode = SSLMode(rawValue: value) {
                sslMode = mode
            } else {
                throw ParseError(message: "Unknown sslmode “\(value)”.")
            }
        case let keyword where Self.passThroughKeywords.contains(keyword):
            options[keyword] = value
        default:
            ignored.append(key)
        }
    }

    // MARK: Applying

    /// Fills a connection config from the parsed values, leaving unspecified fields as they are.
    public func apply(to config: inout ConnectionConfig) {
        if let host { config.host = host }
        if let port { config.port = port } else if host != nil { config.port = config.kind.defaultPort }
        if let user { config.user = user }
        if let database { config.database = database }
        if let sslMode { config.sslMode = sslMode }
        for (key, value) in options { config.options[key] = value }
        if config.name.isEmpty {
            config.name = Self.suggestedName(database: database, host: host)
        }
    }

    /// A short connection name: the database plus the first label of the host
    /// (`staging on ep-crimson-field-a4lnycv1` rather than the full cloud hostname).
    public static func suggestedName(database: String?, host: String?) -> String {
        var place = host ?? "localhost"
        let isIPAddress = place.contains(":") || place.allSatisfy { $0.isNumber || $0 == "." }
        if !place.hasPrefix("/"), !isIPAddress, let first = place.split(separator: ".").first {
            place = String(first)
        }
        return database.map { "\($0) on \(place)" } ?? place
    }
}
