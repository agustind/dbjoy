import DBCore
import SwiftUI
import UniformTypeIdentifiers

struct QueryTabView: View {
    @Bindable var model: QueryTabModel
    var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: model.title,
                       subtitle: model.fileURL.map { "\($0.deletingLastPathComponent().lastPathComponent)/ · \(workspace.currentDatabase)" }
                           ?? "SQL · \(workspace.currentDatabase)",
                       showsToolbar: false) {
                if model.savedQueryID != nil {
                    Image(systemName: "bookmark.fill").font(.system(size: 12)).foregroundStyle(Theme.accentText)
                        .help("Saved query")
                }
                transactionBadge
            } trailing: {
                Button { workspace.openSQLFiles() } label: { Label("Open file…", systemImage: "doc.text") }
                    .buttonStyle(.outline)
                    .help("Open a .sql file in the editor, optionally running it (⌘O)")
                transactionControls
                Button { model.isSaveSheetPresented = true } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.outline)
                    .help("Save query (⌘S)")
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Button { model.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.primary)
                        .help("Cancel the running query (⌘.)")
                } else {
                    Button { if !model.formatSQL() { NSSound.beep() } } label: { Label("Format", systemImage: "text.alignleft") }
                        .buttonStyle(.outline)
                        .help("Format the selection or the statement under the cursor (⌘I)")
                    Button { model.explain() } label: { Label("Explain", systemImage: "list.bullet.indent") }
                        .buttonStyle(.outline)
                        .help("Show how the database runs the statement under the cursor (⌥⌘↩)")
                    Button { model.run(.all) } label: { Label("Run all", systemImage: "forward.end.fill") }
                        .buttonStyle(.outline)
                        .help("Run the whole editor (⇧⌘↩)")
                        .accessibilityIdentifier("run-all")
                    Button { model.run(.current) } label: {
                        Label(model.selection.length > 0 ? "Run selection" : "Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.primary)
                    .help("Run the selection or the statement under the cursor (⌘↩)")
                    .accessibilityIdentifier("run-current")
                }
            } toolbar: {
                EmptyView()
            }

            GeometryReader { geometry in
                let editorHeight = max(80, min(geometry.size.height - 160, geometry.size.height * model.editorFraction))
                VStack(spacing: 0) {
                    SQLEditorView(text: $model.sql, selection: $model.selection, requestedSelection: $model.requestedSelection,
                                  requestedReplacement: $model.requestedReplacement,
                                  catalog: { workspace.completionCatalog }, onRun: { model.run($0) })
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
                        .frame(height: editorHeight)

                    SplitHandle { translation in
                        let proposed = (editorHeight + translation) / max(geometry.size.height, 1)
                        model.editorFraction = min(max(proposed, 0.12), 0.85)
                    }

                    ResultsPane(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(Theme.contentBackground)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL }
            for url in files { workspace.openSQLFile(url, run: false) }
            return !files.isEmpty
        }
        .sheet(isPresented: $model.isSaveSheetPresented) {
            SaveQuerySheet(model: model)
        }
    }

    @ViewBuilder private var transactionBadge: some View {
        switch model.transactionStatus {
        case .inTransaction, .failedTransaction:
            let failed = model.transactionStatus == .failedTransaction
            Label(failed ? "Transaction failed" : "In transaction",
                  systemImage: failed ? "exclamationmark.triangle.fill" : "circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(failed ? Color.red : Color.orange)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background((failed ? Color.red : Color.orange).opacity(0.14), in: Capsule())
                .help(failed ? "A statement failed. Roll back to continue." : "Changes are not visible to others until you commit.")
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var transactionControls: some View {
        switch model.transactionStatus {
        case .inTransaction, .failedTransaction:
            if model.transactionStatus == .inTransaction {
                Button { model.commitTransaction() } label: { Label("Commit", systemImage: "checkmark") }
                    .buttonStyle(.outline(active: true))
            }
            Button { model.rollback() } label: { Label("Rollback", systemImage: "arrow.uturn.backward") }
                .buttonStyle(.outline)
        default:
            Button { model.begin() } label: { Label("Begin", systemImage: "arrow.triangle.branch") }
                .buttonStyle(.outline)
                .help("Start a transaction. Run statements, then Commit or Rollback.")
                .disabled(model.isRunning)
        }
    }
}

/// Draggable divider between the editor and results.
private struct SplitHandle: View {
    var onDrag: (CGFloat) -> Void
    @State private var lastTranslation: CGFloat = 0
    @State private var isHovering = false

    var body: some View {
        Capsule()
            .fill(isHovering ? Theme.textTertiary : Theme.border)
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .contentShape(Rectangle())
            .onHover { inside in
                isHovering = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    onDrag(value.translation.height - lastTranslation)
                    lastTranslation = value.translation.height
                }
                .onEnded { _ in lastTranslation = 0 })
    }
}

private struct ResultsPane: View {
    @Bindable var model: QueryTabModel
    @State private var selectedRows = IndexSet()
    @State private var pane = Pane.results
    @State private var sort: SortKey?
    /// Result row indices in display order while sorted.
    @State private var order: [Int]?
    @State private var gridVersion = 0
    @State private var showsDetails = false
    @State private var copiedForAI = false
    @State private var exportError: String?

    private enum Pane: Hashable { case results, messages, plan }

    private static let messagesKey = "messages"
    private static let planKey = "plan"

    private var tabItems: [(value: String, title: String)] {
        var items = model.results.enumerated().map { index, result in
            (value: result.id.uuidString,
             title: model.results.count == 1 ? "Results" : "Result \(index + 1)")
        }
        items.append((value: Self.messagesKey, title: model.messages.isEmpty ? "Messages" : "Messages (\(model.messages.count))"))
        if model.plan != nil { items.append((value: Self.planKey, title: "Plan")) }
        return items
    }

    private var tabSelection: Binding<String> {
        Binding(
            get: {
                switch visiblePane {
                case .plan: Self.planKey
                case .messages: Self.messagesKey
                case .results: model.selectedResult!.id.uuidString
                }
            },
            set: { value in
                switch value {
                case Self.messagesKey: pane = .messages
                case Self.planKey: pane = .plan
                default:
                    pane = .results
                    model.selectedResultID = UUID(uuidString: value)
                }
            })
    }

    /// The pane to show, falling back to messages when the chosen one has nothing.
    private var visiblePane: Pane {
        switch pane {
        case .results where model.selectedResult == nil: .messages
        case .plan where model.plan == nil: .messages
        default: pane
        }
    }

    private var errorMessage: QueryMessage? { model.messages.last(where: { $0.kind == .error }) }

    /// Selected rows as result row indices, in display order.
    private var selectedResultRows: [Int] {
        selectedRows.map { order?[$0] ?? $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                UnderlineTabs(items: tabItems, selection: tabSelection)
                Spacer()
                status
                actions
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Rectangle().fill(Theme.separator).frame(height: 1)

            switch visiblePane {
            case .messages:
                if model.messages.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "play.circle").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.accent)
                        Text("Run a query").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("⌘↩ runs the statement under the cursor, ⇧⌘↩ runs everything.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    messages
                }
            case .plan:
                if let plan = model.plan { PlanView(plan: plan) }
            case .results:
                if let result = model.selectedResult {
                    HStack(spacing: 0) {
                        DataGridView(columns: result.columns, rowCount: result.rows.count, version: gridVersion,
                                     value: { row, column in
                                         (CellValue(result.rows[order?[row] ?? row][column]), .normal)
                                     },
                                     sort: sort.map { [$0] } ?? [],
                                     selection: $selectedRows,
                                     actions: GridActions(sort: { toggleSort($0, in: result) },
                                                          copyForAI: { rows in markdown(result, rows: rows) }))
                            .id(result.id)
                        if showsDetails {
                            Rectangle().fill(Theme.separator).frame(width: 1)
                            ResultRowDetails(result: result, rows: selectedResultRows)
                                .frame(width: 310)
                        }
                    }
                }
            }
        }
        .background(Theme.contentBackground)
        .onChange(of: model.messages) { _, messages in
            // Each run picks its view: the data table for row results, messages for errors
            // or statements that return no rows.
            pane = messages.contains { $0.kind == .error } || model.selectedResult == nil ? .messages : .results
        }
        .onChange(of: model.planRequest) { _, _ in pane = .plan }
        .onChange(of: model.selectedResult?.id) { _, _ in
            selectedRows = []
            sort = nil
            order = nil
            gridVersion += 1
        }
        .alert("Couldn't export the results", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: Header

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            if visiblePane == .plan, let plan = model.plan {
                Text(plan.isAnalyzed ? "Measured by running the query" : "Estimated, not run")
                    .foregroundStyle(Theme.textSecondary)
                if let time = plan.executionTime {
                    Text(String(format: "%.1f ms", time)).foregroundStyle(Theme.textTertiary)
                }
            } else {
                if let error = errorMessage {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(error.text.components(separatedBy: "\n").first ?? "").lineLimit(1).help(error.text)
                        .foregroundStyle(Theme.textPrimary)
                } else if let result = model.selectedResult {
                    Text("\(result.rows.count.formatted()) row(s)\(result.truncated ? " (truncated)" : "")")
                        .foregroundStyle(Theme.textSecondary)
                }
                if let duration = model.lastDuration {
                    Text(formatDuration(duration)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .font(.system(size: 12))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            switch visiblePane {
            case .results:
                if let result = model.selectedResult {
                    Button { showsDetails.toggle() } label: { Image(systemName: "sidebar.right") }
                        .buttonStyle(.ghost(active: showsDetails))
                        .help("Row details")
                    Menu {
                        Button("CSV…") { export(result, as: .csv) }
                        Button("JSON…") { export(result, as: .json) }
                    } label: { Image(systemName: "square.and.arrow.up") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .help("Export these rows to a file")
                    Button { copyForAI(result) } label: {
                        Label(copiedForAI ? "Copied" : "Copy for AI", systemImage: copiedForAI ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.ghost)
                    .help(selectedRows.isEmpty
                          ? "Copy the query and its rows as Markdown to paste into an AI chat"
                          : "Copy the query and the selected rows as Markdown to paste into an AI chat")
                    Button { askAboutResult(result) } label: { Label("Ask AI", systemImage: "sparkles") }
                        .buttonStyle(.ghost)
                        .help(selectedRows.isEmpty ? "Ask the assistant about these rows" : "Ask the assistant about the selected rows")
                }
            case .messages:
                if errorMessage != nil, model.lastRunSQL != nil {
                    Button { fixWithAI() } label: { Label("Fix with AI", systemImage: "sparkles") }
                        .buttonStyle(.ghost)
                        .help("Ask the assistant why this failed and for a corrected query")
                }
            case .plan:
                Button { explainWithAI() } label: { Label("Explain with AI", systemImage: "sparkles") }
                    .buttonStyle(.ghost)
                    .help("Ask the assistant where the time goes and how to speed up the query")
            }
        }
        .font(.system(size: 12))
    }

    // MARK: Sorting

    private func toggleSort(_ column: String, in result: QueryResult) {
        guard let index = result.columns.firstIndex(where: { $0.name == column }) else { return }
        if let sort, sort.column == column {
            self.sort = sort.ascending ? SortKey(column: column, ascending: false) : nil
        } else {
            sort = SortKey(column: column)
        }
        let selected = Set(selectedResultRows)
        order = sort.map { result.rowOrder(sortedBy: index, ascending: $0.ascending) }
        // Keep the same rows selected at their new positions.
        selectedRows = IndexSet((order ?? Array(result.rows.indices)).enumerated().compactMap { selected.contains($1) ? $0 : nil })
        gridVersion += 1
    }

    // MARK: AI

    private func markdown(_ result: QueryResult, rows: IndexSet? = nil) -> String {
        let displayRows = rows ?? selectedRows
        return ExportEncoding.markdownForAI(result, rowIndices: displayRows.isEmpty ? nil : displayRows.map { order?[$0] ?? $0 },
                                            order: order, databaseKind: model.workspace?.config.kind ?? .postgres,
                                            database: model.workspace?.currentDatabase ?? "")
    }

    private func copyForAI(_ result: QueryResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(result), forType: .string)
        copiedForAI = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedForAI = false
        }
    }

    private func askAboutResult(_ result: QueryResult) {
        let count = selectedRows.isEmpty ? result.rows.count : selectedRows.count
        let title = "\(selectedRows.isEmpty ? "Query result" : "Selected rows"): \(count) row\(count == 1 ? "" : "s")"
        model.workspace?.askAssistant(attaching: .init(kind: "rows", title: title, text: markdown(result)))
    }

    private func fixWithAI() {
        guard let error = errorMessage, let sql = model.lastRunSQL, let workspace = model.workspace else { return }
        let text = """
            The query below failed on \(workspace.config.kind.displayName) database `\(workspace.currentDatabase)`.

            ```sql
            \(sql.trimmingCharacters(in: .whitespacesAndNewlines))
            ```

            Error:

            ```
            \(error.text)
            ```
            """
        workspace.askAssistant("Why did this query fail? Give me a corrected query.",
                               attaching: .init(kind: "error", title: "Error: \(error.text.components(separatedBy: "\n").first ?? "")",
                                                text: text))
    }

    private func explainWithAI() {
        guard let plan = model.plan, let workspace = model.workspace else { return }
        let limit = 100_000
        let json = plan.json.count > limit ? String(plan.json.prefix(limit)) + "\n… (plan cut at \(limit) characters)" : plan.json
        let text = """
            \(workspace.config.kind.displayName) database `\(workspace.currentDatabase)`. The query:

            ```sql
            \((model.planStatement ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            ```

            Its plan from EXPLAIN (\(plan.isAnalyzed ? "ANALYZE, BUFFERS, " : "")FORMAT JSON)\(plan.isAnalyzed ? "" : ", estimated without running it"):

            ```json
            \(json)
            ```
            """
        let title = plan.executionTime.map { String(format: "Query plan: %.1f ms", $0) } ?? "Query plan (estimated)"
        workspace.askAssistant("Explain this query plan. Where does the time go, and how can I make the query faster?",
                               attaching: .init(kind: "plan", title: title, text: text))
    }

    // MARK: Export

    private func export(_ result: QueryResult, as format: ExportFormat) {
        guard FilePanels.available() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = "\(model.title.replacingOccurrences(of: "/", with: "-")).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows = (order ?? Array(result.rows.indices)).map { result.rows[$0] }
        var text: String
        switch format {
        case .json:
            text = "[\n" + rows.map { "  " + ExportEncoding.jsonObject(columns: result.columns, row: $0) }.joined(separator: ",\n") + "\n]\n"
        default:
            text = ExportEncoding.csvLine(result.columns.map(\.name)) + rows.map(ExportEncoding.csvLine).joined()
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: Messages

    private var messages: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.messages) { message in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(message.kind)).foregroundStyle(color(message.kind))
                        Text(message.text).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func icon(_ kind: QueryMessage.Kind) -> String {
        switch kind {
        case .info: "checkmark.circle"
        case .notice: "info.circle"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(_ kind: QueryMessage.Kind) -> Color {
        switch kind {
        case .info: .green
        case .notice: .blue
        case .error: .red
        }
    }
}

/// Read-only fields of the selected result rows. Values that differ between rows show as Mixed.
private struct ResultRowDetails: View {
    var result: QueryResult
    var rows: [Int]

    var body: some View {
        if rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.textTertiary)
                Text("Select rows to see their details").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if rows.count > 1 {
                        Text("\(rows.count) rows selected").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accentText)
                    }
                    ForEach(Array(result.columns.enumerated()), id: \.offset) { index, column in
                        field(index: index, column: column)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func field(index: Int, column: ResultColumn) -> some View {
        let values = rows.map { result.rows[$0][index] }
        let mixed = values.contains { $0 != values[0] }
        let value = values[0]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(column.name.uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(Theme.textSecondary)
                Text(column.typeName).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            Text(mixed ? "Mixed" : value.map { column.category == .json ? Self.prettyJSON($0) : $0 } ?? "NULL")
                .font(column.category == .json && !mixed && value != nil ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .textSelection(.enabled)
                .foregroundStyle(mixed || value == nil ? Theme.textTertiary : Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let string = String(data: pretty, encoding: .utf8) else { return text }
        return string
    }
}

/// An EXPLAIN plan as an indented tree. Bars show each step's share of the time (or cost when
/// the query wasn't run); steps that take a large share are highlighted.
private struct PlanView: View {
    var plan: QueryPlan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(plan.nodes) { node in
                    row(node)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
                }
                if let planning = plan.planningTime {
                    Text(String(format: "Planning: %.2f ms", planning)
                         + (plan.executionTime.map { String(format: " · Execution: %.2f ms", $0) } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ node: QueryPlan.Node) -> some View {
        let hot = node.share >= 0.3
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(node.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(hot ? Color.orange : Theme.textPrimary)
                ForEach(node.details, id: \.self) { detail in
                    Text(detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                if let miss = node.estimateMiss, let actual = node.actualRows, let loops = node.loops {
                    Label("Estimated \(Int(node.estimatedRows * Double(loops)).formatted()) rows, got \(Int(actual).formatted()) (\(Int(miss))× off)",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(Color.orange)
                }
            }
            .padding(.leading, CGFloat(node.depth) * 18)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.separator)
                        Capsule().fill(hot ? Color.orange : Theme.accent).frame(width: max(2, 80 * node.share))
                    }
                    .frame(width: 80, height: 5)
                    Text("\(Int((node.share * 100).rounded()))%").monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Text(metrics(node)).foregroundStyle(Theme.textTertiary).monospacedDigit()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(hot ? Color.orange.opacity(0.07) : .clear)
    }

    private func metrics(_ node: QueryPlan.Node) -> String {
        if let selfTime = node.selfTime, let actual = node.actualRows {
            var text = String(format: "%.2f ms · ", selfTime) + "\(Int(actual).formatted()) rows"
            if let loops = node.loops, loops > 1 { text += " · \(loops.formatted()) loops" }
            return text
        }
        return String(format: "cost %.1f · ", node.totalCost) + "\(Int(node.estimatedRows).formatted()) rows"
    }
}

private struct SaveQuerySheet: View {
    var model: QueryTabModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var shared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.savedQueryID == nil ? "Save Query" : "Update Saved Query").font(.headline)
            TextField("Name", text: $name)
            Toggle("Available in all connections", isOn: $shared)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.save(name: name, shared: shared)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            name = model.savedQuery?.name ?? (model.title.hasPrefix("Query ") ? "" : model.title)
            shared = model.savedQuery.map { $0.connectionID == nil } ?? false
        }
    }
}
