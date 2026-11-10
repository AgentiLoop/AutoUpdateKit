//
//  AutoUpdater.swift
//  AutoUpdateKit
//
//  Extracted from StarPlayrXMac's Updater.swift.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import AppKit
import Security

/// What to update from and how a downloaded app is trusted.
public struct AutoUpdateConfiguration: Sendable {
    /// Shown in prompts ("Agent! 1.2.0 is available").
    public var appName: String
    /// GitHub `owner/repo` whose releases are checked.
    public var repository: String
    /// Release tags look like `<tagPrefix><version>` ("v1.1.98.298", "mac-1.1.15").
    public var tagPrefix: String
    /// Picks the zip asset (containing the .app) out of a release's assets.
    public var isUpdateAsset: @Sendable (String) -> Bool
    /// Apple Developer Team ID that must have signed the downloaded app (Developer ID).
    public var teamID: String
    /// Bundle identifier the downloaded app must have.
    public var bundleIdentifier: String
    /// The running version, compared numerically against the tag's version.
    public var installedVersion: String
    public var checkInterval: TimeInterval
    public var snoozeInterval: TimeInterval
    /// Delay before the first automatic check after `start()`.
    public var firstCheckDelay: TimeInterval
    /// UserDefaults keys. The pre-release key is a Bool the app can bind to a menu toggle.
    public var skippedVersionKey: String
    public var snoozedUntilKey: String
    public var prereleasesKey: String

    public init(appName: String,
                repository: String,
                tagPrefix: String = "v",
                isUpdateAsset: @escaping @Sendable (String) -> Bool = { $0.hasSuffix(".zip") },
                teamID: String,
                bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
                installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                checkInterval: TimeInterval = 6 * 3600,
                snoozeInterval: TimeInterval = 3600,
                firstCheckDelay: TimeInterval = 20,
                skippedVersionKey: String = "updateSkippedVersion",
                snoozedUntilKey: String = "updateSnoozedUntil",
                prereleasesKey: String = "updatePrereleases") {
        self.appName = appName
        self.repository = repository
        self.tagPrefix = tagPrefix
        self.isUpdateAsset = isUpdateAsset
        self.teamID = teamID
        self.bundleIdentifier = bundleIdentifier
        self.installedVersion = installedVersion
        self.checkInterval = checkInterval
        self.snoozeInterval = snoozeInterval
        self.firstCheckDelay = firstCheckDelay
        self.skippedVersionKey = skippedVersionKey
        self.snoozedUntilKey = snoozedUntilKey
        self.prereleasesKey = prereleasesKey
    }

    var releasesAPI: URL { URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")! }
    var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }
    /// What a downloaded app must satisfy before it replaces this one.
    var requirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(bundleIdentifier)\""
    }
}

/// Keeps an app up to date from its GitHub releases (zip asset with the .app inside).
/// A newer version is offered once: Update (download, verify the Developer ID signature, swap the
/// bundle in place and relaunch), Remind Me in 1 Hour, or No Thanks (that version is never offered again).
@MainActor
public final class AutoUpdater {
    public let configuration: AutoUpdateConfiguration

    public struct Release: Equatable, Sendable {
        public let version: String
        public let notes: String
        public let zip: URL
        public let page: URL
    }

    public enum UpdateError: LocalizedError {
        case notWritable(String, app: String), noApp(String), badSignature(OSStatus, app: String), unzip(Int32), http(Int)
        public var errorDescription: String? {
            switch self {
            case .notWritable(let path, let app): return "\(app) can't replace itself in \(path). Download the update and drag it to Applications."
            case .noApp(let app): return "The download didn't contain \(app)."
            case .badSignature(let s, let app): return "The downloaded app isn't signed by \(app)'s developer (code \(s)). It was not installed."
            case .unzip(let s): return "The download couldn't be unpacked (ditto exited \(s))."
            case .http(let code): return "GitHub returned HTTP \(code)."
            }
        }
    }

    public private(set) var busy = false
    private var timer: Timer?
    private var snooze: Timer?

    public init(configuration: AutoUpdateConfiguration) {
        self.configuration = configuration
    }

