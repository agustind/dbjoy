import Foundation

public struct CompletionCatalog: Sendable {
    public var tables: [String]
    /// Columns keyed by table name.
    public var columns: [String: [String]]
    public var schemas: [String]
    public var keywords: [String]
    public var functions: [String]

    public init(tables: [String] = [], columns: [String: [String]] = [:], schemas: [String] = [],
                keywords: [String] = SQLKeywords.list, functions: [String] = []) {
        self.tables = tables
        self.columns = columns
        self.schemas = schemas
        self.keywords = keywords
        self.functions = functions
    }
}

public struct CompletionItem: Hashable, Sendable {
    public enum Kind: Sendable { case keyword, table, column, function, schema }

    public var label: String
    public var insertText: String
    public var kind: Kind
    public var detail: String?
}

public struct CompletionResult: Sendable {
    /// UTF-16 range of the partial word to replace.
    public var replacementRange: Range<Int>
    public var items: [CompletionItem]
}

public enum CompletionEngine {
    private static let tableContextKeywords: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE", "TRUNCATE"]

    /// Suggestions for the word ending at `cursor`. Returns `nil` when nothing useful applies.
    /// Set `explicit` when the user asked for completion, to allow an empty prefix.
    public static func complete(sql: String, cursor: Int, catalog: CompletionCatalog, explicit: Bool = false) -> CompletionResult? {
        let u = Array(sql.utf16)
        guard cursor <= u.count else { return nil }
        var start = cursor
        while start > 0, SQLLexer.isIdentChar(u[start - 1]) { start -= 1 }
        let prefix = String(decoding: u[start..<cursor], as: UTF16.self)
        // Don't complete inside numbers.
        if let first = prefix.utf16.first, SQLLexer.isDigit(first) { return nil }

        let statement = SQLSplitter.statement(at: cursor, in: sql)
        let statementTokens = statement.map { SQLLexer.tokens(in: $0.text) } ?? []
        let aliases = aliasMap(statementTokens, catalog: catalog)

        var items: [CompletionItem] = []
        if start > 0, u[start - 1] == UInt16(UInt8(ascii: ".")) {
            // qualifier.prefix → columns of the table or alias.
            var qStart = start - 1
            while qStart > 0, SQLLexer.isIdentChar(u[qStart - 1]) || u[qStart - 1] == UInt16(UInt8(ascii: "\"")) { qStart -= 1 }
            let qualifier = unquote(String(decoding: u[qStart..<(start - 1)], as: UTF16.self))
            let table = aliases[qualifier.lowercased()] ?? qualifier
            if let columns = columns(of: table, in: catalog) {
                items = columns.map { CompletionItem(label: $0, insertText: quoteIfNeeded($0), kind: .column, detail: table) }
            } else if catalog.schemas.contains(qualifier) {
                items = catalog.tables.map { CompletionItem(label: $0, insertText: quoteIfNeeded($0), kind: .table, detail: nil) }
            }
        } else {
            guard !prefix.isEmpty || explicit else { return nil }
            let previous = previousKeyword(in: u, before: start)
            let lowercaseKeywords = prefix.first.map { $0.isLowercase } ?? false
            let tables = catalog.tables.map { CompletionItem(label: $0, insertText: quoteIfNeeded($0), kind: .table, detail: nil) }
            if let previous, tableContextKeywords.contains(previous) {
                items = tables + catalog.schemas.map { CompletionItem(label: $0, insertText: quoteIfNeeded($0), kind: .schema, detail: nil) }
            } else {
                var seen = Set<String>()
                for table in Set(aliases.values).sorted() {
                    for column in columns(of: table, in: catalog) ?? [] where seen.insert(column).inserted {
                        items.append(CompletionItem(label: column, insertText: quoteIfNeeded(column), kind: .column, detail: table))
                    }
                }
                items += tables
                items += catalog.functions.map { CompletionItem(label: $0, insertText: $0, kind: .function, detail: nil) }
                items += catalog.keywords.map {
                    let word = lowercaseKeywords ? $0.lowercased() : $0
                    return CompletionItem(label: word, insertText: word, kind: .keyword, detail: nil)
                }
            }
        }

        let needle = prefix.lowercased()
        var matches = items.filter { $0.label.lowercased().hasPrefix(needle) }
        if !needle.isEmpty {
            // Fall back to substring matches for tables and columns.
            let substring = items.filter {
                ($0.kind == .table || $0.kind == .column) && !$0.label.lowercased().hasPrefix(needle)
                    && $0.label.lowercased().contains(needle)
            }
            matches += substring
        }
        if matches.count == 1, matches[0].label == prefix { return nil }
        guard !matches.isEmpty else { return nil }
        return CompletionResult(replacementRange: start..<cursor, items: Array(matches.prefix(200)))
    }

