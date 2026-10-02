import DBCore
import Testing

struct CompletionTests {
    let catalog = CompletionCatalog(
        tables: ["customers", "orders", "OrderItems"],
        columns: ["customers": ["id", "name", "email"], "orders": ["id", "customer_id", "status"], "OrderItems": ["qty"]],
        schemas: ["public", "sales"],
        functions: ["count", "coalesce"])

    func labels(_ sql: String, explicit: Bool = false) -> [String] {
        let cursor = sql.utf16.count
        return CompletionEngine.complete(sql: sql, cursor: cursor, catalog: catalog, explicit: explicit)?.items.map(\.label) ?? []
    }

    @Test func tablesAfterFrom() {
        #expect(labels("SELECT * FROM or") == ["orders", "OrderItems"])
        #expect(labels("select * from ", explicit: true).prefix(3) == ["customers", "orders", "OrderItems"])
    }

    @Test func columnsViaAlias() {
        let sql = "SELECT o.st FROM orders o"
        let cursor = (sql as NSString).range(of: "o.st").upperBound
        #expect(CompletionEngine.complete(sql: sql, cursor: cursor, catalog: catalog)?.items.map(\.label) == ["status", "customer_id"]) // prefix matches rank first
        #expect(labels("SELECT * FROM public.customers AS c WHERE c.") == ["id", "name", "email"])
        #expect(labels("SELECT * FROM customers JOIN orders ON customers.id = orders.cu") == ["customer_id"])
    }

    @Test func columnsOfReferencedTablesFirst() {
        let sql = "SELECT na FROM customers"
        let cursor = (sql as NSString).range(of: "na").upperBound
        let items = CompletionEngine.complete(sql: sql, cursor: cursor, catalog: catalog)?.items ?? []
        #expect(items.first?.label == "name")
        #expect(items.first?.kind == .column)
    }

    @Test func keywordCaseFollowsPrefix() {
        #expect(labels("sel") == ["select"])
        #expect(labels("SEL") == ["SELECT"])
    }

    @Test func quotesMixedCaseIdentifiers() {
        let items = CompletionEngine.complete(sql: "SELECT * FROM Order", cursor: 19, catalog: catalog)?.items
        #expect(items?.first { $0.label == "OrderItems" }?.insertText == "\"OrderItems\"")
        #expect(CompletionEngine.quoteIfNeeded("user") == "\"user\"")
        #expect(CompletionEngine.quoteIfNeeded("user_id2") == "user_id2")
    }

    @Test func nothingForEmptyPrefixOrNumbers() {
        #expect(labels("SELECT ").isEmpty)
        #expect(labels("SELECT 12").isEmpty)
        #expect(labels("SELECT name").isEmpty) // exact single match
    }
}

import Foundation
