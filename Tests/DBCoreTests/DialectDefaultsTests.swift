import DBCore
import Testing

struct GenericDialect: SQLDialect {
    func selectStatement(for ref: ObjectRef, request: RowRequest) -> String { "" }
    func countStatement(for ref: ObjectRef, request: RowRequest) -> String { "" }
    func filterExpression(_ filter: RowFilter, columns: [String]) -> String? { nil }
    func statements(for change: TableSchemaChange) -> [String] { [] }
    func statements(for request: CreateTableRequest) -> [String] { [] }
    func dropStatement(for ref: ObjectRef, cascade: Bool) -> String { "" }
    func truncateStatement(for ref: ObjectRef, cascade: Bool) -> String { "" }
    var keywords: [String] { [] }
    var functions: [String] { [] }
    var dataTypes: [String] { [] }
}

struct DialectDefaultsTests {
    let d = GenericDialect()
    let table = ObjectRef(schema: "public", name: "my \"table\"", kind: .table)

    @Test func quoting() {
        #expect(d.quoteIdentifier("a\"b") == "\"a\"\"b\"")
        #expect(d.quoteLiteral("it's") == "'it''s'")
        #expect(d.qualifiedName(table) == "\"public\".\"my \"\"table\"\"\"")
    }

    @Test func rowChanges() {
        #expect(d.statement(for: .update(key: [ColumnValue("id", .value("7"))],
                                         values: [ColumnValue("name", .value("O'Hara")), ColumnValue("note", .null)]), in: table)
                == "UPDATE \"public\".\"my \"\"table\"\"\" SET \"name\" = 'O''Hara', \"note\" = NULL WHERE \"id\" = '7';")
        #expect(d.statement(for: .insert(values: [ColumnValue("id", .defaultValue), ColumnValue("n", .value("x"))]), in: table)
                == "INSERT INTO \"public\".\"my \"\"table\"\"\" (\"n\") VALUES ('x');")
        #expect(d.statement(for: .insert(values: [ColumnValue("id", .defaultValue)]), in: table)
                == "INSERT INTO \"public\".\"my \"\"table\"\"\" DEFAULT VALUES;")
        #expect(d.statement(for: .delete(key: [ColumnValue("a", .value("1")), ColumnValue("b", .value("2"))]), in: table)
                == "DELETE FROM \"public\".\"my \"\"table\"\"\" WHERE \"a\" = '1' AND \"b\" = '2';")
    }

    @Test func detectsWrites() {
        #expect(!d.isWriteStatement("select 1; -- delete\n explain select 2"))
        #expect(d.isWriteStatement("SELECT 1; UPDATE t SET a = 1"))
        #expect(d.isWriteStatement("with x as (delete from t returning *) select * from x"))
        #expect(d.isWriteStatement("drop table t"))
        #expect(!d.isWriteStatement("/* c */ (SELECT 1)"))
    }
}

struct DefaultExpressionTests {
    let d = GenericDialect()

    @Test func plainWordsBecomeLiterals() {
        #expect(d.defaultExpression("blabla") == "'blabla'")
        #expect(d.defaultExpression("hello world") == "'hello world'")
        #expect(d.defaultExpression("O'Hara") == "'O''Hara'")
        #expect(d.defaultExpression("pending ") == "'pending'")
    }

    @Test func expressionsStayAsIs() {
        for sql in ["now()", "gen_random_uuid()", "0", "-1", "3.14", "1e3", "true", "FALSE", "null", "CURRENT_TIMESTAMP",
                    "'draft'", "'draft'::text", "nextval('t_id_seq'::regclass)", "ARRAY[1,2]", "1 + 2", "now() + interval '1 day'"] {
            #expect(d.defaultExpression(sql) == sql)
        }
    }
}
