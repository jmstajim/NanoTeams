import Foundation

/// Who is issuing an LLM request.
///
/// The transport had no way to answer this: `streamChat` carries no task id, and `stepID` is
/// `nil` at most of its call sites. Without it a prompt-prefix cache miss cannot be attributed —
/// neither to the conversation it belongs to (so it cannot be compared against its own previous
/// request) nor to a suspect (so "the server dropped your prefix" can name nobody).
///
/// The discriminator between `.chain` and `.oneShot` is **"does this caller resend a growing
/// prefix"**, NOT "is `stepID` nil". Three `stepID: nil` call sites are genuinely accumulating
/// conversations and must be `.chain`, or the detector is blind to them:
///
/// - `ask_teammate` consultations — `RoleConsultationChat.messagesToSend()` is the whole run-long
///   chat, resent every call; the call site's own comment says the prefix cache carries the cost.
/// - meeting turns — a turn's stack continues across tool follow-ups, and speakers rotate on one
///   model.
/// - `DelegatedSupervisorAnswerService` — its seed grows via `persistExchange`.
///
/// `nonisolated` because the app target defaults types to `@MainActor`; this is a value.
nonisolated enum LLMCallOwner: Hashable, Sendable {
    /// A role's tool loop. Compared against its own previous request.
    case step(taskID: Int, stepID: String)
    /// An accumulating conversation outside the step machinery, identified by a stable id.
    case chain(id: String)
    /// A genuinely self-contained call — a judge verdict, a Vision description, one work-folder
    /// context generation. Records its presence (so it can be named as a suspect) but never has
    /// a prefix of its own to lose.
    case oneShot(label: String)

    /// Stable identity within one `(server, model)`. Chains are compared owner-against-itself,
    /// so this is what keeps two parallel roles on one model from being mistaken for each
    /// other's predecessor.
    var key: String {
        switch self {
        case .step(let taskID, let stepID): "step:\(taskID):\(stepID)"
        case .chain(let id): "chain:\(id)"
        case .oneShot(let label): "oneShot:\(label)"
        }
    }

    /// Human-readable name for the banner and the status pill.
    var displayName: String {
        switch self {
        case .step(_, let stepID): stepID
        case .chain(let id): id
        case .oneShot(let label): label
        }
    }

    /// The inverse projection of `key` → `displayName`, for the one place that holds a key and
    /// not the owner: the ledger's activity ring records `owner.key` (its format is pinned by
    /// `PromptPrefixLedgerTests`), so a suspect arrives at the UI as `step:42:autovisor_autovisor`
    /// while the row beside it shows `displayName`. Rendering both spellings in one popover reads
    /// as two different callers.
    ///
    /// Lives here, next to the two projections it bridges, so a new case cannot add a `key`
    /// prefix and leave this behind. Drops exactly the leading components `key` added, so an id
    /// that itself contains `:` (a meeting chain is `taskID:runID:meetingID`) survives intact.
    static func displayName(forKey key: String) -> String {
        if key.hasPrefix("step:") {
            let rest = key.dropFirst("step:".count)
            guard let separator = rest.firstIndex(of: ":") else { return String(rest) }
            return String(rest[rest.index(after: separator)...])
        }
        if key.hasPrefix("chain:") { return String(key.dropFirst("chain:".count)) }
        if key.hasPrefix("oneShot:") { return String(key.dropFirst("oneShot:".count)) }
        return key
    }

    /// Whether this owner accumulates a prefix worth protecting. A one-shot cannot be a victim —
    /// its conversation is new every time — but it can still be a suspect.
    var accumulatesPrefix: Bool {
        switch self {
        case .step, .chain: true
        case .oneShot: false
        }
    }
}
