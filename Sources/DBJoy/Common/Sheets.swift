import DBCore
import SwiftUI

/// Shows generated SQL for review before it runs.
struct SQLPreviewSheet: View {
    var request: SQLPreviewRequest
    var environment: ConnectionEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selection = NSRange()
    @State private var requested: NSRange?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(request.title).font(.headline)
                Spacer()
                if environment.requiresWriteConfirmation { EnvironmentBadge(environment: environment) }
            }
            Text("\(request.statements.count) statement(s) will run in a single transaction and roll back on any error.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SQLEditorView(text: $text, selection: $selection, requestedSelection: $requested, isEditable: false)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button("Copy SQL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.actionTitle) {
                    dismiss()
                    Task { await request.action() }
                }
                .keyboardShortcut(.defaultAction)
                .tint(environment.requiresWriteConfirmation ? .red : nil)
            }
        }
        .padding(20)
        .frame(width: 680, height: 440)
        .onAppear { text = request.statements.joined(separator: "\n") }
    }
}

/// ⌘P: jump to any table, view or function across schemas.
struct QuickOpenView: View {
    var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var matches: [SchemaObject] {
        let source = model.allObjects.isEmpty ? model.objects : model.allObjects
        guard !query.isEmpty else { return Array(source.prefix(100)) }
        let lower = query.lowercased()
        return source.filter { fuzzyMatch(query, $0.name) || fuzzyMatch(query, "\($0.ref.schema).\($0.name)") }
            .sorted { a, b in
                let aScore = a.name.lowercased().hasPrefix(lower) ? 0 : (a.name.lowercased().contains(lower) ? 1 : 2)
                let bScore = b.name.lowercased().hasPrefix(lower) ? 0 : (b.name.lowercased().contains(lower) ? 1 : 2)
                return aScore != bScore ? aScore < bScore : a.name.count < b.name.count
            }
            .prefix(100).map { $0 }
    }

    var body: some View {
        let matches = matches
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Open table, view or function…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { open(matches) }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(matches.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List(Array(matches.enumerated()), id: \.element.id) { index, object in
                    HStack {
                        Image(systemName: object.kind.systemImage).frame(width: 18)
                        Text(object.name)
                        Text(object.ref.schema).foregroundStyle(.secondary)
                        Spacer()
                        Text(object.kind.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(index == selected ? Color.accentColor.opacity(0.2) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selected = index
                        open(matches)
                    }
                    .id(index)
                }
                .listStyle(.plain)
                .onChange(of: selected) { _, index in proxy.scrollTo(index) }
            }
        }
        .frame(width: 560, height: 420)
        .onChange(of: query) { _, _ in selected = 0 }
        .task {
            focused = true
            await model.loadAllObjects()
        }
    }

    private func open(_ matches: [SchemaObject]) {
        guard selected < matches.count else { return }
        let object = matches[selected]
        dismiss()
        model.open(object.ref)
    }
}

/// Editable column list shared by the structure editor and the create-table sheet.
struct ColumnsEditor: View {
    @Binding var columns: [ColumnDefinition]
    @Binding var selection: Set<ColumnDefinition.ID>
    var dataTypes: [String]
    var allowsPrimaryKeyEditing: Bool

    var body: some View {
        Table($columns, selection: $selection) {
            TableColumn("Name") { $column in
                TextField("", text: $column.name).textFieldStyle(.plain)
                    .foregroundStyle(column.originalName == nil ? Color.green : Color.primary)
            }
            .width(min: 100, ideal: 160)
            TableColumn("Type") { $column in
                HStack(spacing: 2) {
                    TextField("", text: $column.dataType).textFieldStyle(.plain).font(.body.monospaced())
                    Menu {
                        ForEach(dataTypes, id: \.self) { type in Button(type) { column.dataType = type } }
                    } label: { EmptyView() }
                        .menuStyle(.borderlessButton)
                        .frame(width: 16)
                }
            }
            .width(min: 120, ideal: 190)
            TableColumn("Null") { $column in
                Toggle("", isOn: $column.isNullable).labelsHidden()
            }
            .width(40)
            TableColumn("Default") { $column in
                TextField("", text: $column.defaultValue, prompt: Text("none")).textFieldStyle(.plain).font(.body.monospaced())
            }
            .width(min: 100, ideal: 170)
            TableColumn("Key") { $column in
                if allowsPrimaryKeyEditing {
                    Toggle("", isOn: $column.isPrimaryKey).labelsHidden()
                } else if column.isPrimaryKey {
                    Image(systemName: "key.fill").foregroundStyle(.yellow)
                }
            }
            .width(36)
            TableColumn("Comment") { $column in
                TextField("", text: $column.comment).textFieldStyle(.plain)
            }
        }
    }
}

struct CreateTableSheet: View {
    @Bindable var model: CreateTableModel
    var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    private var existingTables: Set<String> {
        let objects = model.schema == workspace.currentSchema ? workspace.objects : workspace.allObjects
        return Set(objects.filter { $0.ref.schema == model.schema && $0.kind.hasRows }.map(\.name))
    }

    var body: some View {
        let problem = model.validationMessage(existingTables: existingTables)
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Table").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    HStack(spacing: 8) {
                        TextField("Table name", text: $model.name, prompt: Text("e.g. invoices"))
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                        Picker("Schema", selection: $model.schema) {
                            ForEach(workspace.schemas, id: \.self) { Text($0).tag($0) }
                        }
                        .fixedSize()
                    }
                }
                GridRow {
                    Text("Comment")
                    TextField("Comment", text: $model.comment, prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            ColumnsEditor(columns: $model.columns, selection: $model.selectedColumns,
                          dataTypes: workspace.dialect?.dataTypes ?? [], allowsPrimaryKeyEditing: true)
            Text("Defaults: plain text like pending is saved as a string; now(), 0, true or 'quoted' are used as SQL.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button { model.columns.append(ColumnDefinition(name: "column_\(model.columns.count + 1)")) } label: {
                    Image(systemName: "plus")
                }
                .help("Add column")
                Button {
                    model.columns.removeAll { model.selectedColumns.contains($0.id) }
                } label: { Image(systemName: "minus") }
                    .disabled(model.selectedColumns.isEmpty)
                    .help("Remove selected columns")
                Spacer()
                if let problem {
                    Label(problem, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("create-table-cancel")
                Button("Review & Create…") { review() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
                    .help(problem ?? "Review the CREATE TABLE statement before running it")
            }
        }
        .padding(20)
        .frame(width: 820, height: 500)
        .onAppear { nameFocused = true }
        .task { await workspace.loadAllObjects() }
    }

    private func review() {
        guard let dialect = workspace.dialect else { return }
        let request = model.request
        let statements = dialect.statements(for: request)
        dismiss()
        workspace.sqlPreview = SQLPreviewRequest(title: "Create \(request.schema).\(request.name)", statements: statements,
                                                 actionTitle: "Create Table") { [workspace] in
            guard await workspace.runStatements(statements) else { return }
            if request.schema == workspace.currentSchema { await workspace.reloadObjects() }
            workspace.open(ObjectRef(schema: request.schema, name: request.name, kind: .table), mode: .structure)
        }
    }
}
