import DBCore
import SwiftUI

struct ConnectionDraft: Identifiable {
    var id: UUID { config.id }
    var config: ConnectionConfig
    var isNew: Bool
}

/// The connection manager shown at launch.
struct WelcomeView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var selection: UUID?
    @State private var draft: ConnectionDraft?
    @State private var pendingDelete: ConnectionConfig?

    private var filtered: [ConnectionConfig] {
        let all = store.connections
        guard !search.isEmpty else { return all }
        return all.filter {
            [$0.displayName, $0.host, $0.database, $0.group, $0.environment.displayName]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private var groups: [(name: String, connections: [ConnectionConfig])] {
        Dictionary(grouping: filtered, by: \.group)
            .map { (name: $0.key, connections: $0.value.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.accent)
                    Image(systemName: "cylinder.split.1x2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Connections").font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text("\(store.connections.count) saved").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button { newConnection() } label: { Label("New connection", systemImage: "plus") }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("new-connection")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            SearchInput(prompt: "Search connections", text: $search)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Rectangle().fill(Theme.separator).frame(height: 1)

            if store.connections.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "cylinder").font(.system(size: 32, weight: .light)).foregroundStyle(Theme.accent)
                    Text("No connections yet").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Create a connection to a PostgreSQL server to get started.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    Button { newConnection() } label: { Label("New connection", systemImage: "plus") }
                        .buttonStyle(.primary)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.name) { group in
                            SectionLabel(title: group.name.isEmpty ? "Connections" : group.name,
                                         trailing: "\(group.connections.count)")
                                .padding(.horizontal, 12)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                            ForEach(group.connections) { config in
                                ConnectionRow(config: config, isSelected: selection == config.id)
                                    .onTapGesture(count: 2) { connect(config) }
                                    .onTapGesture { selection = config.id }
                                    .contextMenu {
                                        Button("Connect") { connect(config) }
                                        Button("Edit…") { draft = ConnectionDraft(config: config, isNew: false) }
                                        Button("Duplicate") { store.duplicate(config) }
                                        Divider()
                                        Button("Delete…", role: .destructive) { pendingDelete = config }
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityIdentifier("connection-\(config.displayName)")
                                    .accessibilityAction { selection = config.id }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }

            Rectangle().fill(Theme.separator).frame(height: 1)
            HStack(spacing: 8) {
                Button {
                    if let id = selection, let config = store.connection(id: id) {
                        draft = ConnectionDraft(config: config, isNew: false)
                    }
                } label: { Label("Edit", systemImage: "pencil") }
                    .buttonStyle(.outline)
                    .disabled(selection == nil)
                Spacer()
                Text("Double-click to connect").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Button {
                    if let id = selection, let config = store.connection(id: id) { connect(config) }
                } label: { Label("Connect", systemImage: "bolt.fill") }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
                    .accessibilityIdentifier("connect")
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
        }
        .background(Theme.contentBackground)
        .tint(Theme.accent)
        .frame(minWidth: 560, minHeight: 380)
        .sheet(item: $draft) { draft in
            ConnectionFormView(draft: draft) { config in
                selection = config.id
                connect(config)
            }
        }
        .alert("Delete \(pendingDelete?.displayName ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let config = pendingDelete { store.delete(config.id) }
            }
        } message: {
            Text("The saved connection and its stored password will be removed.")
        }
    }

    private func newConnection() {
        draft = ConnectionDraft(config: ConnectionConfig(), isNew: true)
    }

    private func connect(_ config: ConnectionConfig) {
        openWindow(id: "workspace", value: config.id)
    }
}

private struct ConnectionRow: View {
    var config: ConnectionConfig
    var isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(config.environment.color.opacity(0.18))
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(config.environment.color)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(config.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.accentText : Theme.textPrimary)
                    if config.readOnly {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                            .help("Read-only")
                    }
                }
                Text(verbatim: "\(config.user)@\(config.host):\(config.port)\(config.database.isEmpty ? "" : "/" + config.database)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            EnvironmentBadge(environment: config.environment)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Theme.accentFill : (isHovering ? Theme.elevated : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isSelected ? Theme.accentStroke : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
