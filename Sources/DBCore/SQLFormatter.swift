import Foundation

/// Reformats SELECT, INSERT, UPDATE, DELETE and WITH statements: one clause per line, one
/// select item per line, AND/OR conditions on their own lines, subqueries indented and
/// keywords uppercased. Other statements (DDL, DO blocks…) are left as they are.
public enum SQLFormatter {
    private static let indentUnit = "    "

    /// The formatted SQL, or `nil` when nothing in it could be formatted.
    public static func format(_ sql: String) -> String? {
        let statements = SQLSplitter.split(sql)
        guard !statements.isEmpty else { return nil }
        let u = Array(sql.utf16)
        var out = ""
        var changed = false
        var end = 0
        for statement in statements {
            // Keep what sits between statements (comments), but put each statement after a blank line.
            let gap = String(decoding: u[end..<statement.range.lowerBound], as: UTF16.self)
            out += gap.trimmingCharacters(in: .whitespacesAndNewlines) == ";" ? ";\n\n" : gap
            if let formatted = formatStatement(statement.text) {
                out += formatted
                changed = changed || formatted != statement.text
            } else {
                out += statement.text
            }
            end = statement.range.upperBound
        }
        out += String(decoding: u[end...], as: UTF16.self)
        return changed ? out : nil
    }

    private static let formattable: Set<String> = ["SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "VALUES", "TABLE"]

    /// Clauses that start a line. Multi-word clauses are matched on their first word.
    private static let clauses: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "HAVING", "WINDOW", "ORDER", "LIMIT", "OFFSET", "FETCH", "FOR",
        "UNION", "INTERSECT", "EXCEPT", "INSERT", "VALUES", "UPDATE", "SET", "DELETE", "RETURNING", "WITH",
        "JOIN", "LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL", "ON CONFLICT", "USING",
    ]
    /// Clauses whose top-level comma-separated items go one per line.
    private static let listClauses: Set<String> = ["SELECT", "VALUES", "SET", "WITH", "RETURNING"]
    /// Clauses whose top-level AND/OR conditions go one per line.
    private static let conditionClauses: Set<String> = ["WHERE", "HAVING", "ON"]
    /// Keywords that are usually column or table names; left in the case they were typed.
    private static let nameLike: Set<String> = [
        "KEY", "TYPE", "USER", "ROLE", "COMMENT", "OWNER", "LANGUAGE", "ZONE", "FIRST", "LAST", "START", "DOMAIN",
        "SCHEMA", "SEQUENCE", "INDEX", "TRIGGER", "POLICY", "RULE", "PUBLICATION", "DATABASE", "VIEW", "TABLESPACE",
        "EXTENSION", "FUNCTION", "PROCEDURE", "TRANSACTION", "SESSION_USER", "CURRENT_USER", "LOCAL", "CACHE",
    ]
    /// Keywords that can't be directly followed by a function-call parenthesis.
    private static let spacedBeforeParen: Set<String> = [
        "AS", "IN", "VALUES", "ON", "EXISTS", "AND", "OR", "NOT", "FROM", "JOIN", "USING", "OVER", "FILTER",
        "WITHIN", "SELECT", "WHERE", "BY", "THEN", "ELSE", "WHEN", "INTO", "TABLE", "SET", "RETURNING", "CASE",
        "LATERAL", "ALL", "UNION", "INTERSECT", "EXCEPT", "HAVING", "WITH", "RECURSIVE", "DISTINCT", "IS", "LIKE",
        "ILIKE", "BETWEEN", "CONFLICT", "DO", "UPDATE", "MATERIALIZED",
    ]
    /// Keywords that end a list clause's items.
    private static let listEnd: Set<String> = [
        "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "UNION", "INTERSECT", "EXCEPT",
        "RETURNING", "ON", "INTO", "WINDOW", "FETCH", "FOR", "SELECT",
    ]

    private struct Frame {
        /// A subquery gets its own lines; other parentheses (calls, lists, CASE…) stay inline.
        var isBlock: Bool
        var indent: Int
        var clause = ""
        /// The clause's items go one per line because it has more than one.
        var breaksList = false
    }

