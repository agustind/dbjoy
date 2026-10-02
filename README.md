# DBJoy

A native macOS database client in the spirit of TablePlus. PostgreSQL first, built so more engines can be added as drivers.

## Requirements

- macOS 15+, Xcode 16+ (Swift 6)
- libpq: `brew install libpq` (keg-only; the package links `/opt/homebrew/opt/libpq`, override with `LIBPQ_PREFIX`)

## Build & run

```sh
swift run DBJoy                  # run from the command line
scripts/build-app.sh             # build build/DBJoy.app (release)
open build/DBJoy.app
```

Or open `Package.swift` in Xcode and run the `DBJoy` scheme.

### Distributing

```sh
scripts/make-dmg.sh              # build/DBJoy-<version>.dmg
```

The app bundles libpq and its OpenSSL/Kerberos dependencies in `Contents/Frameworks`, so it runs on
Apple Silicon Macs without Homebrew. It's signed with the first Developer ID / Apple Development identity
in your keychain (override with `DBJOY_SIGN_IDENTITY`). To notarize, store credentials once with
`xcrun notarytool store-credentials dbjoy …` and run `DBJOY_NOTARY_PROFILE=dbjoy scripts/make-dmg.sh`.

### Sample database

```sh
docker run -d --name dbjoy-pg -e POSTGRES_PASSWORD=secret -p 55432:5432 postgres:17
psql "postgres://postgres:secret@localhost:55432/postgres" -f scripts/sample-db.sql
```

Then add a connection to `localhost:55432`, user `postgres`, password `secret`, database `dbjoy_sample`.
The sample includes `type_showcase`, a table with one column per common Postgres type (enum, CHECK list,
domain, arrays, ranges, JSON, network types, a generated column…) for testing editors. Reload just that table with
`scripts/type-showcase.sql`.

### Tests

```sh
swift test                       # unit tests (lexer, splitter, completion, SQL generation)
DBJOY_TEST_PG=1 swift test       # + integration tests against the sample database
```

## Features

**Connections**: saved profiles grouped by folder, tagged by environment (local/dev/testing/staging/production) with colors. Passwords live in the Keychain. SSL modes are supported, as are server-enforced read-only connections. Each connection opens in its own window, and several can be open at once.

**Browsing**: database and schema switcher; tables, views, materialized views, foreign tables, functions and procedures. The sidebar has fuzzy search, and ⌘P opens objects across all schemas.

**Data**: paged spreadsheet grid with column sorting, a ⌘F search bar (field/operator/value, "any column" search, raw SQL conditions), a row inspector for long values, foreign-key navigation (*Open Referenced Row*), and copy as TSV or INSERT.

**Type-aware editing**: booleans, enum types and columns limited by a `CHECK (col IN (...))` list are edited with a dropdown (plus NULL when allowed). Generated columns are read-only.

**Export**: CSV or JSON (one file per table), SQL INSERT statements (one file, FK-ordered, sequences reset), or a full restorable backup via `pg_dump` (⌥⌘E, the toolbar, or right-click a table). Rows stream through a server-side cursor from one consistent snapshot.

**Safe editing**: edits are staged. Modified cells show yellow, new rows green, deleted rows red. ⌘S commits everything in one transaction, and each statement must affect exactly one row or the whole batch rolls back. Rows are identified by primary key; tables without one are read-only. Production connections always show the SQL for review before committing.

**Structure**: edit columns (rename, type, nullability, default, comment), add or drop columns, indexes, constraints and foreign keys, and create tables. Changes are applied as reviewed ALTER statements in one transaction.

**Relationships**: a per-table Relations view (outgoing and incoming FKs drawn as a map, dependent views, dependencies) and a schema-wide ER diagram with draggable tables (⇧⌘E).

**SQL editor**: syntax highlighting, line numbers, context-aware completion (tables after FROM/JOIN, `alias.` columns, columns of referenced tables), ⌘↩ run statement under cursor or selection, ⇧⌘↩ run all, ⌘. cancel, ⌘/ toggle comment. Multiple result sets, notices, and error positions that move the cursor. Each query tab has its own connection with Begin/Commit/Rollback and a live transaction indicator. Queries can be saved, per connection or shared, and per-connection history is kept.

**Production safety**: writes from the editor and grid commits on production connections require confirmation. Drop and truncate always confirm.

## Architecture

```
Sources/
  CLibPQ/          system module for libpq
  DBCore/          engine-agnostic: models, DatabaseDriver/DatabaseConnection protocols,
                   SQLDialect (edit + DDL generation), SQL lexer/splitter, completion engine
  PostgresDriver/  libpq wrapper (serial queue per connection, single-row streaming,
                   cancellation, notices) + Postgres introspection and dialect
  DBJoy/           SwiftUI app; AppKit for the data grid (NSTableView) and SQL editor (NSTextView)
```

Adding an engine: implement `DatabaseDriver`, `DatabaseConnection` and `SQLDialect` in a new target, add a `DatabaseKind` case, and register it in `Sources/DBJoy/Services/Drivers.swift`.

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
| Search rows (table) / find in editor | ⌘F |
| ER diagram | ⇧⌘E |
| Export tables | ⌥⌘E |
| Next / previous tab | ⇧⌘] / ⇧⌘[ |
| Completion | typing, Esc or ⌃Space |
| Edit cell | double-click or Return; Tab moves to the next cell |
| Delete rows | ⌫ |

## License

Proprietary. All rights reserved. See [LICENSE](LICENSE).
