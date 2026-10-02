import DBCore
import SwiftUI

struct TableTabView: View {
    @Bindable var model: TableTabModel

    private var activeFilterCount: Int {
        model.filters.filter { $0.isEnabled && (!$0.op.takesValue || !$0.value.isEmpty) }.count
    }

    private var subtitle: String {
        var parts = [model.ref.schema, model.ref.kind.displayName.lowercased()]
        if let comment = model.structure?.comment { parts.append(comment) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: model.ref.name, subtitle: subtitle) {
                Rectangle().fill(Theme.border).frame(width: 1, height: 22)
                UnderlineTabs(items: TableMode.allCases.map { ($0, $0.rawValue) }, selection: $model.mode)
            } trailing: {
                Button { model.workspace?.startExport([model.ref]) } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.outline)
                if model.mode == .data, model.isEditable {
                    Button { model.addRow() } label: { Label("Add row", systemImage: "plus") }
                        .buttonStyle(.primary)
                        .help("Add a row (saved when you commit)")
                }
            } toolbar: {
                if model.mode == .data {
                    Button {
                        model.isFilterBarVisible ? model.closeSearch() : model.showSearch()
                    } label: {
                        Label(activeFilterCount > 0 ? "Search · \(activeFilterCount)" : "Search",
                              systemImage: "line.3.horizontal.decrease")
                    }
                    .buttonStyle(.outline(active: model.isFilterBarVisible || activeFilterCount > 0))
                    .help("Search rows (⌘F)")
                    Button { model.isInspectorVisible.toggle() } label: {
                        Label("Row details", systemImage: "sidebar.right")
                    }
                    .buttonStyle(.outline(active: model.isInspectorVisible))
                    Spacer()
                    Pager(model: model)
                } else {
                    Spacer()
                }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.outline)
                    .help("Refresh (⌘R)")
            }
            Rectangle().fill(Theme.separator).frame(height: 1)

            if let error = model.loadError {
                ErrorBanner(message: error)
            }

            switch model.mode {
            case .data: DataPane(model: model)
            case .structure: StructurePane(model: model)
            case .relations: RelationsPane(model: model)
            case .definition: DefinitionPane(model: model)
            }
        }
        .background(Theme.contentBackground)
        .task { await model.loadCurrentMode() }
    }
}

/// "‹ Rows 1–300 of 1,000 ›" page control.
private struct Pager: View {
    var model: TableTabModel

    private var label: String {
        let start = model.page * model.pageSize
        let total = model.rowCount.map { ($0.isEstimate ? "~" : "") + $0.value.formatted() } ?? "…"
        guard !model.rows.isEmpty else { return "No rows" }
        return "\((start + 1).formatted())–\((start + model.rows.count).formatted()) of \(total)"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { model.previousPage() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.ghost)
                .disabled(model.page == 0)
                .help("Previous page")
            HStack(spacing: 6) {
                Image(systemName: "list.number").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .help(model.lastSQL)
            Button { model.nextPage() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.ghost)
                .disabled(!model.hasMoreRows)
                .help("Next page")
        }
        .padding(.horizontal, 2)
        .frame(height: 30)
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border, lineWidth: 1))
    }
}

struct ErrorBanner: View {
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).textSelection(.enabled).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.12))
    }
}

// MARK: - Data

private struct DataPane: View {
    @Bindable var model: TableTabModel

