import DBCore
import SwiftUI

/// Database → Copy Database…: replaces everything in a target database with a copy of a source database.
struct CopyDatabaseView: View {
    @State private var model: CopyDatabaseModel
    @State private var isConfirming = false

    init(request: CompareRequest) {
        _model = State(initialValue: CopyDatabaseModel(request: request))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                SideCard(model: model, side: model.source, title: "Source", caption: "The database to copy")
                Button {
                    Task { await model.swap() }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.ghost)
                .help("Swap source and target")
                .padding(.top, 34)
                .disabled(model.isCopying)
                SideCard(model: model, side: model.target, title: "Target", caption: "Everything in it is replaced")
            }
            .disabled(model.isCopying)

            options
            if model.includeData {
                CopyTablesList(model: model)
            }
            notes
            if !model.includeData { Spacer(minLength: 0) }
            status
            footer
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 640)
        .background(Theme.contentBackground)
        .tint(Theme.accent)
        .navigationTitle("Copy Database")
        .task { await model.start() }
        .onDisappear { Task { await model.close() } }
        .sheet(isPresented: $isConfirming) {
            ConfirmCopySheet(model: model)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $model.includeData) {
                Text("Copy data")
                Text("When off, only the structure is copied and the tables are empty.")
            }
            .accessibilityIdentifier("copy-include-data")
            Toggle(isOn: $model.includePlatformData) {
                Text("Copy rows in platform schemas")
                Text("Such as Supabase's auth.users. When off, those tables keep the target's rows, and foreign keys that point into them don't check existing rows.")
            }
            .disabled(!model.includeData)
            .accessibilityIdentifier("copy-platform-data")
            Toggle(isOn: $model.keepOwnership) {
                Text("Copy owners and privileges")
                Text("When off, the target's user owns everything and no grants are copied. When on, the source's roles must exist on the target server.")
            }
            .accessibilityIdentifier("copy-keep-ownership")
        }
        .disabled(model.isCopying)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DBJoy drops every schema in the target, then copies the source in with pg_dump: schemas, tables, views, materialized views, functions, procedures, types, sequences, triggers, extensions and data. On managed services such as Supabase, schemas that belong to the platform (auth, storage, …) stay as they are. It all runs in one transaction, so if anything fails, the target stays as it was.")
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.sameDatabase {
                Label("Pick two different databases.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Theme.textSecondary)
            }
            if model.targetIsReadOnly {
                Label("The target connection is read-only.", systemImage: "lock")
                    .foregroundStyle(Theme.textSecondary)
            }
            if let warning = model.versionWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .copying:
            TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.progress.step).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(progressDetail(now: context.date))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.callout)
            .accessibilityIdentifier("copy-progress")
        case .done(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "checkmark.circle.fill")
                    .accessibilityIdentifier("copy-result")
                ForEach(model.warnings, id: \.self) { warning in
                    Label(warning.prefix(1).uppercased() + warning.dropFirst(), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .textSelection(.enabled)
        case .failed(let message):
            ScrollView {
                Label {
                    Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .font(.callout)
            }
            .frame(maxHeight: 160)
            .accessibilityIdentifier("copy-result")
        }
    }

    private func progressDetail(now: Date) -> String {
        let elapsed = Duration.seconds(max(0, Int(now.timeIntervalSince(model.startedAt))))
        let time = elapsed.formatted(.time(pattern: .minuteSecond))
        guard model.progress.bytes > 0 else { return time }
        return ByteCountFormatter.string(fromByteCount: model.progress.bytes, countStyle: .file) + " · " + time
    }

    private var footer: some View {
        HStack {
            Spacer()
            if model.isCopying {
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.outline)
                    .help("Stop the copy. The target isn't changed.")
            } else {
                if model.isPlanning { ProgressView().controlSize(.small) }
                Button("Copy to Target…") {
                    Task { if await model.preparePlan() { isConfirming = true } }
                }
                .buttonStyle(.primary)
                .disabled(!model.canCopy || model.isPlanning)
                    .accessibilityIdentifier("copy-start")
            }
        }
    }
}

