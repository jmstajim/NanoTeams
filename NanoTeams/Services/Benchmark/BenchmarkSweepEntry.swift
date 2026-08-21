import Foundation

/// One model in a sweep, and what became of it.
///
/// Runtime state, not a record: a sweep is not persisted, and what it produced is already on disk
/// as ordinary `GenerationBenchmarkRun` rows. This exists so the screen can show twelve models
/// going by, and so a finished sweep can say which of them failed without the reader having to
/// diff the leaderboard against the plan.
nonisolated struct BenchmarkSweepEntry: Identifiable, Equatable, Sendable {

    var target: BenchmarkTarget
    var state: State = .pending
    /// Whether this model takes part in the next run. Everything found is selected by default —
    /// the request was "measure them all", and a list that arrived empty would make the user tick
    /// twelve boxes to say what they already said by pressing the button.
    var isSelected: Bool = true

    /// The leaderboard's own group key, deliberately rather than a fresh identifier: a sweep row
    /// and the leaderboard row it produces then share ONE identity, so nothing has to define
    /// "the same model on the same server" twice and let the two definitions drift.
    ///
    /// It also satisfies CLAUDE.md #22 by construction — no index, no `String.hashValue` — and
    /// keeps one model name pulled on both providers distinct, since the provider leads the key.
    var id: String {
        BenchmarkLeaderboard.groupKey(
            provider: target.provider,
            baseURLString: target.baseURLString,
            modelName: target.modelName)
    }

    nonisolated enum State: Equatable, Sendable {
        /// Not reached yet.
        case pending
        /// This is the one being measured right now. The per-sample detail is not duplicated
        /// here — `GenerationBenchmarkRunner.phase` already says it, and a second copy would be
        /// a fact with two homes (CLAUDE.md #91).
        case measuring
        /// A run was recorded, and what it was worth.
        ///
        /// The WHOLE summary, not the one figure the row prints. It used to carry
        /// `generationTokensPerSecond: Double?` — and `BenchmarkRunOutcome` already held the
        /// summary at the construction site, so the narrowing threw away, among other things,
        /// which source the rate came from. The card could then no longer tell a server-measured
        /// rate from one the app timed, so it marked neither, and every sweep row printed as exact
        /// (CLAUDE.md #51). A seam must not narrow a value the caller already has in hand.
        ///
        /// "Recorded samples but none produced a rate" is still expressible — it is
        /// `summary.generationTokensPerSecond == nil` — and it is still a different outcome from
        /// a failure.
        case measured(BenchmarkMetricsPolicy.RunSummary)
        /// A run was attempted and produced nothing usable. Carries the reason, already worded
        /// for a reader by `GenerationBenchmarkRunner.describe`.
        case failed(String)
        /// Never attempted, because the sweep was stopped before it got here. Distinct from
        /// `.failed` on purpose: "we did not measure this" is not "this model is slow or broken",
        /// and a stopped sweep that marked its tail failed would be libelling every model in it.
        case skipped
    }
}

nonisolated extension BenchmarkSweepEntry.State {
    /// Reached a terminal state. Drives the "N of M done" counters and the settled edge the
    /// history table reloads on.
    var isSettled: Bool {
        switch self {
        case .pending, .measuring: false
        case .measured, .failed, .skipped: true
        }
    }
}
