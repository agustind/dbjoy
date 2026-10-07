import AppKit
import DBCore
import SwiftUI

/// Collapsible bar on the far left of a workspace window listing starred connections.
/// One click opens a connection, or brings its window forward if it's already open.
struct StarredRail: View {
    var currentConnectionID: UUID
    /// Switches this window to the given connection.
    var openHere: (ConnectionConfig) -> Void
    @AppStorage("starredRailExpanded") private var isExpanded = false
    @AppStorage(StarredRail.newWindowKey) private var opensNewWindow = false

    static let newWindowKey = "starredOpensNewWindow"
    @Environment(\.openWindow) private var openWindow
    private var store: ConnectionStore { ConnectionStore.shared }

    static let collapsedWidth: CGFloat = 56
    static let expandedWidth: CGFloat = 220

    var body: some View {
        let starred = store.starredConnections
        VStack(alignment: .leading, spacing: 4) {
            if isExpanded {
                SectionLabel(title: "Starred", trailing: starred.isEmpty ? nil : "\(starred.count)")
                    .padding(.horizontal, 6)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
            } else {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                    .help("Starred connections")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(starred) { config in
                        StarredItem(config: config, isCurrent: config.id == currentConnectionID, isExpanded: isExpanded,
                                    hint: opensNewWindow ? "⌘-click to open in this window" : "⌘-click to open in a new window") {
                            open(config)
                        }
                    }
                    if starred.isEmpty, isExpanded {
                        Text("Star connections in the Connections window to pin them here.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6)
                            .padding(.top, 4)
                    }
                }
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
            Rectangle().fill(Theme.separator).frame(height: 1)
            railButton(icon: "square.stack.3d.up", title: "All connections", help: "Show connections (⇧⌘K)") {
                openWindow(id: "welcome")
            }
            railButton(icon: isExpanded ? "sidebar.left" : "sidebar.right",
                       title: "Collapse", help: isExpanded ? "Collapse starred bar" : "Expand starred bar") {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 8)
        .frame(width: isExpanded ? Self.expandedWidth : Self.collapsedWidth)
        .background(Theme.sidebarBackground)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.separator).frame(width: 1) }
    }

    /// Opens a starred connection in this window or a new one, per the setting; ⌘-click does the opposite.
    private func open(_ config: ConnectionConfig) {
        guard config.id != currentConnectionID else { return }
        let commandHeld = NSEvent.modifierFlags.contains(.command)
        if opensNewWindow != commandHeld {
            openWindow(id: "workspace", value: config.id)
        } else {
            openHere(config)
        }
    }

    private func railButton(icon: String, title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 24)
                if isExpanded {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .frame(height: 32)
            .padding(.horizontal, isExpanded ? 6 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
    }
}

private struct StarredItem: View {
    var config: ConnectionConfig
    var isCurrent: Bool
    var isExpanded: Bool
    var hint: String
    var open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ConnectionAvatar(config: config, size: 32)
                .overlay(Circle().strokeBorder(isCurrent ? Theme.accent : .clear, lineWidth: 2).padding(-3))
                if isExpanded {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(config.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isCurrent ? Theme.accentText : Theme.textPrimary)
                            .lineLimit(1)
                        Text(config.host.isEmpty ? "localhost" : config.host)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(isExpanded ? 6 : 4)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isCurrent && isExpanded ? Theme.accentFill : (isHovering ? Theme.elevated : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isCurrent
              ? "\(config.displayName) · \(config.environment.displayName) (this window)"
              : "\(config.displayName) · \(config.environment.displayName)\n\(config.user)@\(config.host):\(config.port)\n\(hint)")
        .accessibilityLabel("\(config.displayName), \(config.environment.displayName)\(isCurrent ? ", current" : "")")
        .accessibilityIdentifier("starred-\(config.displayName)")
    }
}
