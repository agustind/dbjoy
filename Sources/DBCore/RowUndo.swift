import Foundation

// MARK: - Undoing committed row changes

public extension SQLDialect {
    /// The statements that apply `change` and also return what reverting it needs: the row as it was
    /// before (UPDATE, DELETE) and as it is after (INSERT, UPDATE). Each must affect exactly one row.
    /// Uses `FOR UPDATE` and `RETURNING`, which PostgreSQL supports.
    func capturingStatements(for change: RowChange, in table: ObjectRef) -> [TransactionStatement] {
        let plain = statement(for: change, in: table)
        let returning = String(plain.dropLast(plain.hasSuffix(";") ? 1 : 0)) + " RETURNING *;"
        switch change {
        case .update(let key, _):
            let lock = "SELECT * FROM \(qualifiedName(table)) WHERE \(whereClause(key)) FOR UPDATE;"
            return [TransactionStatement(lock, expectedRows: 1), TransactionStatement(returning, expectedRows: 1)]
        case .insert, .delete:
            return [TransactionStatement(returning, expectedRows: 1)]
        }
    }

    /// The statement that reverts `change`, built from the results of `capturingStatements`.
    /// It only matches the row while it still holds what the change wrote, so reverting fails
    /// (no row affected) instead of overwriting someone's later edit.
    /// - Parameters:
    ///   - primaryKey: the table's primary key columns.
    ///   - generated: columns the database computes, which can't be inserted.
    func undoStatement(for change: RowChange, in table: ObjectRef, primaryKey: [String], generated: Set<String>,
                       results: [QueryResult]) -> String? {
        guard !primaryKey.isEmpty, let after = results.last.flatMap(Self.firstRow) else { return nil }
        let name = qualifiedName(table)
        func key(_ row: [String: String?]) -> [ColumnValue]? {
            var key: [ColumnValue] = []
            for column in primaryKey {
                guard case .some(.some(let value)) = row[column] else { return nil }
                key.append(ColumnValue(column, .value(value)))
            }
            return key
        }
        // Compared as text: the values came back as text, and every type casts to text (json has no `=`).
        func unchanged(_ columns: [String], in row: [String: String?]) -> [String] {
            columns.compactMap { column in
                guard let value = row[column] else { return nil }
                return "\(quoteIdentifier(column))::text IS NOT DISTINCT FROM " + (value.map(quoteLiteral) ?? "NULL")
            }
        }

        switch change {
        case .update(_, let values):
            guard results.count == 2, let before = Self.firstRow(results[0]), let key = key(after) else { return nil }
            let columns = values.map(\.column)
            let assignments = columns.compactMap { column in
                before[column].map { "\(quoteIdentifier(column)) = \($0.map(quoteLiteral) ?? "NULL")" }
            }
            guard assignments.count == columns.count else { return nil }
            let conditions = [whereClause(key)] + unchanged(columns, in: after)
            return "UPDATE \(name) SET \(assignments.joined(separator: ", ")) WHERE \(conditions.joined(separator: " AND "));"

        case .insert:
            guard let key = key(after) else { return nil }
            let columns = results.last!.columns.map(\.name).filter { !generated.contains($0) }
            let conditions = [whereClause(key)] + unchanged(columns, in: after)
            return "DELETE FROM \(name) WHERE \(conditions.joined(separator: " AND "));"

        case .delete:
            // `after` is the deleted row, from DELETE … RETURNING.
            let columns = results.last!.columns.map(\.name).filter { !generated.contains($0) }
            let names = columns.map(quoteIdentifier).joined(separator: ", ")
            let values = columns.map { column in after[column]!.map(quoteLiteral) ?? "NULL" }.joined(separator: ", ")
            // Puts back the original values of GENERATED ALWAYS identity columns too.
            return "INSERT INTO \(name) (\(names)) OVERRIDING SYSTEM VALUE VALUES (\(values));"
        }
    }

    private static func firstRow(_ result: QueryResult) -> [String: String?]? {
        guard let row = result.rows.first else { return nil }
        var values: [String: String?] = [:]
        for (column, value) in zip(result.columns, row) { values[column.name] = value }
        return values
    }
}

/// One commit from a table tab, with the SQL that reverts it.
public struct EditRecord: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var database: String
    public var table: ObjectRef
    public var updated: Int
    public var inserted: Int
    public var deleted: Int
    /// The statements that were committed, as shown for review.
    public var statements: [String]
    /// Reverts the commit when run in order in one transaction, each affecting exactly one row.
    public var undo: [String]
    public var revertedAt: Date?

    public init(database: String, table: ObjectRef, changes: [RowChange], statements: [String], undo: [String]) {
        self.database = database
        self.table = table
        self.statements = statements
        self.undo = undo
        updated = changes.filter { if case .update = $0 { true } else { false } }.count
        inserted = changes.filter { if case .insert = $0 { true } else { false } }.count
        deleted = changes.filter { if case .delete = $0 { true } else { false } }.count
    }

    /// "2 updated, 1 deleted".
    public var summary: String {
        [(updated, "updated"), (inserted, "inserted"), (deleted, "deleted")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }
}
