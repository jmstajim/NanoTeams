import Foundation

/// The fixed workload every benchmark run sends.
///
/// Versioned, and the version is recorded on every run: changing the wording changes how many
/// tokens the model produces and in what regime, so old rows stop being comparable the moment the
/// text moves. `BenchmarkLeaderboard` drops rows from other versions rather than ranking them
/// beside the current ones — which only works if the version is bumped whenever `text` changes.
///
/// **Bump `version` whenever the WORKLOAD changes — the text or `outputCeiling`. That is the
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
/// - **A length instruction AND a runaway guard.** The text still asks for ~400 words, because a
///   request that reads like real work produces a real answer. Asking alone was measured to be
///   worthless as a BOUND: on qwen3.5-9b this exact prompt returned 12 040 tokens (96 % reasoning)
///   against its request for 400 words, and the same model spent 625 reasoning tokens on "Say OK".
///   So `outputCeiling` bounds the damage — but it is a guard, not the window the rate is measured
///   over. A thinking model decides its own length, and version 5 measures that length rather than
///   cutting it: see `outputCeiling` for why cutting selects a slice instead of bounding one.
nonisolated enum BenchmarkPrompt {

    static let id = "prose-en"
    /// 5 — the ceiling stopped being the measurement window (2026-09-20). Rows measured before
    /// it are not comparable with rows measured after, and by a wide margin: on LM Studio 0.4.25 /
    /// `qwen3.8-27b-splash` (MLX 4bit, SPLASH engine, M5 Pro) the SAME prompt on the SAME loaded
    /// instance reported **35.6 tok/s cut at 512, 44.7 cut at 4 096, and 54.6 run to its own end**
    /// at 2 626 tokens. Dropping the old rows from the leaderboard is the honest outcome and the
    /// mechanism already exists — they stay visible under Runs.
    ///
    /// 4 — the token ceiling (2026-08-19). Its note claimed the bias ran the OTHER way: "a run cut
    /// at 512 tokens reports a slightly higher rate than the same model left to produce 12 000",
    /// reasoning that per-token decode cost grows with the sequence being attended to. Measured
    /// false in both sign and magnitude — the cut run reported 56 % LOWER, and depth moved the
    /// figure 3 % in the opposite direction (a 61-token prompt gave 35.0 tok/s against a
    /// 2 478-token prompt's 36.2, both cut at 512). Retracted here rather than deleted, because
    /// that claim is what shaped the ceiling.
    static let version = 5

    /// Ceiling on each sample's generated tokens, sent on the wire (`LLMConfig.maxOutputTokens`).
    ///
    /// A RUNAWAY GUARD, not the window the rate is measured over — and that distinction is the
    /// whole of version 5. The invariant: a healthy sample never reaches it. This prompt's own
    /// answer runs ~2 600 tokens on a 27B reasoning model, so 8 192 is three times the room it
    /// needs. A sample that DOES reach it is not measured but voided
    /// (`BenchmarkVoidReason.outputCeilingReached`), because a truncated sample reports the rate
    /// of its own truncation.
    ///
    /// **Why a window is the wrong idea here**, measured 2026-09-20 on LM Studio 0.4.25 /
    /// `qwen3.8-27b-splash`: on a serving that decodes speculatively, the rate follows how
    /// PREDICTABLE the generated text is. Same server, same model, same loaded instance — a prompt
    /// asking for one line repeated verbatim decodes at 88.8 tok/s across its first 128 tokens and
    /// 93–94 tok/s thereafter, while a prompt asking for unpredictable hex digits runs 38–60 and
    /// never climbs. Truncating the output therefore does not BOUND the measurement, it SELECTS a
    /// slice of it, and which slice depends on the model's own verbosity: a 512-token cut on this
    /// model landed entirely inside the slow opening, and on 2 of 3 samples never reached the
    /// answer at all (`reasoning_output_tokens == total_output_tokens`). The only stated window
    /// that survives speculative decoding is "the whole answer".
    ///
    /// 8 192 rather than no guard at all: `BenchmarkWarmUpPolicy` records a measured 12 040-token,
    /// 233-second sample of THIS prompt on qwen3.5-9b. That is what the guard is for, and a model
    /// that hits it on every sample now gets an honest "not measured" instead of a low number.
    ///
    /// It clears `BenchmarkMetricsPolicy`'s floors by three orders of magnitude (a rate needs
    /// ≥ 8 tokens and a window ≥ 50 ms — measured: LM Studio answers 1 000 000 tok/s for a
    /// one-token completion), which was the binding constraint on the old value and is not one
    /// here. What a run now costs is in `AppDefaults.benchmarkRepeats`.
    static let outputCeiling = 8192

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
    /// What a run costs is decided by how long the model ANSWERS, not by this number — see
    /// `AppDefaults.benchmarkRepeats`. Until `outputCeiling` existed this comment claimed a
    /// five-sample run "stays around a minute", which was true of the prompt and false of the run:
    /// nothing bounded the answer, and one measured sample of this very prompt ran 233 s.
    ///
    /// Depth is NOT what makes this model's figure what it is, and the measurement is here rather
    /// than in prose elsewhere because this is the constant that sets depth. Cut at 512 tokens on
    /// LM Studio 0.4.25 / `qwen3.8-27b-splash`: a 61-token prompt reported 35.0 tok/s, this
    /// 2 478-token prompt 36.2, and a 20 171-token prompt 29.8. Across two orders of magnitude of
    /// depth the decode rate moves a few per cent, against the 56 % the output window moves it.
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
