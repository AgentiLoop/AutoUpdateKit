import Foundation
import Testing
@testable import AutoUpdateKit

@Suite struct VersionTests {
    @Test func compares() {
        #expect(AutoUpdater.isVersion("1.1.16", newerThan: "1.1.15"))
        #expect(AutoUpdater.isVersion("1.2", newerThan: "1.1.99"))
        #expect(AutoUpdater.isVersion("1.1.98.299", newerThan: "1.1.98.298"))
        #expect(!AutoUpdater.isVersion("1.1.15", newerThan: "1.1.15"))
        #expect(!AutoUpdater.isVersion("1.1", newerThan: "1.1.0"))
        #expect(!AutoUpdater.isVersion("1.1.x", newerThan: "1.0"))
    }

    @Test func picksNewestMatchingRelease() {
        let page = URL(string: "https://github.com/o/r/releases")!
        let zip = URL(string: "https://example.com/a.zip")!
        let releases = [
            AutoUpdater.Candidate(tag: "v1.1.99.299", draft: false, prerelease: true, notes: "", page: page, zip: zip),
            AutoUpdater.Candidate(tag: "v1.1.98.298", draft: false, prerelease: false, notes: "n", page: page, zip: zip),
            AutoUpdater.Candidate(tag: "v1.2.0.300", draft: true, prerelease: false, notes: "", page: page, zip: zip),
            AutoUpdater.Candidate(tag: "v1.3.0.301", draft: false, prerelease: false, notes: "", page: page, zip: nil),
            AutoUpdater.Candidate(tag: "mac-9.0", draft: false, prerelease: false, notes: "", page: page, zip: zip),
        ]
        #expect(AutoUpdater.pick(releases, tagPrefix: "v", newerThan: "1.1.97.297", prereleases: false)?.version == "1.1.98.298")
        #expect(AutoUpdater.pick(releases, tagPrefix: "v", newerThan: "1.1.97.297", prereleases: true)?.version == "1.1.99.299")
        #expect(AutoUpdater.pick(releases, tagPrefix: "v", newerThan: "1.1.98.298", prereleases: false) == nil)
        #expect(AutoUpdater.pick(releases, tagPrefix: "mac-", newerThan: "1.0", prereleases: false)?.version == "9.0")
    }
}
