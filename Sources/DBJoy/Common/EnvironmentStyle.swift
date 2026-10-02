import DBCore
import SwiftUI

extension ConnectionEnvironment {
    var color: Color {
        switch self {
        case .local: .gray
        case .development: .green
        case .testing: .teal
        case .staging: .orange
        case .production: .red
        }
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
