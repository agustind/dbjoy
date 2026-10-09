// SSH_ASKPASS helper for SSH tunnels: prints the secret DBJoy passes in DBJOY_SSH_SECRET.
// A signed binary inside the app bundle, because the sandboxed build can't run scripts it writes.
import Darwin

if let secret = getenv("DBJOY_SSH_SECRET") {
    print(String(cString: secret))
}
