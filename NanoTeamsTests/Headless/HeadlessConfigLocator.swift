import Foundation

/// Decides WHICH config file a headless run uses.
///
/// Extracted from `HeadlessRunnerTests` so the decision is unit-testable: it
/// used to be four lines inline in the test method, exercisable only by
/// performing a real run, and it silently disagreed with the wrapper.
/// `run_headless.sh` has always exported `NANOTEAMS_CONFIG_PATH`, but nothing
/// in Swift read it — the test hard-coded `<repoRoot>/.nanoteams/headless_task.json`,
/// so `./run_headless.sh some/config.json` ignored its own argument.
///
/// The three outcomes are deliberately distinct, because "no config" and "the
/// config you named isn't there" deserve opposite verdicts:
/// - `.found` — run it.
/// - `.missingOverride` — FAIL. The caller named a path; silence there is a bug
///   in the invocation, not a reason to skip.
/// - `.none` — SKIP. A bare `xcodebuild test` with no config is a legitimate
///   "the normal suite is running, headless isn't configured" state.
nonisolated enum HeadlessConfigLocator {

    /// Environment variable naming the config to run.
    ///
    /// `export`ing it is NOT enough: measured 2026-07-25, `xcodebuild test`
    /// runs the test host as a child of the build system rather than of the
    /// invoking shell, so an exported value never arrives. It has to travel
    /// through the test plan's `environmentVariableEntries`, which
    /// `run_headless.sh` injects for the duration of the run.
    static let environmentKey = "NANOTEAMS_CONFIG_PATH"

    /// Where the test drops a machine-readable record of what it decided.
    ///
    /// The wrapper cannot judge a run by its output: the test host's `stdout`
    /// does not reach `xcodebuild`'s, so every `[HEADLESS]` line the wrapper
    /// filters for is invisible to it — and a skipped XCTest still exits 0, so
    /// the status code says nothing either. That combination is exactly how a
    /// run that did nothing reported "completed successfully". A file the test
    /// writes at every exit path is the one signal that survives both.
    static let receiptEnvironmentKey = "NANOTEAMS_HEADLESS_RECEIPT"

    /// What the test decided, for the wrapper to act on.
    struct Receipt: Codable, Equatable {
        /// Typed rather than a bare string so a caller cannot invent a status
        /// the wrapper does not understand — `ran` is the ONLY value that means
        /// the work happened, and the wrapper treats everything else as
        /// "did not run".
        enum Status: String, Codable { case ran, skipped, failed }

        var status: Status
        var configPath: String?
        var detail: String
    }

    /// Best-effort: a missing receipt path just means nobody asked for one
    /// (a bare `xcodebuild test`), and a write failure must never turn a real
    /// run into a test failure.
    static func writeReceipt(
        _ receipt: Receipt,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard let path = environment[receiptEnvironmentKey],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = try? JSONEncoder().encode(receipt)
        else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Path the repository falls back to when no override is given. Kept
    /// because `.claude/skills/train-app` writes here and invokes `xcodebuild`
    /// directly, bypassing the wrapper.
    static let repositoryDefaultSubpath = ".nanoteams/headless_task.json"

    enum Source: Equatable { case environment, repositoryDefault }

    enum Resolution: Equatable {
        case found(URL, source: Source)
        case missingOverride(URL)
        case none(checked: URL)
    }

    /// `fileExists` is injected so tests never touch the disk.
    static func resolve(
        environment: [String: String],
        repositoryRoot: URL,
        fileExists: (URL) -> Bool
    ) -> Resolution {
        let raw = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !raw.isEmpty {
            // Relative overrides resolve against the repo root. The wrapper
            // already absolutizes, but a hand-run
            // `NANOTEAMS_CONFIG_PATH=cfg.json xcodebuild …` must not silently
            // miss because the test host's CWD is somewhere else entirely.
            let url = raw.hasPrefix("/")
                ? URL(fileURLWithPath: raw)
                : repositoryRoot.appendingPathComponent(raw)
            return fileExists(url) ? .found(url, source: .environment) : .missingOverride(url)
        }

        let fallback = repositoryRoot.appendingPathComponent(repositoryDefaultSubpath)
        return fileExists(fallback) ? .found(fallback, source: .repositoryDefault) : .none(checked: fallback)
    }
}
