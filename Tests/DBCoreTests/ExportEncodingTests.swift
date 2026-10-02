import DBCore
import Testing

struct ExportEncodingTests {
    @Test func csv() {
        #expect(ExportEncoding.csvLine(["1", nil, "", "a,b", "say \"hi\"", "two\nlines", " pad"])
                == "1,,\"\",\"a,b\",\"say \"\"hi\"\"\",\"two\nlines\",\" pad\"\r\n")
    }

    @Test func json() {
        let columns = [ResultColumn(name: "n", typeName: "numeric", category: .number),
                       ResultColumn(name: "m", typeName: "money", category: .number),
                       ResultColumn(name: "b", typeName: "boolean", category: .boolean),
                       ResultColumn(name: "j", typeName: "jsonb", category: .json),
                       ResultColumn(name: "t", typeName: "text", category: .text),
                       ResultColumn(name: "x", typeName: "double precision", category: .number)]
        #expect(ExportEncoding.jsonObject(columns: columns, row: ["-1.5e-10", "$19.99", "true", "{\"a\": [1]}", "line\n\"q\"\u{1}", nil])
                == #"{"n": -1.5e-10, "m": "$19.99", "b": true, "j": {"a": [1]}, "t": "line\n\"q\"\u0001", "x": null}"#)
        #expect(ExportEncoding.jsonValue("NaN", category: .number) == "\"NaN\"")
    }

    @Test func insert() {
        let ref = ObjectRef(schema: "public", name: "t", kind: .table)
        #expect(ExportEncoding.insertStatement(table: ref, columns: ["id", "name"], rows: [["1", "O'Hara"], ["2", nil]],
                                               dialect: GenericDialect(), overridingSystemValue: true)
                == "INSERT INTO \"public\".\"t\" (\"id\", \"name\") OVERRIDING SYSTEM VALUE VALUES\n  ('1', 'O''Hara'),\n  ('2', NULL);\n")
    }

    @Test func dependencyOrder() {
        func ref(_ name: String) -> ObjectRef { ObjectRef(schema: "public", name: name, kind: .table) }
        let fks = [ForeignKeyInfo(name: "a", table: ref("order_items"), columns: ["order_id"], referencedTable: ref("orders"), referencedColumns: ["id"]),
                   ForeignKeyInfo(name: "b", table: ref("orders"), columns: ["customer_id"], referencedTable: ref("customers"), referencedColumns: ["id"]),
                   ForeignKeyInfo(name: "c", table: ref("order_items"), columns: ["product_id"], referencedTable: ref("products"), referencedColumns: ["id"]),
                   ForeignKeyInfo(name: "self", table: ref("tree"), columns: ["parent"], referencedTable: ref("tree"), referencedColumns: ["id"])]
        let order = ExportEncoding.dependencyOrder(["order_items", "orders", "tree", "products", "customers"].map(ref), foreignKeys: fks).map(\.name)
        #expect(order.firstIndex(of: "customers")! < order.firstIndex(of: "orders")!)
        #expect(order.firstIndex(of: "orders")! < order.firstIndex(of: "order_items")!)
        #expect(order.firstIndex(of: "products")! < order.firstIndex(of: "order_items")!)
        #expect(order.count == 5)
    }
}
