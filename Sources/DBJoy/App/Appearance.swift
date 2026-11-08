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
                FontChooserRow(title: "Interface font", family: $fonts.uiFamily, monospacedHint: false)
                FontChooserRow(title: "Data font", family: $fonts.dataFamily, monospacedHint: true)
            } footer: {
                Text("The data font is used for table cells and row details. Pick “Fixed Width” in the font panel’s collections to see only monospaced fonts.")
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

/// Shows the chosen family and opens the native font panel to change it.
private struct FontChooserRow: View {
    var title: String
    @Binding var family: String?
    var monospacedHint: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(family ?? (monospacedHint ? "System (default)" : "System"))
                    .font(family.flatMap { NSFont(name: $0, size: 13) ?? FontSettings.shared.font(family: $0, size: 13, weight: .regular) }
                        .map { Font($0) } ?? .body)
                    .lineLimit(1)
                    .foregroundStyle(family == nil ? .secondary : .primary)
                Button("Choose…") {
                    FontPanelController.shared.show(current: family) { family = $0 }
                }
                if family != nil {
                    Button {
                        family = nil
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Use the system font")
                }
            }
        }
    }
}

/// Drives the shared NSFontPanel and reports the chosen family. Size and effects are hidden;
/// only the family is used, so the app keeps its own sizes and weights.
@MainActor
final class FontPanelController: NSObject {
    static let shared = FontPanelController()

    private var onChange: ((String) -> Void)?
    private var current = NSFont.systemFont(ofSize: 13)

    func show(current family: String?, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        current = family.flatMap { FontSettings.shared.font(family: $0, size: 13, weight: .regular) }
            ?? .systemFont(ofSize: 13)
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(current, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    @objc func changeFont(_ sender: Any?) {
        let font = NSFontManager.shared.convert(current)
        current = font
        if let family = font.familyName { onChange?(family) }
    }

    @objc func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.collection, .face]
    }
}
