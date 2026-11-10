# AutoUpdateKit

Self-updating for macOS apps distributed as Developer ID–signed zips on GitHub Releases.
Extracted from the StarPlayrX Mac updater and used by [Agent!](https://github.com/AgentiLoop/Agent).

- Checks `https://api.github.com/repos/<owner>/<repo>/releases` shortly after launch and every 6 hours.
- Offers a newer version once: **Update**, **Remind Me in 1 Hour**, or **No Thanks** (that version is never offered again).
- Update downloads the zip (with progress), unpacks it with `ditto`, verifies the new app's code signature
  (Developer ID, your Team ID, same bundle identifier, nested code, strict validation), swaps the bundle in place
  and relaunches. Any failure leaves the installed app untouched and offers the release page instead.
- Pre-releases are only offered when the UserDefaults Bool at `prereleasesKey` is on.

Requires macOS 14, Swift 6. The app must not be sandboxed (it replaces its own bundle) and its folder must be writable.

## Usage

```swift
.package(url: "https://github.com/AgentiLoop/AutoUpdateKit.git", from: "1.0.0")
```

```swift
import AutoUpdateKit

@MainActor let updater = AutoUpdater(configuration: AutoUpdateConfiguration(
    appName: "MyApp",
    repository: "owner/MyApp",                         // GitHub owner/repo
    tagPrefix: "v",                                    // tags look like v1.2.3
    isUpdateAsset: { $0.hasSuffix("-macOS.zip") },     // which release asset holds MyApp.app
    teamID: "ABCDE12345"                               // Developer ID team that must sign the update
))

updater.start()                                // automatic checks
await updater.check(interactive: true)         // "Check for Updates…" menu item
```

The installed version defaults to `CFBundleShortVersionString`; pass `installedVersion:` when your tags carry more
(e.g. `"\(short).\(build)"` for `v1.1.98.298`). Versions compare numerically, component by component.

## License

PolyForm Noncommercial 1.0.0 — see [LICENSE](LICENSE).

## Testing

`swift test` runs an end-to-end install against the real Agent! releases: a stand-in 1.1.97.297 app is updated to the newest
release (feed → download → unzip → signature check → swap), and an update signed for another bundle ID must be refused
with the old app left untouched. Needs network; set `AUTOUPDATEKIT_SKIP_NETWORK=1` to skip.
