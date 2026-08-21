import Foundation

/// Turns a pile of runs and samples into a ranked table, and refuses to rank things that are not
/// comparable.
///
/// Pure and `nonisolated`: it takes the history as arguments and returns rows. No store, no clock,
/// no I/O — so every comparability rule below is testable by handing it two runs.
nonisolated enum BenchmarkLeaderboard {

    // MARK: - Row

    struct Row: Identifiable, Equatable, Sendable {
        /// Group identity. Unique by construction, so `ForEach(id: \.id)` cannot collide the way
        /// a display label would (CLAUDE.md #22).
        let id: String
        var provider: LLMProvider
        var modelName: String
        /// The normalized server this model was measured against. Part of the identity, not
        /// decoration — see `groupKey`.
        var baseURLString: String
        /// Server version of the most recent contributing run, when the provider reports one.
        var providerVersion: String?
        /// Model file format (`gguf`, `mlx`, …) of the most recent contributing run — the same
        /// newest-run rule as `providerVersion`, because an Ollama tag re-pulled under the same
        /// name can genuinely change format or quantization, and then the latest measurement is
        /// the honest claim. Drawn as the `Format` column of both tables, and sortable like every
        /// other column there.
        var modelFormat: String?
        /// Quantization (`Q4_K_M`, `4bit`, …) of the most recent contributing run.
        var quantization: String?

        /// MEDIAN of the contributing runs' generation rates — not the best of them. A single
        /// thermally lucky run must not crown a model.
        var generationTokensPerSecond: Double?
        /// The source every contributing run agreed on, or `nil` when they disagreed — the same
        /// rule as `prefillSource`, and here for the same reason: a column that silently mixes a
        /// figure the server measured with one the app timed invites a comparison neither
        /// supports.
        var generationRateSource: GenerationRateSource?
        /// The best run's rate, shown beside the median so both are visible and neither has to
        /// stand in for the other.
        var bestGenerationTokensPerSecond: Double?
        var timeToFirstTokenMs: Double?
        var prefillTokensPerSecond: Double?
        /// The source every contributing run agreed on, or `nil` when they disagreed. A row whose
        /// prefill came from different measurements is not one figure.
        var prefillSource: PrefillSource?

        /// How many RUNS the median was taken over — never how many samples. A median over one
        /// run must not read as a median over seven.
        var runCount: Int
        /// Contributing runs that produced no usable sample at all, and therefore no figure.
        ///
        /// Counted WITHIN `contributing`, so a clean-run row does not report the throttled runs
        /// that were deliberately held back as failures: "we chose not to use it" and "it produced
        /// nothing" are different facts, and only the second is about the model. Without this the
        /// row said `2` after five attempts and nothing said what became of the other three.
        var failedRunCount: Int
        var lastMeasuredAt: Date
        /// Every contributing run was measured while the machine was throttled or in low-power
        /// mode, so these numbers describe the thermal state as much as the model.
        var isThrottled: Bool

        var prefillIsApproximate: Bool { prefillSource?.isApproximate ?? true }
        /// Unknown source reads as approximate, same rule as `prefillIsApproximate`: an unlabelled
        /// mixture is exactly what a reader must not take at face value.
        var generationRateIsApproximate: Bool { generationRateSource?.isApproximate ?? true }
    }

    // MARK: - Sorting

    /// Listed left-to-right as the leaderboard draws them, so a reader comparing this enum with
    /// the header row is comparing two orderings of one list rather than reconstructing it.
    enum SortColumn: String, CaseIterable, Sendable {
        case model
        case format
        case quantization
        case provider
        case providerVersion
        case generation
        case best
        case timeToFirstToken
        case prefill
        case runCount
        case lastMeasured
    }

    // MARK: - Building

    /// Group identity: provider + normalized server + model.
    ///
    /// The server belongs in the key. Two runs of the same model against different endpoints are
    /// two different machines, and averaging them produces a figure describing neither. The URL
    /// goes through `normalizedBaseURL` — the single canonicalizer in this codebase — because
    /// comparing raw strings would split one server into two on a trailing slash.
    static func groupKey(provider: LLMProvider, baseURLString: String, modelName: String) -> String {
        "\(provider.rawValue)|\(baseURLString.normalizedBaseURL)|\(modelName)"
    }

    /// Builds the ranked rows.
    ///
    /// - Parameters:
    ///   - currentPromptVersion: runs measured with any other prompt are dropped entirely. The
    ///     prompt version exists precisely so that a change of wording cannot silently place
    ///     incomparable numbers side by side.
    ///   - includeThrottled: when `false` (the default view), throttled runs do not contribute to
    ///     a model that also has clean ones. A model with ONLY throttled runs still produces a row,
    ///     marked — silently dropping it would hide that the measurement exists at all, the same
    ///     reason void samples are recorded rather than discarded.
    static func rows(
        runs: [GenerationBenchmarkRun],
        samples: [GenerationBenchmarkSample],
        currentPromptVersion: Int,
        includeThrottled: Bool = false
    ) -> [Row] {
        let samplesByRun = Dictionary(grouping: samples, by: \.runID)

        let comparable = runs.filter { $0.promptVersion == currentPromptVersion }
        let grouped = Dictionary(grouping: comparable) {
            groupKey(provider: $0.provider, baseURLString: $0.baseURLString, modelName: $0.modelName)
        }

        return grouped.compactMap { key, groupRuns -> Row? in
            // Prefer clean runs; fall back to the throttled ones rather than dropping the model.
            let clean = groupRuns.filter { !$0.wasThrottled }
            let contributing = (includeThrottled || clean.isEmpty) ? groupRuns : clean
            guard !contributing.isEmpty else { return nil }

            let summaries = contributing.map {
                BenchmarkMetricsPolicy.summarize(samplesByRun[$0.id] ?? [])
            }
            // A run with no usable sample contributes no rate; it must not silently count as one.
            let priced = summaries.filter { !$0.isFailed }
            guard !priced.isEmpty else { return nil }

            let generationRates = priced.map(\.generationTokensPerSecond)
            let sources = Set(priced.compactMap(\.prefillSource))
            let rateSources = Set(priced.compactMap(\.generationRateSource))
            let newest = contributing.max { $0.startedAt < $1.startedAt }

            return Row(
                id: key,
                provider: contributing[0].provider,
                modelName: contributing[0].modelName,
                baseURLString: contributing[0].baseURLString.normalizedBaseURL,
                providerVersion: newest?.providerVersion,
                modelFormat: newest?.modelFormat,
                quantization: newest?.quantization,
                generationTokensPerSecond: BenchmarkMetricsPolicy.median(generationRates),
                generationRateSource: rateSources.count == 1 ? rateSources.first : nil,
                bestGenerationTokensPerSecond: generationRates.compactMap { $0 }.max(),
                timeToFirstTokenMs: BenchmarkMetricsPolicy.median(priced.map(\.timeToFirstTokenMs)),
                prefillTokensPerSecond: BenchmarkMetricsPolicy.median(
                    priced.map(\.prefillTokensPerSecond)),
                prefillSource: sources.count == 1 ? sources.first : nil,
                runCount: priced.count,
                failedRunCount: summaries.count - priced.count,
                // `contributing` is guarded non-empty three statements above, so `newest` cannot
                // be nil and this fallback cannot fire. It reads `contributing[0]` rather than
                // 1 Jan 1970 because the field is drawn now: an unreachable branch that would
                // print a plausible-looking date from the Unix epoch is the kind of thing that
                // only becomes visible once someone changes the guard above it.
                lastMeasuredAt: newest?.startedAt ?? contributing[0].startedAt,
                isThrottled: contributing.allSatisfy(\.wasThrottled))
        }
    }

    /// Every run behind a row, by that row's id.
    ///
    /// Deliberately WIDER than the set of runs whose figures the row shows. `rows` holds throttled
    /// runs back when clean ones exist, and drops other prompt versions entirely — but all of them
    /// share this model-and-server identity, and a delete that spared them would put the row back
    /// on the next render, marked throttled or ranked from an older prompt. "I deleted it and it
    /// came back" is the failure this width exists to prevent, which is why the confirmation states
    /// the count this returns rather than the row's own `runCount`.
    static func runIDs(forRow rowID: String, in runs: [GenerationBenchmarkRun]) -> Set<UUID> {
        Set(
            runs.filter {
                groupKey(
                    provider: $0.provider, baseURLString: $0.baseURLString, modelName: $0.modelName)
                    == rowID
            }.map(\.id))
    }

    // MARK: - Ordering

    /// Sorts by one column, deterministically.
    ///
    /// Three rules, each load-bearing:
    ///
    /// 1. **Throttled rows always sort last**, in both directions. Their numbers describe the
    ///    thermal state, so letting one take the top slot on an ascending sort would be as wrong
    ///    as letting it take the top on a descending one.
    /// 2. **Missing values sort last**, in both directions. A `?? 0` would put a model with no
    ///    measured TTFT first, reading as zero latency.
    /// 3. **Ties break on model name, then provider** — never left to dictionary order. Without it
    ///    two equal rows swap places between renders.
    static func sorted(_ rows: [Row], by column: SortColumn, descending: Bool) -> [Row] {
        rows.sorted { lhs, rhs in
            if lhs.isThrottled != rhs.isThrottled { return !lhs.isThrottled }
            if let order = compare(lhs, rhs, by: column, descending: descending) { return order }
            if lhs.modelName != rhs.modelName { return lhs.modelName < rhs.modelName }
            return lhs.provider.rawValue < rhs.provider.rawValue
        }
    }

    /// `nil` when the two are equal on this column, so the caller applies the tie-break.
    private static func compare(
        _ lhs: Row, _ rhs: Row, by column: SortColumn, descending: Bool
    ) -> Bool? {
        switch column {
        case .model:
            return text(lhs.modelName, rhs.modelName, descending: descending)
        case .provider:
            return text(lhs.provider.displayName, rhs.provider.displayName, descending: descending)
        case .providerVersion:
            return optionalText(lhs.providerVersion, rhs.providerVersion, descending: descending)
        // The RAW value, not the uppercased one the column prints: `text` compares
        // case-insensitively, so the two orderings are identical — and sorting what is stored keeps
        // this enum independent of how a view decided to spell it.
        case .format:
            return optionalText(lhs.modelFormat, rhs.modelFormat, descending: descending)
        case .quantization:
            return optionalText(lhs.quantization, rhs.quantization, descending: descending)
        case .generation:
            return number(
                lhs.generationTokensPerSecond, rhs.generationTokensPerSecond, descending: descending)
        case .best:
            return number(
                lhs.bestGenerationTokensPerSecond, rhs.bestGenerationTokensPerSecond,
                descending: descending)
        case .timeToFirstToken:
            return number(lhs.timeToFirstTokenMs, rhs.timeToFirstTokenMs, descending: descending)
        case .prefill:
            return number(
                lhs.prefillTokensPerSecond, rhs.prefillTokensPerSecond, descending: descending)
        case .runCount:
            return number(Double(lhs.runCount), Double(rhs.runCount), descending: descending)
        case .lastMeasured:
            return number(
                lhs.lastMeasuredAt.timeIntervalSince1970, rhs.lastMeasuredAt.timeIntervalSince1970,
                descending: descending)
        }
    }

    /// Missing sorts last in BOTH directions — the `descending` flag deliberately does not reach
    /// the nil branch.
    private static func number(_ lhs: Double?, _ rhs: Double?, descending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        case (let l?, let r?):
            if l == r { return nil }
            return descending ? l > r : l < r
        }
    }

    private static func text(_ lhs: String, _ rhs: String, descending: Bool) -> Bool? {
        let order = lhs.localizedCaseInsensitiveCompare(rhs)
        if order == .orderedSame { return nil }
        return descending ? order == .orderedDescending : order == .orderedAscending
    }

    private static func optionalText(_ lhs: String?, _ rhs: String?, descending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        case (let l?, let r?): return text(l, r, descending: descending)
        }
    }
}
