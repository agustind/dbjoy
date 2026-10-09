import DBCore
import Darwin
import Foundation

/// A local port forwarded to a database through `ssh -L`, using the system OpenSSH client.
final class SSHTunnel: @unchecked Sendable {
    let localPort: Int
    private let process: Process
    /// The private key file, accessed through its security-scoped bookmark while ssh runs.
    private let scopedKey: URL?

    private init(localPort: Int, process: Process, scopedKey: URL?) {
        self.localPort = localPort
        self.process = process
        self.scopedKey = scopedKey
    }

    deinit { close() }

    var isRunning: Bool { process.isRunning }

    func close() {
        if process.isRunning { process.terminate() }
        scopedKey?.stopAccessingSecurityScopedResource()
    }

    /// Host keys are trusted on first use and kept in DBJoy's own file (alongside the user's
    /// ~/.ssh/known_hosts, which is read but not written). Changed keys are refused.
    static var knownHostsFile: URL { AppFiles.url("known_hosts") }

    /// Starts `ssh -N -L` and waits until the forwarded port accepts connections.
    /// `secret` is the SSH password or private key passphrase, passed through SSH_ASKPASS.
    static func open(_ ssh: SSHTunnelConfig, remoteHost: String, remotePort: Int, secret: String?) async throws -> SSHTunnel {
        guard ssh.isComplete else { throw DatabaseError("SSH tunnel settings are incomplete: host and user are required.") }
        let localPort = try freeLocalPort()
        let target = remoteHost.isEmpty || remoteHost == "localhost" ? "127.0.0.1" : remoteHost
        var arguments = [
            "-N", "-T",
            "-L", "127.0.0.1:\(localPort):\(target):\(remotePort)",
            "-p", String(ssh.port),
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\"\(knownHostsFile.path)\" ~/.ssh/known_hosts",
            "-o", "NumberOfPasswordPrompts=1",
        ]
        var scopedKey: URL?
        switch ssh.authMethod {
        case .agent:
            if Sandbox.isActive {
                throw DatabaseError("The SSH agent isn't available to DBJoy from the Mac App Store.",
                                    detail: "Choose your private key file in the SSH tunnel settings instead.")
            }
            arguments += ["-o", "BatchMode=yes"]
        case .privateKey:
            var path = Sandbox.expandingTilde(ssh.privateKeyPath)
            // ssh inherits the sandbox access granted to DBJoy, so open the bookmark before starting it.
            if let bookmark = ssh.privateKeyBookmark, let url = resolveBookmark(bookmark),
               url.startAccessingSecurityScopedResource() {
                scopedKey = url
                path = url.path
            }
            guard FileManager.default.isReadableFile(atPath: path) else {
                scopedKey?.stopAccessingSecurityScopedResource()
                if Sandbox.isActive && scopedKey == nil {
                    throw DatabaseError("DBJoy needs permission to read the SSH private key.",
                                        detail: "Click Choose… next to the private key in the SSH tunnel settings and select \(path).")
                }
                throw DatabaseError("SSH private key not found at \(path).")
            }
            arguments += ["-i", path, "-o", "IdentitiesOnly=yes"]
            if secret?.isEmpty ?? true { arguments += ["-o", "BatchMode=yes"] }
        case .password:
            arguments += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
        }
        arguments.append("\(ssh.user)@\(ssh.host)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors

        // Feed the password/passphrase non-interactively through the bundled askpass helper.
        var environment = ProcessInfo.processInfo.environment
        if let secret, !secret.isEmpty {
            guard let askpass = BundledTools.url("dbjoy-askpass") else {
                scopedKey?.stopAccessingSecurityScopedResource()
                throw DatabaseError("DBJoy's SSH password helper is missing. Reinstall DBJoy.")
            }
            environment["SSH_ASKPASS"] = askpass.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = environment["DISPLAY"] ?? "dbjoy"
            environment["DBJOY_SSH_SECRET"] = secret
        }
        process.environment = environment
        do {
            try process.run()
        } catch {
            scopedKey?.stopAccessingSecurityScopedResource()
            throw error
        }

        let tunnel = SSHTunnel(localPort: localPort, process: process, scopedKey: scopedKey)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !process.isRunning {
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                tunnel.close()
                throw DatabaseError("SSH tunnel to \(ssh.host) failed",
                                    detail: message.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                                        ?? "ssh exited with status \(process.terminationStatus)")
            }
            if canConnect(port: localPort) { return tunnel }
            try await Task.sleep(for: .milliseconds(150))
        }
        tunnel.close()
        throw DatabaseError("SSH tunnel to \(ssh.host) timed out")
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Asks the kernel for an unused loopback port.
    private static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DatabaseError("Couldn't open a local port for the SSH tunnel") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw DatabaseError("Couldn't reserve a local port for the SSH tunnel") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Opens database connections for a saved config, starting an SSH tunnel first when configured.
enum ConnectionOpener {
    /// The config to hand to the driver: through a tunnel, libpq connects to 127.0.0.1:<local port>
    /// via `hostaddr` while `host` keeps the real name for TLS verification and SNI.
    static func endpoint(for config: ConnectionConfig, tunnel: SSHTunnel?) -> ConnectionConfig {
        guard let tunnel else { return config }
        var routed = config
        routed.port = tunnel.localPort
        routed.options["hostaddr"] = "127.0.0.1"
        return routed
    }

    static func openTunnel(for config: ConnectionConfig, secret: String?) async throws -> SSHTunnel? {
        guard config.ssh.isEnabled else { return nil }
        return try await SSHTunnel.open(config.ssh, remoteHost: config.host, remotePort: config.port, secret: secret)
    }
}
