import AppKit
import SwiftUI

/// App palette and shared controls. Colors adapt to light and dark appearance;
/// the dark palette is the primary design (black sidebar, charcoal content, lilac accent).
enum Theme {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    // MARK: AppKit colors

    static let sidebarBackgroundNS = dynamic(light: hex(0xF3F2F5), dark: hex(0x000000))
    static let contentBackgroundNS = dynamic(light: hex(0xFFFFFF), dark: hex(0x1E1D20))
    static let elevatedNS = dynamic(light: hex(0xF6F5F8), dark: hex(0x262529))
    static let borderNS = dynamic(light: hex(0xD9D7DE), dark: hex(0x47454C))
    static let separatorNS = dynamic(light: hex(0x000000, alpha: 0.07), dark: hex(0xFFFFFF, alpha: 0.07))
    /// Very faint column dividers in grids.
    static let gridLineNS = dynamic(light: hex(0x000000, alpha: 0.045), dark: hex(0xFFFFFF, alpha: 0.045))
    static let textPrimaryNS = dynamic(light: hex(0x1E1D20), dark: hex(0xF2F1F4))
    static let textSecondaryNS = dynamic(light: hex(0x6B6970), dark: hex(0xA9A7AE))
    static let textTertiaryNS = dynamic(light: hex(0xA19FA6), dark: hex(0x6C6A71))
    static let accentNS = dynamic(light: hex(0xA2569E), dark: hex(0xD49AD2))
    static let accentTextNS = dynamic(light: hex(0x8E3F8A), dark: hex(0xE8A8E4))
    static let accentFillNS = dynamic(light: hex(0xA2569E, alpha: 0.12), dark: hex(0x3A2238))
    static let accentStrokeNS = dynamic(light: hex(0xA2569E, alpha: 0.35), dark: hex(0x6B3D67))
    static let onAccentNS = dynamic(light: hex(0xFFFFFF), dark: hex(0x1E1D20))
    static let selectionNS = dynamic(light: hex(0xA2569E, alpha: 0.14), dark: hex(0xD49AD2, alpha: 0.16))

    // MARK: SwiftUI colors

    static let sidebarBackground = Color(nsColor: sidebarBackgroundNS)
    static let contentBackground = Color(nsColor: contentBackgroundNS)
    static let elevated = Color(nsColor: elevatedNS)
    static let border = Color(nsColor: borderNS)
    static let separator = Color(nsColor: separatorNS)
    static let textPrimary = Color(nsColor: textPrimaryNS)
    static let textSecondary = Color(nsColor: textSecondaryNS)
    static let textTertiary = Color(nsColor: textTertiaryNS)
    static let accent = Color(nsColor: accentNS)
    static let accentText = Color(nsColor: accentTextNS)
    static let accentFill = Color(nsColor: accentFillNS)
    static let accentStroke = Color(nsColor: accentStrokeNS)
    static let onAccent = Color(nsColor: onAccentNS)

    static let cornerRadius: CGFloat = 8
}

// MARK: - Buttons

/// Filled lilac button for the primary action of a view.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Outlined button used in toolbars.
struct OutlineButtonStyle: ButtonStyle {
    var isActive = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(isActive ? Theme.accentText : Theme.textPrimary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(isActive ? Theme.accentFill : (isHovering || configuration.isPressed ? Theme.elevated : .clear)))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(isActive ? Theme.accentStroke : Theme.border, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// Borderless icon button with a hover background.
struct GhostButtonStyle: ButtonStyle {
    var isActive = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isActive ? Theme.accentText : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(minWidth: 28, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Theme.accentFill : (isHovering || configuration.isPressed ? Theme.elevated : .clear)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    static var outline: OutlineButtonStyle { OutlineButtonStyle() }
    static func outline(active: Bool) -> OutlineButtonStyle { OutlineButtonStyle(isActive: active) }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var ghost: GhostButtonStyle { GhostButtonStyle() }
    static func ghost(active: Bool) -> GhostButtonStyle { GhostButtonStyle(isActive: active) }
}

// MARK: - Building blocks

/// Text tabs with an accent underline on the selected one (like "Summary · Utilization").
struct UnderlineTabs<Value: Hashable>: View {
    var items: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 18) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button { selection = item.value } label: {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selected ? Theme.accentText : Theme.textSecondary)
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selected ? Theme.accent : .clear).frame(height: 2).offset(y: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Uppercase, letter-spaced section label.
struct SectionLabel: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// Small keyboard shortcut badge, e.g. ⌘P.
struct ShortcutBadge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Rounded search input with a leading magnifier.
struct SearchInput: View {
    var prompt: String
    @Binding var text: String
    var shortcut: String?
    var onShortcutTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
            } else if let shortcut {
                Button { onShortcutTap?() } label: { ShortcutBadge(text: shortcut) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Theme.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Header shared by tab contents: large title on the left, actions on the right, and an
/// optional toolbar row below.
struct PageHeader<Leading: View, Trailing: View, Toolbar: View>: View {
    var title: String
    var subtitle: String?
    var showsToolbar = true
    /// Draws a divider between the title and `leading` when they share a row.
    var separatesLeading = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var toolbar: Toolbar

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Pick the first layout that fits: one row, then tabs on their own row,
            // then icon-only actions.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    titleBlock
                    if separatesLeading {
                        Rectangle().fill(Theme.border).frame(width: 1, height: 22)
                    }
                    leading
                    Spacer(minLength: 12)
                    trailing
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        titleBlock
                        Spacer(minLength: 12)
                        trailing
                    }
                    HStack(spacing: 14) { leading }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        titleBlock
                        Spacer(minLength: 12)
                        trailing.labelStyle(.iconOnly)
                    }
                    HStack(spacing: 14) { leading }
                }
            }
            if showsToolbar {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { toolbar }
                    HStack(spacing: 8) { toolbar }.labelStyle(.iconOnly)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let subtitle {
                Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Text(title).font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
        .help(title)
    }
}
