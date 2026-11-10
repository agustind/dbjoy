@testable import DBJoy
import Foundation
import Testing

struct UpdaterTests {
    @Test func comparesVersionsNumerically() {
        #expect(AppRelease.isVersion("0.4.10", newerThan: "0.4.9"))
        #expect(AppRelease.isVersion("1.0", newerThan: "0.9.9"))
        #expect(AppRelease.isVersion("0.4.15.1", newerThan: "0.4.15"))
        #expect(!AppRelease.isVersion("0.4.15", newerThan: "0.4.15"))
        #expect(!AppRelease.isVersion("0.4.15", newerThan: "0.4.15.0"))
        #expect(!AppRelease.isVersion("0.4.2", newerThan: "0.4.15"))
    }

    @Test func readsTheLatestRelease() throws {
        let json = """
            {"tag_name": "v0.4.16", "body": "- Undo commits", "html_url": "https://github.com/agustind/dbjoy/releases/tag/v0.4.16",
             "draft": false, "prerelease": false,
             "assets": [{"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
                        {"name": "DBJoy-0.4.16.dmg", "browser_download_url": "https://example.com/DBJoy-0.4.16.dmg",
                         "digest": "sha256:ABC123"}]}
            """
        let release = try #require(try AppRelease.parse(Data(json.utf8)))
        #expect(release.version == "0.4.16")
        #expect(release.dmg.lastPathComponent == "DBJoy-0.4.16.dmg")
        #expect(release.sha256 == "ABC123")
        #expect(release.notes == "- Undo commits")

        let noDMG = json.replacingOccurrences(of: "DBJoy-0.4.16.dmg", with: "DBJoy-0.4.16.zip")
        #expect(try AppRelease.parse(Data(noDMG.utf8)) == nil)
        let prerelease = json.replacingOccurrences(of: "\"prerelease\": false", with: "\"prerelease\": true")
        #expect(try AppRelease.parse(Data(prerelease.utf8)) == nil)
    }

    @Test func refusesAppsNotSignedByDBJoy() {
        #expect(throws: Updater.UpdateError.self) {
            try Updater.verifySignature(of: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        }
    }
}

/// Downloads the latest release from GitHub and stages it the way an update does, without installing it.
/// Enable with DBJOY_TEST_UPDATE=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBJOY_TEST_UPDATE"] != nil))
struct UpdaterDownloadTests {
    @Test func stagesAndVerifiesTheLatestRelease() async throws {
        let (data, _) = try await URLSession.shared.data(from: Updater.latestURL)
        let release = try #require(try AppRelease.parse(data))
        let (dmg, _) = try await URLSession.shared.download(from: release.dmg)
        let place = FileManager.default.temporaryDirectory.appendingPathComponent("dbjoy-update-test-\(UUID().uuidString)/DBJoy.app")
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: place.deletingLastPathComponent()) }

        let staged = try Updater.stage(dmg: dmg, sha256: release.sha256, besides: place)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        #expect(Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version)

        #expect(throws: Updater.UpdateError.self) {
            try Updater.stage(dmg: dmg, sha256: String(repeating: "0", count: 64), besides: place)
        }
        // Any change to the bundle breaks its signature.
        try Data("tampered".utf8).write(to: staged.appendingPathComponent("Contents/Resources/extra.txt"))
        #expect(throws: Updater.UpdateError.self) { try Updater.verifySignature(of: staged) }
    }
}
