import DBCore
import Foundation
import Observation

enum TableMode: String, CaseIterable, Identifiable {
    case data = "Data"
    case structure = "Structure"
    case relations = "Relations"
    case definition = "Definition"

    var id: String { rawValue }
}

enum CellState {
    case normal, modified, inserted, deleted
}

/// A table/view tab: paged rows with staged edits, plus structure, relations and DDL.
@MainActor @Observable
final class TableTabModel: Identifiable {
    let id = UUID()
    let ref: ObjectRef
    @ObservationIgnored weak var workspace: WorkspaceModel?

    var mode: TableMode {
        didSet { Task { await loadCurrentMode() } }
    }

    // Data
    var structure: TableStructure?
    /// Foreign keys declared on this table, for navigating to referenced rows.
    var outgoingForeignKeys: [ForeignKeyInfo] = []
    var columns: [ResultColumn] = []
    var rows: [[String?]] = []
    var pageSize = 300
    var page = 0
    var hasMoreRows = false
    var rowCount: RowCount?
    var sort: [SortKey] = []

    /// The user's sort, or the primary key when none is chosen. Without an ORDER BY, Postgres
    /// returns rows in physical order, which changes after an UPDATE and makes paging unstable.
    var effectiveSort: [SortKey] {
        sort.isEmpty ? (structure?.primaryKey ?? []).map { SortKey(column: $0) } : sort
    }
    var filters: [RowFilter] = []
    var isFilterBarVisible = false
    /// Bumped to move keyboard focus to the search value field.
    var searchFocusRequest = 0
    var isLoading = false
    var loadError: String?
    var queryDuration: TimeInterval?
    var lastSQL = ""

    // Staged edits, keyed by row index in `rows`.
    var edits: [Int: [Int: CellValue]] = [:]
    var deletedRows: Set<Int> = []
    var insertedRows: [[CellValue]] = []
    var selectedRows = IndexSet()
    var isInspectorVisible = false
    /// Bumped whenever the grid needs to reload.
    var gridVersion = 0

    // Other modes
    var relations: TableRelations?
    var definition: String?
    var structureEditor: StructureEditorModel?

    private var didLoadData = false

    init(ref: ObjectRef, workspace: WorkspaceModel, mode: TableMode = .data) {
        self.ref = ref
        self.workspace = workspace
        self.mode = mode
    }

    private var connection: (any DatabaseConnection)? { workspace?.connection }

    // MARK: Loading

