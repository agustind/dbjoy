import AppKit
import DBCore
import SwiftUI

/// Chat panel on the right of a workspace window.
struct AssistantPanel: View {
    @Bindable var model: AssistantModel
    var workspace: WorkspaceModel
    @AppStorage(AssistantSettings.providerKey) private var provider: AIProvider = .anthropic
    @AppStorage(AssistantSettings.allowWritesKey) private var allowWrites = false
    @State private var hasKey = true
    @State private var showsChats = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.separator).frame(height: 1)
            if showsChats {
                ChatBrowser(model: model, connectionID: workspace.config.id) { showsChats = false }
            } else if !hasKey {
                missingKey
            } else if model.items.isEmpty {
                suggestions
            } else {
                transcript
            }
            if !showsChats { composer }
        }
        .background(Theme.contentBackground)
        .onAppear {
            refreshKey()
            isComposerFocused = true
        }
        .onChange(of: provider) { refreshKey() }
        // Pick up a key added in the Settings window when coming back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshKey() }
    }

    private func refreshKey() { hasKey = model.hasAPIKey }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accentText)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title ?? "Assistant").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(AssistantSettings.model(for: provider))
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            Button { showsChats.toggle() } label: { Image(systemName: "list.bullet") }
                .buttonStyle(.ghost(active: showsChats))
                .help("Saved chats")
                .accessibilityIdentifier("assistant-chats")
            Button {
                model.reset()
                showsChats = false
                isComposerFocused = true
            } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.ghost)
                .help("New chat")
                .disabled(model.items.isEmpty && !showsChats)
                .accessibilityIdentifier("assistant-new-chat")
            Button { workspace.toggleAssistant() } label: { Image(systemName: "xmark") }
                .buttonStyle(.ghost)
                .help("Hide assistant (⌘J)")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var missingKey: some View {
        VStack(spacing: 12) {
            Image(systemName: "key").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.accent)
            Text("Add an API key to start").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text("The assistant uses your own Anthropic or OpenAI key. Keys are kept in your keychain.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            SettingsLink { Text("Open Settings…") }
                .buttonStyle(.primary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer()
            Text("Ask about \(workspace.currentDatabase)")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(allowWrites && !workspace.config.readOnly
                 ? "It can read your data, write SQL and, with your approval, make changes."
                 : "It can read your data and write SQL. Changing data is off; turn it on in Settings.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            ForEach(["What tables are in this database and how do they relate?",
                     "How many rows were added to each table in the last 7 days?",
                     "Write a query for the top 10 customers by revenue"], id: \.self) { prompt in
                Button {
                    model.draft = prompt
                    model.send()
                } label: {
                    Text(prompt).font(.system(size: 12)).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.outline)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.items) { item in
                        ChatItemView(item: item, workspace: workspace).id(item.id)
                    }
                    if model.isRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working…").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        }
                        .id("working")
                    }
                }
                .padding(14)
            }
            .onChange(of: model.items.count) {
                guard let last = model.items.last?.id else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about your data…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...8)
                    .focused($isComposerFocused)
                    .onSubmit { model.send() }
                    .disabled(!hasKey)
                    .accessibilityIdentifier("assistant-input")
                if model.isRunning {
                    Button { model.stop() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.primary)
                        .help("Stop")
                } else {
                    Button { model.send() } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.primary)
                        .help("Send (↩)")
                        .accessibilityIdentifier("assistant-send")
                        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasKey)
                }
            }
            .padding(10)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
            Label(model.allowsWrites ? "Can change data, \(AssistantSettings.confirmsWrites ? "with your approval" : "without asking")"
                  : "Read-only", systemImage: model.allowsWrites ? "pencil" : "lock")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .help(model.allowsWrites ? "Change this in Settings → AI Assistant."
                      : "Queries run in read-only transactions. Change this in Settings → AI Assistant.")
        }
        .padding(12)
    }
}

// MARK: - Items

private struct ChatItemView: View {
    var item: ChatItem
    var workspace: WorkspaceModel

