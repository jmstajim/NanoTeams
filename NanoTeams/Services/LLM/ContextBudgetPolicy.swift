import Foundation

/// Pure decision for "does this request still fit the model's context window".
///
/// Exists because a prompt that overflows is not rejected — it is silently TRUNCATED,
/// and truncation drops the HEAD. The head is the system prompt: the role's identity, its
/// deliverable contract and the Harmony tool catalog. The server answers HTTP 200 with a
/// fluent reply, so nothing downstream can tell the difference between "the model ignored
/// its instructions" and "the model never received them".
///
/// Ollama makes this the common case rather than an edge one: its runtime window is
/// `OLLAMA_CONTEXT_LENGTH` (~4096 stock) regardless of what the architecture supports, and
/// `OllamaClient.modelContextLength` deliberately reports only the modelfile `num_ctx` so
/// the app never overstates it. Sending an explicit `num_ctx` to force a bigger window was
/// considered and rejected: it silently changes the user's server-side memory profile and
/// can fail the load outright. Warning loudly keeps the decision with the user.
///
/// `nonisolated` because the app target defaults types to `@MainActor`; pure value-in /
/// value-out (house pattern: `PlanningPhasePolicy`, `LoopRecoveryPolicy`, `ConversationReplay`).
nonisolated enum ContextBudgetPolicy {

    /// Fraction of the window at which a request is called out. Deliberately 1.0 and not a
    /// safety margin below it: `estimateTokens` already over-counts (it divides ASCII by
    /// 3.5 where real tokenizers average ~4 chars/token, so it reads ~14% high), and the
    /// generation itself still needs room beyond the prompt. A margin on top of a
    /// conservative estimator would fire on prompts that fit comfortably, and a warning
    /// nobody believes is worse than no warning.
    static let overflowFraction = 1.0

    enum Verdict: Equatable {
        /// The window is unknown — no probe, or a provider that does not report one. Never
        /// warn on a guess: a wrong "your prompt is too long" is worse than silence.
        case unknown
        case withinBudget(promptTokens: Int, contextLength: Int)
        case exceeded(promptTokens: Int, contextLength: Int)

        var isExceeded: Bool {
            if case .exceeded = self { return true }
            return false
        }
    }

    /// Conservative token estimate for a whole request. Reuses
    /// `WorkFolderContextPromptPlanner.estimateTokens`, the same two-class ASCII/non-ASCII
    /// heuristic that sizes the work-folder context prompt, so the two surfaces cannot
    /// drift into disagreeing about what "too big" means.
    ///
    /// `toolSchemaText` is the Harmony tool catalog the client will APPEND to the system
    /// prompt at request-build time — which is empty whenever `messages` already carry it
    /// (a role step: `PromptBuilder` renders it into the system message via the
    /// `{toolCalling}` chip, so both builders skip the append). The caller owns that gate,
    /// in `NativeLMStudioClient.toolSchemaTextForMeasurement`, so this stays a pure sum and
    /// the same rule serves the fingerprint. It is the largest fixed cost in a small
    /// window: omitting it would under-count exactly the requests most likely to overflow,
    /// and adding it unconditionally priced a copy no request has ever carried.
    ///
    /// Tool calls are priced through `HarmonyToolCallEnvelope` — the same function both
    /// request builders render from — because they do NOT live in `content`: the streaming
    /// path truncates the Harmony envelope out of it and files the calls under
    /// `ChatMessage.toolCalls`, so an envelope-only turn reads as `content == nil` while the
    /// wire carries the whole thing. This is the estimator's only UNBOUNDED omission when it
    /// is missing: `create_artifact` / `write_file` / `edit_file` carry the entire body inside
    /// `argumentsJSON`, and it is resent on every remaining iteration of the step. (The
    /// builders' `[Assistant]` / `[Tool Result]` labels and `\n\n` joins stay unpriced by
    /// contrast — a fixed few tokens per message, and Ollama MERGES consecutive user-side
    /// turns, so join cost is not derivable per-message, which is what
    /// `PrefixCachePolicy.discardedTokens`' slice pricing requires.)
    ///
    /// Image payloads are counted by their base64 length, which is wrong in detail (a
    /// vision model prices an image in tiles, not characters) but right in direction: a
    /// large image is the single most likely thing to blow a small window.
    static func estimateTokens(messages: [ChatMessage], toolSchemaText: String = "") -> Int {
        var total = WorkFolderContextPromptPlanner.estimateTokens(toolSchemaText)
        for message in messages {
            if let content = message.content {
                total += WorkFolderContextPromptPlanner.estimateTokens(content)
            }
            total += WorkFolderContextPromptPlanner.estimateTokens(
                HarmonyToolCallEnvelope.appendedWireText(for: message))
            for image in message.imageContent ?? [] {
                total += WorkFolderContextPromptPlanner.estimateTokensForBase64(image.base64Data)
            }
        }
        return total
    }

    /// A non-positive or absent `contextLength` is `.unknown`, never `.exceeded` — a failed
    /// probe must not manufacture a warning.
    static func verdict(promptTokens: Int, contextLength: Int?) -> Verdict {
        guard let contextLength, contextLength > 0 else { return .unknown }
        let limit = Int((Double(contextLength) * overflowFraction).rounded(.down))
        return promptTokens >= limit
            ? .exceeded(promptTokens: promptTokens, contextLength: contextLength)
            : .withinBudget(promptTokens: promptTokens, contextLength: contextLength)
    }

    /// Whether the server has stopped processing everything we send — i.e. it is truncating.
    ///
    /// **Deliberately does NOT compare against `estimateTokens`.** The first version of this did,
    /// gated at 75% of our estimate on the reasoning that the estimator reads only ~14% high. A
    /// live calibration against Ollama (`ornith:35b-q4_K_M`, 2026-07-26, `num_ctx` set wide so
    /// nothing could truncate) showed that ~14% is an ASCII-only figure and the two-class heuristic
    /// is wildly language-dependent:
    ///
    /// | corpus | server/estimate |
    /// |---|---|
    /// | ASCII English | 0.78 |
    /// | **Cyrillic** | **0.45** |
    /// | mixed RU/EN | 0.57 |
    /// | CJK | 1.02 |
    /// | Swift source | 1.41 |
    /// | base64 | 2.26 |
    /// | emoji-heavy | 2.58 |
    ///
    /// A Cyrillic prompt is over-counted 2.2×, so a 75% gate reports every healthy Russian-language
    /// request as truncated. No single fraction survives that spread, and tightening the estimator
    /// is not the answer either: over-counting is the SAFE direction for the pre-send overflow
    /// warning (it warns early), and one non-ASCII divisor cannot serve Cyrillic (~3.3 chars/token),
    /// CJK (~1.5) and emoji (~0.6) at once.
    ///
    /// So the evidence is server-only: **the prompt grew but the server's own count did not.**
    /// Measured clamping behaviour, same session — with `num_ctx: 2048`, a prompt of 1872 tokens
    /// reported 1872; doubling it reported 1026; doubling again reported 1026 again (+0). Once it
    /// truncates, the count stops tracking what we send. `appendedTokens` only has to establish
    /// "we genuinely added content", and the estimator's bias is multiplicative, so it cannot flip
    /// that sign.
    ///
    /// Returns the count the server DID process. Note that is not the context window: the same
    /// measurements show Ollama reporting roughly HALF the window when it truncates (1026 of 2048,
    /// 2050 of 4096), which is why nothing here claims to have discovered the window.
    static func shouldReportTruncation(
        appendedTokens: Int,
        serverPromptTokens: Int?,
        previousServerPromptTokens: Int?
    ) -> Int? {
        guard let serverPromptTokens, serverPromptTokens > 0,
              let previous = previousServerPromptTokens, previous > 0
        else { return nil }
        // We added real content…
        guard appendedTokens >= PrefixCachePolicy.materialTokenThreshold else { return nil }
        // …and the server did not process any more than last time.
        guard serverPromptTokens <= previous else { return nil }
        return serverPromptTokens
    }

    /// The banner text. Names the model, both numbers and the concrete remedy, because the
    /// symptom the user actually sees ("the role ignored its instructions") points nowhere
    /// near the cause.
    /// The banner for a truncation caught after the fact. Says what was MEASURED — the server
    /// stopped keeping up — and never names a context window, because the reported count is not
    /// one (Ollama reports about half the window once it truncates).
    static func truncationMessage(
        modelName: String,
        serverPromptTokens: Int,
        provider: LLMProvider
    ) -> String {
        let remedy: String
        switch provider {
        case .ollama:
            remedy = "Raise it with OLLAMA_CONTEXT_LENGTH or a modelfile num_ctx"
        case .lmStudio:
            remedy = "Raise the loaded context length in LM Studio (My Models → gear)"
        }
        return "\(modelName): the conversation grew but the server processed only "
            + "\(serverPromptTokens) prompt tokens — it is truncating from the START, so the "
            + "system prompt and tool catalog are being dropped without an error. \(remedy), or "
            + "shorten the work-folder context."
    }

    /// What the runtime already tried before giving up on an overflow the server refused.
    ///
    /// The failure text has to say this, because the three outcomes point the user at three
    /// different actions: turn compaction on, raise the window, or accept that the head
    /// itself is too big for this model. Before compaction existed there was one outcome and
    /// the sentence stated it as a law of the wire ("an append-only conversation cannot
    /// shrink on retry") — true of the RETRY, and now misleading about the app.
    enum CompactionOutcome: Equatable {
        /// Auto-compaction is off, so nothing was attempted.
        case disabled
        /// A compaction epoch ran and the next request still did not fit.
        case attempted
        /// Nothing could be compacted: the pinned head is already past the budget, or the
        /// step carries no summarizable body.
        case nothingToSeed
    }

    /// The step-failure text for an overflow the SERVER refused (Ollama's MLX runner and
    /// LM Studio both answer with an error rather than a silent head-drop). Carries the
    /// server's own sentence — it names both numbers when the runner has them — the
    /// provider's remedy, and what the runtime already tried, because the bubble is the
    /// only place the user learns why the step stopped.
    static func overflowFailureMessage(
        modelName: String,
        serverMessage: String,
        provider: LLMProvider,
        compaction: CompactionOutcome
    ) -> String {
        let tried: String
        switch compaction {
        case .disabled:
            tried = "auto-compaction is off, so the conversation was resent unchanged"
        case .attempted:
            tried = "compacting the conversation to a summary did not make it fit"
        case .nothingToSeed:
            tried = "there was nothing left to compact — the pinned head does not fit on its own"
        }
        return "\(modelName): the prompt does not fit the model's context window, and \(tried). "
            + "Server: \(serverMessage.trimmingCharacters(in: .whitespacesAndNewlines)) "
            + "\(remedy(for: provider)), or shorten the work-folder context and restart the role."
    }

    private static func remedy(for provider: LLMProvider) -> String {
        switch provider {
        case .ollama:
            "Raise it with OLLAMA_CONTEXT_LENGTH or a modelfile num_ctx"
        case .lmStudio:
            "Raise the loaded context length in LM Studio (My Models → gear)"
        }
    }

    static func warningMessage(
        modelName: String,
        promptTokens: Int,
        contextLength: Int,
        provider: LLMProvider
    ) -> String {
        let remedy: String
        switch provider {
        case .ollama:
            remedy = "Raise it with OLLAMA_CONTEXT_LENGTH or a modelfile num_ctx"
        case .lmStudio:
            remedy = "Raise the loaded context length in LM Studio (My Models → gear)"
        }
        return "\(modelName): the prompt is about \(promptTokens) tokens but the model's "
            + "context window is \(contextLength). The server truncates from the START, so "
            + "the system prompt and tool catalog may be dropped without an error. "
            + "\(remedy), or shorten the work-folder context."
    }

    // MARK: - Step budget (compaction)

    /// How many tokens ONE step may occupy before it compacts, from the window and the
    /// user's chosen share.
    ///
    /// Deliberately a fraction of the window rather than the window itself: what has to fit
    /// is the prompt PLUS everything the remainder of the step will append to it — tool
    /// results, the model's own turns, and the generation. `overflowFraction` sits at 1.0
    /// because it answers a different question (has this request already overflowed), and a
    /// budget that waited that long would compact after the failure it exists to prevent.
    ///
    /// `nil` — never a manufactured number — when the window is unknown or so small that the
    /// share floors to zero. The callers treat `nil` as "cannot judge", which is why a failed
    /// probe can never trigger a compaction.
    static func stepBudget(window: Int?, percent: Int) -> Int? {
        guard let window, window > 0, percent > 0 else { return nil }
        let budget = Int((Double(window) * Double(percent) / 100).rounded(.down))
        return budget > 0 ? budget : nil
    }

    /// Whether a step has crossed its budget, given the SERVER's own prompt count.
    ///
    /// Server-only by contract, for the reason `shouldReportTruncation` is: the estimator
    /// spans 0.45×–2.58× against real tokenizers (see the table above), so a Cyrillic
    /// conversation reads 2.2× too big and would compact itself on a quarter-full window,
    /// discarding work to solve a problem it does not have.
    ///
    /// Equality counts as exceeded, matching `verdict`.
    static func compactionVerdict(
        serverPromptTokens: Int?,
        window: Int?,
        percent: Int
    ) -> CompactionVerdict {
        guard let serverPromptTokens, serverPromptTokens > 0,
              let budget = stepBudget(window: window, percent: percent)
        else { return .unknown }
        return serverPromptTokens >= budget
            ? .budgetExceeded(promptTokens: serverPromptTokens, budget: budget)
            : .withinBudget(promptTokens: serverPromptTokens, budget: budget)
    }

    enum CompactionVerdict: Equatable {
        /// No server count, or no window to measure it against. Never compacts on a guess.
        case unknown
        case withinBudget(promptTokens: Int, budget: Int)
        case budgetExceeded(promptTokens: Int, budget: Int)

        var isExceeded: Bool {
            if case .budgetExceeded = self { return true }
            return false
        }
    }
}
