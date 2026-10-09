import SwiftUI

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("DBJoy").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text("Version \(version)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }

            Text("A native macOS client for PostgreSQL.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)

            Rectangle().fill(Theme.separator).frame(height: 1).padding(.horizontal, 24)

            HStack(spacing: 5) {
                Text("Built with")
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .accessibilityLabel("love")
                Text("by")
                Link("Dondo.dev", destination: URL(string: "https://dondo.dev")!)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.accentText)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)

            Text("© 2026 Agu Dondo. MIT License.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 6)
        }
        .padding(28)
        .frame(width: 340)
        .background(Theme.contentBackground)
        .tint(Theme.accent)
    }
}
