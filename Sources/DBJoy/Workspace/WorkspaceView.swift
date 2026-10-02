import DBCore
import SwiftUI

/// Root of a connection window: handles connecting, password prompts and global sheets.
struct WorkspaceRoot: View {
    @State private var model: WorkspaceModel

    init(config: ConnectionConfig) {
        _model = State(initialValue: WorkspaceModel(config: config))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .connecting:
                ProgressView("Connecting to \(model.config.displayName)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsPassword(let message):
                PasswordPrompt(model: model, message: message)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't connect", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    Button("Retry") { Task { await model.retry() } }
                        .buttonStyle(.borderedProminent)
                }
            case .connected:
                WorkspaceView(model: model)
            }
        }
        .background(Theme.contentBackground)
        .task { await model.start() }
        .onDisappear { Task { await model.disconnect() } }
        .navigationTitle(model.windowTitle)
        .focusedSceneValue(\.workspace, model)
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(model.confirmation?.title ?? "", isPresented: Binding(
            get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
            presenting: model.confirmation
        ) { request in
            Button(request.actionTitle, role: request.isDestructive ? .destructive : nil) {
                Task { await request.action() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .sheet(item: $model.sqlPreview) { request in
            SQLPreviewSheet(request: request, environment: model.config.environment)
        }
        .sheet(item: $model.createTable) { createModel in
            CreateTableSheet(model: createModel, workspace: model)
        }
        .sheet(item: $model.export) { export in
            ExportSheet(model: export)
        }
        .sheet(isPresented: $model.isQuickOpenPresented) {
            QuickOpenView(model: model)
        }
    }
}

private struct PasswordPrompt: View {
    var model: WorkspaceModel
    var message: String?
    @State private var password = ""

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.circle").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Password for \(model.config.user)@\(model.config.host)").font(.headline)
            if let message { Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(submit)
            Button("Connect", action: submit).keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        Task { await model.submitPassword(password) }
    }
}

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 268

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: sidebarWidth)
                .background(Theme.sidebarBackground)
            ResizeHandle(width: $sidebarWidth, range: 200...460)
            VStack(spacing: 0) {
                if model.config.environment.requiresWriteConfirmation {
                    Rectangle().fill(model.config.environment.color).frame(height: 3)
                }
                if !model.tabs.isEmpty {
                    TabStrip(model: model)
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.contentBackground)
        }
        .tint(Theme.accent)
    }

    @ViewBuilder private var detail: some View {
        switch model.selectedTab {
        case .table(let tab): TableTabView(model: tab).id(tab.id)
        case .query(let tab): QueryTabView(model: tab, workspace: model).id(tab.id)
        case .diagram(let tab): DiagramView(model: tab).id(tab.id)
        case nil: EmptyWorkspace(model: model)
        }
    }
}

private struct EmptyWorkspace: View {
    var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 6) {
                Text(model.currentDatabase).font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text("Pick a table from the sidebar, or start a query.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                Button { model.newQuery() } label: { Label("New query", systemImage: "plus") }
                    .buttonStyle(.primary)
                Button { model.isQuickOpenPresented = true } label: { Label("Open anything", systemImage: "magnifyingglass") }
                    .buttonStyle(.outline)
                Button { model.openDiagram() } label: { Label("ER diagram", systemImage: "point.3.connected.trianglepath.dotted") }
                    .buttonStyle(.outline)
            }
            HStack(spacing: 16) {
                shortcut("⌘T", "New query")
                shortcut("⌘P", "Open anything")
                shortcut("⌘F", "Search rows")
                shortcut("⇧⌘E", "Diagram")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            ShortcutBadge(text: keys)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Draggable vertical divider that resizes the sidebar.
struct ResizeHandle: View {
    @Binding var width: Double
    var range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = startWidth ?? width
                            startWidth = start
                            width = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in startWidth = nil })
            }
    }
}

// MARK: - Tab strip

struct TabStrip: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.tabs) { tab in
                            TabChip(tab: tab, isSelected: tab.id == model.selectedTabID,
                                    select: { model.selectedTabID = tab.id },
                                    close: { model.closeTab(tab.id) },
                                    closeOthers: {
                                        for other in model.tabs where other.id != tab.id { model.closeTab(other.id) }
                                    })
                            .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onChange(of: model.selectedTabID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
            Button { model.newQuery() } label: { Image(systemName: "plus") }
                .buttonStyle(.ghost)
                .help("New query tab (⌘T)")
                .padding(.trailing, 10)
        }
        .frame(height: 42)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

private struct TabChip: View {
    var tab: WorkspaceTab
    var isSelected: Bool
    var select: () -> Void
    var close: () -> Void
    var closeOthers: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Theme.accentText : Theme.textTertiary)
            Text(tab.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            ZStack {
                if isHovering || isSelected {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                    .help("Close tab (⌘W)")
                } else if tab.hasUnsavedChanges {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                }
            }
            .frame(width: 12)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 28)
        .frame(maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Theme.elevated : (isHovering ? Theme.elevated.opacity(0.5) : .clear)))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? Theme.border : .clear, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if tab.hasUnsavedChanges, isHovering || isSelected {
                Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: -3, y: 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Close Tab", action: close)
            Button("Close Other Tabs", action: closeOthers)
        }
    }
}
