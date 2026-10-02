import DBCore
import Testing

struct SQLSplitterTests {
    @Test func splitsOnTopLevelSemicolons() {
        let sql = "SELECT 1; SELECT ';' AS a; -- comment; here\nSELECT \"x;y\" FROM t"
        #expect(SQLSplitter.split(sql).map(\.text) == ["SELECT 1", "SELECT ';' AS a", "SELECT \"x;y\" FROM t"])
    }

    @Test func handlesDollarQuotesAndComments() {
        let sql = """
        CREATE FUNCTION f() RETURNS int AS $body$ SELECT 1; $body$ LANGUAGE sql;
        /* block; /* nested; */ still */ SELECT $$a;b$$;
        """
        let statements = SQLSplitter.split(sql)
        #expect(statements.count == 2)
        #expect(statements[0].text.hasSuffix("LANGUAGE sql"))
        #expect(statements[1].text == "SELECT $$a;b$$")
    }

    @Test func handlesEscapeStringsAndBeginAtomic() {
        let sql = """
        SELECT E'it\\'s; fine';
        CREATE FUNCTION g() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT CASE WHEN true THEN 1 END; SELECT 2; END;
        SELECT 3
        """
        #expect(SQLSplitter.split(sql).count == 3)
    }

    @Test func dropsCommentOnlyFragments() {
        #expect(SQLSplitter.split("-- nothing\n;  ; /* x */").isEmpty)
    }

    @Test func findsStatementAtCursor() {
        let sql = "SELECT 1;\n\nSELECT 2;\nSELECT 3"
        let offset = (sql as NSString).range(of: "2").location
        #expect(SQLSplitter.statement(at: offset, in: sql)?.text == "SELECT 2")
        #expect(SQLSplitter.statement(at: 9, in: sql)?.text == "SELECT 1")
        #expect(SQLSplitter.statement(at: 0, in: sql)?.text == "SELECT 1")
    }

    @Test func rangesAreUTF16() {
        let sql = "SELECT 'héllo 🎉'; SELECT 2"
        let statements = SQLSplitter.split(sql)
        let ns = sql as NSString
        #expect(ns.substring(with: NSRange(location: statements[1].range.lowerBound, length: statements[1].range.count)) == "SELECT 2")
    }

    @Test func lexesTokens() {
        let kinds = SQLLexer.tokens(in: "select \"Col\", 1.5e3, $1, x::int -- c").map(\.kind)
        #expect(kinds == [.keyword, .quotedIdentifier, .punctuation, .number, .punctuation, .parameter, .punctuation,
                          .identifier, .op, .identifier, .comment])
    }
}

import Foundation
