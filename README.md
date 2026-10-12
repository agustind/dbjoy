<div align="center">
<pre>
██████╗ ██████╗      ██╗ ██████╗ ██╗   ██╗
██╔══██╗██╔══██╗     ██║██╔═══██╗╚██╗ ██╔╝
██║  ██║██████╔╝     ██║██║   ██║ ╚████╔╝ 
██║  ██║██╔══██╗██   ██║██║   ██║  ╚██╔╝  
██████╔╝██████╔╝╚█████╔╝╚██████╔╝   ██║   
╚═════╝ ╚═════╝  ╚════╝  ╚═════╝    ╚═╝   
</pre>
</div>

The AI-first PostgreSQL client for the Mac. Ask questions about your data in plain language and get answers backed
by real queries, or have the SQL written for you, with your own Anthropic or OpenAI key. Then browse schemas, edit
data safely, write SQL and export, all in a fast, keyboard-friendly SwiftUI app. More database engines can be added
as drivers.

<p align="center">
  <img src="demo.gif" alt="DBJoy tour: color-coded connections, browsing the products table, the AI assistant answering which countries bring in the most revenue, the assistant writing a top-customers query that runs in a tab, the ER diagram, comparing the staging and production schemas with the generated migration SQL, and Claude Code's queries in Settings → MCP" width="880">
</p>

## Install

