import Foundation

/// A PostgreSQL plan from `EXPLAIN (FORMAT JSON)`, flattened into rows for a tree view.
public struct QueryPlan: Sendable {
    public struct Node: Identifiable, Sendable {
        public let id: Int
        public var depth: Int
        /// As in EXPLAIN's text output, e.g. "Index Scan using orders_pkey on orders o".
        public var title: String
        /// Conditions, sort keys and other attributes worth reading, e.g. "Filter: (total > 10)".
        public var details: [String]
        public var estimatedRows: Double
        public var totalCost: Double
        /// Rows over all loops. Only with ANALYZE.
        public var actualRows: Double?
        public var loops: Int?
        /// Time in this node and its children over all loops, in milliseconds. Only with ANALYZE.
        public var totalTime: Double?
        /// Time in this node alone (`totalTime` minus its children's).
        public var selfTime: Double?
        /// Cost of this node alone (`totalCost` minus its children's).
        public var selfCost: Double
        /// This node's share of the whole plan's time (with ANALYZE) or cost, from 0 to 1.
        public var share: Double = 0

        /// Set when the planner's row estimate is off by 10× or more, which often explains a bad plan.
        public var estimateMiss: Double? {
            guard let actualRows, let loops, loops > 0 else { return nil }
            let estimate = max(estimatedRows * Double(loops), 1), actual = max(actualRows, 1)
            let ratio = max(estimate / actual, actual / estimate)
            return ratio >= 10 ? ratio : nil
        }
    }

    public var nodes: [Node]
    public var planningTime: Double?
    public var executionTime: Double?
    public var isAnalyzed: Bool { nodes.first?.totalTime != nil }
    /// The JSON as returned by the server.
    public var json: String

    public init(json: String) throws {
        self.json = json
        guard let data = json.data(using: .utf8),
              let top = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first,
              let root = top["Plan"] as? [String: Any] else {
            throw DatabaseError("The server didn't return a plan in the expected format.")
        }
        planningTime = top["Planning Time"] as? Double
        executionTime = top["Execution Time"] as? Double
        nodes = []
        add(root, depth: 0)

        let weights = nodes.map { $0.selfTime ?? $0.selfCost }
        let total = weights.reduce(0, +)
        if total > 0 {
            for index in nodes.indices { nodes[index].share = weights[index] / total }
        }
    }

    /// Adds a node and its children in tree order and returns its (time, cost) for the parent.
    @discardableResult
    private mutating func add(_ plan: [String: Any], depth: Int) -> (time: Double?, cost: Double) {
        let index = nodes.count
        let loops = plan["Actual Loops"] as? Int
        let time = (plan["Actual Total Time"] as? Double).map { $0 * Double(loops ?? 1) }
        let cost = plan["Total Cost"] as? Double ?? 0
        nodes.append(Node(id: index, depth: depth, title: Self.title(plan), details: Self.details(plan),
                          estimatedRows: plan["Plan Rows"] as? Double ?? 0, totalCost: cost,
                          actualRows: (plan["Actual Rows"] as? Double).map { $0 * Double(loops ?? 1) },
                          loops: loops, totalTime: time, selfTime: time, selfCost: cost))
        var childTime = 0.0, childCost = 0.0
        for child in plan["Plans"] as? [[String: Any]] ?? [] {
            let (time, cost) = add(child, depth: depth + 1)
            childTime += time ?? 0
            childCost += cost
        }
        nodes[index].selfTime = time.map { max($0 - childTime, 0) }
        nodes[index].selfCost = max(cost - childCost, 0)
        return (time, cost)
    }

    private static func title(_ plan: [String: Any]) -> String {
        var title = plan["Node Type"] as? String ?? "Node"
        // Writes show as "Insert", "Update", "Delete" or "Merge", like EXPLAIN's text output.
        if title == "ModifyTable", let operation = plan["Operation"] as? String { title = operation }
        if let join = plan["Join Type"] as? String, join != "Inner" {
            title = title.contains("Join") ? title.replacingOccurrences(of: "Join", with: "\(join) Join")
                : "\(title) \(join) Join"
        }
        if let strategy = plan["Strategy"] as? String, title == "Aggregate", strategy != "Plain" {
            title = "\(strategy == "Hashed" ? "Hash" : strategy) Aggregate"
        }
        if let index = plan["Index Name"] as? String { title += " using \(index)" }
        if let relation = plan["Relation Name"] as? String {
            title += " on \(relation)"
            if let alias = plan["Alias"] as? String, alias != relation { title += " \(alias)" }
        } else if let name = plan["CTE Name"] as? String {
            title += " on \(name)"
        } else if let name = plan["Function Name"] as? String {
            title += " on \(name)"
        }
        if let subplan = plan["Subplan Name"] as? String { title = "\(subplan): \(title)" }
        return title
    }

    private static func details(_ plan: [String: Any]) -> [String] {
        var details: [String] = []
        for key in ["Index Cond", "Recheck Cond", "Hash Cond", "Merge Cond", "Join Filter", "Filter"] {
            if let value = plan[key] as? String { details.append("\(key): \(value)") }
        }
        for key in ["Sort Key", "Group Key", "Presorted Key"] {
            if let value = plan[key] as? [String] { details.append("\(key): \(value.joined(separator: ", "))") }
        }
        for key in ["Rows Removed by Filter", "Rows Removed by Join Filter", "Rows Removed by Index Recheck", "Heap Fetches"] {
            if let value = plan[key] as? Int, value > 0 { details.append("\(key): \(value)") }
        }
        if let method = plan["Sort Method"] as? String {
            var text = "Sort Method: \(method)"
            if let space = plan["Sort Space Used"] as? Int, let type = plan["Sort Space Type"] as? String {
                text += ", \(space) kB (\(type.lowercased()))"
            }
            details.append(text)
        }
        if let planned = plan["Workers Planned"] as? Int {
            details.append("Workers: \(plan["Workers Launched"] as? Int ?? planned) of \(planned) planned")
        }
        let hit = plan["Shared Hit Blocks"] as? Int ?? 0, read = plan["Shared Read Blocks"] as? Int ?? 0
        if hit + read > 0 { details.append("Buffers: \(hit) cached, \(read) read from disk") }
        return details
    }
}
