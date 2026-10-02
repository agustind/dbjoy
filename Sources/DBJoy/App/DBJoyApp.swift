import AppKit
import DBCore
import SwiftUI

@main
struct DBJoyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ConnectionStore.shared

    var body: some Scene {
        Window("Connections", id: "welcome") {
            WelcomeView()
                .environment(store)
        }
        .defaultSize(width: 760, height: 500)

        WindowGroup("Workspace", id: "workspace", for: UUID.self) { $connectionID in
            if let id = connectionID, let config = store.connection(id: id) {
                WorkspaceRoot(config: config)
            } else {
                ContentUnavailableView("Connection not found", systemImage: "questionmark.circle",
                                       description: Text("It may have been deleted."))
            }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        AppearanceMode.current.apply()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension FocusedValues {
    @Entry var workspace: WorkspaceModel?
}

struct AppCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    private var tableTab: TableTabModel? {
        if case .table(let model) = workspace?.selectedTab { return model }
        return nil
    }

    private var queryTab: QueryTabModel? {
        if case .query(let model) = workspace?.selectedTab { return model }
        return nil
    }

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Picker("Appearance", selection: Binding(get: { appearance }, set: { mode in
                appearance = mode
                mode.apply()
            })) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            Divider()
        }

        CommandGroup(after: .newItem) {
            Button("New Query Tab") { workspace?.newQuery() }
                .keyboardShortcut("t")
                .disabled(workspace == nil)
            Button("Close Tab") {
                if workspace?.closeSelectedTab() != true { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Button("Open Anything…") { workspace?.isQuickOpenPresented = true }
                .keyboardShortcut("p")
                .disabled(workspace == nil)
            Divider()
            Button("Show Connections") { openWindow(id: "welcome") }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }

        CommandMenu("Database") {
            Button("Refresh") {
                if let tableTab { tableTab.refresh() } else if let workspace { Task { await workspace.refreshAll() } }
            }
            .keyboardShortcut("r")
            .disabled(workspace == nil)

            Button(queryTab != nil ? "Save Query…" : "Commit Changes") {
                if let queryTab { queryTab.isSaveSheetPresented = true } else { tableTab?.commit() }
            }
            .keyboardShortcut("s")
            .disabled(queryTab == nil && !(tableTab?.hasChanges ?? false))

            Button("Discard Changes") { tableTab?.discardChanges() }
                .disabled(!(tableTab?.hasChanges ?? false))

            Button("Find…") {
                if let tableTab {
                    tableTab.showSearch()
                } else if queryTab != nil {
                    // Standard find bar in the SQL editor.
                    let sender = NSMenuItem()
                    sender.tag = NSTextFinder.Action.showFindInterface.rawValue
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: sender)
                }
            }
            .keyboardShortcut("f")
            .disabled(tableTab == nil && queryTab == nil)

            Divider()

            Button("Run Current Statement") { queryTab?.run(.current) }
                .keyboardShortcut(.return)
                .disabled(queryTab == nil)
            Button("Run All") { queryTab?.run(.all) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(queryTab == nil)
            Button("Cancel Query") { queryTab?.cancel() }
                .keyboardShortcut(".")
                .disabled(!(queryTab?.isRunning ?? false))

            Divider()

            Button("Create Table…") {
                if let workspace { workspace.createTable = CreateTableModel(schema: workspace.currentSchema) }
            }
            .disabled(workspace == nil)
            Button("Export Tables…") { workspace?.startExport() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(workspace == nil)
            Button("ER Diagram") { workspace?.openDiagram() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(workspace == nil)

            Divider()

            Button("Next Tab") { workspace?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Button("Previous Tab") { workspace?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(workspace == nil)
        }
    }
}
