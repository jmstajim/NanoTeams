import Foundation

/// Everything the sweep needs to ask the app's settings, and nothing else.
///
/// A protocol rather than a `StoreConfiguration` reference so the sequencer can be driven in tests
/// by a struct with four stored properties — and narrow (ISP) so it cannot grow into a second door
/// onto settings. The sweep asks these questions LIVE, on each target, rather than snapshotting
/// them at the start: an hour-long sweep will outlast some of the user's edits, and the honest
/// answer to "how many samples" is the one in force when the sample is taken.
@MainActor
protocol BenchmarkSweepSettings: AnyObject {

    /// The request this app would send to measure `target`.
    ///
    /// Owned by settings rather than assembled by the sweep because timeout and keep-alive are
    /// transport policy, not part of what is being compared — and a sweep that assembled its own
    /// would silently measure under different conditions than the Run button does, producing rows
    /// that share a leaderboard group and nothing else.
    func benchmarkConfig(for target: BenchmarkTarget) -> LLMConfig

    /// Measured samples per model, excluding the warm-up.
    var benchmarkRepeats: Int { get }

    /// Endpoints the app KNOWS for a provider — never a default standing in for one. What the
    /// sweep seeds its rows from before proposing anything.
    func knownLLMEndpoints(for provider: LLMProvider) -> [String]

    /// Providers switched off for the sweep. Read at seed time and written when the user toggles
    /// one, so the choice survives a relaunch.
    var benchmarkExcludedProviders: Set<LLMProvider> { get set }
}

/// The production conformance. Every member but one already existed; `benchmarkConfig(for:)` is
/// new here so that the screen's prompt preview, the Run button and the sweep all read the request
/// from ONE assembly — a second one is exactly how the preview and the wire come to disagree.
extension StoreConfiguration: BenchmarkSweepSettings {

    func benchmarkConfig(for target: BenchmarkTarget) -> LLMConfig {
        target.llmConfig(
            requestTimeoutSeconds: llmRequestTimeoutSeconds,
            keepAliveSeconds: globalLLMConfig.keepAliveSeconds)
    }
}
