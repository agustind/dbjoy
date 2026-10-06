@testable import DBJoy
import Testing

@MainActor
struct SQLFileTests {
    @Test func detectsPsqlMetaCommands() {
        let dump = """
            -- Dumped by pg_dump
            SET statement_timeout = 0;
            \\connect app
            CREATE TABLE t (id int);
            COPY t (id) FROM stdin;
            1
            \\.
            """
        let found = QueryTabModel.psqlMetaCommand(in: dump)
        #expect(found?.line == 3)
        #expect(found?.command == "\\connect")
        #expect(QueryTabModel.psqlMetaCommand(in: "  \\set ON_ERROR_STOP on\nSELECT 1;")?.line == 1)
    }

    @Test func plainScriptsPass() {
        let script = """
            CREATE TABLE notes (body text);
            INSERT INTO notes VALUES ('path\\to\\file'), (E'tab\\there');
            SELECT * FROM notes;
            """
        #expect(QueryTabModel.psqlMetaCommand(in: script) == nil)
    }
}