    private static func formatStatement(_ text: String) -> String? {
        guard let first = SQLLexer.firstKeyword(in: text), formattable.contains(first) else { return nil }
        let tokens = SQLLexer.tokens(in: text)
        guard !tokens.isEmpty else { return nil }

        var out = ""
        var stack = [Frame(isBlock: true, indent: 0)]
        var previous: SQLToken?
        var previousWord = ""
        var lastKeyword = ""
        var betweenPending = false
        var caseDepth = 0
        var atLineStart = true

        func newline(_ indent: Int) {
            while out.last == " " { out.removeLast() }
            if !out.isEmpty { out += "\n" }
            out += String(repeating: indentUnit, count: indent)
            atLineStart = true
        }
        func hasListComma(from start: Int) -> Bool {
            var depth = 0
            for token in tokens[start...] {
                if token.text == "(" || token.text == "[" {
                    depth += 1
                } else if token.text == ")" || token.text == "]" {
                    depth -= 1
                    if depth < 0 { return false }
                } else if depth == 0 {
                    if token.text == "," { return true }
                    if token.kind == .keyword, listEnd.contains(token.text.uppercased()) { return false }
                }
            }
            return false
        }
        func emit(_ text: String, space: Bool) {
            if !atLineStart, space, !out.isEmpty, out.last != " ", out.last != "\n" { out += " " }
            out += text
            atLineStart = false
        }

        for (index, token) in tokens.enumerated() {
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            let word = token.kind == .keyword ? token.text.uppercased() : ""
            var frame = stack[stack.count - 1]
            let topLevel = frame.isBlock && caseDepth == 0

            if token.kind == .comment {
                emit(token.text, space: true)
                if token.text.hasPrefix("--") { newline(frame.indent + (frame.clause.isEmpty ? 0 : 1)) }
                previous = token
                continue
            }

            // Uppercase keywords, except name-like ones and those used as qualified names (t.type).
            var shown = token.text
            let qualified = previous?.text == "." || next?.text == "."
            if token.kind == .keyword, !nameLike.contains(word), !qualified { shown = word }

            if token.kind == .keyword, !qualified, topLevel {
                var clause = word
                if word == "ON", next.map({ $0.text.uppercased() == "CONFLICT" }) == true { clause = "ON CONFLICT" }
                // Words that only start a clause in some positions.
                let joinPrefix = ["LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL"].contains(word)
                let isJoin = word == "JOIN" && !["LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL", "OUTER"].contains(previousWord)
                let startsClause: Bool
                switch clause {
                case "JOIN": startsClause = isJoin
                case "LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL": startsClause = joinPrefix && previousWord != "NATURAL"
                case "SET": startsClause = lastKeyword == "UPDATE" || previousWord == "UPDATE" || frame.clause == "UPDATE"
                case "USING": startsClause = frame.clause == "DELETE"
                case "FOR": startsClause = frame.clause != "" && !["UPDATE"].contains(previousWord)
                case "UPDATE": startsClause = previousWord != "FOR" && previousWord != "DO" && previousWord != "KEY"
                case "SELECT": startsClause = previousWord != "DISTINCT"
                case "WITH": startsClause = previous == nil || previous?.text == "("
                case "FROM": startsClause = frame.clause != "DELETE"
                case "VALUES": startsClause = true
                case "ON": startsClause = false
                default: startsClause = clauses.contains(clause)
                }
                if startsClause {
                    newline(frame.indent)
                    emit(shown, space: false)
                    frame.clause = clause == "LEFT" || clause == "RIGHT" || clause == "INNER" || clause == "FULL"
                        || clause == "CROSS" || clause == "NATURAL" ? "JOIN" : clause
                    if word == "DELETE" { frame.clause = "DELETE" }
                    frame.breaksList = listClauses.contains(clause) && (clause == "WITH" || hasListComma(from: index + 1))
                    stack[stack.count - 1] = frame
                    if frame.breaksList, clause != "WITH", next.map({ $0.text.uppercased() != "DISTINCT" }) ?? true {
                        newline(frame.indent + 1)
                    }
                    previous = token
                    previousWord = word
                    lastKeyword = word
                    continue
                }
                if word == "ON", frame.clause == "JOIN" {
                    frame.clause = "ON"
                    stack[stack.count - 1] = frame
                }
                if (word == "AND" || word == "OR"), conditionClauses.contains(frame.clause) || frame.clause == "JOIN" {
                    if word == "AND", betweenPending {
                        betweenPending = false
                    } else {
                        newline(frame.indent + 1)
                        emit(shown, space: false)
                        previous = token
                        previousWord = word
                        lastKeyword = word
                        continue
                    }
                }
            }
            if word == "BETWEEN" { betweenPending = true }
            if word == "CASE" { caseDepth += 1 }
            if word == "END", caseDepth > 0 { caseDepth -= 1 }

            switch token.text {
            case "(":
                let opensSubquery = next.map { ["SELECT", "WITH", "VALUES"].contains($0.text.uppercased()) } ?? false
                let callLike = previous.map { p in
                    (p.kind == .identifier || p.kind == .quotedIdentifier) && lastKeyword != "INTO"
                        || (p.kind == .keyword && !spacedBeforeParen.contains(p.text.uppercased()))
                        || p.text == "]"
                } ?? false
                emit("(", space: !callLike && previous?.text != "(" && previous?.text != "[" && previous?.text != "::")
                let base = frame.indent + (frame.clause.isEmpty ? 0 : 1)
                stack.append(Frame(isBlock: opensSubquery, indent: base))
                if opensSubquery { atLineStart = true }
            case ")":
                let closing = stack.count > 1 ? stack.removeLast() : frame
                if closing.isBlock {
                    newline(max(closing.indent - 1, 0))
                    emit(")", space: false)
                } else {
                    emit(")", space: false)
                }
            case ",":
                emit(",", space: false)
                if topLevel, frame.breaksList { newline(frame.clause == "WITH" ? frame.indent : frame.indent + 1) }
            case ".", "::", "[", "]":
                emit(token.text, space: false)
            default:
                let afterTight = ["(", ".", "::", "["].contains(previous?.text ?? "")
                // Unary minus or plus: no space after it.
                let previousIsUnary = previous.map { p in
                    (p.text == "-" || p.text == "+") && index >= 2 && {
                        let before = tokens[index - 2]
                        return before.kind == .op || before.text == "(" || before.text == "," || before.kind == .keyword
                    }()
                } ?? false
                emit(shown, space: !afterTight && !previousIsUnary && !atLineStart)
                if word == "DISTINCT", previousWord == "SELECT", frame.breaksList, next.map({ $0.text.uppercased() != "ON" }) ?? false {
                    newline(frame.indent + 1)
                }
            }
            previous = token
            if token.kind == .keyword { previousWord = word; lastKeyword = word } else { previousWord = "" }
        }
        while out.last == " " || out.last == "\n" { out.removeLast() }

        // Formatting only changes whitespace and keyword case. Anything else means a bug: keep the original.
        func normalized(_ s: String) -> String { s.filter { !$0.isWhitespace }.lowercased() }
        return normalized(out) == normalized(text) ? out : nil
    }
}
