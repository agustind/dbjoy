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
    /// The connection being dragged to reorder the bar.
    @State private var dragging: UUID?

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
                                    isDragged: config.id == dragging,
                                    hint: opensNewWindow ? "⌘-click to open in this window" : "⌘-click to open in a new window") {
                            open(config)
                        }
                        .onDrag {
                            startDragging(config.id)
                            return NSItemProvider(object: config.id.uuidString as NSString)
                        } preview: {
                            StarredItem.DragPreview(config: config, isCurrent: config.id == currentConnectionID,
                                                    isExpanded: isExpanded)
                        }
                        .onDrop(of: [.utf8PlainText, .plainText, .text], delegate: StarredDropDelegate(target: config.id, dragging: $dragging))
                        .accessibilityAction(named: "Move Up") { store.moveStarred(config.id, by: -1) }
                        .accessibilityAction(named: "Move Down") { store.moveStarred(config.id, by: 1) }
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

    /// Hides the dragged item until the mouse is released, wherever the drop lands (or doesn't).
    private func startDragging(_ id: UUID) {
        dragging = id
        Task { @MainActor in
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(50)) }
            if dragging == id { dragging = nil }
        }
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

/// Reorders the bar live as a dragged connection passes over the others.
private struct StarredDropDelegate: DropDelegate {
    var target: UUID
    @Binding var dragging: UUID?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { ConnectionStore.shared.moveStarred(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct StarredItem: View {
    var config: ConnectionConfig
    var isCurrent: Bool
    var isExpanded: Bool
    var isDragged = false
    var hint: String
    var open: () -> Void
    @State private var isHovering = false

    /// What follows the pointer while dragging: the avatar alone, so it keeps its round shape.
    struct DragPreview: View {
        var config: ConnectionConfig
        var isCurrent: Bool
        var isExpanded: Bool

        var body: some View {
            HStack(spacing: 10) {
                ConnectionAvatar(config: config, size: 32)
                    .overlay(Circle().strokeBorder(isCurrent ? Theme.accent : .clear, lineWidth: 2).padding(-3))
                if isExpanded {
                    Text(config.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
            }
            .padding(4)
        }
    }

    // A tap gesture rather than a Button, so the mouse-down isn't swallowed and the item can be dragged.
    var body: some View {
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
        // The dragged item leaves a gap rather than showing under the pointer.
        .opacity(isDragged ? 0 : 1)
        .onChange(of: isDragged) { isHovering = false }
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .help(isCurrent
              ? "\(config.displayName) · \(config.environment.displayName) (this window)"
              : "\(config.displayName) · \(config.environment.displayName)\n\(config.user)@\(config.host):\(config.port)\n\(hint), drag to reorder")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityLabel("\(config.displayName), \(config.environment.displayName)\(isCurrent ? ", current" : "")")
        .accessibilityIdentifier("starred-\(config.displayName)")
    }
}
