import DBCore
import Foundation

/// Database sessions for MCP requests, one per connection, separate from any open window.
/// Requests on the same connection run one at a time, so one query's transaction never
/// interleaves with another's. Sessions close after a few idle minutes.
@MainActor
final class MCPDatabases {
    static let idleTimeout: Duration = .seconds(300)

    private struct Session {
        var config: ConnectionConfig
        var connection: any DatabaseConnection
        var tunnel: SSHTunnel?
        var lastUsed = ContinuousClock.now
    }

    private var sessions: [UUID: Session] = [:]
    private var busy: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var sweeper: Task<Void, Never>?

    /// Runs `body` with this connection's session, opening (or reopening) it as needed.
    func withSession<T>(_ config: ConnectionConfig, password: String?,
                        _ body: (any DatabaseConnection) async throws -> T) async throws -> T {
        await acquire(config.id)
        defer { release(config.id) }
        let connection = try await session(for: config, password: password)
        do {
            let result = try await body(connection)
            sessions[config.id]?.lastUsed = .now
            return result
        } catch {
            // A broken session is reopened on the next request.
            if await connection.transactionStatus() == .unknown { await drop(config.id) }
            throw error
        }
    }

    func closeAll() async {
        sweeper?.cancel()
        sweeper = nil
        for id in Array(sessions.keys) { await drop(id) }
    }

    private func session(for config: ConnectionConfig, password: String?) async throws -> any DatabaseConnection {
        if let session = sessions[config.id] {
            let tunnelAlive = session.tunnel?.isRunning ?? true
            if session.config == config, tunnelAlive, await session.connection.transactionStatus() != .unknown {
                return session.connection
            }
            await drop(config.id)
        }
        let tunnel = try await ConnectionOpener.openTunnel(for: config, secret: Keychain.password(for: config.id, ssh: true))
        do {
            let connection = try await Drivers.driver(for: config.kind)
                .connect(ConnectionOpener.endpoint(for: config, tunnel: tunnel), password: password, database: nil)
            sessions[config.id] = Session(config: config, connection: connection, tunnel: tunnel)
            startSweeper()
            return connection
        } catch {
            tunnel?.close()
            throw error
        }
    }

    private func drop(_ id: UUID) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.connection.close()
        session.tunnel?.close()
    }

    private func startSweeper() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                let now = ContinuousClock.now
                for (id, session) in self.sessions where !self.busy.contains(id) && now - session.lastUsed > Self.idleTimeout {
                    await self.drop(id)
                }
                if self.sessions.isEmpty {
                    self.sweeper = nil
                    return
                }
            }
        }
    }

    // MARK: One request per connection at a time

    private func acquire(_ id: UUID) async {
        if busy.insert(id).inserted { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    /// Hands the connection to the next waiting request, or frees it.
    private func release(_ id: UUID) {
        if var queue = waiters[id], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[id] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            busy.remove(id)
        }
    }
}
