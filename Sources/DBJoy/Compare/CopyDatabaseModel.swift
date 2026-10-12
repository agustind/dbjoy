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
    var includePlatformData = false
    /// Tables the user chose to copy without their rows.
    var tablesWithoutData: Set<DatabaseCopier.Plan.Table> = []
    private(set) var phase: Phase = .idle
    private(set) var progress = DatabaseCopier.Progress(step: "", bytes: 0)
    private(set) var startedAt = Date()
    /// What the copy leaves alone, worked out before asking for confirmation.
    private(set) var plan = DatabaseCopier.Plan()
    private(set) var isPlanning = false
    /// Whether `plan` matches the databases picked now, so its tables can be listed.
    private(set) var hasPlan = false
    private(set) var planError: String?
    @ObservationIgnored private var planTask: Task<DatabaseCopier.Plan, Error>?
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
        await refreshPlan()
    }

    func select(_ id: UUID?, on side: CompareSide) async {
        databasesChanged(on: side)
        await side.select(id)
        clearResult()
        await refreshPlan()
    }

    func selectDatabase(_ name: String, on side: CompareSide) async {
        databasesChanged(on: side)
        await side.selectDatabase(name)
        clearResult()
        await refreshPlan()
    }

    func submitPassword(_ value: String, on side: CompareSide) async {
        await side.submitPassword(value)
        await refreshPlan()
    }

    private func databasesChanged(on side: CompareSide) {
        hasPlan = false
        if side === source { tablesWithoutData = [] }
    }

    /// Swaps source and target, keeping each side's database.
    func swap() async {
        let (sourceID, sourceDatabase) = (source.connectionID, source.database)
        let (targetID, targetDatabase) = (target.connectionID, target.database)
        await source.select(targetID, database: targetDatabase.isEmpty ? nil : targetDatabase)
        await target.select(sourceID, database: sourceDatabase.isEmpty ? nil : sourceDatabase)
        tablesWithoutData = []
        hasPlan = false
        clearResult()
        await refreshPlan()
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

    // MARK: Tables

    /// The tables whose rows can be copied, biggest first.
    var dataTables: [DatabaseCopier.Plan.TableSize] {
        guard hasPlan else { return [] }
        return plan.dataTables(platformRows: includeData && includePlatformData).sorted {
            ($0.bytes, $1.table.description) > ($1.bytes, $0.table.description)
        }
    }

    func copiesRows(of table: DatabaseCopier.Plan.Table) -> Bool {
        !tablesWithoutData.contains(table)
    }

    func setCopiesRows(_ copies: Bool, of tables: [DatabaseCopier.Plan.Table]) {
        if copies { tablesWithoutData.subtract(tables) } else { tablesWithoutData.formUnion(tables) }
    }

    /// Runs one plan at a time: planning sets the source session's search_path for a moment.
    private func makePlan() async throws -> DatabaseCopier.Plan {
        guard let from = source.session, let to = target.session else { throw CancellationError() }
        let previous = planTask
        let task = Task {
            _ = try? await previous?.value
            return try await DatabaseCopier.plan(source: from, target: to)
        }
        planTask = task
        return try await task.value
    }

    /// Plans as soon as both databases are picked, to list the source's tables.
    func refreshPlan() async {
        guard source.session != nil, target.session != nil, !sameDatabase, !isCopying else { return }
        let pair = (source.connectionID, source.database, target.connectionID, target.database)
        do {
            let plan = try await makePlan()
            guard pair == (source.connectionID, source.database, target.connectionID, target.database) else { return }
            self.plan = plan
            hasPlan = true
            planError = nil
        } catch {
            planError = (error as? DatabaseError)?.fullDescription ?? error.localizedDescription
        }
    }

    /// Checks both databases for what the copy has to leave alone. Returns false if that failed.
    func preparePlan() async -> Bool {
        guard canCopy, source.session != nil, target.session != nil else { return false }
        isPlanning = true
        defer { isPlanning = false }
        do {
            plan = try await makePlan()
            hasPlan = true
            return true
        } catch {
            phase = .failed("Couldn't check the databases before copying.\n\n"
                + ((error as? DatabaseError)?.fullDescription ?? error.localizedDescription))
            return false
        }
    }

    var options: DatabaseCopier.Options {
        DatabaseCopier.Options(includeData: includeData, keepOwnership: keepOwnership,
                               includePlatformData: includePlatformData,
                               tablesWithoutData: tablesWithoutData.intersection(dataTables.map(\.table)))
    }

    func copy() {
        guard canCopy, let from = source.toolEndpoint, let to = target.toolEndpoint else { return }
        let options = options
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
