import Foundation

/// Task-scoped identity of a dismissed Watchtower notification.
///
/// The task scope is not decoration. `StepExecution.id` IS the team role ID, so
/// every task running the same team shares its step IDs — a step-only dismiss key
/// silently suppressed another task's banner, and let a garbage collector that could
/// see only one task expire keys belonging to tasks it had never loaded. This is the
/// same rule CLAUDE.md states for per-step runtime state ("keyed by
/// `TaskStepKey(taskID:stepID:)` — NEVER by stepID alone"), applied to persisted UI state.
///
/// Lives in `Domain/` so `StoreConfiguration` (Services) can persist it without
/// importing a view type.
nonisolated struct WatchtowerDismissKey: Hashable, Sendable {
    let taskID: Int
    /// Identity WITHIN the task — `WatchtowerNotificationType.dismissID`.
    let typeID: String

    init(taskID: Int, typeID: String) {
        self.taskID = taskID
        self.typeID = typeID
    }

    /// `"t<taskID>::<typeID>"`. The `t` prefix keeps a legacy bare-`stepID` entry from
    /// ever parsing as a valid key, so old rows are recognisably legacy rather than
    /// being mis-attributed to some task.
    var storageKey: String { "t\(taskID)::\(typeID)" }

    /// Round-trips `storageKey`. Nil for anything else — including every key written
    /// before this type existed, which is exactly what makes them safe to drop.
    init?(storageKey: String) {
        guard storageKey.hasPrefix("t") else { return nil }
        let body = storageKey.dropFirst()
        guard let sep = body.range(of: "::") else { return nil }
        guard let taskID = Int(body[body.startIndex..<sep.lowerBound]) else { return nil }
        let typeID = String(body[sep.upperBound...])
        guard !typeID.isEmpty else { return nil }
        self.init(taskID: taskID, typeID: typeID)
    }
}

// MARK: - Shared type-ID vocabulary

/// The single spelling of the within-task identity of the three event-retired
/// notification families — `.supervisorInput`, `.acceptance` and `.failed` — shared by
/// `WatchtowerNotificationType.dismissID` (Views — builds keys when banners render)
/// and the orchestrator's event-driven retirement (Services — expires keys when the
/// state that produced a banner is consumed: `retireRoleBannerDismissals` for the
/// role families, `answerSupervisorQuestion` for the question). Without one owner the
/// two spellings drift, and a retirement that misses is invisible: the stale key just
/// keeps suppressing the NEXT instance of the banner.
///
/// The `acceptance::` / `failed::` prefixes are load-bearing, not decorative: both
/// families used to spell their typeID as the bare `stepID`, so dismissing a failed
/// banner also suppressed a later acceptance banner on the same step, and vice versa.
nonisolated extension WatchtowerDismissKey {
    static func acceptanceTypeID(stepID: String) -> String { "acceptance::\(stepID)" }
    static func failedTypeID(stepID: String) -> String { "failed::\(stepID)" }

    /// `.supervisorInput`: the asking `ask_supervisor` call's persisted UUID when there is one
    /// (chat mode: every turn), else the question text — the flag-only escalation path has no
    /// call to name. Deliberately NO family prefix: this is the byte-for-byte spelling
    /// `WatchtowerNotificationType.dismissID` has always written, so every key already on disk
    /// keeps matching. The `acceptance::`/`failed::` rename accepted a "banner returns once"
    /// cost because bare stepIDs collided across families; `stepID::<uuid|text>` collides with
    /// nothing, so there is no reason to pay it here.
    static func supervisorInputTypeID(stepID: String, toolCallID: UUID?, question: String) -> String {
        "\(stepID)::\(toolCallID?.uuidString ?? question)"
    }

    static func acceptance(taskID: Int, stepID: String) -> Self {
        Self(taskID: taskID, typeID: acceptanceTypeID(stepID: stepID))
    }
    static func failed(taskID: Int, stepID: String) -> Self {
        Self(taskID: taskID, typeID: failedTypeID(stepID: stepID))
    }
    static func supervisorInput(taskID: Int, stepID: String, toolCallID: UUID?, question: String) -> Self {
        Self(taskID: taskID,
             typeID: supervisorInputTypeID(stepID: stepID, toolCallID: toolCallID, question: question))
    }
}