    private var defaults: UserDefaults { .standard }
    /// The version the user said No Thanks to: never offered again (a newer one is).
    private var skippedVersion: String? {
        get { defaults.string(forKey: configuration.skippedVersionKey) }
        set { defaults.set(newValue, forKey: configuration.skippedVersionKey) }
    }
    private var snoozedUntil: Date? {
        get { defaults.object(forKey: configuration.snoozedUntilKey) as? Date }
        set { defaults.set(newValue, forKey: configuration.snoozedUntilKey) }
    }
    /// Offer pre-releases too (UserDefaults Bool at `configuration.prereleasesKey`).
    public var includesPrereleases: Bool { defaults.bool(forKey: configuration.prereleasesKey) }

    /// First check shortly after launch, then every `checkInterval`. A snooze that is still running
    /// from the last session is honored (the check after it fires asks again).
    public func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: configuration.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(interactive: false) }
        }
        timer?.tolerance = 300
        let delay = configuration.firstCheckDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.check(interactive: false)
        }
    }

    /// Looks for a newer release and offers it. Returns its version ("" when up to date).
    /// Automatic checks respect No Thanks and a running snooze; an interactive one (a menu item)
    /// always asks, and says so when there is nothing newer.
    @discardableResult
    public func check(interactive: Bool) async -> String {
        guard !busy else { return "" }
        busy = true
        defer { busy = false }
        let name = configuration.appName
        let release: Release?
        do {
            release = try await Self.newestRelease(configuration, prereleases: includesPrereleases)
        } catch {
            if interactive { await UpdatePrompt.ask(title: "Couldn't check for updates", message: error.localizedDescription, buttons: ["OK"]) }
            return ""
        }
        guard let release else {
            if interactive {
                await UpdatePrompt.ask(title: "You're up to date", message: "\(name) \(configuration.installedVersion) is the newest version.", buttons: ["OK"])
            }
            return ""
        }
        if !interactive {
            // Skipped or snoozed: not offered, so there is no version to report — empty, like up to date.
            if release.version == skippedVersion { return "" }
            if let until = snoozedUntil, until > Date() { scheduleSnooze(until); return "" }
        }
        await offer(release)
        return release.version
    }

    private func offer(_ release: Release) async {
        let name = configuration.appName
        var message = "You have \(name) \(configuration.installedVersion). Would you like to update now?"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { message += "\n\n" + String(notes.prefix(600)) }
        switch await UpdatePrompt.ask(title: "\(name) \(release.version) is available", message: message,
                                      buttons: ["Update", "Remind Me in 1 Hour", "No Thanks"]) {
        case 0:
            skippedVersion = nil
            snoozedUntil = nil
            await install(release)
        case 1:
            scheduleSnooze(Date().addingTimeInterval(configuration.snoozeInterval))
        default:
            skippedVersion = release.version
            snoozedUntil = nil
        }
    }

    private func scheduleSnooze(_ until: Date) {
        snoozedUntil = until
        snooze?.invalidate()
        snooze = Timer.scheduledTimer(withTimeInterval: max(until.timeIntervalSinceNow, 1), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.snoozedUntil = nil
                await self?.check(interactive: false)
            }
        }
    }

    // MARK: Releases

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let html_url: URL
        let assets: [Asset]
    }

    public struct Candidate: Sendable {
        public let tag: String
        public let draft: Bool
        public let prerelease: Bool
        public let notes: String
        public let page: URL
        public let zip: URL?
        public init(tag: String, draft: Bool, prerelease: Bool, notes: String, page: URL, zip: URL?) {
            self.tag = tag; self.draft = draft; self.prerelease = prerelease; self.notes = notes; self.page = page; self.zip = zip
        }
    }

    /// The highest `<tagPrefix>X.Y.Z` release above the installed version that has a zip, or nil.
    nonisolated public static func newestRelease(_ config: AutoUpdateConfiguration, prereleases: Bool) async throws -> Release? {
        var request = URLRequest(url: config.releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.http(http.statusCode) }
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        return pick(releases.map { Candidate(tag: $0.tag_name, draft: $0.draft, prerelease: $0.prerelease, notes: $0.body ?? "", page: $0.html_url,
                                             zip: $0.assets.first { config.isUpdateAsset($0.name) }?.browser_download_url) },
                    tagPrefix: config.tagPrefix, newerThan: config.installedVersion, prereleases: prereleases)
    }

    nonisolated public static func pick(_ releases: [Candidate], tagPrefix: String, newerThan current: String, prereleases: Bool) -> Release? {
        releases.compactMap { r -> Release? in
            guard !r.draft, prereleases || !r.prerelease, r.tag.hasPrefix(tagPrefix), let zip = r.zip else { return nil }
            let version = String(r.tag.dropFirst(tagPrefix.count))
            guard isVersion(version, newerThan: current) else { return nil }
            return Release(version: version, notes: r.notes, zip: zip, page: r.page)
        }
        .max { isVersion($1.version, newerThan: $0.version) }
    }

    /// "1.1.16" > "1.1.15", "1.2" > "1.1.99"; anything non-numeric is not a version (never newer).
    nonisolated public static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ s: String) -> [Int]? {
            let p = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return p.allSatisfy { $0 != nil } ? p.map { $0! } : nil
        }
        guard let x = parts(a), let y = parts(b) else { return false }
        let n = max(x.count, y.count)
        let xs = x + Array(repeating: 0, count: n - x.count)
        let ys = y + Array(repeating: 0, count: n - y.count)
        return xs.lexicographicallyPrecedes(ys) == false && xs != ys
    }

    // MARK: Install

    /// Download → unzip → verify signature → swap bundles → relaunch. Any failure is reported, with
    /// the release page as the fallback, and leaves the installed app untouched.
    private func install(_ release: Release) async {
        let name = configuration.appName
        let current = Bundle.main.bundleURL
        let progress = ProgressWindow(title: "Downloading \(name) \(release.version)…")
        progress.show()
        defer { progress.close() }
        do {
            try await Self.replace(current, with: release.zip, requirement: configuration.requirement, appName: name,
                                   delegate: progress) {
                progress.set(text: "Installing \(name) \(release.version)…", indeterminate: true)
            }
            relaunch(current)
        } catch {
            progress.close()
            if await UpdatePrompt.ask(title: "The update couldn't be installed", message: error.localizedDescription,
                                      buttons: ["OK", "Open Download Page"]) == 1 {
                NSWorkspace.shared.open(release.page)
            }
        }
    }

    /// Downloads the zip at `download`, unpacks it, verifies the app inside against `requirement` and swaps it in
    /// for the bundle at `current`. Throws (leaving `current` untouched) on any failure. No UI, no relaunch, so
    /// tests can run the whole pipeline against a stand-in bundle.
    public static func replace(_ current: URL, with download: URL, requirement: String, appName: String = "the app",
                               delegate: URLSessionTaskDelegate? = nil, downloaded: () -> Void = {}) async throws {
        let fm = FileManager.default
        let folder = current.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else { throw UpdateError.notWritable(folder.path, app: appName) }
        // Same volume as the app, so the final moves are renames.
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
        defer { try? fm.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("update.zip")
        let (tmp, _) = try await URLSession.shared.download(for: URLRequest(url: download), delegate: delegate)
        try fm.moveItem(at: tmp, to: zip)
        downloaded()

        let unpacked = dir.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.unzip(ditto.terminationStatus) }
        guard let app = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.noApp(appName) }
        try verify(app, requirement: requirement, appName: appName)

        let old = dir.appendingPathComponent("old.app")
        try fm.moveItem(at: current, to: old)
        do {
            try fm.moveItem(at: app, to: current)
        } catch {
            try? fm.moveItem(at: old, to: current)
            throw error
        }
    }


    /// Developer ID signed by the configured team, same bundle identifier, every nested piece intact.
    nonisolated public static func verify(_ app: URL, requirement requirementString: String, appName: String = "the app") throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw UpdateError.badSignature(status, app: appName) }
        status = SecRequirementCreateWithString(requirementString as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw UpdateError.badSignature(status, app: appName) }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate))
        status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { throw UpdateError.badSignature(status, app: appName) }
    }

    /// A detached shell waits for this process to exit, then opens the new app at the same path.
    private func relaunch(_ app: URL) {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? sh.run()
        NSApp.terminate(nil)
    }
}