/// Asks for the target database's name before replacing it.
private struct ConfirmCopySheet: View {
    var model: CopyDatabaseModel
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    private var targetName: String { model.target.config?.displayName ?? "the target" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Replace \(model.target.database) on \(targetName)?")
                    .font(.headline)
                Spacer()
                if let environment = model.target.config?.environment { EnvironmentBadge(environment: environment) }
            }
            Text("Everything in \(model.target.database) is deleted and replaced with a copy of \(model.source.database) from \(model.source.config?.displayName ?? "the source")\(model.includeData ? "" : ", without its data").")
                .fixedSize(horizontal: false, vertical: true)
            if !PlanSummary.sections(model.plan, options: model.options).isEmpty {
                skipped
            }
            Text("Type \(model.target.database) to confirm.")
                .foregroundStyle(Theme.textSecondary)
            TextField(model.target.database, text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
                .accessibilityIdentifier("copy-confirm-name")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Replace", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(typed != model.target.database)
                    .accessibilityIdentifier("copy-confirm")
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// What the copy handles differently, as worked out by the plan.
    private var skipped: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(PlanSummary.sections(model.plan, options: model.options), id: \.title) { section in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.title)
                            .font(.callout.weight(.semibold))
                        ForEach(section.lines, id: \.self) { line in
                            Text("• " + line)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 280)
        .fixedSize(horizontal: false, vertical: true)
        .font(.callout)
        .foregroundStyle(Theme.textSecondary)
        .accessibilityIdentifier("copy-skipped")
    }

    private func confirm() {
        guard typed == model.target.database else { return }
        dismiss()
        model.copy()
    }
}

/// The plan in words, for the confirmation.
enum PlanSummary {
    struct Section {
        var title: String
        var lines: [String]
    }

    static func sections(_ plan: DatabaseCopier.Plan, options: DatabaseCopier.Options) -> [Section] {
        let rows = options.includeData, platformRows = options.copiesPlatformRows
        let copiedPlatformTables = options.platformRows(plan)
        var sections: [Section] = []
        var kept: [String] = []
        let byReason = Dictionary(grouping: plan.skippedSchemas, by: \.reason)
        for reason in byReason.keys.sorted() {
            kept.append("Schemas that \(reason.replacingOccurrences(of: "belongs", with: "belong").replacingOccurrences(of: "holds", with: "hold").replacingOccurrences(of: "isn't", with: "aren't")): "
                + list(byReason[reason]!.map(\.schema)))
        }
        if !plan.skippedExtensions.isEmpty {
            kept.append("Extensions that belong to another role: " + list(plan.skippedExtensions))
        }
        if rows, !platformRows, !plan.platformTables.isEmpty {
            kept.append("The rows in those schemas, such as " + list(plan.platformTables.map(\.description), limit: 3))
        }
        if rows, !platformRows, !plan.foreignKeysIntoPlatform.isEmpty {
            kept.append("Foreign keys into them don't check the copied rows: " + list(plan.foreignKeysIntoPlatform, limit: 3))
        }
        if !kept.isEmpty { sections.append(Section(title: "Kept as they are in the target", lines: kept)) }

        var copied: [String] = []
        if !copiedPlatformTables.isEmpty {
            copied.append("Rows of \(count(copiedPlatformTables.count, "table")): " + list(copiedPlatformTables.map(\.description)))
        }
        let triggers = plan.platformTriggers.count, policies = plan.platformPolicies.count
        if triggers + policies > 0 {
            copied.append([triggers > 0 ? count(triggers, "trigger") : nil, policies > 0 ? count(policies, "policy", "policies") : nil]
                .compactMap { $0 }.joined(separator: " and ") + " on their tables, replacing the target's")
        }
        if !copied.isEmpty { sections.append(Section(title: "Copied into those schemas", lines: copied)) }

        if !plan.clearedSchemas.isEmpty {
            sections.append(Section(title: "Emptied instead of dropped", lines: plan.clearedSchemas.map {
                "\($0): it holds another role's objects (such as an extension), which stay"
            }))
        }

        var skipped: [String] = []
        if rows, !options.tablesWithoutData.isEmpty {
            let names = options.tablesWithoutData.map(\.description).sorted()
            skipped.append("Data of the tables you unchecked, which are created empty: " + list(names)
                + ". Foreign keys into them don't check the copied rows")
        }
        if rows, !plan.skippedTableData.isEmpty {
            skipped.append("Rows of extension tables: " + list(plan.skippedTableData.map(\.description)))
        }
        if platformRows, plan.skippedSchemaNames.contains(where: DatabaseCopier.platformSchemasWithoutData.contains) {
            skipped.append("Rows in storage: the files themselves live outside the database")
        }
        if !plan.skippedEventTriggers.isEmpty {
            skipped.append("Event triggers: " + list(plan.skippedEventTriggers))
        }
        if !plan.copiesPublications {
            skipped.append("Publications, because the target's " + list(plan.keptPublications) + " belong to another role")
        }
        if !skipped.isEmpty { sections.append(Section(title: "Not copied", lines: skipped)) }
        return sections
    }

