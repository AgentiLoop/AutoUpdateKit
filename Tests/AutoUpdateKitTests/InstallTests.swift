import Foundation
import Testing
@testable import AutoUpdateKit

/// End to end against the real Agent! GitHub releases: an "installed" 1.1.97.297 finds the newest release,
/// downloads its zip, verifies the Developer ID signature and swaps it in for a stand-in old bundle.
/// Needs network. Skip with AUTOUPDATEKIT_SKIP_NETWORK=1.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AUTOUPDATEKIT_SKIP_NETWORK"] == nil), .serialized)
struct InstallTests {
    static let config = AutoUpdateConfiguration(
        appName: "Agent!",
        repository: "AgentiLoop/Agent",
        tagPrefix: "v",
        isUpdateAsset: { $0.hasPrefix("Agent-v") && $0.hasSuffix("-macOS.zip") },
        teamID: "469UCUB275",
        bundleIdentifier: "Agent.app.toddbruss",
        installedVersion: "1.1.97.297"
    )

    /// A minimal "old" Agent!.app in a fresh writable folder.
    func makeOldApp() throws -> (folder: URL, app: URL) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("AutoUpdateKitTests-\(UUID().uuidString)", isDirectory: true)
        let app = folder.appendingPathComponent("Agent!.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "Agent.app.toddbruss",
                                    "CFBundleShortVersionString": "1.1.97", "CFBundleVersion": "297"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return (folder, app)
    }

    func version(of app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    @Test func updatesOldAppToNewestRelease() async throws {
        let release = try #require(try await AutoUpdater.newestRelease(Self.config, prereleases: false))
        #expect(AutoUpdater.isVersion(release.version, newerThan: "1.1.97.297"))

        let (folder, app) = try makeOldApp()
        defer { try? FileManager.default.removeItem(at: folder) }
        var downloaded = false
        try await AutoUpdater.replace(app, with: release.zip, requirement: Self.config.requirement, appName: "Agent!") {
            downloaded = true
        }
        #expect(downloaded)
        let info = try #require(Bundle(url: app)?.infoDictionary)
        let installed = "\(info["CFBundleShortVersionString"] as? String ?? "").\(info["CFBundleVersion"] as? String ?? "")"
        #expect(installed == release.version)
        // The swapped-in bundle is the genuine signed app.
        try AutoUpdater.verify(app, requirement: Self.config.requirement)
        // Staging folder cleaned up: only the app is left next to it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Agent!.app"])
    }

    @Test func refusesUpdateSignedForAnotherApp() async throws {
        let release = try #require(try await AutoUpdater.newestRelease(Self.config, prereleases: false))
        let (folder, app) = try makeOldApp()
        defer { try? FileManager.default.removeItem(at: folder) }
        var wrong = Self.config
        wrong.bundleIdentifier = "com.example.not-agent"
        await #expect {
            try await AutoUpdater.replace(app, with: release.zip, requirement: wrong.requirement)
        } throws: { error in
            if case AutoUpdater.UpdateError.badSignature = error { return true }
            return false
        }
        #expect(version(of: app) == "1.1.97")   // installed app untouched
    }
}
