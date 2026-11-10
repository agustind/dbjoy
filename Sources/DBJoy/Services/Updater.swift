import AppKit
import CryptoKit
import Foundation
import Observation
import Security
import SwiftUI

/// A DBJoy release on GitHub with its DMG.
struct AppRelease: Equatable, Sendable {
    var version: String
    var notes: String
    var page: URL
    var dmg: URL
    /// The asset's SHA-256 as GitHub reports it, when it does.
    var sha256: String?

    private struct Payload: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
            var digest: String?
        }
        var tag_name: String
        var body: String?
        var html_url: URL
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]
    }

    /// Reads GitHub's `releases/latest` response. `nil` without a DBJoy DMG.
    static func parse(_ data: Data) throws -> AppRelease? {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.draft != true, payload.prerelease != true,
              let asset = payload.assets.first(where: { $0.name.hasPrefix("DBJoy-") && $0.name.hasSuffix(".dmg") })
        else { return nil }
        let digest = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return AppRelease(version: payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name,
                          notes: payload.body ?? "", page: payload.html_url, dmg: asset.browser_download_url, sha256: digest)
    }

    /// Whether version `a` is newer than `b`, comparing dot-separated numbers ("0.4.10" > "0.4.9").
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// Checks GitHub for a newer release, then downloads, verifies and installs it over the running
/// app and relaunches. Only for the Developer ID build; the App Store updates its own build.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let latestURL = URL(string: "https://api.github.com/repos/agustind/dbjoy/releases/latest")!
    static let automaticKey = "updates.automatic"
    static let skippedKey = "updates.skippedVersion"
    /// What a downloaded DBJoy must be: notarized, ours, signed by our Developer ID team.
    nonisolated static let requirement = #"anchor apple generic and identifier "app.dbjoy.DBJoy" and certificate leaf[subject.OU] = "4637X2WX3Q" and notarized"#

    enum State: Equatable {
        case idle, checking, upToDate
        case available(AppRelease)
        case installing(AppRelease, step: String)
        case failed(String, page: URL?)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var schedule: Task<Void, Never>?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Running as a real app bundle outside the sandbox.
    static var isSupported: Bool {
        !Sandbox.isActive && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var checksAutomatically: Bool {
        UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true
    }

    /// Checks shortly after launch and then once a day, while automatic checks are on.
    func start() {
        guard Self.isSupported, schedule == nil else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                if Self.checksAutomatically { await self?.check(userInitiated: false) }
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    /// Looks for a newer release. Automatic checks stay quiet unless they find one the user didn't skip.
    func check(userInitiated: Bool) async {
        if case .installing = state { return showWindow() }
        if userInitiated {
            state = .checking
            showWindow()
        }
        do {
            var request = URLRequest(url: Self.latestURL, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("DBJoy/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("GitHub answered with status \((response as? HTTPURLResponse)?.statusCode ?? 0).")
            }
            guard let release = try AppRelease.parse(data),
                  AppRelease.isVersion(release.version, newerThan: Self.currentVersion) else {
                if userInitiated { state = .upToDate }
                return
            }
            if !userInitiated, UserDefaults.standard.string(forKey: Self.skippedKey) == release.version { return }
            state = .available(release)
            showWindow()
        } catch {
            if userInitiated { state = .failed("Couldn't check for updates. \(error.localizedDescription)", page: nil) }
        }
    }

    func skip(_ release: AppRelease) {
        UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        close()
    }

    func close() {
        if case .installing = state { return }
        state = .idle
        window?.close()
    }

    /// Downloads, verifies and swaps in the release, then relaunches.
    func install(_ release: AppRelease) async {
        let app = Bundle.main.bundleURL
        do {
            try Self.checkInstallable(app)
            state = .installing(release, step: "Downloading DBJoy \(release.version)…")
            let (download, _) = try await URLSession.shared.download(from: release.dmg)
            state = .installing(release, step: "Verifying…")
            let staged = try await Task.detached { try Self.stage(dmg: download, sha256: release.sha256, besides: app) }.value
            let version = Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            guard AppRelease.isVersion(version, newerThan: Self.currentVersion) else {
                throw UpdateError("The download is version \(version), which isn't newer than this one.")
            }
            state = .installing(release, step: "Installing…")
            _ = try FileManager.default.replaceItemAt(app, withItemAt: staged)
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            Self.relaunch(app)
        } catch {
            state = .failed((error as? UpdateError)?.message ?? error.localizedDescription, page: release.page)
        }
    }

    // MARK: Steps

    struct UpdateError: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// DBJoy can only replace itself where it's installed, and where the user can write.
    private static func checkInstallable(_ app: URL) throws {
        if app.path.contains("/AppTranslocation/") || app.path.hasPrefix("/Volumes/") {
            throw UpdateError("DBJoy is running from the disk image or Downloads. Drag it to Applications, open it from there and try again.")
        }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.path), fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw UpdateError("DBJoy can't replace itself in \(app.deletingLastPathComponent().path) because your account can't write there.")
        }
    }

    /// Checks the DMG, copies the app out of it next to `app` (same volume, so the swap is atomic) and
    /// checks the copy's signature. Returns the staged app.
    nonisolated static func stage(dmg: URL, sha256: String?, besides app: URL) throws -> URL {
        if let sha256 {
            let digest = SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe))
            guard digest.map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else {
                throw UpdateError("The download doesn't match the release's checksum.")
            }
        }
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        let mount = fm.temporaryDirectory.appendingPathComponent("dbjoy-update-\(UUID().uuidString)")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let staged = staging.appendingPathComponent("DBJoy.app")
        try run("/usr/bin/ditto", [mount.appendingPathComponent("DBJoy.app").path, staged.path])
        do {
            try verifySignature(of: staged)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return staged
    }

    nonisolated static func verifySignature(of app: URL) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess
        else { throw UpdateError("Couldn't read the downloaded app's signature.") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError("The downloaded app isn't signed and notarized by DBJoy's developer (error \(status)), so it wasn't installed.")
        }
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError("\((tool as NSString).lastPathComponent) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Opens the new app once this process has exited, then quits.
    private static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Window

    private func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.title = "Software Update"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: UpdateView(updater: self))
            window.center()
            self.window = window
        }
        // Brought forward without activating DBJoy, so a background check doesn't take focus.
        window?.makeKeyAndOrderFront(nil)
    }
}

