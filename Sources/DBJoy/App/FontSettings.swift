import AppKit
import SwiftUI

/// User-selected font families for the interface and for data (grid cells, row details).
/// `nil` means the system default. Views pick fonts up through `Font.ui`/`Font.data` (SwiftUI,
/// tracked by Observation) or `NSFont.ui`/`NSFont.data` plus `didChangeNotification` (AppKit).
@MainActor @Observable
final class FontSettings {
    static let shared = FontSettings()
    static let didChangeNotification = Notification.Name("DBJoyFontSettingsDidChange")

    private static let uiKey = "uiFontFamily"
    private static let dataKey = "dataFontFamily"

    var uiFamily: String? {
        didSet { store(uiFamily, key: Self.uiKey) }
    }

    var dataFamily: String? {
        didSet { store(dataFamily, key: Self.dataKey) }
    }

    @ObservationIgnored private var cache: [CacheKey: NSFont] = [:]

    private init() {
        uiFamily = Self.validFamily(UserDefaults.standard.string(forKey: Self.uiKey))
        dataFamily = Self.validFamily(UserDefaults.standard.string(forKey: Self.dataKey))
    }

    /// Ignores families that were uninstalled since they were chosen.
    private static func validFamily(_ family: String?) -> String? {
        guard let family, NSFontManager.shared.availableFontFamilies.contains(family) else { return nil }
        return family
    }

    private func store(_ family: String?, key: String) {
        UserDefaults.standard.set(family, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: Resolving

    private struct CacheKey: Hashable {
        var family: String
        var size: CGFloat
        var weight: CGFloat
        var italic: Bool
    }

    /// The face of `family` closest to `weight`, or nil if the family has no usable face.
    func font(family: String, size: CGFloat, weight: NSFont.Weight, italic: Bool = false) -> NSFont? {
        let key = CacheKey(family: family, size: size, weight: weight.rawValue, italic: italic)
        if let cached = cache[key] { return cached }
        let faces = NSFontDescriptor(fontAttributes: [.family: family])
            .matchingFontDescriptors(withMandatoryKeys: [.family])
        func traits(_ face: NSFontDescriptor) -> (weight: CGFloat, italic: Bool) {
            let values = face.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            let weight = (values?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            return (weight, face.symbolicTraits.contains(.italic))
        }
        let best = faces.min { a, b in
            let ta = traits(a), tb = traits(b)
            let sa = abs(ta.weight - weight.rawValue) + (ta.italic == italic ? 0 : 10)
            let sb = abs(tb.weight - weight.rawValue) + (tb.italic == italic ? 0 : 10)
            return sa < sb
        }
        guard let best, let font = NSFont(descriptor: best, size: size) else { return nil }
        cache[key] = font
        return font
    }

    /// Point sizes and weights of the macOS text styles, used to map styles onto a custom family.
    static func metrics(_ style: Font.TextStyle) -> (size: CGFloat, weight: NSFont.Weight) {
        switch style {
        case .largeTitle: (26, .regular)
        case .title: (22, .regular)
        case .title2: (17, .regular)
        case .title3: (15, .regular)
        case .headline: (13, .bold)
        case .subheadline: (11, .regular)
        case .body: (13, .regular)
        case .callout: (12, .regular)
        case .footnote: (10, .regular)
        case .caption: (10, .regular)
        case .caption2: (10, .regular)
        @unknown default: (13, .regular)
        }
    }
}

extension Font.Weight {
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

// MARK: - SwiftUI

extension Font {
    /// Interface font: the chosen UI family, or the system font.
    @MainActor static func ui(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let family = FontSettings.shared.uiFamily,
           let font = FontSettings.shared.font(family: family, size: size, weight: weight.nsWeight) {
            return Font(font)
        }
        return .system(size: size, weight: weight)
    }

    /// Interface font for a text style.
    @MainActor static func ui(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        if let family = FontSettings.shared.uiFamily {
            let metrics = FontSettings.metrics(style)
            if let font = FontSettings.shared.font(family: family, size: metrics.size,
                                                   weight: weight?.nsWeight ?? metrics.weight) {
                return Font(font)
            }
        }
        let font = Font.system(style)
        return weight.map { font.weight($0) } ?? font
    }

    /// Data font (cell values, row details): the chosen data family, or the system font —
    /// monospaced when `monospaced` is set (JSON and similar).
    @MainActor static func data(size: CGFloat, weight: Font.Weight = .regular, monospaced: Bool = false) -> Font {
        if let family = FontSettings.shared.dataFamily,
           let font = FontSettings.shared.font(family: family, size: size, weight: weight.nsWeight) {
            return Font(font)
        }
        return .system(size: size, weight: weight, design: monospaced ? .monospaced : .default)
    }

    /// Data font for a text style.
    @MainActor static func data(_ style: Font.TextStyle, monospaced: Bool = false) -> Font {
        if let family = FontSettings.shared.dataFamily {
            let metrics = FontSettings.metrics(style)
            if let font = FontSettings.shared.font(family: family, size: metrics.size, weight: metrics.weight) {
                return Font(font)
            }
        }
        return .system(style, design: monospaced ? .monospaced : .default)
    }
}

/// Sets the chosen interface font as the default for text without an explicit font.
private struct InterfaceFontModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.ui(.body))
    }
}

extension View {
    func interfaceFont() -> some View { modifier(InterfaceFontModifier()) }
}

// MARK: - AppKit

extension NSFont {
    @MainActor static func ui(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let family = FontSettings.shared.uiFamily,
           let font = FontSettings.shared.font(family: family, size: size, weight: weight) {
            return font
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    /// `kind` picks the system fallback: proportional, monospaced digits, or fully monospaced.
    enum DataKind { case text, number, monospaced }

    @MainActor static func data(size: CGFloat, weight: NSFont.Weight = .regular, kind: DataKind = .text,
                                italic: Bool = false) -> NSFont {
        if let family = FontSettings.shared.dataFamily,
           let font = FontSettings.shared.font(family: family, size: size, weight: weight, italic: italic) {
            return font
        }
        let font: NSFont = switch kind {
        case .text: .systemFont(ofSize: size, weight: weight)
        case .number: .monospacedDigitSystemFont(ofSize: size, weight: weight)
        case .monospaced: .monospacedSystemFont(ofSize: size, weight: weight)
        }
        return italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
    }
}
