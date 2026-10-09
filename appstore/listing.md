# DBJoy App Store listing

Everything to paste into App Store Connect, field by field. Limits are App Store Connect's; counts were checked.

## App information

| Field | Value |
| --- | --- |
| Name (30) | `DBJoy: PostgreSQL Client` (24) |
| Subtitle (30) | `Browse, edit & query safely` (27) |
| Bundle ID | `app.dbjoy.DBJoy` |
| SKU | `dbjoy-macos` |
| Primary category | Developer Tools |
| Secondary category | Productivity |
| Content rights | Does not contain, show or access third-party content |
| Age rating | 4+ (answer "None" / "No" to every question in the questionnaire) |
| Copyright | `2026 Agu Dondo` |
| Price | Your call. Set in Pricing and Availability |

## Version information

**Promotional text** (170; can be changed any time without a review):

```
Edit Postgres data with confidence: staged, color-coded changes, one-transaction commits and SQL review on production. Native, fast and private.
```

**Keywords** (100):

```
postgres,sql,database,db,gui,schema,erd,diagram,ssh,tunnel,export,backup,psql,dba,developer,table
```

Words already in the name and subtitle (PostgreSQL, client, browse, edit, query) are indexed anyway, so they aren't
repeated. Competitor names (pgAdmin, TablePlus, Postico…) are left out on purpose: Apple rejects them in keywords.

**Description** (4000):

```
DBJoy is a fast, native PostgreSQL client for the Mac. Browse schemas, edit data without fear, write SQL and export, all in a clean, keyboard-friendly app.

EDIT SAFELY
• Changes are staged and color-coded, so modified, inserted and deleted rows stand out before anything is written
• ⌘S commits everything in one transaction. Each statement must affect exactly one row, or the whole batch rolls back
• On production connections, every write shows its SQL and waits for your OK
• Dropdowns for booleans, enums and CHECK lists. Type NOW() or gen_random_uuid() and the server fills in the value
• Change a field on many rows at once from the Row details panel

BROWSE AND SEARCH
• Tables, views, materialized views, functions and procedures, schema by schema
• Fuzzy sidebar search, and ⌘P to open anything across all schemas
• ⌘F search by column and operator (contains, equals, ranges, IN, IS NULL or raw SQL), with editable results
• Jump from a foreign key to the row it points at
• A relations view for every table and an ER diagram for the whole schema

WRITE SQL
• Syntax highlighting, line numbers and completion that understands table aliases
• Run the statement under the cursor (⌘↩) or everything (⇧⌘↩), and cancel with ⌘.
• Multiple result sets, server notices, and errors that put the cursor on the problem
• Every query tab has its own session with Begin, Commit and Rollback
• Saved queries, per-connection history, and .sql files you can open and run

CHANGE STRUCTURE
• Edit columns, indexes, constraints and foreign keys, or create new tables
• Changes run as reviewed ALTER statements in a single transaction

CONNECT YOUR WAY
• Saved connections in folders, tagged local, development, testing, staging or production, each with its own color
• Paste a postgres:// connection string to fill in the form
• SSH tunnels with a private key or a password
• SSL modes, server-enforced read-only connections, and passwords kept in the macOS Keychain
• Star your favorite connections and switch between them from any window

EXPORT AND BACK UP
• CSV or JSON (one file per table), or SQL INSERT statements ordered by foreign keys
• Full, restorable backups made with pg_dump, which is included
• Rows stream from one consistent snapshot, so big tables never fill your memory

PRIVATE BY DESIGN
DBJoy only talks to the servers you add. No account, no tracking, no analytics.

Light and dark themes. Works with local and hosted PostgreSQL servers.
```

**What's New**: not shown for the first version. Later, e.g. `Bug fixes and improvements.`

**Support URL**: `https://dondo.dev/dbjoy/support` (page in `appstore/site/`)
**Marketing URL** (optional): `https://dondo.dev/dbjoy`
**Privacy Policy URL**: `https://dondo.dev/dbjoy/privacy` (page in `appstore/site/`)

## Screenshots

Mac screenshots must be 16:10 at 1280×800, 1440×900, 2560×1600 or 2880×1800; up to 10. Upload
`appstore/screenshots/*.png` (2880×1800) in this order:

1. `01-browse.png`: Postgres, beautifully native.
2. `02-edit.png`: Edit safely. Commit with confidence.
3. `03-review.png`: No surprises on production.
4. `04-sql.png`: A SQL editor that keeps up.
5. `05-diagram.png`: See your whole schema.
6. `06-search-dark.png`: Find any row in seconds.
7. `07-connections.png`: Every environment, color-coded.
8. `08-structure-dark.png`: Change structure without the DDL.

All data is fictional (the `acme` demo database in `appstore/demo-db.sql`, hosts under the reserved `.example`
domain). Smaller 1440×900 copies are in `appstore/screenshots/1440x900/`. To retake them, see `appstore/README.md`.

## App Privacy

Answer **"No, we do not collect data from this app."** That gives the label **Data Not Collected**.
DBJoy has no analytics, crash reporting, accounts or servers of its own. Connection details stay on the Mac, and
passwords go in the Keychain.

## Export compliance

`Info.plist` sets `ITSAppUsesNonExemptEncryption = false`, so App Store Connect won't ask for each build. DBJoy uses
TLS (OpenSSL, through libpq) and SSH only to protect connections to the user's own servers, which falls under the
exemption for standard encryption whose main purpose isn't security. This is the usual answer for database clients.
If you'd rather answer the questionnaire per build, delete the key from `scripts/build-app.sh`.

## App Review information

Sign-in required: **No**. Reviewers still need a PostgreSQL server to connect to. Without one, database clients
are usually rejected under guideline 2.1 ("unable to review"). Host the demo database (see `appstore/README.md`),
then fill in and paste:

```
DBJoy is a client for PostgreSQL databases. To try it, add this test server (all data is fictional and can be changed freely):

1. Click "New connection".
2. Paste this into "Connection string" and click Save & Connect:
   postgres://REVIEW_USER:REVIEW_PASSWORD@REVIEW_HOST:5432/acme?sslmode=require
3. Pick a table in the sidebar (for example "customers") to browse and edit rows. Edits are staged; press ⌘S or Commit to save them.
4. Click "+" in the tab bar for a SQL query tab, or "ER diagram" in the sidebar for the schema diagram.

The connection is labelled "Local" by default. Set Environment to "Production" in the form to see the extra confirmation every write gets on production databases.

SSH tunnels need an SSH server of your own and aren't needed to review the app.
```

Contact: your name, phone and email.