struct UpdateView: View {
    var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            content
        }
        .padding(20)
        .frame(width: 520)
        .frame(minHeight: 150)
    }

    private var title: String {
        switch updater.state {
        case .idle, .checking: "Checking for updates…"
        case .upToDate: "You're up to date"
        case .available(let release): "DBJoy \(release.version) is available"
        case .installing(let release, _): "Updating to DBJoy \(release.version)"
        case .failed: "Couldn't update DBJoy"
        }
    }

    private var subtitle: String {
        switch updater.state {
        case .idle, .checking: "Looking at the latest release on GitHub."
        case .upToDate: "DBJoy \(Updater.currentVersion) is the latest version."
        case .available: "You have \(Updater.currentVersion). DBJoy relaunches after installing; reconnect to pick up where you were."
        case .installing(_, let step): step
        case .failed(let message, _): message
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case .idle, .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            buttons { Button("OK") { updater.close() }.buttonStyle(.primary).keyboardShortcut(.defaultAction) }
        case .available(let release):
            if !release.notes.isEmpty {
                ScrollView {
                    Text((try? AttributedString(markdown: release.notes,
                                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                         ?? AttributedString(release.notes))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 160)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border))
            }
            HStack {
                Button("Skip This Version") { updater.skip(release) }.buttonStyle(.ghost)
                Spacer()
                Button("Later") { updater.close() }.buttonStyle(.outline).keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { Task { await updater.install(release) } }
                    .buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        case .installing:
            ProgressView().progressViewStyle(.linear)
        case .failed(_, let page):
            buttons {
                if let page {
                    Button("Download from GitHub") { NSWorkspace.shared.open(page); updater.close() }.buttonStyle(.outline)
                }
                Button("Close") { updater.close() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack { Spacer(); content() }
    }
}
