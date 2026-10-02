# DBJoy

A fast, native macOS client for PostgreSQL. Browse schemas, edit data safely, write SQL and export, all in a
keyboard-friendly SwiftUI app. More database engines can be added as drivers.

## Install

Download the latest `DBJoy-<version>.dmg` from [Releases](https://github.com/agustind/dbjoy/releases), open it, and
drag **DBJoy** to Applications. Builds are signed with a Developer ID and notarized by Apple.

- macOS 15 or later, Apple Silicon
- Backup export uses `pg_dump` if it's installed (`brew install libpq`); everything else is self-contained

## Features

### Connections
- Saved connections grouped into folders and tagged by environment: local, development, testing, staging, production
- Passwords stored in the macOS Keychain; SSL modes supported
- Read-only connections, enforced by the server
- Each connection opens in its own window, and several can be open at once

### Browsing
- Database and schema switcher; tables, views, materialized views, foreign tables, functions and procedures
- Fuzzy sidebar search, and ⌘P to open any object across all schemas
- Relations view per table (outgoing and incoming foreign keys, dependent views) and a schema-wide ER diagram

### Data
- Paged grid with column sorting, a row details panel for long values, and copy as TSV or INSERT
- ⌘F search by field and operator (contains, equals, ranges, IN, IS NULL, raw SQL…) with editable results
- Jump from a foreign-key value to the row it references

### Safe editing
- Edits are staged and color-coded: modified, inserted, deleted
- ⌘S commits everything in one transaction; each statement must affect exactly one row or the whole batch rolls back
- Dropdown editors for booleans, enum types and `CHECK (col IN (...))` lists; generated columns are read-only
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

### Export
- CSV or JSON (one file per table), or SQL `INSERT`s (one file, ordered by foreign keys, sequences reset)
- Full restorable backup via `pg_dump`
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

## License

Proprietary. All rights reserved. See [LICENSE](LICENSE).
