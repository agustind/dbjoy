import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, json, sql

    public var id: String { rawValue }

    public var fileExtension: String { rawValue }
}

/// Events produced while streaming table contents for export.
public enum RowStreamEvent: Sendable {
    /// First event for a table, with its column descriptions.
    case begin(ObjectRef, [ResultColumn])
    case rows(ObjectRef, [[String?]])
    case end(ObjectRef, rowCount: Int)
}

/// Text encodings used by exports. NULL handling: CSV writes an empty unquoted field
/// (empty strings are quoted), JSON writes `null`, SQL writes `NULL`.
public enum ExportEncoding {
    // MARK: CSV (RFC 4180)

    public static func csvField(_ value: String?) -> String {
        guard let value else { return "" }
        if value.isEmpty { return "\"\"" }
        let needsQuoting = value.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
            || value.first == " " || value.last == " "
        return needsQuoting ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }

    public static func csvLine(_ values: [String?]) -> String {
        values.map(csvField).joined(separator: ",") + "\r\n"
    }

    // MARK: JSON

    public static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static func isJSONNumber(_ value: String) -> Bool {
        value.wholeMatch(of: /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/) != nil
    }

    /// Numbers and booleans become JSON scalars, json/jsonb values are embedded as-is,
    /// everything else (including NaN, money, etc.) is a string.
    public static func jsonValue(_ value: String?, category: ValueCategory) -> String {
        guard let value else { return "null" }
        switch category {
        case .number where isJSONNumber(value): return value
        case .boolean where value == "true" || value == "false": return value
        case .json: return value
        default: return jsonString(value)
        }
    }

    public static func jsonObject(columns: [ResultColumn], row: [String?]) -> String {
        let fields = zip(columns, row).map { column, value in
            jsonString(column.name) + ": " + jsonValue(value, category: column.category)
        }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    // MARK: SQL

    /// A multi-row INSERT. Pass `overridingSystemValue` when the column list includes
    /// GENERATED ALWAYS identity columns.
    public static func insertStatement(table: ObjectRef, columns: [String], rows: [[String?]],
                                       dialect: any SQLDialect, overridingSystemValue: Bool = false) -> String {
        let columnList = columns.map(dialect.quoteIdentifier).joined(separator: ", ")
        let values = rows.map { row in
            "  (" + row.map { $0.map(dialect.quoteLiteral) ?? "NULL" }.joined(separator: ", ") + ")"
        }
        let overriding = overridingSystemValue ? " OVERRIDING SYSTEM VALUE" : ""
        return "INSERT INTO \(dialect.qualifiedName(table)) (\(columnList))\(overriding) VALUES\n"
            + values.joined(separator: ",\n") + ";\n"
    }

    /// Orders tables so referenced tables come before the tables that reference them.
    /// Cycles fall back to name order.
    public static func dependencyOrder(_ tables: [ObjectRef], foreignKeys: [ForeignKeyInfo]) -> [ObjectRef] {
        let set = Set(tables.map { "\($0.schema).\($0.name)" })
        var dependencies: [String: Set<String>] = [:]
        for fk in foreignKeys {
            let from = "\(fk.table.schema).\(fk.table.name)"
            let to = "\(fk.referencedTable.schema).\(fk.referencedTable.name)"
            if from != to, set.contains(from), set.contains(to) { dependencies[from, default: []].insert(to) }
        }
        var ordered: [ObjectRef] = []
        var done = Set<String>()
        var visiting = Set<String>()
        let byKey = Dictionary(tables.map { ("\($0.schema).\($0.name)", $0) }, uniquingKeysWith: { a, _ in a })
        func visit(_ key: String) {
            guard !done.contains(key), !visiting.contains(key) else { return }
            visiting.insert(key)
            for dependency in (dependencies[key] ?? []).sorted() { visit(dependency) }
            visiting.remove(key)
            done.insert(key)
            if let ref = byKey[key] { ordered.append(ref) }
        }
        for key in byKey.keys.sorted() { visit(key) }
        return ordered
    }
}