    private static func list(_ items: [String], limit: Int = 6) -> String {
        items.count <= limit ? items.joined(separator: ", ")
            : items.prefix(limit).joined(separator: ", ") + " and \(items.count - limit) more"
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
    }
}

/// The source's tables, with a checkbox for whether their rows are copied.
private struct CopyTablesList: View {
    @Bindable var model: CopyDatabaseModel
    @State private var filter = ""
    @State private var sortOrder = [KeyPathComparator(\DatabaseCopier.Plan.TableSize.bytes, order: .reverse)]

    private var platform: Set<DatabaseCopier.Plan.Table> { Set(model.plan.platformTables) }

    private var tables: [DatabaseCopier.Plan.TableSize] {
        let all = model.dataTables
        let shown = filter.isEmpty ? all : all.filter { $0.table.description.localizedCaseInsensitiveContains(filter) }
        return shown.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(title: "Tables")
                    .fixedSize()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 180)
                Button("All") { model.setCopiesRows(true, of: tables.map(\.table)) }
                    .controlSize(.small)
                    .help(filter.isEmpty ? "Copy the data of every table" : "Copy the data of the tables shown")
                Button("None") { model.setCopiesRows(false, of: tables.map(\.table)) }
                    .controlSize(.small)
                    .help(filter.isEmpty ? "Copy every table without data" : "Copy the tables shown without data")
            }
            Text("Every table's structure is copied. The Data checkbox decides whether its rows come too: unchecked tables are created empty.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            content
                .frame(minHeight: 180, maxHeight: .infinity)
        }
        .disabled(model.isCopying)
    }

    @ViewBuilder private var content: some View {
        if let error = model.planError, !model.hasPlan {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.hasPlan {
            Text(model.source.session != nil && model.target.session != nil && !model.sameDatabase
                 ? "Reading the tables…" : "Pick a source and a target to choose which tables' rows to copy.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(tables, sortOrder: $sortOrder) {
                TableColumn("Data") { (item: DatabaseCopier.Plan.TableSize) in
                    Toggle("Copy the rows of \(item.table.description)", isOn: Binding(
                        get: { model.copiesRows(of: item.table) },
                        set: { model.setCopiesRows($0, of: [item.table]) }))
                        .labelsHidden()
                        .accessibilityIdentifier("copy-rows-\(item.table.description)")
                        .help(platform.contains(item.table)
                              ? "Copy this table's rows. When off, the table keeps the target's rows"
                              : "Copy this table's rows. When off, the table is created empty")
                }
                .width(44)
                TableColumn("Table", value: \.table.description) { item in
                    HStack(spacing: 6) {
                        Text(item.table.description)
                        if platform.contains(item.table) {
                            Text("platform").font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                TableColumn("Rows", value: \.sortableRows) { item in
                    Text(item.rows.map { $0.formatted(.number.notation(.compactName)) } ?? "unknown")
                        .monospacedDigit()
                        .foregroundStyle(item.rows == nil ? Theme.textTertiary : Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help("Postgres's estimate")
                }
                .width(90)
                TableColumn("Size", value: \.bytes) { item in
                    Text(Self.size(item.bytes))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(90)
            }
            .accessibilityIdentifier("copy-tables")
        }
    }

    private var summary: String {
        let all = model.dataTables
        guard model.hasPlan, !all.isEmpty else { return "" }
        let copied = all.filter { model.copiesRows(of: $0.table) }
        let size = { (tables: [DatabaseCopier.Plan.TableSize]) in
            Self.size(tables.reduce(0) { $0 + $1.bytes })
        }
        return "Data of \(copied.count) of \(all.count) tables, \(size(copied)) of \(size(all))"
    }
}

private extension CopyTablesList {
    /// "0 bytes" rather than "Zero KB".
    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}

private extension DatabaseCopier.Plan.TableSize {
    var sortableRows: Int64 { rows ?? -1 }
}
