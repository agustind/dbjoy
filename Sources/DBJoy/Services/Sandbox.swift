import Darwin
import Foundation

/// The App Sandbox, which the Mac App Store build runs in.
enum Sandbox {
    static let isActive = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// The user's real home folder. Inside the sandbox NSHomeDirectory() and `~` point at the app's container.
    static let homeDirectory: URL = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// Expands a leading `~` to the real home folder.
    static func expandingTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory.path + path.dropFirst()
    }

    /// Abbreviates the real home folder to `~`.
    static func abbreviatingHome(_ path: String) -> String {
        let home = homeDirectory.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Command-line helpers shipped inside the app (Contents/Helpers): `pg_dump` and `dbjoy-askpass`.
enum BundledTools {
    /// The bundled tool, or during development (`swift run`, tests) the one built next to the binary.
    static func url(_ name: String) -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
            Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent(name),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private final class Marker {}
}
