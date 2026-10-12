import AppKit
import Darwin

/// Open and save panels run in a system service that checks the app's code signature. If the
/// app bundle is replaced while DBJoy runs (an update installed over it), that check fails:
/// creating the panel blocks the main thread for about 10 seconds and then shows nothing.
enum FilePanels {
    /// The executable's inode when DBJoy launched. Read it early, before an update can land.
    private static let launchInode = executableInode()

    static func recordLaunch() { _ = launchInode }

    /// Whether panels can open. If not, explains why and returns false.
    @MainActor static func available() -> Bool {
        guard let launchInode, let current = executableInode(), current != launchInode else { return true }
        let alert = NSAlert()
        alert.messageText = "Restart DBJoy to open files"
        alert.informativeText = "DBJoy was updated while it was running. macOS won't show open or save dialogs until you quit and reopen it."
        alert.runModal()
        return false
    }

    private static func executableInode() -> ino_t? {
        guard let path = Bundle.main.executablePath else { return nil }
        var info = stat()
        return stat(path, &info) == 0 ? info.st_ino : nil
    }
}
