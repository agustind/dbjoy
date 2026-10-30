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

struct MarkdownForAITests {
    let result = QueryResult(columns: [ResultColumn(name: "id", typeName: "int4", category: .number),
                                       ResultColumn(name: "note", typeName: "text", category: .text)],
                             rows: [["1", "a|b"], ["2", nil], ["3", "two\nlines"]],
                             statement: "SELECT id, note FROM t;\n")

    @Test func allRows() {
        #expect(ExportEncoding.markdownForAI(result, databaseKind: .postgres, database: "shop") == """
            PostgreSQL query on database `shop`:

            ```sql
            SELECT id, note FROM t;
            ```

            Result: 3 rows.

            Columns: id (int4), note (text)

            | id | note |
            | --- | --- |
            | 1 | a\\|b |
            | 2 | NULL |
            | 3 | two<br>lines |

            """)
    }

    @Test func selectionAndLimits() {
        let text = ExportEncoding.markdownForAI(result, rowIndices: [2, 0], databaseKind: .postgres, database: "shop",
                                                rowLimit: 1, cellLimit: 3)
        #expect(text.contains("Result: 2 rows selected out of 3. Showing the first 1.\n"))
        #expect(text.contains("| 3 | two… (9 characters) |\n"))
        #expect(!text.contains("| 1 |"))
    }
}

struct ResultSortingTests {
    let result = QueryResult(columns: [ResultColumn(name: "n", typeName: "int4", category: .number),
                                       ResultColumn(name: "s", typeName: "text", category: .text)],
                             rows: [["10", "file10"], [nil, "b"], ["9", "file9"], ["10", nil], ["-1", "A"]])

    @Test func numbersNumericallyAndNullsLast() {
        #expect(result.rowOrder(sortedBy: 0, ascending: true) == [4, 2, 0, 3, 1])
        #expect(result.rowOrder(sortedBy: 0, ascending: false) == [0, 3, 2, 4, 1])
    }

    @Test func textInFinderOrder() {
        #expect(result.rowOrder(sortedBy: 1, ascending: true) == [4, 1, 2, 0, 3])
    }
}

struct TableMarkdownForAITests {
    @Test func structureAndRows() {
        let ref = ObjectRef(schema: "public", name: "orders", kind: .table)
        let structure = TableStructure(
            ref: ref,
            columns: [ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true, isIdentity: true),
                      ColumnInfo(name: "customer_id", dataType: "integer"),
                      ColumnInfo(name: "status", dataType: "text", isNullable: false, defaultValue: "'new'::text",
                                 allowedValues: ["new", "paid"])],
            indexes: [IndexInfo(name: "orders_status_idx", columns: ["status"], isUnique: false, isPrimary: false, method: "btree",
                                definition: "CREATE INDEX orders_status_idx ON public.orders USING btree (status)")],
            constraints: [ConstraintInfo(name: "orders_pkey", type: .primaryKey, definition: "PRIMARY KEY (id)")])
        let fk = ForeignKeyInfo(name: "orders_customer_fk", table: ref, columns: ["customer_id"],
                                referencedTable: ObjectRef(schema: "public", name: "customers", kind: .table), referencedColumns: ["id"])
        let columns = structure.columns.map { ResultColumn(name: $0.name, typeName: $0.dataType, category: .text) }
        let text = ExportEncoding.markdownForAI(table: structure, foreignKeys: [fk], columns: columns, rows: [["1", "7", "paid"]],
                                                selected: true, totalRows: RowCount(value: 1200, isEstimate: true),
                                                query: "SELECT * FROM orders", databaseKind: .postgres, database: "shop")
        #expect(text == """
            PostgreSQL table `public.orders` in database `shop`.

            Columns:
            - id: integer, primary key, not null, identity
            - customer_id: integer, nullable, references public.customers(id)
            - status: text, not null, default 'new'::text, one of new, paid

            Indexes:
            - CREATE INDEX orders_status_idx ON public.orders USING btree (status)

            Rows: 1 row selected out of about 1200 in the table.

            | id | customer_id | status |
            | --- | --- | --- |
            | 1 | 7 | paid |

            """)
    }
}
