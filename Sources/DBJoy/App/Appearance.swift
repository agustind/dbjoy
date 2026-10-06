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
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @AppStorage(StarredRail.newWindowKey) private var starredOpensNewWindow = false

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Section {
                Picker("Starred connections open in", selection: $starredOpensNewWindow) {
                    Text("This window").tag(false)
                    Text("A new window").tag(true)
                }
            } footer: {
                Text("Hold ⌘ while clicking a starred connection to do the opposite.")
                    .font(.caption)
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
