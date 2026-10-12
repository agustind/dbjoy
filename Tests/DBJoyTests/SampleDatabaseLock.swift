/// Tests that change the sample database's tables, or read all of it, take turns. Otherwise
/// pg_dump fails when another suite drops a table it already listed.
actor SampleDatabaseLock {
    private static let shared = SampleDatabaseLock()
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    static func run<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        await shared.acquire()
        do {
            let result = try await body()
            await shared.release()
            return result
        } catch {
            await shared.release()
            throw error
        }
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
