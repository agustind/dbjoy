import DBCore
import Testing

struct SQLFormatterTests {
    @Test func selectWithJoinsAndConditions() {
        let sql = "select c.id, count(o.id) as orders from customers c left join orders o on o.customer_id = c.id and o.status = 'paid' "
            + "where c.active and c.created_at between now() - interval '7 days' and now() group by c.id having count(*) > 2 order by orders desc limit 10"
        #expect(SQLFormatter.format(sql) == """
            SELECT
                c.id,
                count(o.id) AS orders
            FROM customers c
            LEFT JOIN orders o ON o.customer_id = c.id
                AND o.status = 'paid'
            WHERE c.active
                AND c.created_at BETWEEN now() - interval '7 days' AND now()
            GROUP BY c.id
            HAVING count(*) > 2
            ORDER BY orders DESC
            LIMIT 10
            """)
    }

    @Test func ctesAndSubqueries() {
        #expect(SQLFormatter.format("with a as (select * from t), b as (select x, y from a) select * from b where x in (select id from c)") == """
            WITH a AS (
                SELECT *
                FROM t
            ),
            b AS (
                SELECT
                    x,
                    y
                FROM a
            )
            SELECT *
            FROM b
            WHERE x IN (
                SELECT id
                FROM c
            )
            """)
    }

    @Test func writes() {
        #expect(SQLFormatter.format("insert into t (a, b) values (1, 'x'), (2, -3) on conflict (a) do update set b = excluded.b returning *") == """
            INSERT INTO t (a, b)
            VALUES
                (1, 'x'),
                (2, -3)
            ON CONFLICT (a) DO UPDATE
            SET b = excluded.b
            RETURNING *
            """)
        #expect(SQLFormatter.format("update p set price = price * 1.1, at = now() where id = any($1::int[])") == """
            UPDATE p
            SET
                price = price * 1.1,
                at = now()
            WHERE id = ANY($1::int[])
            """)
    }

    @Test func keepsNamesStringsAndInlineParentheses() {
        #expect(SQLFormatter.format("select t.type, 'and Or' from t where t.key is null or x = 'select'") == """
            SELECT
                t.type,
                'and Or'
            FROM t
            WHERE t.key IS NULL
                OR x = 'select'
            """)
        #expect(SQLFormatter.format("select case when x > 0 then 1 end, row_number() over (partition by g order by x) from t") == """
            SELECT
                CASE WHEN x > 0 THEN 1 END,
                row_number() OVER (PARTITION BY g ORDER BY x)
            FROM t
            """)
    }

    @Test func separatesStatementsAndSkipsDDL() {
        #expect(SQLFormatter.format("select 1; select 2") == "SELECT 1;\n\nSELECT 2")
        #expect(SQLFormatter.format("create table x (id int)") == nil)
        #expect(SQLFormatter.format("SELECT 1") == nil)
    }
}
