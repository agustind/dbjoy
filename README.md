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
  <img src="screenshot.png" alt="DBJoy's AI assistant answering which categories brought in the most revenue, next to the products table" width="720">
</p>

## Install

Download the latest `DBJoy-<version>.dmg` from [Releases](https://github.com/agustind/dbjoy/releases), open it, and
drag **DBJoy** to Applications. Builds are signed with a Developer ID and notarized by Apple.

- macOS 15 or later, Apple Silicon
- Self-contained: libpq and pg_dump (for backups) ship inside the app

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

### Export
- CSV or JSON (one file per table), or SQL `INSERT`s (one file, ordered by foreign keys, sequences reset)
- Full restorable backup via `pg_dump` (bundled with the app)
- Rows stream from a single consistent snapshot, so large tables don't load into memory

### Appearance
- Light and dark themes; follows the system by default, or pick one in **View → Appearance** or Settings (⌘,)

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
```

To add an engine, implement `DatabaseDriver`, `DatabaseConnection` and `SQLDialect` in a new target, add a
`DatabaseKind` case, and register it in `Sources/DBJoy/Services/Drivers.swift`.

## Releasing

1. Bump `CFBundleShortVersionString` in `scripts/build-app.sh`.
2. Build, sign and notarize the DMG:

   ```sh
   scripts/make-dmg.sh              # build/DBJoy-<version>.dmg
   ```

   The app bundles libpq and its OpenSSL/Kerberos dependencies in `Contents/Frameworks`, so it runs without Homebrew.
   The DMG is notarized and stapled with the `dondo` notarytool keychain profile (override with
   `DBJOY_NOTARY_PROFILE=<profile>`, or set it empty to skip).
3. Publish it:

   ```sh
   gh release create v<version> build/DBJoy-<version>.dmg --title "DBJoy <version>"
   ```

For the Mac App Store (sandboxed build, `.pkg` for Transporter), run `scripts/make-appstore.sh`. The one-time setup,
listing text, screenshots and web pages are in [`appstore/`](appstore/README.md).

## License

Proprietary. All rights reserved. See [LICENSE](LICENSE).
