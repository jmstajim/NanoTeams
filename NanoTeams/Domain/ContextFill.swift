import Foundation

/// How full a step's context window is, as of its last measurement.
///
/// Exists because the wire is append-only and resent whole on every request
/// (`StepExecution.wireTranscript`), so a chat-mode role grows monotonically toward a
/// window it cannot see. Until the window is actually hit there is NO symptom: the
/// server either truncates the head silently and answers HTTP 200 (`ContextBudgetPolicy`
/// documents the measurement) or refuses the request outright. Both outcomes arrive with
/// the conversation already too big to save. This value is what the composer renders
/// beside the role chip so the user sees the slope before the cliff, and what
/// `CompactionPolicy`'s automatic trigger reads.
///
/// `promptTokens` is the SERVER's own count whenever one is available (`isEstimate ==
/// false`) and `ContextBudgetPolicy.estimateTokens` otherwise. The distinction is not
/// cosmetic: the estimator's error against real tokenizers spans 0.45× (Cyrillic) to
/// 2.58× (emoji), so an estimate can only ever be shown with a `~`, and NOTHING may
/// auto-compact on one — the same reason `shouldReportTruncation` is server-only.
///
/// `window` and `budget` are optional independently. A window is unknown until a probe
/// answers (Ollama's `/api/ps` is silent on a cold model), and `budget` is `nil`
/// whenever the window is — it is `stepBudget(window:percent:)` of it, the fraction the
/// user set in Settings.
///
/// `nonisolated` because the app target defaults types to `@MainActor` and this is read
/// from the execution service, the projection and pure presentation alike.
nonisolated struct ContextFill: Codable, Hashable, Sendable {

    /// Prompt tokens the last request cost — server-reported unless `isEstimate`.
    var promptTokens: Int

    /// The model's runtime context window, when a probe has answered. Never a nominal
    /// architecture maximum: `LLMClient.modelContextLength` reports only what the server
    /// says it loaded.
    var window: Int?

    /// The share of `window` a single step is allowed before auto-compaction fires.
    /// `nil` exactly when `window` is.
    var budget: Int?

    /// True when `promptTokens` came from `ContextBudgetPolicy.estimateTokens` rather
    /// than the server. Display-only signal — every automatic decision refuses to read
    /// an estimate.
    var isEstimate: Bool

    /// How many compaction epochs this step has been through. Shown in the tooltip and
    /// used by nothing else; the terminal latch lives in execution state, not here,
    /// because it must not survive a restart.
    var compactions: Int

    /// When the measurement was taken. `MonotonicClock`, like every other model stamp.
    var measuredAt: Date

    init(
        promptTokens: Int,
        window: Int? = nil,
        budget: Int? = nil,
        isEstimate: Bool = false,
        compactions: Int = 0,
        measuredAt: Date = MonotonicClock.shared.now()
    ) {
        self.promptTokens = promptTokens
        self.window = window
        self.budget = budget
        self.isEstimate = isEstimate
        self.compactions = compactions
        self.measuredAt = measuredAt
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens
        case window
        case budget
        case isEstimate
        case compactions
        case measuredAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        self.window = try c.decodeIfPresent(Int.self, forKey: .window)
        self.budget = try c.decodeIfPresent(Int.self, forKey: .budget)
        self.isEstimate = try c.decodeIfPresent(Bool.self, forKey: .isEstimate) ?? false
        self.compactions = try c.decodeIfPresent(Int.self, forKey: .compactions) ?? 0
        self.measuredAt =
            try c.decodeIfPresent(Date.self, forKey: .measuredAt) ?? MonotonicClock.shared.now()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(promptTokens, forKey: .promptTokens)
        try c.encodeIfPresent(window, forKey: .window)
        try c.encodeIfPresent(budget, forKey: .budget)
        // Omitted when false / zero so a step that never overflowed and never compacted
        // doesn't grow two keys in every `task.json`.
        if isEstimate { try c.encode(isEstimate, forKey: .isEstimate) }
        if compactions > 0 { try c.encode(compactions, forKey: .compactions) }
        try c.encode(measuredAt, forKey: .measuredAt)
    }
}