Download the latest `DBJoy-<version>.dmg` from [Releases](https://github.com/agustind/dbjoy/releases), open it, and
drag **DBJoy** to Applications. Builds are signed with a Developer ID and notarized by Apple.

- macOS 15 or later, Apple Silicon
- Self-contained: libpq, pg_dump (for backups) and psql (for copying databases) ship inside the app

## Features

### AI assistant
- Ask about your data in plain language (⌘J): the assistant looks up table structures, runs queries and answers
  with the results, shown inline in the chat
- Ask it to write SQL and it opens the query in a new tab for you to review, run or save
- Chats are saved automatically per connection; reopen one to pick up where you left off, and organize them in
  folders (drag a chat onto a folder, or use its context menu to rename, move or delete it)
- Bring your own Anthropic or OpenAI API key (Settings → AI Assistant); keys are stored in the macOS Keychain, and the
  model is configurable
- Read-only by default: its queries run in read-only transactions. Turn on **Allow the assistant to change data** to
  let it run INSERT/UPDATE/DELETE and schema changes, each in one transaction, with an approval step before each change
  (always on production connections; never on read-only connections)

### Claude Code and other MCP clients
- Ask Claude Code about your data from any project: DBJoy shares the connections you choose over MCP, so Claude Code
  can look up tables and run read-only queries with DBJoy's saved passwords and SSH tunnels.
  See [Use DBJoy from Claude Code](#use-dbjoy-from-claude-code)

### Connections
- Saved connections grouped into folders and tagged by environment: local, development, testing, staging, production
- Paste a connection string (`postgres://user:pass@host:5432/db?sslmode=require` or `host=… dbname=…`) to fill in a
  new connection; DBJoy also offers one it finds on the clipboard
- Passwords stored in the macOS Keychain; SSL modes supported
- SSH tunnels: reach databases whose port is blocked from your network through an SSH server (agent, private key or
  password auth). Set it up in the connection form, or straight from the "Couldn't connect" screen
- Read-only connections, enforced by the server
- Each connection opens in its own window, and several can be open at once
- Give each connection an icon from a built-in pack (or keep its initials), shown on its environment's pastel color
- Star connections to pin them to a collapsible bar on the left of every window; one click switches that window to
  the connection (or opens a new window, per Settings; ⌘-click does the opposite)

### Browsing
- Database and schema switcher; tables, views, materialized views, foreign tables, functions and procedures
- Fuzzy sidebar search, and ⌘P to open any object across all schemas
- Relations view per table (outgoing and incoming foreign keys, dependent views) and a schema-wide ER diagram

### Data
- Paged grid with column sorting, a row details panel for long values, and copy as TSV or INSERT
- Batch editing: select several rows and open **Row details** to change a field on all of them at once
- ⌘F search by field and operator (contains, equals, ranges, IN, IS NULL, raw SQL…) with editable results
- Jump from a foreign-key value to the row it references

### Safe editing
- Edits are staged and color-coded: modified, inserted, deleted
- ⌘S commits everything in one transaction; each statement must affect exactly one row or the whole batch rolls back
- Dropdown editors for booleans, enum types and `CHECK (col IN (...))` lists; generated columns are read-only
- SQL functions as values: type `NOW()`, `CURRENT_DATE` or `gen_random_uuid()` in date, number or UUID cells, or start
  any cell with `=` for an expression (`=now() + interval '1 day'`, `=upper('x')`); the server computes the value on
  commit. Type `\=` to store text that starts with `=`
- Tables without a primary key are read-only
- On production connections, every write shows its SQL for review and asks for confirmation; drop and truncate always confirm

### Structure
- Edit columns (name, type, nullability, default, comment), indexes, constraints and foreign keys
- Create tables
- Changes run as reviewed `ALTER` statements in one transaction

### SQL editor
- Syntax highlighting, line numbers, and completion that understands table aliases
- ⌘↩ runs the statement under the cursor or the selection, ⇧⌘↩ runs everything, ⌘. cancels
- Multiple result sets, server notices, and error positions that move the cursor
- Each query tab has its own connection with Begin / Commit / Rollback and a live transaction indicator
- Saved queries (per connection or shared) and per-connection history
- Open `.sql` files (⌘O, or drag them onto a query tab) and optionally run them right away; Run SQL File… (⇧⌘O)
  opens and runs in one step. psql-only commands such as `\connect` or `\copy` are flagged before anything runs

### Schema compare and migrations
- Compare a schema between two databases, e.g. development against production (Database → Compare Schemas…, ⇧⌘D):
  tables, columns, keys, indexes, check constraints, views, materialized views, functions, procedures, triggers,
  enums, domains, sequences and extensions
- Each difference shows both definitions side by side and the SQL that migrates it. DBJoy writes the whole migration in
  an order that runs: types before the tables that use them, drops before creates, foreign keys after the tables
  they reference, and views dropped and recreated around the column changes that need it
- Pick which changes to include. Changes that delete data (dropping a table or column) start unchecked and are marked
  in red; changes that can fail on existing rows (adding NOT NULL, a unique index, a type change) are flagged
- Copy the script, save it as a `.sql` file, open it in a query tab on the target, or run it there in one
  transaction (nothing changes if a statement fails), with a confirmation that names the environment
- Not compared: partitions, grants, policies, and indexes on materialized views

### Copy a database
- Replace everything in one database with an exact copy of another, e.g. production into a local database
  (Database → Copy Database…): every schema, table, view, materialized view, function, procedure, type, sequence,
  trigger and extension, with or without the data
- Pick which tables come with their rows. The list shows each table's estimated row count and size, biggest first;
  unchecked tables are copied empty, and foreign keys into them are added without checking the copied rows
- DBJoy drops every schema in the target first. The whole copy runs in one transaction, so if anything fails or you
  cancel, the target stays as it was
- You confirm by typing the target database's name
- Owners and grants aren't copied by default, so the copy works between servers with different roles. Turn on
  Copy owners and privileges to keep them
- Works across connections and servers, including through SSH tunnels, with the bundled pg_dump and psql
- Works on managed services such as Supabase without changing roles: schemas that belong to the platform (auth,
  storage, …) stay as they are, and `public` is emptied in place when it holds the platform's extensions. Foreign keys
  into platform tables are added without checking the copied rows. Turn on Copy rows in platform schemas to also copy
  rows such as `auth.users`

### Export
- CSV or JSON (one file per table), or SQL `INSERT`s (one file, ordered by foreign keys, sequences reset)
- Full restorable backup via `pg_dump` (bundled with the app)
- Rows stream from a single consistent snapshot, so large tables don't load into memory

### Appearance
- Light and dark themes; follows the system by default, or pick one in **View → Appearance** or Settings (⌘,)

## Use DBJoy from Claude Code

When you work on a project with [Claude Code](https://claude.com/claude-code), it can query that project's database
through DBJoy. Ask "how many schools do we have?" from the terminal, and Claude Code finds the connection in DBJoy,
checks the tables and runs the query itself. You don't copy credentials into the project: DBJoy connects with the
password in your Keychain and any SSH tunnel you set up, and the shared connections are read-only.

### Set it up
1. In DBJoy, open **Settings → MCP** and turn on **Let MCP clients read your databases**.
2. Under **Shared connections**, turn on the connections Claude Code may use (or use **Share with MCP clients** in a
   connection's Safety section). Every connection starts unshared, and clients never see the others.
3. Click **Copy Command** and run it once in Terminal. It registers DBJoy for all your projects:
   ```sh
   claude mcp add --transport http --scope user dbjoy http://127.0.0.1:47821/mcp \
     --header "Authorization: Bearer <token>"
   ```
4. In each project's `CLAUDE.md`, say which connection it uses:
   ```markdown
   The database is the DBJoy connection "Andromeda (dev)".
   ```

Then ask away in that project: "how many schools signed up this month?", "which tables reference students?".
Run `/mcp` in Claude Code to check that DBJoy is connected.

### What Claude Code can do
| Tool | What it does |
|---|---|
| `list_connections` | Lists the shared connections with their environment and database |
| `list_tables` | Lists a schema's tables, views and routines, and the other schemas |
| `describe_table` | Shows columns, keys, indexes, constraints and foreign keys |
| `run_query` | Runs SELECT, WITH, EXPLAIN, SHOW or VALUES and returns the first 100 rows |

### Safety
- **Read-only.** Statements other than reads are refused, and every query runs in a read-only transaction, which
  also stops writes hidden in CTEs or functions. Queries time out after 30 seconds.
- **Local only.** The server listens on 127.0.0.1, so nothing else on your network can reach it. Each request needs
  the token, and requests from web pages on other sites are rejected.
- **You see what ran.** **Settings → MCP → Recent activity** lists each request: client, connection and SQL.
- **Revocable.** Turn off a connection to hide it, or click **Reset Token…** to disconnect every client.

### Good to know
- DBJoy has to be open. It doesn't need a window open for that connection.
- A connection must save its password in DBJoy, because DBJoy can't ask for one on a client's behalf.
- If port 47821 is taken, change it in Settings → MCP and copy the command again.
- Other MCP clients (such as Cursor) work the same way. Point them at `http://127.0.0.1:47821/mcp` (Streamable HTTP)
  with the header `Authorization: Bearer <token>`; **Copy Token** copies the token.

## Keyboard shortcuts

| Action | Keys |
| --- | --- |
| New query tab | ⌘T |
| Close tab | ⌘W |
| Open anything | ⌘P |
| Run statement / selection | ⌘↩ |
| Run all | ⇧⌘↩ |
| Cancel query | ⌘. |
| Commit changes / save query | ⌘S |
| Refresh | ⌘R |
| Search rows / find in editor | ⌘F |
| ER diagram | ⇧⌘E |
| Compare schemas | ⇧⌘D |
| Export tables | ⌥⌘E |
| Open SQL file / run SQL file | ⌘O / ⇧⌘O |
| AI assistant | ⌘J |
| Next / previous tab | ⇧⌘] / ⇧⌘[ |
| Completion | typing, Esc or ⌃Space |
| Edit cell | double-click or Return; Tab moves to the next cell |
| Delete rows | ⌫ |
| Settings | ⌘, |

## Development

### Requirements

- macOS 15+, Xcode 16+ (Swift 6)
- libpq: `brew install libpq` (keg-only; the package links `/opt/homebrew/opt/libpq`, override with `LIBPQ_PREFIX`)

### Build and run

```sh
swift run DBJoy                  # run from the command line
scripts/build-app.sh             # build build/DBJoy.app (release)
open build/DBJoy.app
```

Or open `Package.swift` in Xcode and run the `DBJoy` scheme.

`build-app.sh` signs with the first Developer ID / Apple Development identity in your keychain (override with
`DBJOY_SIGN_IDENTITY`). A stable signature keeps the Keychain from asking for your password after every rebuild.
`DBJOY_SANDBOX=1 scripts/build-app.sh` builds the sandboxed variant the Mac App Store needs.

Set `DBJOY_DATA_DIR=<folder>` to keep connections, saved queries and history in another folder (demos,
screenshots) instead of `~/Library/Application Support/DBJoy`.

### Sample database

```sh
docker run -d --name dbjoy-pg -e POSTGRES_PASSWORD=secret -p 55432:5432 postgres:17
psql "postgres://postgres:secret@localhost:55432/postgres" -f scripts/sample-db.sql
```

Then add a connection to `localhost:55432`, user `postgres`, password `secret`, database `dbjoy_sample`.
The sample includes `type_showcase`, a table with one column per common Postgres type (enum, CHECK list, domain,
arrays, ranges, JSON, network types, a generated column…) for testing editors. Reload just that table with
`scripts/type-showcase.sql`.

### Tests

```sh
swift test                       # unit tests (lexer, splitter, completion, SQL generation)
DBJOY_TEST_PG=1 swift test       # + integration and export tests against the sample database

scripts/ssh-test-server.sh       # throwaway sshd on 127.0.0.1:52222 next to the sample database
DBJOY_TEST_SSH=1 DBJOY_TEST_SSH_KEY=/tmp/dbjoy_test_key swift test --filter SSHTunnelTests
docker rm -f dbjoy-ssh
```

### Architecture

```
Sources/
  CLibPQ/          system module for libpq
  DBCore/          engine-agnostic: models, DatabaseDriver/DatabaseConnection protocols,
                   SQLDialect (edit + DDL generation), SQL lexer/splitter, completion, export encoders
  PostgresDriver/  libpq wrapper (serial queue per connection, single-row streaming,
                   cancellation, notices) + Postgres introspection and dialect
  DBJoy/           SwiftUI app; AppKit for the data grid (NSTableView) and SQL editor (NSTextView)
    MCP/           local MCP server (Streamable HTTP on 127.0.0.1) for Claude Code and other clients
    Compare/       schema compare window (the diff and migration SQL live in PostgresDriver)
```

To add an engine, implement `DatabaseDriver`, `DatabaseConnection` and `SQLDialect` in a new target, add a
`DatabaseKind` case, and register it in `Sources/DBJoy/Services/Drivers.swift`.

## License

MIT. See [LICENSE](LICENSE).
