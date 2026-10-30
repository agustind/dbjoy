import Foundation

public extension QueryResult {
    /// Row indices ordered by a column, for sorting loaded results without running the query
    /// again. Numbers compare numerically, text in Finder order, and NULLs come last either way.
    func rowOrder(sortedBy column: Int, ascending: Bool) -> [Int] {
        guard columns.indices.contains(column) else { return Array(rows.indices) }
        let category = columns[column].category
        let numbers: [Double?]? = category == .number ? rows.map { $0[column].flatMap(Double.init) } : nil

        func before(_ a: Int, _ b: Int) -> Bool? {
            if let numbers, let x = numbers[a], let y = numbers[b] {
                return x == y ? nil : x < y
            }
            guard let x = rows[a][column], let y = rows[b][column] else { return nil }
            let order = category == .temporal ? (x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending)
                : x.localizedStandardCompare(y)
            return order == .orderedSame ? nil : order == .orderedAscending
        }

        return rows.indices.sorted { a, b in
            let aNull = rows[a][column] == nil, bNull = rows[b][column] == nil
            if aNull != bNull { return bNull }
            if let isBefore = before(a, b) { return ascending ? isBefore : !isBefore }
            // Keep the server's order for equal values.
            return a < b
        }
    }
}