    func loadCurrentMode() async {
        loadError = nil
        do {
            switch mode {
            case .data:
                if structure == nil { try await loadStructure() }
                if !didLoadData { await reloadData() }
            case .structure:
                if structure == nil || structureEditor == nil { try await loadStructure() }
            case .relations:
                guard let connection else { return }
                relations = try await connection.relations(of: ref)
            case .definition:
                guard let connection else { return }
                definition = try await connection.definition(of: ref)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func loadStructure() async throws {
        guard let connection else { return }
        let structure = try await connection.structure(of: ref)
        self.structure = structure
        outgoingForeignKeys = (try? await connection.relations(of: ref).outgoing) ?? []
        if ref.kind == .table {
            structureEditor = StructureEditorModel(structure: structure)
        }
    }

    func reloadData() async {
        guard let connection else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        let request = RowRequest(filters: filters, sort: effectiveSort, limit: pageSize + 1, offset: page * pageSize,
                                 columns: structure?.columns.map(\.name) ?? columns.map(\.name))
        lastSQL = connection.dialect.selectStatement(for: ref, request: request)
        let started = Date()
        do {
            let result = try await connection.fetchRows(of: ref, request: request)
            queryDuration = Date().timeIntervalSince(started)
            hasMoreRows = result.rows.count > pageSize
            rows = Array(result.rows.prefix(pageSize))
            columns = result.columns
            didLoadData = true
        } catch {
            loadError = (error as? DatabaseError)?.fullDescription ?? error.localizedDescription
            rows = []
            hasMoreRows = false
        }
        resetEdits()
        Task {
            rowCount = try? await connection.rowCount(of: ref, request: request)
        }
    }

    /// Reloads everything, asking first if edits would be lost.
    func refresh() {
        let perform: @MainActor () async -> Void = { [self] in
            relations = nil
            definition = nil
            try? await loadStructure()
            didLoadData = false
            await loadCurrentMode()
        }
        guard hasChanges || (structureEditor?.hasChanges ?? false), let workspace else {
            Task { await perform() }
            return
        }
        workspace.confirm("Discard changes?", message: "Refreshing discards your unsaved changes to \(ref.name).",
                          actionTitle: "Discard & Refresh", destructive: true, action: perform)
    }

    private func reloadDiscardingChanges(_ change: @escaping @MainActor () -> Void) {
        let perform: @MainActor () async -> Void = { [self] in
            change()
            await reloadData()
        }
        if hasChanges, let workspace {
            workspace.confirm("Discard changes?", message: "You have unsaved changes on this page.",
                              actionTitle: "Discard", destructive: true, action: perform)
        } else {
            Task { await perform() }
        }
    }

    func nextPage() {
        guard hasMoreRows else { return }
        reloadDiscardingChanges { [self] in page += 1 }
    }

    func previousPage() {
        guard page > 0 else { return }
        reloadDiscardingChanges { [self] in page -= 1 }
    }

    func toggleSort(_ column: String) {
        reloadDiscardingChanges { [self] in
            if let current = effectiveSort.first, current.column == column {
                sort = current.ascending ? [SortKey(column: column, ascending: false)] : []
            } else {
                sort = [SortKey(column: column)]
            }
            page = 0
        }
    }

    /// ⌘F: show the search bar and focus its value field.
    func showSearch() {
        mode = .data
        if filters.isEmpty { filters.append(RowFilter()) }
        isFilterBarVisible = true
        searchFocusRequest += 1
    }

    /// Hides the search bar and drops any active conditions.
    func closeSearch() {
        isFilterBarVisible = false
        let hadActiveFilters = filters.contains { $0.isEnabled && (!$0.op.takesValue || !$0.value.isEmpty) }
        filters = []
        if hadActiveFilters { applyFilters() }
    }

    func applyFilters() {
        reloadDiscardingChanges { [self] in page = 0 }
    }

    func filter(column: String, equals value: String?) {
        filters.removeAll { $0.value.isEmpty && $0.op.takesValue }
        filters.append(value.map { RowFilter(column: column, op: .equals, value: $0) }
                       ?? RowFilter(column: column, op: .isNull))
        isFilterBarVisible = true
        applyFilters()
    }

    // MARK: Editing

    var primaryKeyIndexes: [Int] {
        (structure?.primaryKey ?? []).compactMap { pk in columns.firstIndex { $0.name == pk } }
    }

    var readOnlyReason: String? {
        if workspace?.config.readOnly == true { return "Read-only connection" }
        switch ref.kind {
        case .table:
            guard let structure else { return "Loading…" }
            return structure.primaryKey.isEmpty ? "No primary key: rows can't be edited safely" : nil
        default:
            return "\(ref.kind.displayName)s are read-only"
        }
    }

    var isEditable: Bool { readOnlyReason == nil }

    private func structureColumn(_ index: Int) -> ColumnInfo? {
        guard index < columns.count else { return nil }
        return structure?.columns.first { $0.name == columns[index].name }
    }

    /// Values offered in a dropdown instead of free text.
    func options(forColumn index: Int) -> [String]? {
        guard index < columns.count else { return nil }
        if columns[index].category == .boolean { return ["true", "false"] }
        return structureColumn(index)?.allowedValues
    }

    /// Generated columns are computed by the server and can't be written.
    func isColumnEditable(_ index: Int) -> Bool {
        !(structureColumn(index)?.isGenerated ?? false)
    }

    func isColumnNullable(_ index: Int) -> Bool {
        structureColumn(index)?.isNullable ?? true
    }

    var hasChanges: Bool { !edits.isEmpty || !deletedRows.isEmpty || !insertedRows.isEmpty }

    var changeCount: Int {
        edits.values.reduce(0) { $0 + $1.count } + deletedRows.count + insertedRows.count
    }

    var displayRowCount: Int { rows.count + insertedRows.count }

    func value(row: Int, column: Int) -> (value: CellValue, state: CellState) {
        if row >= rows.count {
            let inserted = insertedRows[row - rows.count]
            return (column < inserted.count ? inserted[column] : .defaultValue, .inserted)
        }
        let original = CellValue(rows[row][column])
        if deletedRows.contains(row) { return (original, .deleted) }
        if let edited = edits[row]?[column] { return (edited, .modified) }
        return (original, .normal)
    }

    func rowState(_ row: Int) -> CellState {
        if row >= rows.count { return .inserted }
        if deletedRows.contains(row) { return .deleted }
        return edits[row] == nil ? .normal : .modified
    }

    func setValue(_ value: CellValue, row: Int, column: Int) {
        guard isEditable, isColumnEditable(column) else { return }
        if row >= rows.count {
            insertedRows[row - rows.count][column] = value
        } else {
            if value == CellValue(rows[row][column]) {
                edits[row]?[column] = nil
                if edits[row]?.isEmpty == true { edits[row] = nil }
            } else {
                edits[row, default: [:]][column] = value
            }
        }
        gridVersion += 1
    }

    func addRow() {
        guard isEditable else { return }
        insertedRows.append(Array(repeating: .defaultValue, count: columns.count))
        selectedRows = [displayRowCount - 1]
        gridVersion += 1
    }

    func duplicateRows(_ indexes: IndexSet) {
        guard isEditable else { return }
        let generated = Set(structure?.columns.filter { $0.isGenerated || $0.isPrimaryKey }.map(\.name) ?? [])
        for row in indexes {
            let values = columns.indices.map { col -> CellValue in
                generated.contains(columns[col].name) ? .defaultValue : value(row: row, column: col).value
            }
            insertedRows.append(values)
        }
        gridVersion += 1
    }

    func deleteRows(_ indexes: IndexSet) {
        guard isEditable else { return }
        for row in indexes.reversed() {
            if row >= rows.count {
                insertedRows.remove(at: row - rows.count)
            } else if deletedRows.contains(row) {
                deletedRows.remove(row)
            } else {
                deletedRows.insert(row)
            }
        }
        selectedRows = []
        gridVersion += 1
    }

    func discardChanges() {
        resetEdits()
    }

    private func resetEdits() {
        edits = [:]
        deletedRows = []
        insertedRows = []
        gridVersion += 1
    }

    func pendingChanges() -> [RowChange] {
        let pk = primaryKeyIndexes
        func key(_ row: Int) -> [ColumnValue] {
            pk.map { ColumnValue(columns[$0].name, CellValue(rows[row][$0])) }
        }
        var changes: [RowChange] = []
        for row in deletedRows.sorted() {
            changes.append(.delete(key: key(row)))
        }
        for (row, cells) in edits.sorted(by: { $0.key < $1.key }) where !deletedRows.contains(row) {
            let values = cells.sorted { $0.key < $1.key }.map { ColumnValue(columns[$0.key].name, $0.value) }
            changes.append(.update(key: key(row), values: values))
        }
        let generated = Set(structure?.columns.filter(\.isGenerated).map(\.name) ?? [])
        for inserted in insertedRows {
            let values = columns.indices.compactMap { col -> ColumnValue? in
                generated.contains(columns[col].name) ? nil : ColumnValue(columns[col].name, inserted[col])
            }
            changes.append(.insert(values: values))
        }
        return changes
    }

    func pendingStatements() -> [String] {
        guard let dialect = connection?.dialect else { return [] }
        return pendingChanges().map { dialect.statement(for: $0, in: ref) }
    }

    /// Applies staged edits atomically. Every statement must affect exactly one row or
    /// the whole batch is rolled back.
    func commit(preview: Bool = false) {
        guard hasChanges, let workspace else { return }
        let statements = pendingStatements()
        let apply: @MainActor () async -> Void = { [self] in
            guard let connection else { return }
            do {
                try await connection.executeInTransaction(statements.map { TransactionStatement($0, expectedRows: 1) })
                await reloadData()
            } catch {
                workspace.errorMessage = "Changes were rolled back.\n\n"
                    + ((error as? DatabaseError)?.fullDescription ?? error.localizedDescription)
            }
        }
        if preview || workspace.config.environment.requiresWriteConfirmation {
            let environment = workspace.config.environment
            workspace.sqlPreview = SQLPreviewRequest(
                title: environment.requiresWriteConfirmation
                    ? "Commit \(changeCount) change(s) to \(environment.displayName.uppercased())?"
                    : "Review changes",
                statements: statements, actionTitle: "Commit", action: apply)
        } else {
            Task { await apply() }
        }
    }
}

// MARK: - Structure editing

@MainActor @Observable
final class StructureEditorModel {
    let structure: TableStructure
    let original: [ColumnDefinition]
    var columns: [ColumnDefinition]
    var droppedIndexes: Set<String> = []
    var droppedConstraints: Set<String> = []
    var newIndexes: [IndexDefinition] = []
    var newForeignKeys: [ForeignKeyDefinition] = []
    var selectedColumns = Set<ColumnDefinition.ID>()

    init(structure: TableStructure) {
        self.structure = structure
        original = structure.columns.map(ColumnDefinition.init)
        columns = original
    }

    var change: TableSchemaChange {
        // Dropping a constraint-backed index means dropping the constraint.
        let indexConstraints = structure.indexes.filter { droppedIndexes.contains($0.name) }
        let constraintNames = indexConstraints.compactMap(\.constraintName)
        return TableSchemaChange(
            table: structure.ref, original: original, columns: columns,
            newIndexes: newIndexes,
            droppedIndexes: indexConstraints.filter { $0.constraintName == nil }.map(\.name),
            newForeignKeys: newForeignKeys,
            droppedConstraints: Array(droppedConstraints.union(constraintNames)).sorted())
    }

    func statements(_ dialect: any SQLDialect) -> [String] {
        dialect.statements(for: change)
    }

    var hasChanges: Bool {
        columns != original || !droppedIndexes.isEmpty || !droppedConstraints.isEmpty
            || !newIndexes.isEmpty || !newForeignKeys.isEmpty
    }

    func addColumn() {
        var column = ColumnDefinition(name: "column_\(columns.count + 1)", dataType: "text")
        column.originalName = nil
        columns.append(column)
        selectedColumns = [column.id]
    }

    func removeSelectedColumns() {
        columns.removeAll { selectedColumns.contains($0.id) }
        selectedColumns = []
    }

    func revert() {
        columns = original
        droppedIndexes = []
        droppedConstraints = []
        newIndexes = []
        newForeignKeys = []
    }
}

@MainActor @Observable
final class CreateTableModel: Identifiable {
    let id = UUID()
    var schema: String
    var name = ""
    var comment = ""
    var columns: [ColumnDefinition] = [
        ColumnDefinition(name: "id", dataType: "bigserial", isNullable: false, isPrimaryKey: true),
        ColumnDefinition(name: "created_at", dataType: "timestamp with time zone", isNullable: false, defaultValue: "now()"),
    ]
    var selectedColumns = Set<ColumnDefinition.ID>()

    init(schema: String) {
        self.schema = schema
    }

    var request: CreateTableRequest {
        CreateTableRequest(schema: schema, name: name.trimmingCharacters(in: .whitespaces), columns: columns, comment: comment)
    }

    /// Why the table can't be created yet, or `nil` when it's ready.
    func validationMessage(existingTables: Set<String>) -> String? {
        let tableName = name.trimmingCharacters(in: .whitespaces)
        if tableName.isEmpty { return "Enter a table name" }
        if existingTables.contains(tableName) { return "A table named “\(tableName)” already exists in \(schema)" }
        if columns.isEmpty { return "Add at least one column" }
        if columns.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "Every column needs a name"
        }
        if let column = columns.first(where: { $0.dataType.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "Column “\(column.name)” needs a type"
        }
        var seen = Set<String>()
        for column in columns {
            let columnName = column.name.trimmingCharacters(in: .whitespaces)
            if !seen.insert(columnName).inserted { return "Duplicate column name “\(columnName)”" }
        }
        return nil
    }
}
