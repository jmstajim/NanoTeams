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
        /// The fastest single SAMPLE behind this row, shown beside the median so both are
        /// visible and neither has to stand in for the other.
        ///
        /// A sample, not a run's median — changed 2026-09-20, and the change is what makes this
        /// column mean something a reader can check against another tool. A chat window's footer
        /// reports ONE generation; the median reports the middle of many; a max over run medians
        /// reported neither, and on a two-run row it was simply the better of two medians.
        ///
        /// `max` grows with the number of samples drawn, so this figure is NOT comparable between
        /// rows whose `bestSampleCount` differ, and the column prints that count beside it rather
        /// than leaving the reader to assume equal bases.
        var bestGenerationTokensPerSecond: Double?
        /// How many usable samples `bestGenerationTokensPerSecond` was the maximum of.
        var bestSampleCount: Int
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
        /// Contributing runs whose every sample ran into `BenchmarkPrompt.outputCeiling`.
        ///
        /// Separate from `failedRunCount` because it is a different sentence: nothing failed, the
        /// model simply never stopped writing, and the honest report is "not measured" rather than
        /// a rate over the slice the ceiling admitted. Folding the two together would tell a user
        /// their server is broken when their model is merely verbose.
        var ceilingRunCount: Int
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

    /// A model that was measured on the current prompt and STILL produced no rankable row.
    ///
    /// Exists because "no row" and "no measurement" look identical on screen and have opposite
    /// fixes. The counters on `Row` — `failedRunCount`, `ceilingRunCount` — can only describe a
    /// model that kept at least one usable sample; a model whose every run was voided is dropped
    /// before those are computed, so without this it left the table with nothing said about it.
    struct Unranked: Equatable, Sendable {
        var modelName: String
        /// Contributing runs behind the model — the number the card's sentence names.
        var runCount: Int
        var reason: Reason

        /// The two reasons point at different fixes, which is the whole reason they are apart:
        /// one says the model writes too much, the other says the measurement broke.
        enum Reason: Equatable, Sendable {
            /// EVERY contributing run produced only samples an output bound cut short. Not a
            /// failure — the server answered and the model wrote; it simply never stopped.
            case everyRunHitTheCeiling
            /// EVERY contributing run was cut by the SERVER's own context window, below the
            /// ceiling the app asked for. A different fix from the one above — `num_ctx` on the
            /// server rather than a verbose model — and the likeliest of the three on a default
            /// Ollama install (DEBTS Q-6).
            case everyRunHitTheContextWindow
            /// Everything else, mixtures included. A model with one run cut by the ceiling and
            /// one that returned HTTP 500 is not a verbose-model story, so it lands here.
            case noUsableSample
        }
    }

    /// The ranked rows AND the models that could not be ranked, from one pass over one input.
    ///
    /// Two values rather than two functions: the second answer is a by-product of computing the
    /// first, and a separate entry point would have to redo the grouping, the throttle fallback
    /// and the summarising — three rules that would then have two homes to drift between.
    struct Table: Equatable, Sendable {
        var rows: [Row]
        /// Sorted by model name, because the source is a Dictionary and an unstable order would
        /// reshuffle a sentence on screen between renders.
        var unranked: [Unranked]
    }

    /// Builds the ranked rows.
    ///
    /// A view onto `table` — see there for the parameters. Kept because ranking is what almost
    /// every caller wants, and because it is the signature the tests and the card already speak.
    static func rows(
        runs: [GenerationBenchmarkRun],
        samples: [GenerationBenchmarkSample],
        currentPromptVersion: Int,
        includeThrottled: Bool = false
    ) -> [Row] {
        table(
            runs: runs, samples: samples, currentPromptVersion: currentPromptVersion,
            includeThrottled: includeThrottled
        ).rows
    }

    /// Builds the ranked rows, and names the models that could not be ranked.
    ///
    /// - Parameters:
    ///   - currentPromptVersion: runs measured with any other prompt are dropped entirely. The
    ///     prompt version exists precisely so that a change of wording cannot silently place
    ///     incomparable numbers side by side. Such a model is NOT reported as unranked — it is
    ///     out of scope rather than unrankable, and the card has its own sentence for it.
    ///   - includeThrottled: when `false` (the default view), throttled runs do not contribute to
    ///     a model that also has clean ones. A model with ONLY throttled runs still produces a row,
    ///     marked — silently dropping it would hide that the measurement exists at all, the same
    ///     reason void samples are recorded rather than discarded.
    static func table(
        runs: [GenerationBenchmarkRun],
        samples: [GenerationBenchmarkSample],
        currentPromptVersion: Int,
        includeThrottled: Bool = false
    ) -> Table {
        let samplesByRun = Dictionary(grouping: samples, by: \.runID)

        let comparable = runs.filter { $0.promptVersion == currentPromptVersion }
        let grouped = Dictionary(grouping: comparable) {
            groupKey(provider: $0.provider, baseURLString: $0.baseURLString, modelName: $0.modelName)
        }

        var rows: [Row] = []
        var unranked: [Unranked] = []

        for (key, groupRuns) in grouped {
            // Prefer clean runs; fall back to the throttled ones rather than dropping the model.
            let clean = groupRuns.filter { !$0.wasThrottled }
            let contributing = (includeThrottled || clean.isEmpty) ? groupRuns : clean
            guard !contributing.isEmpty else { continue }

            let summaries = contributing.map {
                BenchmarkMetricsPolicy.summarize(samplesByRun[$0.id] ?? [])
            }
            // A run with no usable sample contributes no rate; it must not silently count as one.
            let priced = summaries.filter { !$0.isFailed }
            guard !priced.isEmpty else {
                // Measured, and still no figure. Which of the two reasons decides what the user
                // should do about it, so the answer is carried out rather than re-guessed by the
                // view from a run count it can see but cannot interpret.
                // All-or-nothing on each: a MIXTURE of causes is not a story about either
                // bound, and saying it is would send the user to change the wrong setting.
                let cut = summaries.count { $0.everySampleHitCeiling }
                let windowed = summaries.count { $0.everySampleHitTheContextWindow }
                let reason: Unranked.Reason =
                    cut == summaries.count ? .everyRunHitTheCeiling
                        : windowed == summaries.count ? .everyRunHitTheContextWindow
                        : .noUsableSample
                unranked.append(Unranked(
                    modelName: contributing[0].modelName,
                    runCount: contributing.count,
                    reason: reason))
                continue
            }

            let generationRates = priced.map(\.generationTokensPerSecond)
            // Every usable sample of every contributing run, so `best` is a real generation
            // somebody could reproduce rather than the better of two medians.
            let sampleRates = contributing
                .flatMap { BenchmarkMetricsPolicy.usableSamples(samplesByRun[$0.id] ?? []) }
                .compactMap { BenchmarkMetricsPolicy.generationRate(for: $0)?.rate }
            let sources = Set(priced.compactMap(\.prefillSource))
            let rateSources = Set(priced.compactMap(\.generationRateSource))
            let newest = contributing.max { $0.startedAt < $1.startedAt }

            rows.append(Row(
                id: key,
                provider: contributing[0].provider,
                modelName: contributing[0].modelName,
                baseURLString: contributing[0].baseURLString.normalizedBaseURL,
                providerVersion: newest?.providerVersion,
                modelFormat: newest?.modelFormat,
                quantization: newest?.quantization,
                generationTokensPerSecond: BenchmarkMetricsPolicy.median(generationRates),
                generationRateSource: rateSources.count == 1 ? rateSources.first : nil,
                bestGenerationTokensPerSecond: sampleRates.max(),
                bestSampleCount: sampleRates.count,
                timeToFirstTokenMs: BenchmarkMetricsPolicy.median(priced.map(\.timeToFirstTokenMs)),
                prefillTokensPerSecond: BenchmarkMetricsPolicy.median(
                    priced.map(\.prefillTokensPerSecond)),
                prefillSource: sources.count == 1 ? sources.first : nil,
                runCount: priced.count,
                failedRunCount: summaries.count - priced.count,
                ceilingRunCount: summaries.count { $0.isFailed && $0.everySampleHitCeiling },
                // `contributing` is guarded non-empty three statements above, so `newest` cannot
                // be nil and this fallback cannot fire. It reads `contributing[0]` rather than
                // 1 Jan 1970 because the field is drawn now: an unreachable branch that would
                // print a plausible-looking date from the Unix epoch is the kind of thing that
                // only becomes visible once someone changes the guard above it.
                lastMeasuredAt: newest?.startedAt ?? contributing[0].startedAt,
                isThrottled: contributing.allSatisfy(\.wasThrottled)))
        }
        return Table(rows: rows, unranked: unranked.sorted { $0.modelName < $1.modelName })
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
