import DBCore
import SwiftUI

struct QueryTabView: View {
    @Bindable var model: QueryTabModel
    var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: model.title, subtitle: "SQL · \(workspace.currentDatabase)", showsToolbar: false) {
                if model.savedQueryID != nil {
                    Image(systemName: "bookmark.fill").font(.system(size: 12)).foregroundStyle(Theme.accentText)
                        .help("Saved query")
                }
                transactionBadge
            } trailing: {
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
    @State private var showMessages = false

    private static let messagesKey = "messages"

    private var tabItems: [(value: String, title: String)] {
        var items = model.results.enumerated().map { index, result in
            (value: result.id.uuidString,
             title: model.results.count == 1 ? "Results" : "Result \(index + 1)")
        }
        items.append((value: Self.messagesKey, title: model.messages.isEmpty ? "Messages" : "Messages (\(model.messages.count))"))
        return items
    }

    private var tabSelection: Binding<String> {
        Binding(
            get: { showMessages || model.selectedResult == nil ? Self.messagesKey : model.selectedResult!.id.uuidString },
            set: { value in
                if value == Self.messagesKey {
                    showMessages = true
                } else {
                    showMessages = false
                    model.selectedResultID = UUID(uuidString: value)
                }
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                UnderlineTabs(items: tabItems, selection: tabSelection)
                Spacer()
                status
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Rectangle().fill(Theme.separator).frame(height: 1)

            if showMessages || model.selectedResult == nil {
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
            } else if let result = model.selectedResult {
                DataGridView(columns: result.columns, rowCount: result.rows.count, version: 0,
                             value: { row, column in
                                 (CellValue(result.rows[row][column]), .normal)
                             },
                             selection: $selectedRows)
                    .id(result.id)
            }
        }
        .background(Theme.contentBackground)
        .onChange(of: model.messages) { _, messages in
            // Each run picks its view: the data table for row results, messages for errors
            // or statements that return no rows.
            showMessages = messages.contains { $0.kind == .error } || model.selectedResult == nil
        }
        .onChange(of: model.selectedResultID) { _, _ in selectedRows = [] }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            if let error = model.messages.last(where: { $0.kind == .error }) {
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
        .font(.system(size: 12))
    }

    private var messages: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
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
        }
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
