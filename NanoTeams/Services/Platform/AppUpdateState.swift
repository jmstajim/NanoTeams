import Foundation
import Observation

/// Observable wrapper around `AppUpdateChecker`. Two views over the same fetched
/// release:
/// - `latestRelease` — raw fetched payload, never filtered. Drives the Updates
///   settings tab so the user can always see what's available even after they
///   dismissed a tag in the Watchtower banner.
/// - `availableRelease` — filtered through `skippedAppUpdateTags`. Drives the
///   Watchtower banner so dismissed tags stay hidden there.
///
/// Background probes (`force == false`) swallow failures silently — an offline
/// user shouldn't see a banner for a check they didn't initiate. Forced probes
/// (`force == true`, the "Check for Updates" button) surface errors via
/// `lastCheckFailure`.
@Observable @MainActor
final class AppUpdateState {

    /// Raw latest release fetched from GitHub, unfiltered by skip list. May be
    /// stale (older than `AppVersion.current`) — consumers must compare.
    private(set) var latestRelease: AppUpdateChecker.Release?

    /// Latest release filtered through `skippedAppUpdateTags` AND the
    /// newer-than-current gate. `nil` = nothing to show in the Watchtower banner.
    var availableRelease: AppUpdateChecker.Release? {
        guard let latest = latestRelease else { return nil }
        return Self.isDisplayable(release: latest, skipped: config.skippedAppUpdateTags)
            ? latest
            : nil
    }

    /// True iff `latestRelease` is strictly newer than the running binary
    /// (regardless of skip status). Drives the "Update Now" button in the
    /// Updates settings tab.
    var hasNewerRelease: Bool {
        guard let latest = latestRelease else { return false }
        return AppVersion.compare(AppVersion.current, latest.tag) < 0
    }

    /// True iff the latest fetched release was previously dismissed from the
    /// Watchtower banner. Used to label the Updates tab status line.
    var isLatestSkipped: Bool {
        guard let latest = latestRelease else { return false }
        return config.skippedAppUpdateTags.contains(latest.tag)
    }

    /// Currently running a fetch. Used by the Settings "Check for Updates" button
    /// to show a spinner and disable re-entry.
    private(set) var isChecking: Bool = false

    /// Populated only on user-initiated failures (force == true). Background
    /// refreshes leave it `nil` so offline users don't see noise.
    private(set) var lastCheckFailure: String?

    /// Timestamp of the most recent successful check (background or forced).
    /// Reads through to `StoreConfiguration` so the value survives relaunches.
    var lastCheckedAt: Date? { config.lastAppUpdateCheckAt }

    @ObservationIgnored
    private let checker: AppUpdateChecker
    @ObservationIgnored
    let config: StoreConfiguration

    /// - Parameter checker: injected for testing. `nil` (the default) constructs
    ///   a `URLSession.shared`-backed instance inside the init body — `@MainActor`
    ///   default params would otherwise be evaluated off-actor.
    init(checker: AppUpdateChecker? = nil, config: StoreConfiguration) {
        self.checker = checker ?? AppUpdateChecker()
        self.config = config
        // Hydrate from cache so the status line is correct on launch even
        // before the first background refresh fires. The cache is intentionally
        // kept across upgrades — a stale "older than current" payload is fine
        // here because `hasNewerRelease` re-checks against `AppVersion.current`.
        self.latestRelease = config.cachedAppUpdateRelease
    }

    /// Performs a release check, respecting the user-configured throttle unless
    /// `force` is set. The "Check for Updates" button in the Updates settings
    /// tab passes `force: true` so the user always gets a fresh answer.
    ///
    /// On success: records `lastAppUpdateCheckAt`, updates `latestRelease` and
    /// the persisted cache. On failure: leaves state unchanged (timestamp NOT
    /// advanced) so the next probe retries.
    func refresh(force: Bool = false) async {
        if !force {
            // .never disables background probes entirely; the user can still
            // force one from the settings tab.
            guard let interval = config.appUpdateCheckInterval.seconds else {
                return
            }
            if let last = config.lastAppUpdateCheckAt,
               Date().timeIntervalSince(last) < interval
            {
                return
            }
        }
        isChecking = true
        if force { lastCheckFailure = nil }
        defer { isChecking = false }

        do {
            let release = try await checker.fetchLatestRelease()
            config.lastAppUpdateCheckAt = MonotonicClock.shared.now()
            // A successful refresh resolves any prior stale failure, even when
            // the user opened Settings after the failure but never re-clicked.
            lastCheckFailure = nil
            latestRelease = release
            config.cachedAppUpdateRelease = release
        } catch {
            // Background: silent — an offline user shouldn't see a banner.
            // Forced (user clicked "Check for Updates"): surface the diagnostic.
            if force {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                lastCheckFailure = message
            }
        }
    }

    /// Mark a release tag as skipped — hides the Watchtower banner for that tag
    /// only. The Updates settings tab still shows the release; users can install
    /// from there if they change their mind.
    func skip(_ tag: String) {
        config.skippedAppUpdateTags.insert(tag)
    }

    /// Removes a tag from the skip list so the Watchtower banner re-appears for
    /// it. Used by the Updates settings tab's "Show in Watchtower" affordance.
    func unskip(_ tag: String) {
        config.skippedAppUpdateTags.remove(tag)
    }

    /// True if the release is newer than the running binary and the user hasn't
    /// dismissed that specific tag.
    private static func isDisplayable(release: AppUpdateChecker.Release, skipped: Set<String>) -> Bool {
        let isNewer = AppVersion.compare(AppVersion.current, release.tag) < 0
        let isSkipped = skipped.contains(release.tag)
        return isNewer && !isSkipped
    }
}
