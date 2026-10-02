import Foundation

public struct SQLToken: Hashable, Sendable {
    public enum Kind: Sendable {
        case keyword, identifier, quotedIdentifier, string, number, comment, op, punctuation, parameter
    }

    public var kind: Kind
    /// UTF-16 offsets, compatible with `NSRange`.
    public var range: Range<Int>
    public var text: String

    public var nsRange: NSRange { NSRange(location: range.lowerBound, length: range.count) }
}

/// A forgiving SQL tokenizer covering PostgreSQL lexical rules (dollar quoting, E-strings,
/// nested block comments). Used for highlighting, statement splitting and completion.
public enum SQLLexer {
    public static func tokens(in sql: String, keywords: Set<String> = SQLKeywords.all) -> [SQLToken] {
        let u = Array(sql.utf16)
        let n = u.count
        var tokens: [SQLToken] = []
        var i = 0

        func text(_ r: Range<Int>) -> String {
            String(decoding: u[r], as: UTF16.self)
        }
        func add(_ kind: SQLToken.Kind, _ start: Int, _ end: Int) {
            tokens.append(SQLToken(kind: kind, range: start..<end, text: text(start..<end)))
        }
        func at(_ j: Int) -> UInt16 { j < n ? u[j] : 0 }

        while i < n {
            let c = u[i]
            let start = i

            if isSpace(c) {
                i += 1
                continue
            }
            // -- line comment
            if c == ch("-"), at(i + 1) == ch("-") {
                while i < n, u[i] != ch("\n") { i += 1 }
                add(.comment, start, i)
                continue
            }
            // /* block comment */ (nestable)
            if c == ch("/"), at(i + 1) == ch("*") {
                var depth = 0
                while i < n {
                    if u[i] == ch("/"), at(i + 1) == ch("*") { depth += 1; i += 2; continue }
                    if u[i] == ch("*"), at(i + 1) == ch("/") {
                        depth -= 1; i += 2
                        if depth == 0 { break }
                        continue
                    }
                    i += 1
                }
                add(.comment, start, min(i, n))
                continue
            }
            // String literal, with optional E/B/X/N prefix.
            if c == ch("'") || (isPrefixLetter(c) && at(i + 1) == ch("'")) {
                let escapes = c == ch("E") || c == ch("e")
                if c != ch("'") { i += 1 }
                i += 1
                while i < n {
                    if escapes, u[i] == ch("\\") { i += 2; continue }
                    if u[i] == ch("'") {
                        if at(i + 1) == ch("'") { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                add(.string, start, min(i, n))
                continue
            }
            // "quoted identifier"
            if c == ch("\"") {
                i += 1
                while i < n {
                    if u[i] == ch("\"") {
                        if at(i + 1) == ch("\"") { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                add(.quotedIdentifier, start, min(i, n))
                continue
            }
            if c == ch("$") {
                // $1 positional parameter
                if isDigit(at(i + 1)) {
                    i += 1
                    while i < n, isDigit(u[i]) { i += 1 }
                    add(.parameter, start, i)
                    continue
                }
                // $tag$ ... $tag$ dollar quoting
                var j = i + 1
                while j < n, isIdentChar(u[j]), u[j] != ch("$") { j += 1 }
                if j < n, u[j] == ch("$"), j == i + 1 || isIdentStart(u[i + 1]) {
                    let tag = Array(u[i...j])
                    i = j + 1
                    var closed = false
                    while i < n {
                        if u[i] == ch("$"), i + tag.count <= n, Array(u[i..<(i + tag.count)]) == tag {
                            i += tag.count
                            closed = true
                            break
                        }
                        i += 1
                    }
                    if !closed { i = n }
                    add(.string, start, i)
                    continue
                }
            }
            if isDigit(c) || (c == ch(".") && isDigit(at(i + 1))) {
                while i < n, isDigit(u[i]) || u[i] == ch(".") || u[i] == ch("_") { i += 1 }
                if i < n, u[i] == ch("e") || u[i] == ch("E") {
                    var j = i + 1
                    if at(j) == ch("+") || at(j) == ch("-") { j += 1 }
                    if isDigit(at(j)) {
                        i = j
                        while i < n, isDigit(u[i]) { i += 1 }
                    }
                }
                add(.number, start, i)
                continue
            }
            if isIdentStart(c) {
                while i < n, isIdentChar(u[i]) { i += 1 }
                let word = text(start..<i)
                tokens.append(SQLToken(kind: keywords.contains(word.uppercased()) ? .keyword : .identifier,
                                       range: start..<i, text: word))
                continue
            }
            // :name bind parameter (but not :: casts)
            if c == ch(":"), at(i + 1) != ch(":"), isIdentStart(at(i + 1)), (start == 0 || u[start - 1] != ch(":")) {
                i += 1
                while i < n, isIdentChar(u[i]) { i += 1 }
                add(.parameter, start, i)
                continue
            }
            if c == ch(";") || c == ch(",") || c == ch("(") || c == ch(")") || c == ch(".")
                || c == ch("[") || c == ch("]") {
                i += 1
                add(.punctuation, start, i)
                continue
            }
            // Operators: consume a run of operator characters.
            i += 1
            while i < n, isOperatorChar(u[i]), !(u[i] == ch("-") && at(i + 1) == ch("-")),
                  !(u[i] == ch("/") && at(i + 1) == ch("*")) {
                i += 1
            }
            add(.op, start, i)
        }
        return tokens
    }

    /// The first keyword of a statement, uppercased, ignoring comments and parentheses.
    public static func firstKeyword(in sql: String) -> String? {
        for token in tokens(in: sql) {
            switch token.kind {
            case .comment, .punctuation: continue
            case .keyword, .identifier: return token.text.uppercased()
            default: return nil
            }
        }
        return nil
    }

    @inline(__always) static func ch(_ s: Unicode.Scalar) -> UInt16 { UInt16(s.value) }
    static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }
    static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    static func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    static func isIdentStart(_ c: UInt16) -> Bool { isLetter(c) || c == 95 || c > 127 }
    public static func isIdentChar(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) || c == 36 }
    static func isPrefixLetter(_ c: UInt16) -> Bool {
        c == ch("E") || c == ch("e") || c == ch("B") || c == ch("b") || c == ch("X") || c == ch("x")
            || c == ch("N") || c == ch("n")
    }
    static func isOperatorChar(_ c: UInt16) -> Bool {
        "+-*/<>=~!@#%^&|`?:".utf16.contains(c)
    }
}

public struct SQLStatement: Hashable, Sendable {
    public var text: String
    /// UTF-16 range of the statement content (without the trailing semicolon).
    public var range: Range<Int>
}

public enum SQLSplitter {
    /// Splits a script into statements on top-level semicolons. Comment-only fragments are dropped.
    public static func split(_ sql: String) -> [SQLStatement] {
        let tokens = SQLLexer.tokens(in: sql)
        let u = Array(sql.utf16)
        var statements: [SQLStatement] = []
        var first: Int?
        var last = 0
        var atomicDepth = 0
        var previousKeyword = ""

        func flush() {
            if let start = first {
                statements.append(SQLStatement(text: String(decoding: u[start..<last], as: UTF16.self), range: start..<last))
            }
            first = nil
        }

        for token in tokens {
            if token.kind == .comment { continue }
            if token.kind == .punctuation, token.text == ";", atomicDepth == 0 {
                flush()
                previousKeyword = ""
                continue
            }
            if token.kind == .keyword {
                let word = token.text.uppercased()
                if word == "ATOMIC", previousKeyword == "BEGIN" {
                    atomicDepth += 1
                } else if atomicDepth > 0, word == "CASE" {
                    atomicDepth += 1
                } else if atomicDepth > 0, word == "END" {
                    atomicDepth -= 1
                }
                previousKeyword = word
            }
            if first == nil { first = token.range.lowerBound }
            last = token.range.upperBound
        }
        flush()
        return statements
    }

    /// The statement under the cursor: the last statement starting at or before `offset`.
    public static func statement(at offset: Int, in sql: String) -> SQLStatement? {
        let statements = split(sql)
        return statements.last(where: { $0.range.lowerBound <= offset }) ?? statements.first
    }
}
