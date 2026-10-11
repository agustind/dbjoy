import AppKit
import DBCore
import SwiftUI

/// Settings → MCP: serve the shared connections to Claude Code and other MCP clients.
struct MCPSettingsView: View {
    @AppStorage(MCPSettings.enabledKey) private var enabled = false
    @AppStorage(MCPSettings.portKey) private var port = MCPSettings.defaultPort
    @State private var store = ConnectionStore.shared
    @State private var server = MCPServer.shared
    @State private var copied = false
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Let MCP clients read your databases", isOn: $enabled)
                    .accessibilityIdentifier("mcp-enabled")
                if enabled {
                    TextField("Port", value: $port, format: .number.grouping(.never))
                    statusRow
                }
            } footer: {
                footnote("Claude Code, Cursor and other MCP clients on this Mac can list tables and run "
                         + "read-only queries on the connections you turn on below, while DBJoy is open. "
                         + "Queries run in read-only transactions with a \(MCPServer.statementTimeout) timeout.")
            }

            if enabled {
                Section {
                    Text(MCPSettings.claudeCommand(port: MCPSettings.port, token: "••••••••"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(copied ? "Copied" : "Copy Command") {
                            copy(MCPSettings.claudeCommand(port: MCPSettings.port, token: MCPSettings.token()))
                        }
                        Button("Copy Token") { copy(MCPSettings.token()) }
                        Spacer()
                        Button("Reset Token…") { isConfirmingReset = true }
                    }
                } header: {
                    Text("Add to Claude Code")
                } footer: {
                    footnote("Run the command once in Terminal; --scope user makes DBJoy available in every project. "
                             + "Other clients: connect to \(MCPSettings.endpoint(port: MCPSettings.port)) with the header "
                             + "Authorization: Bearer <token>.")
                }

                Section {
                    if store.connections.isEmpty {
                        Text("No connections yet.").foregroundStyle(.secondary)
                    }
                    ForEach(sortedConnections) { config in
                        Toggle(isOn: Binding(get: { config.allowsMCP },
                                             set: { store.setAllowsMCP($0, for: config.id) })) {
                            HStack(spacing: 8) {
                                ConnectionAvatar(config: config, size: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(config.displayName)
                                    if !config.savePassword {
                                        Text("Save its password to use it from MCP clients")
                                            .font(.caption).foregroundStyle(.orange)
                                    } else if config.environment == .production {
                                        Text("Production").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Shared connections")
                } footer: {
                    footnote("Clients only see the connections turned on here. In a project's CLAUDE.md, name the one it "
                             + "uses, e.g. “The database is the DBJoy connection Andromeda (dev).”")
                }

                Section {
                    if server.activity.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    }
                    ForEach(server.activity.prefix(20)) { entry in
                        ActivityRow(entry: entry)
                    }
                } header: {
                    HStack {
                        Text("Recent activity")
                        Spacer()
                        if !server.activity.isEmpty {
                            Button("Clear") { server.clearActivity() }.buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: enabled ? 640 : 220)
        .onChange(of: enabled) { server.applySettings() }
        .onChange(of: port) { server.applySettings() }
        .confirmationDialog("Reset the MCP token?", isPresented: $isConfirmingReset) {
            Button("Reset Token", role: .destructive) { server.resetToken() }
        } message: {
            Text("Clients set up with the current token stop working until you add DBJoy to them again.")
        }
    }

    private var sortedConnections: [ConnectionConfig] {
        store.connections.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    @ViewBuilder private var statusRow: some View {
        switch server.status {
        case .running(let port):
            Label("Listening on \(MCPSettings.endpoint(port: port))", systemImage: "circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .textSelection(.enabled)
        case .starting:
            Label("Starting…", systemImage: "circle.dotted").foregroundStyle(.secondary).font(.callout)
        case .failed(let message):
            Label("Couldn't start: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        case .off:
            Label("Stopped", systemImage: "circle").foregroundStyle(.secondary).font(.callout)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ActivityRow: View {
    let entry: MCPActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: entry.error == nil ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(entry.error == nil ? Color.secondary : Color.red)
                Text("\(entry.client) · \(entry.connection) · \(entry.summary)").lineLimit(1)
                Spacer()
                Text(entry.date, style: .time).foregroundStyle(.secondary)
            }
            .font(.callout)
            if let sql = entry.sql {
                Text(sql)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if let error = entry.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}
