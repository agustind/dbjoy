import AppKit
import DBCore
import SwiftUI

/// A connection's badge: its chosen icon, or its initials, on the environment's pastel color.
struct ConnectionAvatar: View {
    enum Shape { case circle, roundedSquare }

    var config: ConnectionConfig
    var size: CGFloat
    var shape: Shape = .circle

    var body: some View {
        ZStack {
            switch shape {
            case .circle: Circle().fill(config.environment.fill)
            case .roundedSquare: RoundedRectangle(cornerRadius: size * 0.24).fill(config.environment.fill)
            }
            if let icon = ConnectionIcons.validated(config.icon) {
                Image(systemName: icon)
                    .font(.system(size: size * 0.44, weight: .semibold))
            } else {
                Text(ConnectionIcons.initials(config.displayName))
                    .font(.system(size: size * 0.38, weight: .bold))
            }
        }
        .foregroundStyle(config.environment.ink)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum ConnectionIcons {
    /// The icon pack offered in the connection form.
    static let pack = [
        "cylinder.split.1x2.fill", "server.rack", "externaldrive.fill", "cloud.fill", "globe", "network", "cpu.fill", "terminal.fill",
        "building.2.fill", "house.fill", "briefcase.fill", "cart.fill", "bag.fill", "creditcard.fill", "chart.bar.fill", "chart.pie.fill",
        "person.2.fill", "envelope.fill", "bubble.left.and.bubble.right.fill", "bell.fill", "clock.fill", "book.fill", "graduationcap.fill", "doc.text.fill",
        "folder.fill", "shippingbox.fill", "gift.fill", "tag.fill", "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill", "testtube.2",
        "flask.fill", "ant.fill", "ladybug.fill", "lock.shield.fill", "key.fill", "bolt.fill", "flame.fill", "sparkles",
        "star.fill", "heart.fill", "leaf.fill", "tree.fill", "mountain.2.fill", "drop.fill", "sun.max.fill", "moon.fill",
        "cloud.sun.fill", "snowflake", "paperplane.fill", "airplane", "car.fill", "bicycle", "gamecontroller.fill", "music.note",
        "camera.fill", "paintpalette.fill", "cup.and.saucer.fill", "fork.knife", "pawprint.fill", "fish.fill", "bird.fill", "tortoise.fill",
        "hare.fill", "crown.fill", "trophy.fill", "flag.fill", "map.fill", "puzzlepiece.fill", "atom",
    ]

    /// The icon if it exists on this macOS version; otherwise nil, so initials are shown.
    static func validated(_ icon: String?) -> String? {
        guard let icon, NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil else { return nil }
        return icon
    }

    /// Two-letter monogram: initials of the first two meaningful words, or the first two letters.
    static func initials(_ name: String) -> String {
        let filler: Set<String> = ["on", "at", "the", "of", "and", "de", "la", "el"]
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !filler.contains($0.lowercased()) }
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return (String(a) + String(b)).uppercased()
        }
        return String((words.first ?? name).prefix(2)).uppercased()
    }
}

/// Grid of the icon pack, previewed in the connection's environment colors. "Initials" clears the icon.
struct ConnectionIconPicker: View {
    @Binding var config: ConnectionConfig
    @Environment(\.dismiss) private var dismiss
    private static let columnCount = 8

    /// Initials first, then the pack, in rows of eight.
    private var rows: [[String?]] {
        let cells: [String?] = [nil] + ConnectionIcons.pack.map { Optional($0) }
        return stride(from: 0, to: cells.count, by: Self.columnCount).map {
            Array(cells[$0..<min($0 + Self.columnCount, cells.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection icon").font(.headline)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(row, id: \.self) { cell(icon: $0) }
                    }
                }
            }
            .padding(2)
            Text("Initials are used when no icon is chosen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .fixedSize()
    }

    private func cell(icon: String?) -> some View {
        var preview = config
        preview.icon = icon
        let selected = ConnectionIcons.validated(config.icon) == icon
        return Button {
            config.icon = icon
            dismiss()
        } label: {
            ConnectionAvatar(config: preview, size: 34, shape: .roundedSquare)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2).padding(-3))
        }
        .buttonStyle(.plain)
        .help(icon.map { $0.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " ") } ?? "Initials")
        .accessibilityLabel(icon ?? "Initials")
    }
}