    private var foreignKeyColumns: Set<String> {
        Set(model.outgoingForeignKeys.flatMap(\.columns))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isFilterBarVisible {
                FilterBar(model: model)
                Rectangle().fill(Theme.separator).frame(height: 1)
            }
            HStack(spacing: 0) {
            DataGridView(
                columns: model.columns,
                rowCount: model.displayRowCount,
                version: model.gridVersion,
                value: { model.value(row: $0, column: $1) },
                isEditable: model.isEditable,
                sort: model.effectiveSort,
                primaryKeyColumns: Set(model.structure?.primaryKey ?? []),
                foreignKeyColumns: foreignKeyColumns,
                selection: $model.selectedRows,
                actions: GridActions(
                    setValue: { model.setValue($0, row: $1, column: $2) },
                    deleteRows: { model.deleteRows($0) },
                    duplicateRows: { model.duplicateRows($0) },
                    sort: { model.toggleSort($0) },
                    filter: { model.filter(column: $0, equals: $1) },
                    followForeignKey: { followForeignKey(column: $0, value: $1) },
                    copyAsInsert: { insertStatements(rows: $0) }),
                columnOptions: { model.options(forColumn: $0) },
                isColumnEditable: { model.isColumnEditable($0) },
                isColumnNullable: { model.isColumnNullable($0) })
            .overlay {
                if model.isLoading, model.rows.isEmpty { ProgressView() }
            }
            if model.isInspectorVisible {
                Rectangle().fill(Theme.separator).frame(width: 1)
                RowInspector(model: model)
                    .frame(width: 310)
                    .background(Theme.contentBackground)
            }
            }
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.hasChanges {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text("\(model.changeCount) pending change(s)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accentText)
                Spacer()
                Button("Discard") { model.discardChanges() }
                    .buttonStyle(.ghost)
                Button("Preview SQL") { model.commit(preview: true) }
                    .buttonStyle(.outline)
                Button { model.commit() } label: { Label("Commit", systemImage: "checkmark") }
                    .buttonStyle(.primary)
                    .keyboardShortcut("s")
            } else {
                if let reason = model.readOnlyReason {
                    Label(reason, systemImage: "lock")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else if !model.selectedRows.isEmpty {
                    Button { model.deleteRows(model.selectedRows) } label: {
                        Label("Delete \(model.selectedRows.count) row(s)", systemImage: "trash")
                    }
                    .buttonStyle(.ghost)
                    .help("Mark the selected rows for deletion (⌫)")
                } else {
                    Text("Double-click a cell to edit · ⌫ deletes rows · ⌘S commits")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                if let duration = model.queryDuration {
                    Text(formatDuration(duration))
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        .help(model.lastSQL)
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .background(model.hasChanges ? Theme.accentFill.opacity(0.5) : Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    private func followForeignKey(column: String, value: String) {
        guard let workspace = model.workspace,
              let fk = model.outgoingForeignKeys.first(where: { $0.columns.contains(column) }),
              let index = fk.columns.firstIndex(of: column), index < fk.referencedColumns.count else { return }
        Task {
            workspace.open(fk.referencedTable)
            if case .table(let target) = workspace.selectedTab {
                target.filters = [RowFilter(column: fk.referencedColumns[index], op: .equals, value: value)]
                target.isFilterBarVisible = true
                target.page = 0
                if target.structure == nil { try? await target.loadStructure() }
                await target.reloadData()
            }
        }
    }

    private func insertStatements(rows: IndexSet) -> String {
        guard let dialect = model.workspace?.dialect else { return "" }
        return rows.map { row in
            let values = model.columns.indices.map { ColumnValue(model.columns[$0].name, model.value(row: row, column: $0).value) }
            return dialect.statement(for: .insert(values: values), in: model.ref)
        }.joined(separator: "\n")
    }
}

private struct FilterBar: View {
    @Bindable var model: TableTabModel
    @FocusState private var focusedFilter: RowFilter.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($model.filters) { $filter in
                HStack(spacing: 6) {
                    Toggle("", isOn: $filter.isEnabled).labelsHidden()
                    Picker("", selection: $filter.column) {
                        Text("Any column").tag(String?.none)
                        Divider()
                        ForEach(model.columns, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    Picker("", selection: $filter.op) {
                        ForEach(FilterOperator.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    if filter.op.takesValue {
                        TextField(filter.op == .rawSQL ? "e.g. price > 10 AND active" : (filter.op == .inList || filter.op == .notInList ? "a, b, c" : "Value"),
                                  text: $filter.value)
                            .textFieldStyle(.roundedBorder)
                            .font(filter.op == .rawSQL ? .body.monospaced() : .body)
                            .focused($focusedFilter, equals: filter.id)
                            .onSubmit { model.applyFilters() }
                    } else {
                        Spacer()
                    }
                    Button { model.filters.removeAll { $0.id == filter.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove condition")
                    Button {
                        let added = RowFilter()
                        model.filters.append(added)
                        focusedFilter = added.id
                    } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                        .help("Add condition (all conditions must match)")
                }
            }
            HStack {
                if model.filters.isEmpty {
                    Button("Add Filter") { model.filters.append(RowFilter()) }
                }
                Spacer()
                Text("Return to search · Esc to close").font(.caption).foregroundStyle(.secondary)
                Button("Clear") {
                    model.filters = [RowFilter()]
                    model.applyFilters()
                    focusedFilter = model.filters.first?.id
                }
                .disabled(model.filters.isEmpty)
                .help("Reset the conditions and show all rows")
                Button("Search") { model.applyFilters() }
                    .help("Show matching rows (Return)")
                Button { model.closeSearch() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close search and show all rows (Esc)")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.elevated.opacity(0.5))
        .onExitCommand { model.closeSearch() }
        .onAppear {
            if model.filters.isEmpty { model.filters.append(RowFilter()) }
            focusFirstValueField()
        }
        .onChange(of: model.searchFocusRequest) { _, _ in focusFirstValueField() }
    }

    private func focusFirstValueField() {
        // Defer so the field exists when the bar has just appeared.
        DispatchQueue.main.async {
            focusedFilter = model.filters.first(where: { $0.op.takesValue })?.id
        }
    }
}

private struct RowInspector: View {
    @Bindable var model: TableTabModel

    var body: some View {
        if let row = model.selectedRows.first, row < model.displayRowCount {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
                        field(row: row, index: index, column: column)
                    }
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.textTertiary)
                Text("Select a row to see its details").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func field(row: Int, index: Int, column: ResultColumn) -> some View {
        let cell = model.value(row: row, column: index)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(column.name.uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(Theme.textSecondary)
                Text(column.typeName).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                Spacer()
                if model.isEditable, cell.state != .deleted, model.isColumnEditable(index) {
                    Menu {
                        Button("Set NULL") { model.setValue(.null, row: row, column: index) }
                        Button("Set DEFAULT") { model.setValue(.defaultValue, row: row, column: index) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }
            }
            if model.isEditable, cell.state != .deleted, model.isColumnEditable(index) {
                if let options = model.options(forColumn: index) {
                    Picker("", selection: Binding<String?>(
                        get: { if case .value(let text) = model.value(row: row, column: index).value { text } else { nil } },
                        set: { model.setValue($0.map(CellValue.value) ?? .null, row: row, column: index) })
                    ) {
                        ForEach(options, id: \.self) { Text($0).tag(Optional($0)) }
                        if model.isColumnNullable(index) {
                            Divider()
                            Text("NULL").tag(String?.none)
                        }
                    }
                    .labelsHidden()
                } else {
                    TextField(placeholder(cell.value), text: Binding(
                        get: { if case .value(let text) = model.value(row: row, column: index).value { text } else { "" } },
                        set: { model.setValue(.value($0), row: row, column: index) }),
                        axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...10)
                        .font(column.category == .json ? .body.monospaced() : .body)
                }
            } else {
                Text(display(cell.value))
                    .textSelection(.enabled)
                    .foregroundStyle(cell.value == .null ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func placeholder(_ value: CellValue) -> String {
        switch value {
        case .null: "NULL"
        case .defaultValue: "DEFAULT"
        case .value: ""
        }
    }

    private func display(_ value: CellValue) -> String {
        if case .value(let text) = value { return text }
        return placeholder(value)
    }
}

// MARK: - Structure

private struct StructurePane: View {
    @Bindable var model: TableTabModel

    var body: some View {
        if let editor = model.structureEditor {
            StructureEditorView(editor: editor, model: model)
        } else if let structure = model.structure {
            // Views and other read-only relations.
            Table(structure.columns) {
                TableColumn("Name", value: \.name)
                TableColumn("Type", value: \.dataType)
                TableColumn("Nullable") { Text($0.isNullable ? "YES" : "NO") }
                TableColumn("Comment") { Text($0.comment ?? "") }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct StructureEditorView: View {
    @Bindable var editor: StructureEditorModel
    var model: TableTabModel
    @State private var isAddingIndex = false
    @State private var isAddingForeignKey = false

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                ColumnsEditor(columns: $editor.columns, selection: $editor.selectedColumns,
                              dataTypes: model.workspace?.dialect?.dataTypes ?? [], allowsPrimaryKeyEditing: false)
                    .scrollContentBackground(.hidden)
                    .background(Theme.contentBackground)
                Divider()
                HStack {
                    Button { editor.addColumn() } label: { Image(systemName: "plus") }.help("Add column")
                    Button { editor.removeSelectedColumns() } label: { Image(systemName: "minus") }
                        .help("Drop selected columns")
                        .disabled(editor.selectedColumns.isEmpty)
                    Spacer()
                    if editor.hasChanges {
                        Text("Unsaved structure changes").font(.caption).foregroundStyle(.orange)
                        Button("Revert") { editor.revert() }
                        Button("Review & Apply…") { review() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .frame(height: 30)
            }
            .frame(minHeight: 200)

            HStack(alignment: .top, spacing: 0) {
                indexesSection
                Divider()
                constraintsSection
            }
            .frame(minHeight: 160, idealHeight: 240)
            .scrollContentBackground(.hidden)
            .background(Theme.contentBackground)
        }
        .sheet(isPresented: $isAddingIndex) {
            AddIndexSheet(columns: editor.columns.compactMap(\.originalName), table: editor.structure.ref.name) {
                editor.newIndexes.append($0)
            }
        }
        .sheet(isPresented: $isAddingForeignKey) {
            if let workspace = model.workspace {
                AddForeignKeySheet(columns: editor.columns.compactMap(\.originalName), table: editor.structure.ref,
                                   workspace: workspace) { editor.newForeignKeys.append($0) }
            }
        }
    }

    private var indexesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Indexes") { isAddingIndex = true }
            List {
                ForEach(editor.structure.indexes) { index in
                    let dropped = editor.droppedIndexes.contains(index.name)
                    HStack {
                        Image(systemName: index.isPrimary ? "key.fill" : (index.isUnique ? "staroflife" : "list.number"))
                            .foregroundStyle(index.isPrimary ? .yellow : .secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(index.name).strikethrough(dropped)
                            Text("\(index.method) (\(index.columns.joined(separator: ", ")))\(index.isUnique ? " UNIQUE" : "")")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .help(index.definition)
                        Spacer()
                        dropToggle(dropped) {
                            if dropped { editor.droppedIndexes.remove(index.name) } else { editor.droppedIndexes.insert(index.name) }
                        }
                    }
                }
                ForEach(Array(editor.newIndexes.enumerated()), id: \.offset) { offset, index in
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.green).frame(width: 16)
                        Text("\(index.name.isEmpty ? "(auto-named)" : index.name) — \(index.columns.joined(separator: ", "))")
                        Spacer()
                        Button { editor.newIndexes.remove(at: offset) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var constraintsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Constraints") { isAddingForeignKey = true }
            List {
                ForEach(editor.structure.constraints) { constraint in
                    let dropped = editor.droppedConstraints.contains(constraint.name)
                    HStack {
                        Text(constraint.type.displayName)
                            .font(.caption2.bold())
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(constraint.name).strikethrough(dropped)
                            Text(constraint.definition).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        dropToggle(dropped) {
                            if dropped { editor.droppedConstraints.remove(constraint.name) } else { editor.droppedConstraints.insert(constraint.name) }
                        }
                    }
                }
                ForEach(Array(editor.newForeignKeys.enumerated()), id: \.offset) { offset, fk in
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                        Text("FK (\(fk.columns.joined(separator: ", "))) → \(fk.referencedTable.name)(\(fk.referencedColumns.joined(separator: ", ")))")
                        Spacer()
                        Button { editor.newForeignKeys.remove(at: offset) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionHeader(_ title: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button(action: add) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help(title == "Indexes" ? "Add index" : "Add foreign key")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func dropToggle(_ dropped: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: dropped ? "arrow.uturn.backward" : "trash")
        }
        .buttonStyle(.borderless)
        .help(dropped ? "Keep" : "Drop")
    }

    private func review() {
        guard let workspace = model.workspace, let dialect = workspace.dialect else { return }
        let statements = editor.statements(dialect)
        guard !statements.isEmpty else {
            editor.revert()
            return
        }
        workspace.sqlPreview = SQLPreviewRequest(title: "Alter \(model.ref.name)", statements: statements,
                                                 actionTitle: "Apply") { [model] in
            guard await workspace.runStatements(statements) else { return }
            try? await model.loadStructure()
            model.columns = []
            await model.reloadData()
            await workspace.reloadObjects()
        }
    }
}

private struct AddIndexSheet: View {
    var columns: [String]
    var table: String
    var onAdd: (IndexDefinition) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: [String] = []
    @State private var isUnique = false
    @State private var method = "btree"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Index").font(.headline)
            TextField("Name", text: $name, prompt: Text("\(table)_\(selected.joined(separator: "_"))_idx"))
            Picker("Method", selection: $method) {
                ForEach(["btree", "hash", "gin", "gist", "brin"], id: \.self) { Text($0).tag($0) }
            }
            Toggle("Unique", isOn: $isUnique)
            Text("Columns (in order of selection)").font(.caption).foregroundStyle(.secondary)
            List(columns, id: \.self) { column in
                HStack {
                    Image(systemName: selected.contains(column) ? "checkmark.square.fill" : "square")
                    Text(column)
                    Spacer()
                    if let position = selected.firstIndex(of: column) { Text("\(position + 1)").foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let index = selected.firstIndex(of: column) { selected.remove(at: index) } else { selected.append(column) }
                }
            }
            .frame(height: 180)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let fallback = "\(table)_\(selected.joined(separator: "_"))_idx"
                    onAdd(IndexDefinition(name: name.isEmpty ? fallback : name, columns: selected, isUnique: isUnique, method: method))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct AddForeignKeySheet: View {
    var columns: [String]
    var table: ObjectRef
    var workspace: WorkspaceModel
    var onAdd: (ForeignKeyDefinition) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var column = ""
    @State private var referencedTable = ""
    @State private var referencedColumn = ""
    @State private var onUpdate = "NO ACTION"
    @State private var onDelete = "NO ACTION"

    private var tables: [String] {
        workspace.objects.filter { $0.kind == .table }.map(\.name)
    }

    private var referencedColumns: [ColumnInfo] {
        workspace.catalogColumns[referencedTable] ?? []
    }

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("\(table.name)_\(column)_fkey"))
            Picker("Column", selection: $column) {
                ForEach(columns, id: \.self) { Text($0).tag($0) }
            }
            Picker("References table", selection: $referencedTable) {
                ForEach(tables, id: \.self) { Text($0).tag($0) }
            }
            Picker("References column", selection: $referencedColumn) {
                ForEach(referencedColumns) { column in
                    Label(column.name, systemImage: column.isPrimaryKey ? "key.fill" : "line.3.horizontal")
                        .tag(column.name)
                }
            }
            Picker("On update", selection: $onUpdate) {
                ForEach(ForeignKeyDefinition.actions, id: \.self) { Text($0).tag($0) }
            }
            Picker("On delete", selection: $onDelete) {
                ForEach(ForeignKeyDefinition.actions, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(ForeignKeyDefinition(
                        name: name.isEmpty ? "\(table.name)_\(column)_fkey" : name, columns: [column],
                        referencedTable: ObjectRef(schema: workspace.currentSchema, name: referencedTable, kind: .table),
                        referencedColumns: [referencedColumn], onUpdate: onUpdate, onDelete: onDelete))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(column.isEmpty || referencedTable.isEmpty || referencedColumn.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { column = columns.first ?? "" }
        .onChange(of: referencedTable) { _, _ in
            referencedColumn = referencedColumns.first(where: \.isPrimaryKey)?.name ?? referencedColumns.first?.name ?? ""
        }
    }
}

// MARK: - Definition

private struct DefinitionPane: View {
    var model: TableTabModel
    @State private var selection = NSRange()
    @State private var requested: NSRange?

    var body: some View {
        VStack(spacing: 0) {
            SQLEditorView(text: .constant(model.definition ?? "-- Loading…"), selection: $selection,
                          requestedSelection: $requested, isEditable: false)
            Divider()
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.definition ?? "", forType: .string)
                }
                Button("Open in Query Tab") {
                    model.workspace?.newQuery(sql: model.definition ?? "", title: "\(model.ref.name) DDL")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
    }
}