    /// Maps lowercased aliases and table names referenced in a statement to table names.
    static func aliasMap(_ tokens: [SQLToken], catalog: CompletionCatalog) -> [String: String] {
        let meaningful = tokens.filter { $0.kind != .comment }
        var map: [String: String] = [:]
        let stopWords: Set<String> = ["WHERE", "ON", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS",
                                      "GROUP", "ORDER", "LIMIT", "SET", "USING", "VALUES", "NATURAL", "LATERAL",
                                      "UNION", "RETURNING", "HAVING", "WINDOW", "OFFSET", "FETCH", "FOR", "SELECT"]
        var i = 0
        while i < meaningful.count {
            let token = meaningful[i]
            let isTableContext = token.kind == .keyword && tableContextKeywords.contains(token.text.uppercased())
            let isListContinuation = token.text == "," && !map.isEmpty
                && meaningful[..<i].last(where: { $0.kind == .keyword })?.text.uppercased() == "FROM"
            guard isTableContext || isListContinuation else { i += 1; continue }
            var j = i + 1
            guard j < meaningful.count, meaningful[j].kind == .identifier || meaningful[j].kind == .quotedIdentifier else {
                i += 1
                continue
            }
            var table = unquote(meaningful[j].text)
            // schema.table
            if j + 2 < meaningful.count, meaningful[j + 1].text == ".",
               meaningful[j + 2].kind == .identifier || meaningful[j + 2].kind == .quotedIdentifier {
                table = unquote(meaningful[j + 2].text)
                j += 2
            }
            map[table.lowercased()] = table
            var k = j + 1
            if k < meaningful.count, meaningful[k].text.uppercased() == "AS" { k += 1 }
            if k < meaningful.count, meaningful[k].kind == .identifier || meaningful[k].kind == .quotedIdentifier,
               !stopWords.contains(meaningful[k].text.uppercased()) {
                map[unquote(meaningful[k].text).lowercased()] = table
            }
            i = j + 1
        }
        return map
    }

    private static func columns(of table: String, in catalog: CompletionCatalog) -> [String]? {
        catalog.columns[table] ?? catalog.columns.first { $0.key.lowercased() == table.lowercased() }?.value
    }

    private static func previousKeyword(in u: [UInt16], before offset: Int) -> String? {
        let tokens = SQLLexer.tokens(in: String(decoding: u[0..<offset], as: UTF16.self))
        guard let last = tokens.last(where: { $0.kind != .comment }), last.kind == .keyword else { return nil }
        return last.text.uppercased()
    }

    private static func unquote(_ identifier: String) -> String {
        guard identifier.count >= 2, identifier.hasPrefix("\""), identifier.hasSuffix("\"") else { return identifier }
        return String(identifier.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
    }

    /// Quotes identifiers that aren't plain lowercase names.
    public static func quoteIfNeeded(_ identifier: String) -> String {
        let plain = identifier.utf16.enumerated().allSatisfy { index, c in
            (c >= 97 && c <= 122) || c == 95 || (index > 0 && (SQLLexer.isDigit(c) || c == 36))
        }
        if plain, !SQLKeywords.all.contains(identifier.uppercased()) { return identifier }
        return "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
