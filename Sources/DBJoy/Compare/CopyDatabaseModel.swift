import DBCore
import Foundation
import Observation

/// Replaces everything in a target database with a copy of a source database.
@MainActor @Observable
final class CopyDatabaseModel: CompareSidesModel {
    enum Phase: Equatable {
        case idle
        case copying
        case done(String)
        case failed(String)
    }

    let source = CompareSide()
    let target = CompareSide()
    var includeData = true
    var keepOwnership = false
    private(set) var phase: Phase = .idle
    private(set) var progress = DatabaseCopier.Progress(step: "", bytes: 0)
    private(set) var startedAt = Date()
    /// What the copy leaves alone, worked out before asking for confirmation.
    private(set) var plan = DatabaseCopier.Plan()
    private(set) var isPlanning = false
    /// Parts the copy couldn't replace, such as a policy that belongs to another role.
    private(set) var warnings: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    private let request: CompareRequest

    init(request: CompareRequest) {
        self.request = request
    }

    func start() async {
        guard source.connectionID == nil else { return }
        await source.select(request.sourceID, database: request.database)
    }

    func select(_ id: UUID?, on side: CompareSide) async {
        await side.select(id)
        clearResult()
    }

    func selectDatabase(_ name: String, on side: CompareSide) async {
        await side.selectDatabase(name)
        clearResult()
    }

    func submitPassword(_ value: String, on side: CompareSide) async {
        await side.submitPassword(value)
    }

    /// Swaps source and target, keeping each side's database.
    func swap() async {
        let (sourceID, sourceDatabase) = (source.connectionID, source.database)
        let (targetID, targetDatabase) = (target.connectionID, target.database)
        await source.select(targetID, database: targetDatabase.isEmpty ? nil : targetDatabase)
        await target.select(sourceID, database: sourceDatabase.isEmpty ? nil : sourceDatabase)
        clearResult()
    }

    func close() async {
        task?.cancel()
        await source.close()
        await target.close()
    }

    private func clearResult() {
        if phase != .copying { phase = .idle }
    }

    // MARK: Copying

    var isCopying: Bool { phase == .copying }

    var sameDatabase: Bool {
        source.connectionID != nil && source.connectionID == target.connectionID && source.database == target.database
    }

    var targetIsReadOnly: Bool { target.config?.readOnly ?? false }

    var canCopy: Bool {
        source.toolEndpoint != nil && target.toolEndpoint != nil && !sameDatabase && !targetIsReadOnly && !isCopying
    }

    /// pg_dump writes SQL for the source's version, which an older server may not understand.
    var versionWarning: String? {
        guard let from = source.serverMajorVersion, let to = target.serverMajorVersion, to < from else { return nil }
        return "The target runs PostgreSQL \(to), older than the source (\(from)). The copy may fail; if it does, the target isn't changed."
    }

    /// Checks both databases for what the copy has to leave alone. Returns false if that failed.
    func preparePlan() async -> Bool {
        guard canCopy, let from = source.session, let to = target.session else { return false }
        isPlanning = true
        defer { isPlanning = false }
        do {
            plan = try await DatabaseCopier.plan(source: from, target: to)
            return true
        } catch {
            phase = .failed("Couldn't check the databases before copying.\n\n"
                + ((error as? DatabaseError)?.fullDescription ?? error.localizedDescription))
            return false
        }
    }

    func copy() {
        guard canCopy, let from = source.toolEndpoint, let to = target.toolEndpoint else { return }
        let options = DatabaseCopier.Options(includeData: includeData, keepOwnership: keepOwnership)
        let plan = plan
        let summary = "\(source.database) (\(source.config?.displayName ?? "")) → \(target.database) (\(target.config?.displayName ?? ""))"
        phase = .copying
        warnings = []
        progress = .init(step: "Connecting", bytes: 0)
        startedAt = Date()
        task = Task {
            do {
                let warnings = try await DatabaseCopier().run(from: from, to: to, plan: plan, options: options) { progress in
                    Task { @MainActor [weak self] in
                        if self?.phase == .copying { self?.progress = progress }
                    }
                }
                let seconds = Int(Date().timeIntervalSince(startedAt).rounded())
                let time = seconds < 1 ? "under a second" : Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds]))
                phase = .done("Copied \(summary) in \(time).")
                if !warnings.isEmpty { self.warnings = warnings }
            } catch is CancellationError {
                phase = .done("Cancelled. The target wasn't changed.")
            } catch {
                phase = .failed(((error as? DatabaseError)?.fullDescription ?? error.localizedDescription)
                    + "\n\nThe target wasn't changed.")
            }
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }
}
