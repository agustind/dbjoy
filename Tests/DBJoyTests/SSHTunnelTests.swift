@testable import DBJoy
import DBCore
import Foundation
import PostgresDriver
import Testing

/// End-to-end tunnel tests against an SSH server that can reach the sample database.
/// Enable with DBJOY_TEST_SSH=1 (see scripts in the README for the docker setup):
/// sshd on localhost:52222, user tunnel / tunnelpass, database host dbjoy-pg:5432 reachable from it.
/// DBJOY_TEST_SSH_KEY points at a private key (passphrase "keypass") authorized for that user.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBJOY_TEST_SSH"] != nil), .serialized)
struct SSHTunnelTests {
    static let env = ProcessInfo.processInfo.environment

    var database: ConnectionConfig {
        ConnectionConfig(name: "via ssh", host: "dbjoy-pg", port: 5432, user: "postgres", database: "dbjoy_sample", sslMode: .disable)
    }

    func ssh(_ method: SSHTunnelConfig.AuthMethod) -> SSHTunnelConfig {
        SSHTunnelConfig(isEnabled: true, host: "localhost", port: 52222, user: "tunnel", authMethod: method,
                        privateKeyPath: Self.env["DBJOY_TEST_SSH_KEY"] ?? "")
    }

    func queryThrough(_ tunnelConfig: SSHTunnelConfig, secret: String) async throws -> [[String?]] {
        var config = database
        config.ssh = tunnelConfig
        let tunnel = try #require(try await ConnectionOpener.openTunnel(for: config, secret: secret))
        defer { tunnel.close() }
        let connection = try await PostgresDriver().connect(ConnectionOpener.endpoint(for: config, tunnel: tunnel),
                                                            password: "secret", database: nil)
        defer { Task { await connection.close() } }
        return try await connection.query("SELECT current_database(), count(*)::text FROM customers").rows
    }

    @Test func passwordAuthentication() async throws {
        #expect(try await queryThrough(ssh(.password), secret: "tunnelpass") == [["dbjoy_sample", "1000"]])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBJOY_TEST_SSH_KEY"] != nil))
    func privateKeyWithPassphrase() async throws {
        #expect(try await queryThrough(ssh(.privateKey), secret: "keypass") == [["dbjoy_sample", "1000"]])
    }

    @Test func wrongPasswordReportsSSHError() async {
        do {
            _ = try await queryThrough(ssh(.password), secret: "nope")
            Issue.record("Expected the tunnel to fail")
        } catch let error as DatabaseError {
            #expect(error.message.hasPrefix("SSH tunnel to localhost failed"))
            #expect(error.detail?.contains("Permission denied") == true)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func closingStopsForwarding() async throws {
        var config = database
        config.ssh = ssh(.password)
        let tunnel = try #require(try await ConnectionOpener.openTunnel(for: config, secret: "tunnelpass"))
        #expect(tunnel.isRunning)
        tunnel.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!tunnel.isRunning)
        await #expect(throws: DatabaseError.self) {
            _ = try await PostgresDriver().connect(ConnectionOpener.endpoint(for: config, tunnel: tunnel), password: "secret", database: nil)
        }
    }
}
