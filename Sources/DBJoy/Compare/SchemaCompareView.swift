import DBCore
import SwiftUI

/// Database → Compare Schemas…: shows how a schema differs between two databases and builds
/// (and optionally runs) the migration that makes the target match the source.
struct SchemaCompareView: View {
    @State private var model: SchemaCompareModel
    @Environment(\.openWindow) private var openWindow
    @State private var isConfirmingRun = false

    init(request: CompareRequest) {
        _model = State(initialValue: SchemaCompareModel(request: request))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.phase == .compared || model.phase == .running, !model.changes.isEmpty {
                Divider()
                footer
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Theme.contentBackground)
        .tint(Theme.accent)
        .navigationTitle("Compare Schemas")
        .task { await model.start() }
        .onDisappear { Task { await model.close() } }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(runTitle, isPresented: $isConfirmingRun) {
            Button("Run", role: .destructive) { Task { await model.run() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(runMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                SideCard(model: model, side: model.source, title: "Source", caption: "Has the schema you want")
                Button {
                    Task { await model.swap() }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.ghost)
                .help("Swap source and target")
                .accessibilityIdentifier("compare-swap")
                .padding(.top, 34)
                .disabled(model.phase == .comparing || model.phase == .running)
                SideCard(model: model, side: model.target, title: "Target", caption: "The database the migration changes")
            }
            HStack(spacing: 10) {
                Text("Schema").foregroundStyle(Theme.textSecondary)
                Picker("Schema", selection: Binding(get: { model.schema }, set: { model.schema = $0; model.reset() })) {
                    if model.source.schemas.isEmpty, !model.schema.isEmpty { Text(model.schema).tag(model.schema) }
                    ForEach(model.source.schemas, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
                .accessibilityIdentifier("compare-schema")
                if model.sameDatabase {
                    Label("Pick two different databases.", systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if model.phase == .comparing { ProgressView().controlSize(.small) }
                Button(model.phase == .compared ? "Compare Again" : "Compare") {
                    Task { await model.compare() }
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canCompare)
                .accessibilityIdentifier("compare-run")
            }
        }
        .padding(16)
    }

    // MARK: Results

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            ContentUnavailableView {
                Label("Compare two databases", systemImage: "arrow.left.arrow.right.square")
            } description: {
                Text("Pick a source and a target, then compare. DBJoy lists what differs in the schema and writes the SQL that makes the target match the source. Nothing runs until you choose to.")
            }
        case .comparing where model.changes.isEmpty:
            ProgressView("Comparing \(model.schema)…")
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't compare", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            }
        default:
            if model.changes.isEmpty {
                ContentUnavailableView {
                    Label("The schemas match", systemImage: "checkmark.circle")
                } description: {
                    Text(model.notice ?? "No differences in \(model.schema): \(model.comparedTitle).")
                }
            } else {
                HSplitView {
                    ChangeList(model: model)
                        .frame(minWidth: 340, idealWidth: 420, maxHeight: .infinity)
                    ChangeDetail(model: model)
                        .frame(minWidth: 380, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: Footer

    private var destructiveCount: Int { model.includedChanges.filter(\.isDestructive).count }

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.includedChanges.count) of \(model.actionableChanges.count) changes · \(model.statements.count) statements")
                    .font(.callout)
                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(Theme.textSecondary)
                } else if destructiveCount > 0 {
                    Text("\(destructiveCount) included change\(destructiveCount == 1 ? "" : "s") delete\(destructiveCount == 1 ? "s" : "") data")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Group {
                Button("Copy SQL") { model.copyScript() }
                Button("Save…") { model.saveScript() }
                Button("Open in Query Tab") {
                    model.openInQueryTab { openWindow(id: "workspace", value: $0) }
                }
                .help("Open the script in a query tab on the target, to edit or run it yourself")
            }
            .buttonStyle(.outline)
            .disabled(model.statements.isEmpty)
            Button("Run on Target…") { isConfirmingRun = true }
                .buttonStyle(.primary)
                .disabled(model.statements.isEmpty || model.targetIsReadOnly || model.phase == .running)
                .help(model.targetIsReadOnly ? "The target connection is read-only." : "Run the migration in one transaction")
                .accessibilityIdentifier("compare-apply")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var runTitle: String {
        let name = model.target.config?.displayName ?? "the target"
        if model.target.config?.environment.requiresWriteConfirmation == true {
            return "Run the migration on PRODUCTION (\(name))?"
        }
        return "Run the migration on \(name)?"
    }

    private var runMessage: String {
        var lines = ["\(model.statements.count) statements run on \(model.target.database) in one transaction. If one fails, nothing changes."]
        if destructiveCount > 0 {
            lines.append("\(destructiveCount) of the changes delete data: "
                + model.includedChanges.filter(\.isDestructive).map(\.object).joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n\n")
    }
}

/// Picks one side's connection and database.
private struct SideCard: View {
    var model: SchemaCompareModel
    var side: CompareSide
    var title: String
    var caption: String
    @State private var password = ""
    private var store: ConnectionStore { .shared }

    private var connections: [ConnectionConfig] {
        store.connections.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(title: title)
                    .fixedSize()
                Text(caption).font(.caption).foregroundStyle(Theme.textTertiary)
                Spacer()
                if let config = side.config { EnvironmentBadge(environment: config.environment) }
            }
            HStack(spacing: 8) {
                Picker("Connection", selection: Binding(get: { side.connectionID }, set: { id in
                    Task { side === model.source ? await model.selectSource(id) : await model.selectTarget(id) }
                })) {
                    Text("Choose a connection…").tag(UUID?.none)
                    ForEach(connections) { config in
                        Label { Text(config.displayName) } icon: { config.environment.swatch }
                            .tag(UUID?.some(config.id))
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("compare-\(title.lowercased())-connection")
                Picker("Database", selection: Binding(get: { side.database }, set: { name in
                    Task { await model.selectDatabase(name, on: side) }
                })) {
                    if side.databases.isEmpty { Text(side.database.isEmpty ? "Database" : side.database).tag(side.database) }
                    ForEach(side.databases, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
                .disabled(side.state != .ready)
                .accessibilityIdentifier("compare-\(title.lowercased())-database")
            }
            status
                .frame(minHeight: 22, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border, lineWidth: 1))
    }

    @ViewBuilder private var status: some View {
        switch side.state {
        case .empty:
            Text(" ").font(.caption)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Connecting…").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        case .ready:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        case .needsPassword(let message):
            HStack(spacing: 6) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(submit)
                Button("Connect", action: submit).controlSize(.small)
            }
            .help(message ?? "This connection doesn't save its password.")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
                .textSelection(.enabled)
        }
    }

    private func submit() {
        let value = password
        password = ""
        Task { await model.submitPassword(value, on: side) }
    }
}

/// The differences, grouped by what the migration does with them.
private struct ChangeList: View {
    @Bindable var model: SchemaCompareModel

    private var sections: [(kind: SchemaChange.Kind, title: String, changes: [SchemaChange])] {
        [(.added, "Only in source · created", model.changes.filter { $0.kind == .added }),
         (.changed, "Different · altered", model.changes.filter { $0.kind == .changed }),
         (.removed, "Only in target · dropped", model.changes.filter { $0.kind == .removed })]
            .filter { !$0.changes.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.changes.count) difference\(model.changes.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("All") { model.includeAll(true) }
                Button("None") { model.includeAll(false) }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            List(selection: $model.selectedChangeID) {
                ForEach(sections, id: \.kind) { section in
                    Section {
                        ForEach(section.changes) { change in
                            ChangeRow(model: model, change: change).tag(change.id)
                        }
                    } header: {
                        SectionLabel(title: section.title, trailing: "\(section.changes.count)")
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("compare-changes")
        }
    }
}

private struct ChangeRow: View {
    var model: SchemaCompareModel
    var change: SchemaChange

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { model.included.contains(change.id) }, set: { model.setIncluded($0, for: change) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(change.steps.isEmpty)
                .help(change.steps.isEmpty ? "Can't be migrated automatically" : "Include in the migration")
            Image(systemName: change.symbol)
                .foregroundStyle(change.kind.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.object)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(change.objectType) · \(change.summary)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if change.isDestructive {
                Text("DELETES DATA")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.red.opacity(0.5), lineWidth: 1))
            } else if change.warning != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(change.warning ?? "")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The selected change side by side, or the whole migration script.
private struct ChangeDetail: View {
    var model: SchemaCompareModel
    @State private var tab: Tab = .change
    @State private var script = ""
    @State private var selection = NSRange()
    @State private var requested: NSRange?

    enum Tab: Hashable { case change, script }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UnderlineTabs(items: [(.change, "Change"), (.script, "Migration SQL (\(model.statements.count))")], selection: $tab)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            Divider().padding(.top, 2)
            switch tab {
            case .change:
                if let change = model.selectedChange {
                    ScrollView { ChangeDetailBody(change: change).padding(16) }
                } else {
                    ContentUnavailableView("Select a difference", systemImage: "sidebar.left",
                                           description: Text("See both definitions and the SQL that migrates it."))
                }
            case .script:
                SQLEditorView(text: $script, selection: $selection, requestedSelection: $requested, isEditable: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { script = model.script }
        .onChange(of: model.statements) { script = model.script }
        .onChange(of: model.selectedChangeID) { if model.selectedChangeID != nil { tab = .change } }
    }
}

private struct ChangeDetailBody: View {
    var change: SchemaChange

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(change.objectType) \(change.object)").font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(change.summary).foregroundStyle(Theme.textSecondary)
            }
            if change.isDestructive {
                callout("This change deletes data in the target. It starts unchecked.", systemImage: "trash", color: .red)
            }
            if let warning = change.warning {
                callout(warning, systemImage: "exclamationmark.triangle", color: .orange)
            }
            if change.sourceDefinition != nil || change.targetDefinition != nil {
                HStack(alignment: .top, spacing: 12) {
                    definition("In source", change.sourceDefinition)
                    definition("In target", change.targetDefinition)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(title: "Migration SQL")
                if change.steps.isEmpty {
                    Text("Nothing to run: this needs a manual change.").foregroundStyle(Theme.textSecondary)
                } else {
                    code(change.steps.map(\.sql).joined(separator: "\n"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func definition(_ title: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: title)
            if let text {
                code(text)
            } else {
                Text("Doesn't exist").font(.callout).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func callout(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

private extension SchemaChange {
    var symbol: String {
        switch kind {
        case .added: "plus.circle.fill"
        case .removed: "minus.circle.fill"
        case .changed: "pencil.circle.fill"
        }
    }
}

private extension SchemaChange.Kind {
    var color: Color {
        switch self {
        case .added: .green
        case .removed: .red
        case .changed: .orange
        }
    }
}
