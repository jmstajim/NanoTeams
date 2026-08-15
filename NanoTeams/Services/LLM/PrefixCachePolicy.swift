import Foundation

/// Pure decision for "could the server reuse its prompt-prefix cache, and if not, why".
///
/// Exists because a miss is invisible. The transport is stateless — every request resends the
/// whole conversation — so a cache miss costs a full re-prefill (measured: ~350 ms warm vs
/// ~4300–6100 ms cold at 13k tokens) and still returns HTTP 200 with a correct answer. The user
/// experiences it only as "the model got slow", which points nowhere near the cause.
///
/// **What this type is careful NOT to claim.** An earlier design reported "another caller used
/// this model, so your cache was evicted". That is unsound here: the app streams N requests
/// concurrently against one model by construction (`ChatModelEnsurer` tracks `openRequests` as a
/// *count, not a flag*, precisely because "parallel roles legitimately stream against the same
/// model"), and a server that serves concurrent streams keeps more than one cache slot. So
/// interleaving does not imply eviction. Eviction is only ever reported when the SERVER confirms
/// it re-processed the prompt; an interleaving caller is then named as a suspect, not as a
/// verdict.
///
/// `nonisolated` because the app target defaults types to `@MainActor`; pure value-in /
/// value-out (house pattern: `ContextBudgetPolicy`, `LoopRecoveryPolicy`, `ConversationReplay`).
nonisolated enum PrefixCachePolicy {

    // MARK: - Tunables

    /// Below this many discarded tokens the re-prefill costs well under a second and a banner is
    /// noise. 2000 tokens ≈ 0.9 s at the measured cold rate; `bench_baseline` recorded 3281
    /// tokens cold = 1.5 s on Ollama and 870 tokens cold = 0.45 s.
    static let materialTokenThreshold = 2000

    /// Cold-prefill cost used to turn a token count into the number the user actually cares
    /// about. Derived from `bench_baseline/results.jsonl`: 6064 ms / 12927 tokens = 0.469 and
    /// 1516 ms / 3281 tokens = 0.462 on this machine's models.
    ///
    /// A DISPLAY estimate only — never a gate. Hardware and model size move it by an order of
    /// magnitude, so no decision may depend on it.
    ///
    /// It is also the FALLBACK, not the primary: both `bench_baseline` figures come from one
    /// model (`qwen3_5_moe` 35.1B, nvfp4 / 4-bit mlx), and a live `qwen3.8:27b-mlx` run measured
    /// 2.78 ms/token cold — 6.2× this — so the constant understated that popover by the same
    /// factor. `measuredExtraSeconds` below replaces it whenever the server reported enough to
    /// price the miss for real; this value survives for the callers that have no measurement
    /// (a structural miss decided before the send, and every test that builds a `Diagnosis`
    /// directly).
    static let estimatedColdPrefillMsPerToken = 0.45

    /// Turn a token count into the number the reader actually noticed.
    ///
    /// The ONE spelling of the ms→s conversion: `Diagnosis.estimatedSeconds` and
    /// `PrefixCacheReporter.estimatedSecondsLost` both route here (GRASP Information Expert —
    /// this type owns the rate), so re-deriving the rate from a real run cannot land on one
    /// surface and miss the other.
    static func estimatedSeconds(forTokens tokens: Int) -> Double {
        Double(tokens) * estimatedColdPrefillMsPerToken / 1000
    }

    /// What the miss actually cost, from the server's own numbers — no estimate anywhere.
    ///
    /// On a miss the server re-prefilled the prompt, so `prefillNsPerToken × promptTokens` is the
    /// measured price of this request, and `warmFloorNsPerToken × promptTokens` is what the same
    /// request would have cost had the prefix held. The difference is the extra work, and both
    /// terms are already in hand at the reporting site.
    ///
    /// Strictly better than `estimatedSeconds(forTokens:)` here because that one multiplies two
    /// estimates: a hardware-independent rate by `discardedTokens`, which is itself
    /// `ContextBudgetPolicy.estimateTokens` (measured 0.78–2.26× off depending on the corpus).
    ///
    /// `nil` — fall back — when any term is missing, or when the request came in at or below the
    /// warm floor. A non-positive difference means the numbers do not support a cost claim; it is
    /// not an occasion to invent one.
    static func measuredExtraSeconds(
        prefillNsPerToken: Double?, warmFloorNsPerToken: Double?, promptTokens: Int?
    ) -> Double? {
        guard let prefillNsPerToken, let warmFloorNsPerToken, let promptTokens, promptTokens > 0
        else { return nil }
        let extraNs = (prefillNsPerToken - warmFloorNsPerToken) * Double(promptTokens)
        guard extraNs > 0 else { return nil }
        return extraNs / 1_000_000_000
    }

    // MARK: - Cause

    /// Why the cache could not be reused. Ordered from "we did it" to "the server did it".
    enum Cause: Hashable {
        /// Segment 0 differs: the system prompt or the tool catalog rendered into it changed.
        /// The whole conversation re-prefills. Live inputs that can do this mid-run include the
        /// `.git` probe in `filterForGitAvailability`, a re-scanned `CLAUDE.md`, and the
        /// Autovisor rewriting its own memory.
        case systemPromptChanged

        /// This owner's own conversation diverged at `atSegment` — an in-place rewrite rather
        /// than an append. Everything from that index on re-prefills.
        case conversationRewritten(atSegment: Int)

        /// The replay was rebuilt from the display record instead of `wireTranscript`, which
        /// `ConversationReplay.Source.legacyConversation` documents as "not byte-identical to
        /// what was sent, so the prefix cache will miss once".
        case degradedReplay

        /// The server reported spending more than `minimumLoadMsForReload` loading the model for
        /// this request, so its cache was cold by definition. One threshold, no calibration — a
        /// learned floor would need N samples before it could decide anything, and the requests
        /// right after launch are exactly when a real reload happens.
        case modelReloaded

        /// The prefix we sent was intact and the model stayed loaded, yet the server still
        /// re-processed the prompt. `suspect` is the last other caller seen on the same
        /// (server, model) — named as a lead, not as a proven cause.
        case serverDroppedCache(suspect: String?)

        /// Coarse identity used to dedup banners. Two rewrites at different indices, or two
        /// evictions blamed on different suspects, call for the same action from the user, so
        /// they must not each earn their own banner.
        var causeClass: CauseClass {
            switch self {
            case .systemPromptChanged: .systemPromptChanged
            case .conversationRewritten: .conversationRewritten
            case .degradedReplay: .degradedReplay
            case .modelReloaded: .modelReloaded
            case .serverDroppedCache: .serverDroppedCache
            }
        }
    }

    /// `Cause` with its payload erased — the banner dedup key, and the identity the status-pill
    /// popover groups its rows by.
    enum CauseClass: String, Hashable, CaseIterable {
        case systemPromptChanged
        case conversationRewritten
        case degradedReplay
        case modelReloaded
        case serverDroppedCache

        /// Standalone row label for the status-pill popover.
        ///
        /// Lives here rather than on the view because it is data about this enum, and its sibling
        /// `explanation(for:)` already does — a reader adding a case meets both at once instead of
        /// finding one and shipping a blank popover row. Deliberately a `switch` and not a
        /// metadata dictionary (the house OCP idiom elsewhere): a dictionary would trade the
        /// compiler's exhaustiveness check for a runtime lookup, and that check is the only thing
        /// that makes "add a case" safe here.
        ///
        /// Not merged with `explanation(for:)`: that one takes the payload-BEARING `Cause` (it
        /// renders `atSegment` and `suspect`) and reads mid-sentence inside the banner, while this
        /// is a title-case label standing on its own. One string cannot be both.
        var label: String {
            switch self {
            case .systemPromptChanged: "System prompt or tool catalog changed"
            case .conversationRewritten: "Conversation rewritten instead of appended to"
            case .degradedReplay: "Resumed from a rebuilt conversation"
            case .modelReloaded: "Server reloaded the model"
            case .serverDroppedCache: "Server dropped the cached prefix"
            }
        }
    }

    // MARK: - Verdict

    struct Diagnosis: Hashable {
        var cause: Cause
        /// Segments the server can still reuse.
        var commonSegments: Int
        /// Segments the previous request had.
        var previousSegments: Int
        /// Estimated tokens that must be re-processed.
        var discardedTokens: Int

        /// The server-measured cost of this miss, when the reporting site could price it (see
        /// `PrefixCachePolicy.measuredExtraSeconds`). Last member with a default so every existing
        /// construction — production and test — stays source-compatible and keeps the estimate.
        var measuredExtraSeconds: Double?

        /// Measured when we have it, estimated when we do not. Never both: a mixture would be
        /// neither, and the caller cannot tell which it got.
        var estimatedSeconds: Double {
            measuredExtraSeconds ?? PrefixCachePolicy.estimatedSeconds(forTokens: discardedTokens)
        }

        init(
            cause: Cause,
            commonSegments: Int,
            previousSegments: Int,
            discardedTokens: Int,
            measuredExtraSeconds: Double? = nil
        ) {
            self.cause = cause
            self.commonSegments = commonSegments
            self.previousSegments = previousSegments
            self.discardedTokens = discardedTokens
            self.measuredExtraSeconds = measuredExtraSeconds
        }
    }

    enum Verdict: Hashable {
        /// Nothing to compare against for this owner yet. Never a miss — a genuinely new
        /// conversation has to be prefilled once and that is inherent, not a defect.
        case firstRequestForOwner
        /// The prefix was byte-identical and nothing contradicted it. Not proof of a hit; only
        /// proof that we did not break it.
        case reused(segments: Int)
        case missed(Diagnosis)

        var diagnosis: Diagnosis? {
            if case .missed(let diagnosis) = self { return diagnosis }
            return nil
        }
    }

    // MARK: - Decision

    /// Compare an outgoing chain against this owner's previous one.
    ///
    /// `previous == nil` is `.firstRequestForOwner`.
    ///
    /// A miss requires the two chains to actually DISAGREE at a shared index. Sending a strict
    /// prefix of what was cached is a full hit — the cache is a prefix, so a shorter request
    /// reuses it entirely — which is why the bound is `min(previous.count, current.count)` and
    /// not `previous.count`. (The planning-phase boundary is still correctly a miss: it slices
    /// the tail AND appends a seed turn, so the seed disagrees with the first dropped turn. That
    /// one is exempted by the caller, deliberately, rather than hidden here.)
    static func compare(
        previous: [UInt64]?,
        current: [UInt64],
        discardedTokens: Int
    ) -> Verdict {
        guard let previous, !previous.isEmpty else { return .firstRequestForOwner }

        let common = PromptPrefixFingerprint.commonPrefixLength(previous, current)
        guard common < min(previous.count, current.count) else {
            return .reused(segments: common)
        }

        let cause: Cause = common == 0
            ? .systemPromptChanged
            : .conversationRewritten(atSegment: common)
        return .missed(Diagnosis(
            cause: cause,
            commonSegments: common,
            previousSegments: previous.count,
            discardedTokens: discardedTokens))
    }

    // MARK: - Cost of the discarded suffix

    /// Tokens the server has to re-process given that it can reuse `commonSegments` segments.
    ///
    /// Segment 0 is the system prompt plus whatever tool catalog the builder will still append
    /// to it (for a role step: none — the catalog is already INSIDE that system prompt), and
    /// segment `i` (for `i >= 1`) is the `i-1`-th NON-system message — the same mapping
    /// `PromptPrefixFingerprint.chain` builds.
    /// So `commonSegments == 0` discards everything including the system prompt, which is why
    /// `systemPromptChanged` is the most expensive cause there is.
    ///
    /// Reuses `ContextBudgetPolicy.estimateTokens`, the same estimator that decides whether a
    /// prompt overflows, so the two surfaces cannot drift into disagreeing about what a token is.
    static func discardedTokens(
        messages: [ChatMessage],
        toolSchemaText: String,
        commonSegments: Int
    ) -> Int {
        guard commonSegments > 0 else {
            return ContextBudgetPolicy.estimateTokens(
                messages: messages, toolSchemaText: toolSchemaText)
        }
        let nonSystem = messages.filter { $0.role != .system }
        let dropped = nonSystem.count > commonSegments - 1
            ? Array(nonSystem[(commonSegments - 1)...])
            : []
        return ContextBudgetPolicy.estimateTokens(messages: dropped)
    }

    // MARK: - Server-side confirmation

    /// What the server reported about this request. Both fields are absent on providers or
    /// versions that do not report them; absence is never evidence of anything.
    struct ServerSignals: Hashable {
        /// Milliseconds the server says it spent loading the model, VERBATIM. A non-zero value is
        /// NOT by itself a reload — see `minimumLoadMsForReload`. LM Studio
        /// `model_load_time_seconds`, Ollama `load_duration`.
        var modelLoadMs: Double?
        /// Ollama only: `prompt_eval_duration / prompt_eval_count`. Pure server-measured
        /// prefill, decode excluded.
        ///
        /// LM Studio's `time_to_first_token_seconds` is deliberately NOT used here — it includes
        /// queue time, and this app streams parallel roles against one model as its normal mode,
        /// so a queued warm request would look identical to a cold one.
        var prefillNsPerToken: Double?
        /// Tokens the server says it prefilled — the DENOMINATOR of `prefillNsPerToken`, and the
        /// reason that rate is only comparable against a floor sampled at a similar depth.
        var promptTokens: Int?

        init(
            modelLoadMs: Double? = nil,
            prefillNsPerToken: Double? = nil,
            promptTokens: Int? = nil
        ) {
            self.modelLoadMs = modelLoadMs
            self.prefillNsPerToken = prefillNsPerToken
            self.promptTokens = promptTokens
        }
    }

    /// How long a reported model load has to be before it counts as a RELOAD.
    ///
    /// Deliberately not `> 0`. Ollama reports a small non-zero `load_duration` on EVERY request
    /// with the model already resident: across `bench_baseline/results.jsonl` the single genuine
    /// cold load is 2236.6 ms while the other 26 Ollama rows report 20.6–25.1 ms and never 0 (a
    /// live run has been seen at 30.5 ms). LM Studio's `model_load_time_seconds` is exactly 0 on
    /// all 27 of its rows — so `> 0` broke hardest on the provider that reports the signal at
    /// all, and, returning first, it also made `serverDroppedCache` below unreachable.
    ///
    /// 1000 ms sits ~33× above the highest warm figure ever observed and 2.2× below the measured
    /// cold load. It is also the number `benchmark_prompt_processing.sh` voids a sample on
    /// (`MODEL_RELOAD_MS`) — the baseline quoted here was produced by that very rule, so the two
    /// cannot hold different values. `PrefixCacheThresholdParityPinTests` fails if they drift.
    ///
    /// Erring HIGH is the deliberate choice. This banner is always on, so a false positive costs
    /// the whole feature ("a warning nobody believes is worse than no warning"), while a missed
    /// reload costs only the silence that existed before the feature — and a real reload does not
    /// vanish either, since it also re-prefills and can still be caught by the measured branch.
    static let minimumLoadMsForReload = 1000.0

    /// How far above the warm floor a prefill has to land before it counts as "the server
    /// re-processed the prompt". `bench_baseline` measured a 16–18× gap between warm and cold on
    /// this project's models; 4× is far enough below that to survive hardware variance and far
    /// enough above 1× that ordinary jitter cannot reach it.
    static let serverRePrefillFactor = 4.0

    /// A floor built from fewer samples than this is not a floor, it is the first sample — and
    /// the first sample of a fresh conversation is usually cold.
    static let minimumPrefillSamplesForFloor = 3

    /// How much shallower than the floor's own sample a request may be and still be compared
    /// against it.
    ///
    /// `prompt_eval_count` is the size of the WHOLE prompt, while `prompt_eval_duration` on a
    /// cache hit covers only the new tokens plus a fixed overhead — so the rate is roughly
    /// `overhead / depth`, and on `bench_baseline` it falls 11× from K=1000 to K=16000 across
    /// warm turns alone. Comparing a shallow request against a floor sampled deep compares two
    /// different amortizations: 9 of the 20 warm rows clear a 4× gate that way, the worst at
    /// 35.5×. Restricted to comparable depths the same rows top out at 1.62× while the cheapest
    /// cold sample is 86.8× — ~54× of headroom at the EXISTING `serverRePrefillFactor`.
    ///
    /// A suppression guard: it can only ever skip a real eviction at shallow depth, never
    /// manufacture one. Same direction of error as `minimumLoadMsForReload`.
    static let comparableDepthFraction = 0.5

    /// Largest APPENDED tail (tokens the server has not seen before) for which the prefill-rate
    /// comparison still means anything.
    ///
    /// On a cache hit the server spends `overhead + appended × rate`, so the rate this branch
    /// gates on is `overhead/total + (appended/total) × coldRate`. The second term is a HIT's own
    /// honest cost, and past a few hundred appended tokens it alone clears the 4× gate — a
    /// `read_file` result lands a legitimate reuse squarely in eviction territory. Solving
    /// `appended × coldRate = 4 × overhead` on `bench_baseline` gives the break-even at 453 / 565
    /// / 597 appended tokens (K=1000 / 4000 / 16000); 256 keeps ~1.8× of margin under the
    /// tightest of them.
    ///
    /// **The calibration data cannot see this.** Every accepted row in `bench_baseline` replies
    /// with 8 tokens to a fixed prompt, so the appended tail is 0-1 tokens in all 20 of them —
    /// `serverRePrefillFactor` was fitted entirely inside the regime where this term vanishes,
    /// while a tool loop lives outside it.
    ///
    /// Narrowing rather than widening is also what makes the branch mean something: an eviction
    /// shows up as a LARGE re-prefill for a SMALL append. When the append is big, "the server
    /// re-processed a lot" is not evidence of anything.
    static let maxAppendedTokensForRateComparison = 256

    /// Combine what we know we did with what the server reported.
    ///
    /// Order matters. A structural miss DOMINATES: if we rewrote the prefix ourselves, that is
    /// both the true cause and the actionable one, and blaming the server would send the user
    /// looking in the wrong place. Server signals are consulted only when we are confident the
    /// prefix we sent was intact.
    ///
    /// They are also consulted only on `.reused` and never on `.firstRequestForOwner`: a brand
    /// new conversation has nothing to lose, so a model load there is inherent, not a defect.
    /// `locallyReloaded` is the second evidence channel for the SAME cause, and the only one that
    /// works on LM Studio: it reports `model_load_time_seconds` as 0 on every warm row, while its
    /// residency is managed by this app. Categorical rather than measured — "we loaded it" needs
    /// no threshold, unlike the server figure beside it — and checked in the same slot, so the
    /// two channels can never produce two reports for one reload.
    static func resolve(
        structural: Verdict,
        server: ServerSignals,
        locallyReloaded: Bool = false,
        warmFloorNsPerToken: Double?,
        warmFloorPromptTokens: Int?,
        floorSampleCount: Int,
        suspect: String?,
        totalPromptTokens: Int,
        appendedTokens: Int
    ) -> Verdict {
        if structural.diagnosis != nil { return structural }
        guard case .reused(let segments) = structural else { return structural }

        func miss(_ cause: Cause) -> Verdict {
            .missed(Diagnosis(
                cause: cause,
                commonSegments: 0,
                previousSegments: segments,
                discardedTokens: totalPromptTokens))
        }

        if locallyReloaded { return miss(.modelReloaded) }

        if let load = server.modelLoadMs, load > minimumLoadMsForReload {
            return miss(.modelReloaded)
        }

        if let ratio = server.prefillNsPerToken,
           let floor = warmFloorNsPerToken, floor > 0,
           floorSampleCount >= minimumPrefillSamplesForFloor,
           appendedTokens <= maxAppendedTokensForRateComparison,
           isComparableDepth(requestTokens: server.promptTokens, floorTokens: warmFloorPromptTokens),
           ratio > floor * serverRePrefillFactor
        {
            return miss(.serverDroppedCache(suspect: suspect))
        }

        return structural
    }

    /// Whether a request's prefill rate may be compared against a floor sampled at
    /// `floorTokens` — see `comparableDepthFraction`.
    ///
    /// Unknown depth on either side means the comparison cannot be made honestly, so it is
    /// skipped. That is unreachable in production (`ServerPrefillReport.nsPerToken` already
    /// requires a positive `promptTokens`, and the floor records the depth it was sampled at),
    /// and the safe answer for a caller that somehow lacks it.
    static func isComparableDepth(requestTokens: Int?, floorTokens: Int?) -> Bool {
        guard let requestTokens, let floorTokens, floorTokens > 0 else { return false }
        return Double(requestTokens) >= Double(floorTokens) * comparableDepthFraction
    }

    // MARK: - Presentation

    /// The banner text. Opens by stating the miss was not supposed to happen, then names the
    /// cause — the framing the feature was asked for.
    ///
    /// Always carries the SECONDS estimate next to the token count: "12900 tokens" means nothing
    /// to a reader, "~5.8s" is the thing they actually noticed.
    static func warningMessage(modelName: String, diagnosis: Diagnosis) -> String {
        "Prompt cache miss — this shouldn't have happened. "
            + "\(modelName) re-processed \(formatTokens(diagnosis.discardedTokens)) tokens "
            + "(~\(formatSeconds(diagnosis.estimatedSeconds))): \(explanation(for: diagnosis.cause))."
    }

    static func explanation(for cause: Cause) -> String {
        switch cause {
        case .systemPromptChanged:
            "the system prompt or tool catalog changed, so nothing could be reused"
        case .conversationRewritten(let index):
            "this role's conversation was rewritten at message \(index) instead of appended to"
        case .degradedReplay:
            "the step resumed from a rebuilt conversation, not its wire transcript"
        case .modelReloaded:
            "the server reloaded the model, so its cache started empty"
        case .serverDroppedCache(let suspect):
            if let suspect, !suspect.isEmpty {
                "the server dropped it — \(suspect) also used this model"
            } else {
                "the server dropped the cached prefix"
            }
        }
    }

    /// `12927` → `~12.9k`, `840` → `~840`.
    static func formatTokens(_ tokens: Int) -> String {
        tokens < 1000
            ? "~\(tokens)"
            : "~\((Double(tokens) / 1000 * 10).rounded() / 10)k"
    }

    static func formatSeconds(_ seconds: Double) -> String {
        seconds < 10
            ? "\((seconds * 10).rounded() / 10)s"
            : "\(Int(seconds.rounded()))s"
    }
}
