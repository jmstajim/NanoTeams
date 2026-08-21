import Foundation

/// The one text-matching rule behind both benchmark tables.
///
/// Separate from `BenchmarkLeaderboard` because it answers a different question: that enum decides
/// what is COMPARABLE, this one decides what the reader is currently LOOKING FOR. Both tables ask
/// it — the leaderboard over aggregated rows, Runs over raw runs — so one query cannot mean one
/// thing on one tab and something else on the other. Pure and `nonisolated`: hand it a row and a
/// string, get a `Bool`.
nonisolated enum BenchmarkSearch {

    /// Does this leaderboard row match the query?
    ///
    /// The fields searched are the ones that NAME the row — model, provider, server version,
    /// endpoint, and the Format / Quantization columns. That set is deliberate: a row's identity is
    /// model AND server (`groupKey`), so a filter that could only see the model would be unable to
    /// separate the two rows the table deliberately keeps apart — and once "gguf" is printed on the
    /// row, a filter that cannot find it reads as broken.
    ///
    /// The endpoint stays searchable although the table stopped drawing it in a line of its own:
    /// it is still half the identity, still what the delete confirmation names, and still what the
    /// tooltip on a model's name shows.
    static func matches(_ row: BenchmarkLeaderboard.Row, query: String) -> Bool {
        matches(
            fields: [
                row.modelName, row.provider.displayName, row.providerVersion, row.baseURLString,
                row.modelFormat, row.quantization,
            ],
            query: query)
    }

    /// The same rule over a single run, so the Runs tab filters by exactly what the leaderboard
    /// filters by. The run carries the same names before any aggregation touches them.
    static func matches(_ run: GenerationBenchmarkRun, query: String) -> Bool {
        matches(
            fields: [
                run.modelName, run.provider.displayName, run.providerVersion, run.baseURLString,
                run.modelFormat, run.quantization,
            ],
            query: query)
    }

    /// Every whitespace-separated token must appear somewhere in the joined names.
    ///
    /// Token-AND rather than one substring of the whole query, because model ids are dense with
    /// separators (`qwen/qwen3-coder-30b-a3b-instruct-mlx`): a reader typing "qwen 30b" is asking
    /// for exactly that model, and a whole-string `contains` answers with nothing. Tokens are free
    /// to land in DIFFERENT fields, which is what makes "qwen studio" mean "that model, on LM
    /// Studio" — the query the two-machines-are-two-rows design invites.
    ///
    /// An empty or whitespace-only query matches everything: the field is a filter, not a gate.
    ///
    /// `localizedStandardContains` rather than `localizedCaseInsensitiveContains` — it is the
    /// search-field comparison, case- AND diacritic-insensitive, so `qwen` finds `Qwen`.
    private static func matches(fields: [String?], query: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        let haystack = fields.compactMap { $0 }.joined(separator: " ")
        return tokens.allSatisfy { haystack.localizedStandardContains($0) }
    }
}
