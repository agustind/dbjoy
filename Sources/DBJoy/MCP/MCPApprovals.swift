import AppKit
import DBCore
import Observation
import SwiftUI

/// A change an MCP client asked to run, waiting for the user.
struct MCPChangeRequest: Identifiable {
    let id = UUID()
    var client: String
    var config: ConnectionConfig
    var summary: String
    var sql: String
}

/// Shows MCP change requests one at a time in a floating panel and waits for Run or Decline.
/// The panel doesn't activate DBJoy, so it never takes keyboard focus from the app the user is in.
@MainActor @Observable
final class MCPApprovals {
    static let shared = MCPApprovals()
    /// Unanswered requests are declined after this, before MCP clients give up on the call.
    static let timeout: Duration = .seconds(240)

    private(set) var queue: [MCPChangeRequest] = []
    @ObservationIgnored private var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var closer: PanelCloser?
    /// Off in tests, which answer requests themselves.
    @ObservationIgnored var presentsPanel = true

    var current: MCPChangeRequest? { queue.first }

    /// Asks the user; true when they chose Run.
    func request(_ request: MCPChangeRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            waiting[request.id] = continuation
            queue.append(request)
            showPanel()
            Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                self?.resolve(request.id, approved: false)
            }
        }
    }

    func resolve(_ id: UUID, approved: Bool) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        queue.removeAll { $0.id == id }
        continuation.resume(returning: approved)
        if queue.isEmpty { panel?.orderOut(nil) }
    }

    /// Declines everything, e.g. when the MCP server stops.
    func declineAll() {
        for id in Array(waiting.keys) { resolve(id, approved: false) }
    }

    private func showPanel() {
        guard presentsPanel else { return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                                backing: .buffered, defer: true)
            panel.title = "Change requested by MCP client"
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentViewController = NSHostingController(rootView: MCPApprovalView(approvals: self))
            closer = PanelCloser(self)
            panel.delegate = closer
            panel.center()
            self.panel = panel
        }
        panel?.orderFrontRegardless()
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Closing the panel declines what it shows.
    @MainActor private final class PanelCloser: NSObject, NSWindowDelegate {
        weak var approvals: MCPApprovals?
        init(_ approvals: MCPApprovals) { self.approvals = approvals }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            approvals?.declineAll()
            return true
        }
    }
}

struct MCPApprovalView: View {
    var approvals: MCPApprovals

    var body: some View {
        if let request = approvals.current {
            let production = request.config.environment.requiresWriteConfirmation
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ConnectionAvatar(config: request.config, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.summary).font(.headline).lineLimit(2)
                        Text("\(request.client) wants to change \(request.config.displayName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    EnvironmentBadge(environment: request.config.environment)
                }
                ScrollView {
                    Text(request.sql)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border))
                Text("Runs in one transaction with a \(MCPServer.statementTimeout) timeout. If any statement fails, nothing changes."
                     + (approvals.queue.count > 1 ? " \(approvals.queue.count - 1) more waiting." : ""))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Decline") { approvals.resolve(request.id, approved: false) }
                        .buttonStyle(.outline)
                        .keyboardShortcut(.cancelAction)
                    Button {
                        approvals.resolve(request.id, approved: true)
                    } label: {
                        Label(production ? "Run on \(request.config.environment.displayName.uppercased())" : "Run",
                              systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(isDestructive: production))
                }
            }
            .padding(18)
            .frame(minWidth: 460, minHeight: 320)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}
