import Foundation

/// Identifier-and-payload value for the "open in new window" pattern used by
/// every previously-inline expandable section in the Activity Feed.
///
/// SwiftUI's `WindowGroup(for:)` opens one window per unique `Hashable` value
/// and matches values via `==`. The dedup-key override on `==`/`hash` is
/// required because the synthesized `==` compares the full payload — every
/// streaming-tick mutation of `text`/`resultJSON` would otherwise look like
/// a new window value. The override pins identity to a stable id so:
///
///   * Clicking the same record twice focuses the existing window instead of
///     opening a duplicate (documented `WindowGroup(for:)` behaviour).
///   * Mid-stream payload mutation does NOT trigger a new window.
///
/// Snapshot semantics: payload is captured at `openWindow(value:)` time. If
/// the user clicks "Thinking" while streaming is in progress, the window
/// shows whatever text was committed up to that click — it does NOT keep
/// growing as more tokens stream in. To get the latest text, close and
/// reopen. (A future enhancement could re-resolve payload from the live
/// `StreamingPreviewManager` inside the window view.)
///
/// **WARNING — `==` and `hash` are identity-only.** Two values comparing
/// equal can carry observably different `text` / `resultJSON` / `createdAt`
/// payloads. This is the right shape for `WindowGroup(for:)` lookup, but it
/// makes the type unsafe for use as a `Set` element or `Dictionary` key when
/// the consumer expects to retrieve the latest payload. A put-then-get on
/// such a collection would return the FIRST-inserted payload, not the last.
/// Today the only consumer is `WindowGroup(for:)`; new use sites should
/// either (a) use a different identity model, or (b) wrap in a struct that
/// stores the desired payload alongside the dedup key.
nonisolated enum ActivityDetailWindow: Hashable, Codable {
    /// LLM message thinking. `id` = `LLMMessage.id`.
    case thinking(id: UUID, roleName: String, text: String)
    /// Meeting message thinking. `id` = `TeamMessage.id`.
    case meetingThinking(id: UUID, roleName: String, text: String)
    /// `ask_supervisor` thinking. `id` = `toolCallID` (NOT `stepID` — a step
    /// can host several historical Q&A pairs, each with its own toolCallID).
    case supervisorThinking(id: UUID, roleName: String, text: String)

    /// Tool call arguments + result, full untruncated.
    case toolCall(
        id: UUID,
        toolName: String,
        argumentsJSON: String,
        resultJSON: String?,
        isError: Bool,
        createdAt: Date
    )

    /// Artifact viewer. Content is loaded lazily from disk inside
    /// `ArtifactDetailBody` (work-folder URL pulled from the
    /// `NTMSOrchestrator` environment) so this value type stays small.
    case artifact(
        taskID: Int,
        artifactName: String,
        mimeType: String,
        relativePath: String?,
        createdAt: Date
    )

    /// Single meeting tool call summary (full args + result).
    case meetingTool(id: UUID, summary: MeetingToolSummary)
    /// All tool summaries for a single meeting message.
    case meetingTools(id: UUID, summaries: [MeetingToolSummary])

    /// System-authored corrective notice — a retry nudge, a loop-break
    /// correction, or a server-error retry note (see `SystemNoticePresentation`).
    /// The feed collapses these into a one-line row; this is the full text.
    /// `id` = `LLMMessage.id`, the same id space as `.thinking` — one message can
    /// own both windows, which is why the per-case `dedupKey` prefix matters here.
    case systemNotice(id: UUID, label: String, text: String)

    /// Stable dedup key — same key opens / focuses the same window. Picked so
    /// subsequent clicks on the same record (even with mutated payload, e.g.
    /// streaming thinking) reuse the original window.
    var dedupKey: String {
        switch self {
        case .thinking(let id, _, _):           return "thinking:\(id)"
        case .meetingThinking(let id, _, _):    return "meeting-thinking:\(id)"
        case .supervisorThinking(let id, _, _): return "supervisor-thinking:\(id)"
        case .toolCall(let id, _, _, _, _, _):  return "tool:\(id)"
        case .artifact(let taskID, let name, _, let relativePath, let createdAt):
            // `relativePath` (not `name`) is the source of truth for artifact
            // identity: two roles in the same task can produce same-named
            // artifacts (e.g. Frontend Developer + Quality Controller both
            // emitting `index.html`) — names collide, paths don't (paths
            // include the role-dir). Pinned by `TimelineArtifactIDCollisionTests`
            // in spirit.
            //
            // Transient case (relativePath nil — artifact known to the UI
            // before disk persistence): mix in `createdAt` so two roles'
            // same-named in-flight artifacts open distinct windows. Same name
            // + same timestamp (idempotent re-emit of the same artifact) still
            // dedups to one window. `Artifact.createdAt` is sourced from
            // `MonotonicClock` so two independent calls cannot share a
            // timestamp accidentally.
            if let relativePath {
                return "artifact:\(taskID):\(relativePath)"
            }
            return "artifact:\(taskID):\(name):\(createdAt.timeIntervalSince1970)"
        case .meetingTool(let id, _):           return "meeting-tool:\(id)"
        case .meetingTools(let id, _):          return "meeting-tools:\(id)"
        case .systemNotice(let id, _, _):       return "system-notice:\(id)"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(dedupKey)
    }

    static func == (lhs: ActivityDetailWindow, rhs: ActivityDetailWindow) -> Bool {
        lhs.dedupKey == rhs.dedupKey
    }

    // MARK: - Codable

    // `WindowGroup(for:)` requires `Codable` on the value as a generic
    // constraint. We make the conformance asymmetric on purpose:
    //   * `encode` writes only the dedupKey (lossy by design) so any path
    //     that does serialize cannot round-trip a stale payload alongside
    //     the identity key.
    //   * `init(from:)` throws — fail loud if SwiftUI ever attempts to
    //     reconstitute a window from a serialized value. Reopening must go
    //     through a fresh `openWindow(value:)` call so the payload comes
    //     from the live model; a thrown decode bubbles up as "this window
    //     can't be restored" rather than silently swapping payloads.
    // `.restorationBehavior(.disabled)` already prevents app-lifecycle
    // restoration from invoking decode in normal use, so the throw is only
    // a backstop — not a hot path.

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(dedupKey)
    }

    init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "ActivityDetailWindow is not decodable — windows are intentionally not restored. WindowGroup(for:) is configured with .restorationBehavior(.disabled). Open via openWindow(value:) instead."
            )
        )
    }
}
