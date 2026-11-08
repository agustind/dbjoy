import AppKit
import SwiftUI

/// User-selected app appearance, stored in UserDefaults under `appearance`.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var current: AppearanceMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppearanceMode.init) ?? .system
    }

    /// Applies to every window, including AppKit views and dynamic colors.
    @MainActor func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AssistantSettingsView()
                .tabItem { Label("AI Assistant", systemImage: "sparkles") }
            MCPSettingsView()
                .tabItem { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .tint(Theme.accent)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @AppStorage(StarredRail.newWindowKey) private var starredOpensNewWindow = false
    @Bindable private var fonts = FontSettings.shared

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Section {
                FontChooserRow(title: "Interface font", family: $fonts.uiFamily, scale: $fonts.uiScale)
            } footer: {
                Text("Used for the sidebar, tabs, headers and other interface text.")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }

            Section {
                FontChooserRow(title: "Data font", family: $fonts.dataFamily, scale: $fonts.dataScale)
            } footer: {
                Text("Used for table cells and row details. Rows get taller or shorter with the size.")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Starred connections open in", selection: $starredOpensNewWindow) {
                    Text("This window").tag(false)
                    Text("A new window").tag(true)
                }
            } footer: {
                Text("Hold ⌘ while clicking a starred connection to do the opposite.")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        .onChange(of: appearance) { _, mode in mode.apply() }
        .tint(Theme.accent)
    }
}

/// Family popup with a monospaced filter, and a size popup that scales every text size.
private struct FontChooserRow: View {
    var title: String
    @Binding var family: String?
    @Binding var scale: Double
    @State private var monospacedOnly = false

    private var families: [String] {
        var list = monospacedOnly ? FontSettings.monospacedFamilies : FontSettings.allFamilies
        // Keep the current choice listed while the filter hides it.
        if let family, !list.contains(family) { list.insert(family, at: 0) }
        return list
    }

    var body: some View {
        Picker(title, selection: $family) {
            Text("System").tag(String?.none)
            Divider()
            ForEach(families, id: \.self) { Text($0).tag(Optional($0)) }
        }
        Toggle("Show monospaced fonts only", isOn: $monospacedOnly)
        Picker("Size", selection: $scale) {
            ForEach(FontSettings.scales, id: \.self) { value in
                Text(value == 1 ? "100% (default)" : "\(Int((value * 100).rounded()))%").tag(value)
            }
        }
    }
}
