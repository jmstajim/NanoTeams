import Foundation

/// External URLs used by the app (documentation, support, source).
/// Force-unwrapped because these are compile-time literal URLs — any malformed
/// string would crash immediately on first build, which is the desired behavior.
enum AppURLs {
    static let githubRepository = URL(string: "https://github.com/jmstajim/NanoTeams")!
    static let documentation = URL(string: "https://github.com/jmstajim/NanoTeams")!
    static let support = URL(string: "https://github.com/jmstajim/NanoTeams/issues")!
    /// GitHub Releases API endpoint for the latest release. Polled by
    /// `AppUpdateChecker` to detect available app updates.
    static let githubReleasesLatestAPI = URL(string: "https://api.github.com/repos/jmstajim/NanoTeams/releases/latest")!
}
