import DBCore
import PostgresDriver
import Testing

struct SchemaDiffTests {
    let dialect = PostgresDialect()

    func table(_ name: String, columns: [ColumnInfo], indexes: [IndexInfo] = [], constraints: [ConstraintInfo] = []) -> TableStructure {
        TableStructure(ref: ObjectRef(schema: "public", name: name, kind: .table), columns: columns, indexes: indexes,
                       constraints: constraints)
    }

    @Test func migrationOrdersByPhaseAndRunsSharedStatementsOnce() {
        let a = SchemaChange(id: "a", kind: .added, objectType: "View", object: "v", summary: "",
                             steps: [MigrationStep(.createView, "CREATE VIEW v2", rank: 2), MigrationStep(.dropView, "DROP VIEW v")])
        let b = SchemaChange(id: "b", kind: .changed, objectType: "Column", object: "t.c", summary: "",
                             steps: [MigrationStep(.alterColumn, "ALTER c"), MigrationStep(.createView, "CREATE VIEW v1", rank: 1),
                                     MigrationStep(.dropView, "DROP VIEW v")])
        #expect(SchemaChange.migration([a, b]) == ["DROP VIEW v", "ALTER c", "CREATE VIEW v1", "CREATE VIEW v2"])
    }

    @Test func identicalSchemasHaveNoChanges() {
        let users = table("users", columns: [ColumnInfo(name: "id", dataType: "integer", isNullable: false)])
        let snapshot = SchemaSnapshot(schema: "public", tables: [users], enums: [EnumSnapshot(name: "mood", labels: ["ok"])])
        #expect(dialect.schemaChanges(from: snapshot, to: snapshot).isEmpty)
    }

    @Test func enumValuesAreAddedInPlace() {
        let source = SchemaSnapshot(schema: "public", enums: [EnumSnapshot(name: "size", labels: ["xs", "s", "m", "l"])])
        let target = SchemaSnapshot(schema: "public", enums: [EnumSnapshot(name: "size", labels: ["s", "l"])])
        let change = dialect.schemaChanges(from: source, to: target).first
        #expect(change?.steps.map(\.sql) == [
            #"ALTER TYPE "public"."size" ADD VALUE 'xs' BEFORE 's';"#,
            #"ALTER TYPE "public"."size" ADD VALUE 'm' AFTER 's';"#,
        ])
    }

    @Test func renamedIndexesAndConstraintsMatch() {
        let source = table("users", columns: [ColumnInfo(name: "email", dataType: "text")],
                           indexes: [IndexInfo(name: "users_email_idx", columns: ["email"], isUnique: false, isPrimary: false,
                                               method: "btree", definition: "CREATE INDEX users_email_idx ON public.users USING btree (email)")],
                           constraints: [ConstraintInfo(name: "email_present", type: .check, definition: "CHECK (email <> '')")])
        let target = table("users", columns: [ColumnInfo(name: "email", dataType: "text")],
                           indexes: [IndexInfo(name: "idx_1", columns: ["email"], isUnique: false, isPrimary: false,
                                               method: "btree", definition: "CREATE INDEX idx_1 ON public.users USING btree (email)")],
                           constraints: [ConstraintInfo(name: "users_check", type: .check, definition: "CHECK (email <> '')")])
        #expect(dialect.schemaChanges(from: SchemaSnapshot(schema: "public", tables: [source]),
                                      to: SchemaSnapshot(schema: "public", tables: [target])).isEmpty)
    }

    @Test func droppingDataIsMarkedDestructive() {
        let source = table("users", columns: [ColumnInfo(name: "id", dataType: "integer")])
        let target = table("users", columns: [ColumnInfo(name: "id", dataType: "integer"), ColumnInfo(name: "legacy", dataType: "text")])
        let old = table("old", columns: [ColumnInfo(name: "id", dataType: "integer")])
        let changes = dialect.schemaChanges(from: SchemaSnapshot(schema: "public", tables: [source]),
                                            to: SchemaSnapshot(schema: "public", tables: [target, old]))
        #expect(changes.map(\.id) == ["table:users/column:legacy", "table:old"])
        #expect(changes.filter(\.isDestructive).count == 2)
    }

    @Test func missingSchemaIsCreatedFirst() {
        let source = SchemaSnapshot(schema: "sales", tables: [table("orders", columns: [ColumnInfo(name: "id", dataType: "integer")])])
        let target = SchemaSnapshot(schema: "sales", exists: false)
        let statements = SchemaChange.migration(dialect.schemaChanges(from: source, to: target))
        #expect(statements.first == #"CREATE SCHEMA "sales";"#)
        #expect(statements.count == 2)
    }
}
