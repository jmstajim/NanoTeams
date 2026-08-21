import Foundation

/// What one measurement produced, as a value.
///
/// `GenerationBenchmarkRunner` also exposes `phase`, `summary` and `lastRun` as observable
/// properties, and those are for RENDERING — a screen reads them to draw a spinner and a table.
/// This is for DECIDING: the sweep records a per-target outcome, and a decision taken by reading
/// two observable properties after an `await` is a contract that survives only until someone adds
/// a suspension point between them.
nonisolated struct BenchmarkRunOutcome: Equatable, Sendable {

    /// The record that was appended, or nil when nothing was — the run was cancelled before it
    /// measured anything.
    var run: GenerationBenchmarkRun?
    var summary: BenchmarkMetricsPolicy.RunSummary?
    /// The reader-facing sentence when the run produced nothing usable, nil when it did.
    ///
    /// Nil with a nil `run` is not success: it is the cancelled-at-the-door case, which recorded
    /// nothing and therefore has nothing to report either way. `recorded` is what tells the two
    /// apart, and callers must ask it rather than reading a nil `failure` as "fine".
    var failure: String?

    /// Nothing reached the history: the run was cancelled before it measured anything, or it was
    /// refused because a measurement was already in flight.
    ///
    /// One value for both because no caller needs to tell them apart — a sweep marks the entry
    /// "not measured" either way — and inventing two would invite someone to branch on a
    /// difference that carries no consequence.
    static let nothingRecorded = BenchmarkRunOutcome()

    /// The pair a recorded run produced, or nil when nothing reached the history.
    ///
    /// One accessor rather than a `Bool` beside two optionals each caller re-pairs: `run` and
    /// `summary` are written together at the single construction site and are therefore
    /// both-or-neither, and two fields that cannot vary independently must not be readable as if
    /// they could (CLAUDE.md #95).
    ///
    /// It also retires the old `generationTokensPerSecond` projection. That accessor was the whole
    /// mechanism of a lossy seam: the sweep asked it for one `Double`, threw away the rest of a
    /// summary this value already held, and could then no longer say whether the rate it printed
    /// had been measured or inferred — so it printed every one of them as exact. A caller wanting
    /// one figure now takes the summary and reads it there.
    var recorded: (run: GenerationBenchmarkRun, summary: BenchmarkMetricsPolicy.RunSummary)? {
        guard let run, let summary else { return nil }
        return (run, summary)
    }
}
