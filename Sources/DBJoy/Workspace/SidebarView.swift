import DBCore
import SwiftUI

private enum SidebarSection: String, CaseIterable {
    case objects = "Items"
    case queries = "Queries"
    case history = "History"
}

struct SidebarView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var section: SidebarSection = .objects
    @State private var collapsed: Set<ObjectKind> = []

    private var selectedRef: ObjectRef? {
        if case .table(let tab) = model.selectedTab { return tab.ref }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)

            SearchInput(prompt: section == .objects ? "Search items" : "Search", text: $search, shortcut: "⌘P") {
                model.isQuickOpenPresented = true
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            UnderlineTabs(items: SidebarSection.allCases.map { ($0, $0.rawValue) }, selection: $section)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            Rectangle().fill(Theme.separator).frame(height: 1).padding(.top, 2)

            switch section {
            case .objects: objectList
            case .queries: SavedQueriesList(model: model, search: search)
            case .history: HistoryList(model: model, search: search)
            }

            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                // Colored by environment so it's clear what kind of server this window is on.
                Circle().fill(model.config.environment.fill)
                Image(systemName: "cylinder.split.1x2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.config.environment.ink)
            }
            .frame(width: 30, height: 30)
            .help("\(model.config.environment.displayName) connection")
            .accessibilityLabel("\(model.config.environment.displayName) connection")

            VStack(alignment: .leading, spacing: 1) {
                Menu {
                    Section("Databases") {
                        ForEach(model.databases, id: \.self) { name in
                            Button {
                                model.switchDatabase(name)
                            } label: {
                                if name == model.currentDatabase { Label(name, systemImage: "checkmark") } else { Text(name) }
                            }
                        }
                    }
                    Divider()
                    Button("Show Connections…") { openWindow(id: "welcome") }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.currentDatabase)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)

                Menu {
                    ForEach(model.schemas, id: \.self) { name in
                        Button {
                            model.switchSchema(name)
                        } label: {
                            if name == model.currentSchema { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                } label: {
                    HStack(spacing: 0) {
                        // The connection name gives way first so the schema stays visible.
                        Text(model.config.displayName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(" · \(model.currentSchema)")
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: 4).frame(maxWidth: 4)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .help("Schema")
            }
            Spacer(minLength: 0)
            if model.config.readOnly {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    .help("Read-only connection")
            }
        }
    }

    // MARK: Objects

    private var filteredObjects: [SchemaObject] {
        guard !search.isEmpty else { return model.objects }
        return model.objects.filter { fuzzyMatch(search, $0.name) }
    }

    private var objectList: some View {
        let groups = Dictionary(grouping: filteredObjects, by: \.kind)
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(ObjectKind.allCases, id: \.self) { kind in
                    if let objects = groups[kind], !objects.isEmpty {
                        let isExpanded = !collapsed.contains(kind) || !search.isEmpty
                        Button {
                            if collapsed.contains(kind) { collapsed.remove(kind) } else { collapsed.insert(kind) }
                        } label: {
                            HStack(spacing: 6) {
                                SectionLabel(title: sectionTitle(kind), trailing: "\(objects.count)")
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .frame(width: 10)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(sectionTitle(kind)), \(objects.count)")
                        .accessibilityHint(isExpanded ? "Collapse" : "Expand")
                        .padding(.horizontal, 12)
                        .padding(.top, 16)
                        .padding(.bottom, 6)

                        if isExpanded {
                            ForEach(objects) { object in
                                SidebarRow(icon: object.kind.systemImage, title: object.name,
                                           detail: object.kind.isRoutine ? object.ref.arguments.map { "(\($0))" } : nil,
                                           isSelected: object.ref == selectedRef) {
                                    model.open(object.ref)
                                }
                                .help(object.comment ?? object.returnType.map { "returns \($0)" } ?? object.name)
                                .contextMenu { objectMenu(object.ref) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if !model.isLoadingObjects, filteredObjects.isEmpty {
                Text(search.isEmpty ? "No objects in \(model.currentSchema)" : "No matches")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func sectionTitle(_ kind: ObjectKind) -> String {
        switch kind {
        case .table: "Tables"
        case .view: "Views"
        case .materializedView: "Materialized views"
        case .foreignTable: "Foreign tables"
        case .function: "Functions"
        case .procedure: "Procedures"
        }
    }

    @ViewBuilder
    private func objectMenu(_ ref: ObjectRef) -> some View {
        if ref.kind.hasRows {
            Button("Open Data") { model.open(ref, mode: .data) }
            Button("Open Structure") { model.open(ref, mode: .structure) }
            Button("Show Relations") { model.open(ref, mode: .relations) }
            Button("Show Definition") { model.open(ref, mode: .definition) }
            Button("New Query with SELECT") {
                let name = model.dialect?.qualifiedName(ref) ?? ref.description
                model.newQuery(sql: "SELECT *\nFROM \(name)\nLIMIT 100;")
            }
            Button("Export…") { model.startExport([ref]) }
        } else {
            Button("Open Definition") { model.openDefinition(of: ref) }
        }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ref.name, forType: .string)
        }
        Divider()
        if ref.kind == .materializedView {
            Button("Refresh Materialized View") { model.refreshMaterializedView(ref) }
        }
        if ref.kind == .table {
            Button("Truncate…", role: .destructive) { model.truncate(ref) }
        }
        Button("Drop…", role: .destructive) { model.drop(ref) }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            Rectangle().fill(Theme.separator).frame(height: 1).padding(.bottom, 6)
            SidebarRow(icon: "plus.square", title: "New table", isSelected: false) {
                model.createTable = CreateTableModel(schema: model.currentSchema)
            }
            SidebarRow(icon: "point.3.connected.trianglepath.dotted", title: "ER diagram", isSelected: false) {
                model.openDiagram()
            }
            SidebarRow(icon: "square.and.arrow.up", title: "Export", isSelected: false) {
                model.startExport()
            }
            SidebarRow(icon: "arrow.clockwise", title: "Refresh", isSelected: false,
                       trailing: model.isLoadingObjects ? AnyView(ProgressView().controlSize(.mini)) : nil) {
                Task { await model.refreshAll() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}

/// Sidebar item: icon + title, with a plum highlight when selected.
struct SidebarRow: View {
    var icon: String
    var title: String
    var detail: String? = nil
    var isSelected: Bool
    var trailing: AnyView? = nil
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.textPrimary)
                    .lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Theme.accentFill : (isHovering ? Theme.elevated : .clear)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected ? Theme.accentStroke : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(detail.map { "\(title) \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar-\(title)")
    }
}

/// Case-insensitive subsequence match, e.g. "ordit" matches "order_items".
func fuzzyMatch(_ needle: String, _ haystack: String) -> Bool {
    var remaining = needle.lowercased()[...]
    for c in haystack.lowercased() where c == remaining.first {
        remaining = remaining.dropFirst()
        if remaining.isEmpty { return true }
    }
    return remaining.isEmpty
}

func formatDuration(_ seconds: TimeInterval) -> String {
    seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
}

// MARK: - Saved queries & history

/// Two-line sidebar entry used for saved queries and history.
private struct SidebarEntry<Footer: View>: View {
    var title: String?
    var sql: String
    var isSelected = false
    @ViewBuilder var footer: Footer
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.accentText : Theme.textPrimary)
                }
                Text(sql.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(title == nil ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(title == nil ? 3 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                footer
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Theme.accentFill : (isHovering ? Theme.elevated : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct SavedQueriesList: View {
    var model: WorkspaceModel
    var search: String
    @State private var pendingDelete: SavedQuery?

    var body: some View {
        let queries = QueryLibrary.shared.savedQueries(for: model.config.id).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.sql.localizedCaseInsensitiveContains(search)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(queries) { query in
                    let isOpen: Bool = {
                        if case .query(let tab) = model.selectedTab { return tab.savedQueryID == query.id }
                        return false
                    }()
                    SidebarEntry(title: query.name, sql: query.sql, isSelected: isOpen) {
                        if query.connectionID == nil {
                            Label("All connections", systemImage: "globe")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                        }
                    } action: {
                        open(query)
                    }
                    .contextMenu {
                        Button("Open") { open(query) }
                        Button("Delete…", role: .destructive) { pendingDelete = query }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if queries.isEmpty {
                Text("Save a query from a query tab with ⌘S")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).padding()
            }
        }
        .alert("Delete \(pendingDelete?.name ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let query = pendingDelete { QueryLibrary.shared.deleteSavedQuery(query.id) }
            }
        }
    }

    private func open(_ query: SavedQuery) {
        for tab in model.tabs {
            if case .query(let existing) = tab, existing.savedQueryID == query.id {
                model.selectedTabID = existing.id
                return
            }
        }
        model.newQuery(savedQuery: query)
    }
}

private struct HistoryList: View {
    var model: WorkspaceModel
    var search: String

    var body: some View {
        let entries = QueryLibrary.shared.history(for: model.config.id).filter {
            search.isEmpty || $0.sql.localizedCaseInsensitiveContains(search)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries.prefix(300)) { entry in
                    SidebarEntry(title: nil, sql: entry.sql) {
                        HStack(spacing: 5) {
                            if entry.error != nil {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            }
                            Text(entry.executedAt, style: .relative)
                            Text("· \(formatDuration(entry.duration))")
                            if let rows = entry.rowCount { Text("· \(rows) rows") }
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                    } action: {
                        model.newQuery(sql: entry.sql)
                    }
                    .help(entry.error ?? "Open in a new query tab")
                    .contextMenu {
                        Button("Open in New Tab") { model.newQuery(sql: entry.sql) }
                        Button("Copy SQL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.sql, forType: .string)
                        }
                    }
                }
                if !entries.isEmpty {
                    Button("Clear history") { QueryLibrary.shared.clearHistory(for: model.config.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accentText)
                        .padding(10)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if entries.isEmpty {
                Text("No queries yet").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
