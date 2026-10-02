import DBCore
import Testing

struct CellValueInputTests {
    @Test func functionsBecomeExpressionsOutsideTextColumns() {
        #expect(CellValue.parseInput("NOW()", category: .temporal) == .expression("NOW()"))
        #expect(CellValue.parseInput(" now() ", category: .temporal) == .expression("now()"))
        #expect(CellValue.parseInput("current_date", category: .temporal) == .expression("current_date"))
        #expect(CellValue.parseInput("gen_random_uuid()", category: .other) == .expression("gen_random_uuid()"))
        #expect(CellValue.parseInput("pg_catalog.random()", category: .number) == .expression("pg_catalog.random()"))
        #expect(CellValue.parseInput("NULL", category: .number) == .null)
        #expect(CellValue.parseInput("default", category: .temporal) == .defaultValue)
    }

    @Test func plainValuesStayLiteral() {
        #expect(CellValue.parseInput("2026-10-02", category: .temporal) == .value("2026-10-02"))
        #expect(CellValue.parseInput("now", category: .temporal) == .value("now")) // Postgres' own input keyword
        #expect(CellValue.parseInput("{1,2}", category: .other) == .value("{1,2}"))
        #expect(CellValue.parseInput("{\"a\": 1}", category: .json) == .value("{\"a\": 1}"))
        #expect(CellValue.parseInput("now() + 1", category: .temporal) == .value("now() + 1"))
    }

    @Test func textColumnsNeedAnExplicitEquals() {
        #expect(CellValue.parseInput("now()", category: .text) == .value("now()"))
        #expect(CellValue.parseInput("NULL", category: .text) == .value("NULL"))
        #expect(CellValue.parseInput("=upper('x')", category: .text) == .expression("upper('x')"))
        #expect(CellValue.parseInput("=now() + interval '1 day'", category: .temporal) == .expression("now() + interval '1 day'"))
        #expect(CellValue.parseInput("=", category: .text) == .value("="))
        #expect(CellValue.parseInput("\\=1+1", category: .text) == .value("=1+1"))
    }

    @Test func editingTextRoundTrips() {
        for value in [CellValue.value("plain"), .value("=starts with equals"), .expression("now()"), .expression("a + b")] {
            #expect(CellValue.parseInput(value.editingText, category: .text) == value)
        }
    }

    @Test func expressionsAreUnquotedInStatements() {
        let table = ObjectRef(schema: "public", name: "t", kind: .table)
        let d = GenericDialect()
        #expect(d.statement(for: .update(key: [ColumnValue("id", .value("1"))],
                                         values: [ColumnValue("at", .expression("now()"))]), in: table)
                == "UPDATE \"public\".\"t\" SET \"at\" = now() WHERE \"id\" = '1';")
        #expect(d.statement(for: .insert(values: [ColumnValue("u", .expression("gen_random_uuid()")), ColumnValue("n", .value("x"))]), in: table)
                == "INSERT INTO \"public\".\"t\" (\"u\", \"n\") VALUES (gen_random_uuid(), 'x');")
    }
}
