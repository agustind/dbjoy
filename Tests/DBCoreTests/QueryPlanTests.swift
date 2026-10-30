import DBCore
import Testing

struct QueryPlanTests {
    @Test func analyzedPlan() throws {
        let json = """
            [{"Plan": {"Node Type": "Hash Join", "Join Type": "Left", "Total Cost": 100.0, "Plan Rows": 10,
              "Actual Total Time": 8.0, "Actual Rows": 1000, "Actual Loops": 1, "Hash Cond": "(o.customer_id = c.id)",
              "Plans": [
                {"Node Type": "Seq Scan", "Relation Name": "orders", "Alias": "o", "Total Cost": 60.0, "Plan Rows": 1000,
                 "Actual Total Time": 5.0, "Actual Rows": 1000, "Actual Loops": 1, "Filter": "(total > 10)",
                 "Rows Removed by Filter": 50, "Shared Hit Blocks": 3, "Shared Read Blocks": 2},
                {"Node Type": "Hash", "Total Cost": 20.0, "Plan Rows": 100, "Actual Total Time": 1.0, "Actual Rows": 100,
                 "Actual Loops": 1, "Plans": [
                   {"Node Type": "Index Scan", "Index Name": "customers_pkey", "Relation Name": "customers", "Alias": "c",
                    "Total Cost": 15.0, "Plan Rows": 100, "Actual Total Time": 0.5, "Actual Rows": 100, "Actual Loops": 1}]}]},
              "Planning Time": 0.2, "Execution Time": 8.1}]
            """
        let plan = try QueryPlan(json: json)
        #expect(plan.isAnalyzed)
        #expect(plan.executionTime == 8.1)
        #expect(plan.nodes.map(\.title) == ["Hash Left Join", "Seq Scan on orders o", "Hash", "Index Scan using customers_pkey on customers c"])
        #expect(plan.nodes.map(\.depth) == [0, 1, 1, 2])
        #expect(plan.nodes.map(\.selfTime) == [2.0, 5.0, 0.5, 0.5])
        #expect(plan.nodes[1].share == 5.0 / 8.0)
        #expect(plan.nodes[1].details == ["Filter: (total > 10)", "Rows Removed by Filter: 50", "Buffers: 3 cached, 2 read from disk"])
        #expect(plan.nodes[0].estimateMiss == 100)
        #expect(plan.nodes[1].estimateMiss == nil)
    }

    @Test func costOnlyPlan() throws {
        let plan = try QueryPlan(json: #"[{"Plan": {"Node Type": "Seq Scan", "Relation Name": "t", "Alias": "t", "Total Cost": 4.0, "Plan Rows": 3}}]"#)
        #expect(!plan.isAnalyzed)
        #expect(plan.nodes.map(\.title) == ["Seq Scan on t"])
        #expect(plan.nodes[0].share == 1)
        #expect(throws: DatabaseError.self) { try QueryPlan(json: "[]") }
    }
}