    var body: some View {
        switch item.kind {
        case .user(let text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 30)
        case .reply(let text):
            MarkdownView(text: text, workspace: workspace)
        case .step(let step):
            StepView(step: step, workspace: workspace)
        case .problem(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }
}

/// A tool call: its SQL, outcome and result, plus Run/Skip when a change awaits approval.
private struct StepView: View {
    var step: AssistantStep
    var workspace: WorkspaceModel
    @State private var showsSQL = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsSQL.toggle()
            } label: {
                HStack(spacing: 6) {
                    icon.frame(width: 14)
                    Text(step.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                    if step.sql != nil, step.state != .awaitingApproval {
                        Image(systemName: showsSQL ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(step.sql != nil)

            if let sql = step.sql, showsSQL || step.state == .awaitingApproval {
                CodeBlock(code: sql, workspace: workspace)
            }
            if step.state == .awaitingApproval {
                approval
            }
            if let error = step.error {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let result = step.result {
                if result.returnsRows {
                    ResultPreview(result: result)
                    HStack {
                        Text("\(step.totalRows ?? result.rows.count)\(result.truncated ? "+" : "") row(s)")
                            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        if let sql = step.sql {
                            Button("Open in query tab") { workspace.runInNewQuery(sql) }
                                .buttonStyle(.ghost)
                                .font(.system(size: 11))
                        }
                    }
                } else if step.state == .done {
                    Text(result.commandTag + (result.rowsAffected.map { " — \($0) row(s) affected" } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(10)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(step.state == .awaitingApproval ? Color.orange.opacity(0.6) : Theme.border, lineWidth: 1))
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .running: ProgressView().controlSize(.mini)
        case .awaitingApproval: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(Theme.textTertiary)
        }
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workspace.config.environment.requiresWriteConfirmation
                 ? "This changes data on \(workspace.config.environment.displayName.uppercased()) (\(workspace.currentDatabase))."
                 : "Run this change on \(workspace.currentDatabase.isEmpty ? workspace.config.displayName : workspace.currentDatabase)?")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(workspace.config.environment.requiresWriteConfirmation ? Color.red : Theme.textPrimary)
            HStack(spacing: 8) {
                Button { step.resolve(approved: true) } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.primary)
                Button("Skip") { step.resolve(approved: false) }
                    .buttonStyle(.outline)
            }
        }
    }
}

/// The first rows of a result in a small scrollable grid.
private struct ResultPreview: View {
    var result: QueryResult
    private static let maxRows = 50

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(result.columns.enumerated()), id: \.offset) { _, column in
                        Text(column.name.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                ForEach(Array(result.rows.prefix(Self.maxRows).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell.map { $0.count > 80 ? String($0.prefix(80)) + "…" : $0 } ?? "NULL")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(cell == nil ? Theme.textTertiary : Theme.textPrimary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(8)
            .textSelection(.enabled)
        }
        .frame(maxHeight: min(CGFloat(min(result.rows.count, Self.maxRows)) * 19 + 34, 240))
        .background(Theme.contentBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Markdown

/// Renders replies: inline Markdown per paragraph, and fenced code blocks with editor actions.
struct MarkdownView: View {
    var text: String
    var workspace: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let paragraph):
                    Text(Self.attributed(paragraph))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let code):
                    CodeBlock(code: code, workspace: workspace)
                case .table(let rows):
                    MarkdownTable(rows: rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Segment: Equatable {
        case text(String)
        case code(String)
        /// Rows of cells; the first row is the header.
        case table([[String]])
    }

    /// Splits on ``` fences; text between them is split into paragraphs on blank lines,
    /// and runs of `| a | b |` lines become tables.
    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var buffer: [Substring] = []
        var inCode = false

        func flush() {
            let joined = buffer.joined(separator: "\n")
            buffer = []
            if inCode {
                segments.append(.code(joined))
            } else {
                for paragraph in joined.components(separatedBy: "\n\n")
                where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments += textAndTables(paragraph.trimmingCharacters(in: .newlines))
                }
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                buffer.append(line)
            }
        }
        flush()
        return segments
    }

    private static func textAndTables(_ paragraph: String) -> [Segment] {
        var segments: [Segment] = []
        var text: [String] = []
        var table: [[String]] = []
        func flushText() {
            if !text.isEmpty { segments.append(.text(text.joined(separator: "\n"))) }
            text = []
        }
        func flushTable() {
            if !table.isEmpty { segments.append(.table(table)) }
            table = []
        }
        for line in paragraph.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 1 {
                flushText()
                let cells = trimmed.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // Skip the |---|:--:| separator row.
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
            } else {
                flushTable()
                text.append(String(line))
            }
        }
        flushText()
        flushTable()
        return segments
    }

    static func attributed(_ paragraph: String) -> AttributedString {
        // Headings become bold lines; everything else is inline Markdown.
        let lines = paragraph.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop { $0 == "#" }
            if trimmed.count < line.count, trimmed.hasPrefix(" ") { return "**\(trimmed.trimmingCharacters(in: .whitespaces))**" }
            // List markers become bullets.
            let indent = line.prefix { $0 == " " }
            let rest = line.dropFirst(indent.count)
            if rest.hasPrefix("- ") || rest.hasPrefix("* ") { return indent + "• " + rest.dropFirst(2) }
            return String(line)
        }
        let source = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
    }
}

private struct MarkdownTable: View {
    var rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownView.attributed(cell))
                                .font(.system(size: 12, weight: index == 0 ? .semibold : .regular))
                                .foregroundStyle(index == 0 ? Theme.textSecondary : Theme.textPrimary)
                                .lineLimit(1)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(10)
            .textSelection(.enabled)
        }
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
    }
}

private struct CodeBlock: View {
    var code: String
    var workspace: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
            }
            Rectangle().fill(Theme.separator).frame(height: 1)
            HStack(spacing: 4) {
                Button { workspace.newQuery(sql: code) } label: { Label("Open in editor", systemImage: "square.and.pencil") }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                Spacer()
            }
            .buttonStyle(.ghost)
            .font(.system(size: 11))
            .padding(4)
        }
        .background(Theme.contentBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
    }
}
