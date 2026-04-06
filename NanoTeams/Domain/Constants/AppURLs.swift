import Foundation

/// External URLs used by the app (documentation, support, source).
/// Force-unwrapped because these are compile-time literal URLs — any malformed
/// string would crash immediately on first build, which is the desired behavior.
enum AppURLs {
    static let githubRepository = URL(string: "https://github.com/jmstajim/NanoTeams")!
    static let documentation = URL(string: "https://github.com/jmstajim/NanoTeams")!
    static let support = URL(string: "https://github.com/jmstajim/NanoTeams/issues")!
}
