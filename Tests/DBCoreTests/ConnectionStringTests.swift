import DBCore
import Testing

struct ConnectionStringTests {
    @Test func fullURL() throws {
        let parsed = try ConnectionString.parse("postgresql://app%40corp:p%40ss:w0rd@db.example.com:6543/my%20db?sslmode=require&application_name=dbjoy&connect_timeout=5")
        #expect(parsed.user == "app@corp")
        #expect(parsed.password == "p@ss:w0rd")
        #expect(parsed.host == "db.example.com")
        #expect(parsed.port == 6543)
        #expect(parsed.database == "my db")
        #expect(parsed.sslMode == .require)
        #expect(parsed.options == ["application_name": "dbjoy", "connect_timeout": "5"])
        #expect(parsed.ignored.isEmpty)
    }

    @Test func providerStyleURLs() throws {
        let neon = try ConnectionString.parse("  postgres://neondb_owner:npg_secret@ep-cool-1234.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require\n")
        #expect(neon.host == "ep-cool-1234.us-east-2.aws.neon.tech")
        #expect(neon.port == nil)
        #expect(neon.options["channel_binding"] == "require")

        let prisma = try ConnectionString.parse("postgresql://u:p@pooler.supabase.com:6543/postgres?pgbouncer=true&schema=public")
        #expect(prisma.ignored == ["pgbouncer", "schema"])

        let jdbc = try ConnectionString.parse("jdbc:postgresql://localhost:5432/app?user=me&password=secret&ssl=true")
        #expect(jdbc.user == "me")
        #expect(jdbc.password == "secret")
        #expect(jdbc.sslMode == .require)
    }

    @Test func minimalAndUnusualHosts() throws {
        let bare = try ConnectionString.parse("postgres://")
        #expect(bare.host == nil && bare.database == nil)

        let ipv6 = try ConnectionString.parse("postgres://[::1]:5433/app")
        #expect(ipv6.host == "::1")
        #expect(ipv6.port == 5433)

        let socket = try ConnectionString.parse("postgresql://%2Fvar%2Frun%2Fpostgresql/app")
        #expect(socket.host == "/var/run/postgresql")

        let multi = try ConnectionString.parse("postgresql://a.example:5432,b.example:5432/app?target_session_attrs=read-write")
        #expect(multi.host == "a.example")
        #expect(multi.ignored.count == 1)
    }

    @Test func keywordValue() throws {
        let parsed = try ConnectionString.parse("host=localhost port=55432 dbname=dbjoy_sample user = postgres password='it\\'s secret' sslmode=disable")
        #expect(parsed.host == "localhost")
        #expect(parsed.port == 55432)
        #expect(parsed.database == "dbjoy_sample")
        #expect(parsed.user == "postgres")
        #expect(parsed.password == "it's secret")
        #expect(parsed.sslMode == .disable)
    }

    @Test func errors() {
        #expect(throws: ConnectionString.ParseError.self) { try ConnectionString.parse("") }
        #expect(throws: ConnectionString.ParseError.self) { try ConnectionString.parse("mysql://root@localhost/db") }
        #expect(throws: ConnectionString.ParseError.self) { try ConnectionString.parse("postgres://h:99999/db") }
        #expect(throws: ConnectionString.ParseError.self) { try ConnectionString.parse("postgres://h/db?sslmode=sometimes") }
        #expect(throws: ConnectionString.ParseError.self) { try ConnectionString.parse("just some text") }
        #expect(throws: ConnectionString.ParseError.self) { try ConnectionString.parse("password='unterminated") }
    }

    @Test func detection() {
        #expect(ConnectionString.looksLikeConnectionString("postgres://x"))
        #expect(ConnectionString.looksLikeConnectionString(" postgresql://u@h/db "))
        #expect(ConnectionString.looksLikeConnectionString("host=db dbname=app"))
        #expect(!ConnectionString.looksLikeConnectionString("SELECT * FROM users"))
        #expect(!ConnectionString.looksLikeConnectionString("https://example.com"))
    }

    @Test func applyingFillsConfig() throws {
        var config = ConnectionConfig()
        let parsed = try ConnectionString.parse("postgres://me@db.example.com/app?sslmode=verify-full&sslrootcert=/tmp/ca.pem")
        parsed.apply(to: &config)
        #expect(config.host == "db.example.com")
        #expect(config.port == 5432)
        #expect(config.user == "me")
        #expect(config.database == "app")
        #expect(config.sslMode == .verifyFull)
        #expect(config.options["sslrootcert"] == "/tmp/ca.pem")
        #expect(config.name == "app on db.example.com")

        var named = ConnectionConfig(name: "Prod")
        parsed.apply(to: &named)
        #expect(named.name == "Prod")
    }
}
