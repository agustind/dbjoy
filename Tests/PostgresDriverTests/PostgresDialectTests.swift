import DBCore
import PostgresDriver
import Testing

struct PostgresDialectTests {
    let d = PostgresDialect()
    let table = ObjectRef(schema: "public", name: "users", kind: .table)

    @Test func selectWithFiltersSortAndPaging() {
        let request = RowRequest(
            filters: [RowFilter(column: "name", op: .contains, value: "a_b%"),
                      RowFilter(column: "age", op: .greaterOrEqual, value: "18"),
                      RowFilter(column: "x", op: .isNull, isEnabled: false)],
            sort: [SortKey(column: "id", ascending: false)], limit: 100, offset: 200)
        #expect(d.selectStatement(for: table, request: request) ==
                #"SELECT * FROM "public"."users" WHERE "name"::text ILIKE '%a\_b\%%' AND "age" >= '18' ORDER BY "id" DESC LIMIT 100 OFFSET 200"#)
        #expect(d.countStatement(for: table, request: request) ==
                #"SELECT count(*) FROM "public"."users" WHERE "name"::text ILIKE '%a\_b\%%' AND "age" >= '18'"#)
    }

    @Test func anyColumnFilter() {
        let f = RowFilter(column: nil, op: .contains, value: "x")
        #expect(d.filterExpression(f, columns: ["a", "b"]) == #"("a"::text ILIKE '%x%' OR "b"::text ILIKE '%x%')"#)
        let eq = RowFilter(column: nil, op: .equals, value: "1")
        #expect(d.filterExpression(eq, columns: ["a"]) == #"("a"::text = '1')"#)
        #expect(d.filterExpression(RowFilter(column: "a", op: .inList, value: "1, 2"), columns: []) == #""a" IN ('1', '2')"#)
    }

    @Test func alterTable() {
        let id = ColumnDefinition(name: "id", dataType: "integer", isNullable: false, originalName: "id")
        let name = ColumnDefinition(name: "name", dataType: "text", originalName: "name")
        let legacy = ColumnDefinition(name: "legacy", dataType: "text", originalName: "legacy")
        var renamed = name
        renamed.name = "full_name"
        renamed.dataType = "varchar(200)"
        renamed.isNullable = false
        renamed.defaultValue = "''"
        renamed.comment = "Display name"
        let added = ColumnDefinition(name: "age", dataType: "int", isNullable: false, defaultValue: "0")
        let change = TableSchemaChange(
            table: table, original: [id, name, legacy], columns: [id, renamed, added],
            newIndexes: [IndexDefinition(name: "users_age_idx", columns: ["age"])],
            droppedIndexes: ["old_idx"],
            newForeignKeys: [ForeignKeyDefinition(name: "fk_org", columns: ["org_id"],
                                                  referencedTable: ObjectRef(schema: "public", name: "orgs", kind: .table),
                                                  referencedColumns: ["id"], onDelete: "CASCADE")],
            droppedConstraints: ["users_legacy_key"])
        #expect(d.statements(for: change) == [
            #"ALTER TABLE "public"."users" DROP CONSTRAINT "users_legacy_key";"#,
            #"DROP INDEX "public"."old_idx";"#,
            #"ALTER TABLE "public"."users" DROP COLUMN "legacy";"#,
            #"ALTER TABLE "public"."users" RENAME COLUMN "name" TO "full_name";"#,
            #"ALTER TABLE "public"."users" ALTER COLUMN "full_name" TYPE varchar(200) USING "full_name"::varchar(200);"#,
            #"ALTER TABLE "public"."users" ALTER COLUMN "full_name" SET NOT NULL;"#,
            #"ALTER TABLE "public"."users" ALTER COLUMN "full_name" SET DEFAULT '';"#,
            #"COMMENT ON COLUMN "public"."users"."full_name" IS 'Display name';"#,
            #"ALTER TABLE "public"."users" ADD COLUMN "age" int DEFAULT 0 NOT NULL;"#,
            #"CREATE INDEX "users_age_idx" ON "public"."users" USING btree ("age");"#,
            #"ALTER TABLE "public"."users" ADD CONSTRAINT "fk_org" FOREIGN KEY ("org_id") REFERENCES "public"."orgs" ("id") ON UPDATE NO ACTION ON DELETE CASCADE;"#,
        ])
    }

    @Test func createTable() {
        let request = CreateTableRequest(schema: "public", name: "t", columns: [
            ColumnDefinition(name: "id", dataType: "bigserial", isNullable: false, isPrimaryKey: true),
            ColumnDefinition(name: "label", dataType: "text", comment: "Label"),
            ColumnDefinition(name: " ", dataType: "text"),
        ])
        #expect(d.statements(for: request) == [
            "CREATE TABLE \"public\".\"t\" (\n  \"id\" bigserial NOT NULL,\n  \"label\" text,\n  PRIMARY KEY (\"id\")\n);",
            #"COMMENT ON COLUMN "public"."t"."label" IS 'Label';"#,
        ])
    }
}

struct CheckConstraintParsingTests {
    @Test func parsesInLists() {
        #expect(PostgresConnection.checkConstraintValues(
            "CHECK (c_check_list = ANY (ARRAY['draft'::text, 'published'::text, 'it''s'::text]))") == ["draft", "published", "it's"])
        #expect(PostgresConnection.checkConstraintValues("CHECK (n = ANY (ARRAY[1, 2, 3]))") == ["1", "2", "3"])
    }

    @Test func rejectsOtherChecks() {
        #expect(PostgresConnection.checkConstraintValues("CHECK (price >= 0::numeric)") == nil)
        #expect(PostgresConnection.checkConstraintValues("CHECK (a > 0 AND b = ANY (ARRAY[1, 2]))") == nil)
    }
}
