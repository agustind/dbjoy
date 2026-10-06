import AppKit
import DBCore
import SwiftUI

extension ConnectionEnvironment {
    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// Pastel fill, matching the app icon's palette.
    var nsColor: NSColor {
        switch self {
        case .local: Self.hex(0xDCD8EC)       // lavender gray
        case .development: Self.hex(0xBFEFD7) // mint
        case .testing: Self.hex(0xC4E5FA)     // baby blue
        case .staging: Self.hex(0xFFDAB9)     // apricot
        case .production: Self.hex(0xFFC5CC)  // coral rose
        }
    }

    /// Deep shade of the same hue for text and icons on top of (or next to) the pastel.
    var inkNSColor: NSColor {
        switch self {
        case .local: Self.hex(0x575170)
        case .development: Self.hex(0x23704B)
        case .testing: Self.hex(0x24628C)
        case .staging: Self.hex(0x9E521C)
        case .production: Self.hex(0xA3303E)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
    var ink: Color { Color(nsColor: inkNSColor) }

    /// Soft top-to-bottom fill for circles and tiles.
    var fill: LinearGradient {
        LinearGradient(colors: [Color(nsColor: nsColor.blended(withFraction: 0.35, of: .white) ?? nsColor), color],
                       startPoint: .top, endPoint: .bottom)
    }

    /// A colored dot that keeps its color inside menus and pickers, where SF Symbols are
    /// drawn as monochrome templates and lose their tint.
    var swatch: Image {
        let fill = nsColor
        let rim = inkNSColor.withAlphaComponent(0.45)
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            fill.setFill()
            dot.fill()
            rim.setStroke()
            dot.lineWidth = 1
            dot.stroke()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }
}

struct EnvironmentBadge: View {
    var environment: ConnectionEnvironment

    var body: some View {
        Text(environment.displayName.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(environment.ink)
            .background(environment.color, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(environment.ink.opacity(0.2), lineWidth: 1))
            .help(environment.requiresWriteConfirmation ? "Writes require confirmation" : environment.displayName)
    }
}
