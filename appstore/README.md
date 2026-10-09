# Mac App Store

Everything for the App Store release of DBJoy, next to the existing notarized DMG release.

| Path | What it is |
| --- | --- |
| `listing.md` | Every App Store Connect field: name, subtitle, description, keywords, privacy answers, review notes |
| `screenshots/` | Eight 2880×1800 screenshots (upload in file order), 1440×900 copies, raw captures and `compose.py` |
| `site/dbjoy/` | Marketing, support and privacy policy pages to host at `dondo.dev/dbjoy` |
| `demo-db.sql` | The fictional `acme` database shown in the screenshots, and the App Review test server |
| `DBJoy.entitlements`, `Helper.entitlements` | App Sandbox entitlements for the App Store build |

## How the App Store build differs

The App Store requires the App Sandbox. `scripts/make-appstore.sh` builds the same app with
`DBJoy.entitlements`:

- `network.client` for database and SSH servers, and `network.server` because an SSH tunnel listens on a
  127.0.0.1 port
- `files.user-selected.read-write` for exports, backups and `.sql` files, and `files.bookmarks.app-scope` so the
  SSH key picked with **Choose…** stays readable

pg_dump and the SSH askpass helper ship inside the app (`Contents/Helpers`, in both builds) and are signed to inherit
the sandbox. In the sandbox:

- SSH tunnels work with a password or a private key chosen with **Choose…**. The SSH agent can't be reached, so
  that option is hidden.
- Data lives in `~/Library/Containers/app.dbjoy.DBJoy`, so App Store users start with no connections, even if
  they used the DMG version before.

To try the sandboxed build locally, without App Store certificates:

```sh
DBJOY_SANDBOX=1 scripts/build-app.sh && open build/DBJoy.app
```

Tested this way: SSH tunnel with password, Keychain, and a pg_dump backup through the tunnel to a file chosen in the
save panel. Not tested end to end: key-file authentication through a bookmark. It relies on the same inherited file
access that the backup test exercised.

## One-time setup

1. **App ID.** In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list),
   register the explicit App ID `app.dbjoy.DBJoy` for macOS, if it isn't there yet. No extra capabilities are needed.
2. **Certificates.** Create an **Apple Distribution** certificate and a **Mac Installer Distribution**
   certificate (Certificates ▸ +), or let Xcode do it in Settings ▸ Accounts ▸ Manage Certificates. Both must be in the
   login keychain with their private keys. Only the Developer ID Application certificate is installed now.
3. **Provisioning profile.** Profiles ▸ + ▸ *Mac App Store Connect* ▸ App ID `app.dbjoy.DBJoy` ▸ the Apple
   Distribution certificate. Download it to `appstore/DBJoy_Mac_App_Store.provisionprofile` (git-ignored).
4. **App record.** In [App Store Connect](https://appstoreconnect.apple.com) ▸ Apps ▸ + ▸ New App: platform macOS,
   name `DBJoy: PostgreSQL Client`, bundle ID `app.dbjoy.DBJoy`, SKU `dbjoy-macos`.
5. **Web pages.** `site/dbjoy/` is published at `dondo.dev/dbjoy` (with `/dbjoy/support/` and `/dbjoy/privacy/`)
   by copying it into `public/dbjoy/` of the dondo.dev repo, which Vercel deploys on push. Support goes through
   GitHub Issues. Point the landing page's Download button at the App Store once it's live, if you want. The privacy
   policy URL is required before you can submit.
6. **Review server.** App Review needs a PostgreSQL server it can reach. Create a small hosted database (any
   provider with a free tier will do), run `psql "<connection string>" -f appstore/demo-db.sql`, and put its
   connection string into the review notes from `listing.md`. Use a database with nothing else in it: the reviewer
   can change anything.

## Each release

1. Bump `CFBundleShortVersionString`, and **always** `CFBundleVersion`, in `scripts/build-app.sh`. App Store Connect
   rejects a build number it has seen before. Consider `1.0.0` for the App Store launch.
2. Build and package:

   ```sh
   scripts/make-appstore.sh         # build/DBJoy-<version>.pkg
   ```

3. Upload `build/DBJoy-<version>.pkg` with [Transporter](https://apps.apple.com/app/transporter/id1450874784).
   Transporter validates the package first: entitlements, icon, signature. If it reports `._` files in the
   package, build from Terminal.app and try again.
4. In App Store Connect, pick the build for the version, fill in the fields from `listing.md`, upload the
   screenshots, and submit for review.

## Retaking the screenshots

The screenshots come from a separate DBJoy instance with a throwaway data folder (`DBJOY_DATA_DIR`). It never shows
your own connections. The connections come from `demo-connections.json`, and the data from `demo-db.sql` in a local
container:

```sh
docker run -d --name dbjoy-demo -e POSTGRES_HOST_AUTH_METHOD=trust -p 55433:5432 postgres:17
psql "postgres://postgres@localhost:55433/postgres" -c "CREATE DATABASE acme" -c "CREATE ROLE app LOGIN SUPERUSER"
psql "postgres://postgres@localhost:55433/acme" -f appstore/demo-db.sql
mkdir -p /tmp/dbjoy-demo && cp appstore/demo-connections.json /tmp/dbjoy-demo/connections.json
DBJOY_DATA_DIR=/tmp/dbjoy-demo build/DBJoy.app/Contents/MacOS/DBJoy -ApplePersistenceIgnoreState YES \
  -appearance light -starredRailExpanded YES -AppleLocale en_US
```

The demo connections reach the container through OrbStack's `dbjoy-demo.orb.local` address (`hostaddr` in
`demo-connections.json`), so the screens show port 5432. Update that IP if it changes, or use your setup's equivalent.
Make the workspace window 1440×900 points, capture each window with `screencapture -o -l <window id>` into
`screenshots/raw/` using the existing file names, then run `python3 appstore/screenshots/compose.py`.
