import Foundation

/// The fixed workload every benchmark run sends.
///
/// Versioned, and the version is recorded on every run: changing the wording changes how many
/// tokens the model produces and in what regime, so old rows stop being comparable the moment the
/// text moves. `BenchmarkLeaderboard` drops rows from other versions rather than ranking them
/// beside the current ones — which only works if the version is bumped whenever `text` changes.
///
/// **Bump `version` whenever the WORKLOAD changes — the text or `maxOutputTokens`. That is the
/// whole contract.** The version exists because "changing the wording changes how many tokens the
/// model produces and in what regime"; a ceiling on those tokens changes the same thing more
/// directly than any rewording could, so it lives under the same version.
///
/// Design of the text itself:
/// - **One alphabet, and the record says which.** The prompt is Latin-script English, by request,
///   and `id` names that regime (`prose-en`) so a row cannot be read as describing another. The
///   cost is real and worth stating rather than hiding: this codebase measured its own token
///   estimator at 0.78× on ASCII against 0.45× on Cyrillic, so tokens-per-character — and
///   therefore the tokens-per-second these figures report — belong to the script they were
///   measured on. Nothing here divides by an estimate; the counts are the server's. This bullet
///   read "Two alphabets … so both are exercised in one sample" until 2026-08-19, which was false
///   of the shipped text and contradicted by this file's own note 60 lines below.
/// - **Prose, no tools, no lists.** A tool call ends the turn after a handful of tokens, and a
///   rate measured over a handful of tokens is dominated by its own fence-post.
/// - **A length instruction AND a token cap.** The text still asks for ~400 words, because a
///   request that reads like real work produces a real answer; the cap is what makes the ASK
///   non-binding. Asking alone was measured to be worthless as a bound: on qwen3.5-9b this exact
///   prompt returned 12 040 tokens (96 % reasoning) against its request for 400 words, and the
///   same model spent 625 reasoning tokens on "Say OK". A thinking model decides its own length,
///   so a benchmark that only asks is measuring over a sequence it does not control.
nonisolated enum BenchmarkPrompt {

    static let id = "prose-en"
    /// 4 — the token ceiling (2026-08-19). Rows measured before it are not comparable with rows
    /// measured after: per-token decode cost grows with the sequence being attended to, so a run
    /// cut at 512 tokens reports a slightly higher rate than the same model left to produce
    /// 12 000. Dropping the old rows from the leaderboard is the honest outcome and the mechanism
    /// already exists — they stay visible under Runs.
    static let version = 4

    /// Hard ceiling on each sample's generated tokens, sent on the wire
    /// (`LLMConfig.maxOutputTokens`).
    ///
    /// Lives beside the prompt because it is part of the same thing: the WORKLOAD one sample
    /// measures. A rate is only comparable across models if the sequence it was measured over is
    /// comparable too, and before this the sequence was whatever each model felt like producing.
    /// The cap replaces that uncontrolled variable with a stated one — the number becomes "decode
    /// rate over the first 512 tokens", which is a claim a reader can check, rather than "decode
    /// rate over an unknown number of tokens".
    ///
    /// 512 rather than something smaller: it must clear `BenchmarkMetricsPolicy`'s floors by a
    /// wide margin (a rate needs ≥ 8 tokens and a window ≥ 50 ms, and the reported-rate branch is
    /// exactly where a handful of tokens lets the server's own arithmetic dominate — measured:
    /// LM Studio answers 1 000 000 tok/s for a one-token completion). Rather than something
    /// larger: at the ~50 tok/s of a local 9B this is ten seconds a sample, so a five-sample run
    /// stays the "about a minute" `AppDefaults.benchmarkRepeats` promises.
    static let maxOutputTokens = 512

    /// How many times the reference paragraph is repeated to reach a realistic prompt depth.
    ///
    /// MEASURED, not guessed: the task instruction alone is 81 prompt tokens on
    /// `qwen3.8:27b-mlx`, and at that depth `prompt_eval_duration` was 2.03 s — about 40 tok/s,
    /// which is the fixed per-request overhead of the first eval, not prefill throughput. A
    /// prefill figure taken there says nothing about the model and would read alarmingly low.
    /// Agentic prompts in this app are thousands of tokens, so the benchmark measures where the
    /// user actually works.
    ///
    /// 52 repetitions puts the prompt at 2 480 tokens on that model — measured, not estimated —
    /// where prefill came out at 449 tok/s against the 40 tok/s the shallow prompt reported. Deep
    /// enough for the throughput term to dominate the fixed cost, and cheap to READ: at those
    /// 449 tok/s the prefill of one sample is a few seconds.
    ///
    /// What a run costs is decided by `maxOutputTokens`, not by this number. Until that ceiling
    /// existed this comment claimed a five-sample run "stays around a minute", which was true of
    /// the prompt and false of the run: nothing bounded the ANSWER, and one measured sample of
    /// this very prompt ran 233 s.
    private static let referenceRepeats = 52

    /// The depth `referenceRepeats` actually produces, measured on `qwen3.8:27b-mlx`.
    ///
    /// A constant rather than a number retyped into prose. Three places describe this workload to
    /// a reader — the Prefill column's hover text and two comments in `BenchmarkWarmUpPolicy` —
    /// and all three said "2 500" while the measurement was 2 480. Nothing divides by this: it is
    /// documentation, and its only job is to be the one copy, so that changing `referenceRepeats`
    /// cannot leave three sentences describing a prompt that no longer exists (CLAUDE.md #123).
    ///
    /// Not derived, because deriving it would need a tokenizer this app does not have and the
    /// server's own count is per-run. Re-measure it when `referenceRepeats` or the paragraph
    /// changes: any run's `inputTokens` is the answer.
    static let measuredPromptTokens = 2480

    private static let referenceParagraph = """
    A derailleur moves the chain sideways across sprockets of different sizes while the rider \
    keeps pedalling, so the shift happens under load and depends on ramps and pins machined \
    into the sprockets themselves.
    """

    /// Reference material the model is told to ignore, sized to give the prompt real depth.
    ///
    /// English only, by request. Worth stating what that costs, because it is not nothing: the
    /// token-per-character regime differs sharply between Latin and Cyrillic (this codebase
    /// measured 0.78× vs 0.45× on its own estimator), so a figure taken here describes the Latin
    /// regime and nothing else. Nothing divides by an estimate — the token counts are the
    /// server's — but a model whose tokenizer handles one script better than another will not
    /// show that difference in these numbers.
    private static var referenceMaterial: String {
        Array(repeating: referenceParagraph, count: referenceRepeats)
            .enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n\n")
    }

    static var text: String {
        """
        Write an explanation of how a bicycle derailleur shifts gears, about 400 words.
        
        Plain prose only: no lists, no headings, no code, and do not call any tools.
        
        Reference material below — ignore it entirely, it is here only to give the prompt a
        realistic length. Do not summarise it, quote it, or mention it.
        
        \(referenceMaterial)
        """
    }

    /// The messages one sample sends. A single user turn — no system prompt, so the measured
    /// prompt is the same on both providers and nothing the app injects elsewhere can drift into
    /// the benchmark's prefill measurement.
    ///
    /// `nonce` leads the prompt, and it is what makes the prefill figure mean anything.
    ///
    /// Without it every sample after the first would send a BYTE-IDENTICAL prompt, hit the
    /// server's prompt-prefix (KV) cache, and report a prefill time that measures a cache lookup
    /// rather than prompt processing — while the warm-up, which pays the only cold prefill, is
    /// the one sample deliberately excluded from the medians. The number would look excellent and
    /// mean nothing. A LEADING nonce (not a trailing one) is what breaks the reuse: a cache
    /// matches on the prefix, so a marker at the end would still let the whole body hit.
    ///
    /// The same move as `benchmark_prompt_processing.sh`'s cold phase — "a fresh conversation …
    /// (unique prefix, cannot hit any cache)". Generation speed is unaffected either way; only
    /// the prefill figure depends on this.
    static func messages(nonce: String) -> [ChatMessage] {
        [ChatMessage(role: .user, content: prompt(nonce: nonce))]
    }

    /// The prompt one sample sends, as one string.
    ///
    /// Extracted from `messages(nonce:)` so the screen and the wire cannot spell it differently.
    /// What Settings shows is this function called with a marked placeholder instead of a nonce —
    /// not a second copy of the same frame, which is where the two would drift apart first.
    static func prompt(nonce: String) -> String { "Request \(nonce).\n\n\(text)" }

    // MARK: - The varying field

    /// Characters of nonce. Lives here rather than at the call site because the placeholder's
    /// honesty and the character count below are both arithmetic on this number.
    static let nonceLength = 8

    /// A fresh marker for one sample. Lowercase hex, fixed width.
    static func freshNonce() -> String {
        UUID().uuidString.prefix(nonceLength).lowercased()
    }

    /// What stands in for the nonce on screen.
    ///
    /// Guillemets and a word, never eight plausible hex digits: the ONE thing this display must
    /// not do is show a marker that could be mistaken for one that was really sent. It is also
    /// deliberately not `nonceLength` characters long, so the substitution is visible as a
    /// substitution and not as a value.
    static let noncePlaceholder = "‹fresh marker›"

    /// The prompt as a reader sees it — byte-for-byte what goes on the wire except the one field
    /// that is different in every sample, which is shown as a placeholder rather than as a value.
    static var canonicalText: String { prompt(nonce: noncePlaceholder) }

    /// Characters in one SENT sample, never in the displayed rendering.
    ///
    /// The placeholder is longer than a nonce, so `canonicalText.count` would overstate the real
    /// payload by six characters — small, and exactly the kind of number that gets quoted. The
    /// stand-in here is nonce-shaped, so this is the exact length of every sample rather than an
    /// estimate of one.
    static var charactersPerSample: Int {
        prompt(nonce: String(repeating: "0", count: nonceLength)).count
    }
}
