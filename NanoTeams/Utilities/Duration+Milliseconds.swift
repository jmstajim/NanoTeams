import Foundation

nonisolated extension Duration {
    /// This duration in milliseconds.
    ///
    /// `Duration` exposes its magnitude only as a `(seconds, attoseconds)` pair, so every caller
    /// that wants a number ends up writing the same 1e15 division. It was already written twice —
    /// in `ToolRuntime` (which stamps `ToolCallLogRecord.durationMS`) and in the search benchmark
    /// — and the two have to agree for a benchmark figure to be comparable with a logged one.
    ///
    /// Pair with `ContinuousClock`, never `MonotonicClock`: the latter is an ORDERING source
    /// (`max(Date(), last + 1ms)` under a process-wide lock), so differences between its readings
    /// are not elapsed time.
    var milliseconds: Double {
        Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
