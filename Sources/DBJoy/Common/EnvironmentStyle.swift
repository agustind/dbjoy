import AppKit
import DBCore
import SwiftUI

extension ConnectionEnvironment {
    var nsColor: NSColor {
        switch self {
        case .local: .systemGray
        case .development: .systemGreen
        case .testing: .systemTeal
        case .staging: .systemOrange
        case .production: .systemRed
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// A colored dot that keeps its color inside menus and pickers, where SF Symbols are
    /// drawn as monochrome templates and lose their tint.
    var swatch: Image {
        let color = nsColor
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
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
            .foregroundStyle(environment.color)
            .background(environment.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(environment.color.opacity(0.35), lineWidth: 1))
            .help(environment.requiresWriteConfirmation ? "Writes require confirmation" : environment.displayName)
    }
}
