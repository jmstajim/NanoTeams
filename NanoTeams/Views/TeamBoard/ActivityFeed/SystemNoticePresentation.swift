import Foundation

/// Classifies a conversation turn as a SYSTEM-AUTHORED notice and derives the
/// one-line form the activity feed collapses it into.
///
/// Five `MessageSourceContext` cases are written by the runtime itself rather
/// than by a human or a model: the retry nudges (the eight `handleNoToolCalls`
/// sites and the repetition warning), the correction appended after a thinking
/// loop was discarded, the transient server-error retry note, the
/// `update_scratchpad` acknowledgement, and a failure in the app's own work.
/// The steering appended after a failed TOOL call used to be a sixth and is not:
/// it comments on one event the feed already draws as a card, so it is persisted
/// unattributed and never reaches this table — see `ToolErrorNotePolicy`.
/// `.screenDescription` is runtime-generated too but is deliberately absent — it
/// is CONTENT, the only record of what the model was shown, and a one-line row
/// would hide the substance it then acted on. Rendered as ordinary prose they are
/// indistinguishable from the working role's own turns — the feed attributes
/// them to that role (`ActivityFeedBuilder` sets `displayRole = step.role`) and
/// the `(retry)` header label only appears on a section boundary, which a nudge
/// between two turns of the same role never is. `MessageBubbleView` routes them
/// through `SystemNoticeRow` instead: a dim one-liner that opens the full text
/// in a standalone window.
///
/// Pure and `nonisolated` so the classification is unit-testable without
/// standing up a view — same shape as `ArtifactContentDecoder` next door.
nonisolated enum SystemNoticePresentation {

    /// The collapsed form of one system notice.
    struct Notice: Equatable {
        /// Row text: `"system · retry"`. Carries the `system ·` prefix because
        /// the row usually renders header-less under the working role's avatar,
        /// where a bare `retry` would read as the ROLE retrying.
        let rowLabel: String
        /// Detail-window title: the bare kind, `"retry"`.
        let windowTitle: String
        /// Single-line preview of the content. May be empty — see `resolve`.
        let preview: String
        /// Only `.serverError`. Drives the row's red label so a failing LLM call
        /// stays noticeable after losing its full-width red card.
        let isError: Bool
    }

    /// Character ceiling for `previewLine`. A guard on layout/`Equatable` cost
    /// for pathological single-line content, NOT a semantic cap — the row is cut
    /// visually by `.lineLimit(1)` long before this.
    static let previewCharacterLimit = 160

    /// The single membership-and-wording table: adding or removing a context is
    /// a one-line change here and nowhere else.
    ///
    /// Labels are local rather than sourced from `MessageSourceContext.displayLabel`
    /// because `.serverError` is deliberately absent from `displayLabelMap` — that
    /// omission is pinned in `LLMMessageSourceContextTests` with the rationale that
    /// its red bubble carried the meaning. Adding an entry there would create a
    /// value with exactly one reader (this file), since `sourceContextDisplayLabel`
    /// keeps returning nil for it. `SystemNoticePresentationTests` drift-guards the
    /// two kinds that DO have a Domain label.
    private static let kinds: [MessageSourceContext: (label: String, isError: Bool)] = [
        .retryNudge: ("retry", false),
        .loopCorrection: ("loop correction", false),
        .serverError: ("server error", true),
        .toolAcknowledgement: ("note", false),
        .runtimeWarning: ("warning", true),
    ]

    private static let rowLabelPrefix = "system · "

    /// Returns the collapsed form, or `nil` when the turn is ordinary content.
    ///
    /// **The verdict depends on `context` ALONE, never on the content.**
    /// `.serverError` rewrites its content in place on the same message id as
    /// attempts accumulate (`TaskMutationService.appendOrReplaceRetryNotice`);
    /// letting emptiness or length flip the answer would swap the bubble's
    /// `_ConditionalContent` arm mid-update. An empty body yields a notice with
    /// an empty `preview`.
    static func resolve(context: MessageSourceContext?, content: String) -> Notice? {
        guard let context, let kind = kinds[context] else { return nil }
        return Notice(
            rowLabel: rowLabelPrefix + kind.label,
            windowTitle: kind.label,
            preview: previewLine(from: content),
            isError: kind.isError
        )
    }

    /// Reduces a notice body to one displayable line.
    ///
    /// Takes the first non-empty line rather than flattening the whole body:
    /// several nudges follow their opening sentence with a literal envelope
    /// example on its own line, and smearing that into the label row is noise.
    /// For the single-line nudges — most of them, since the `"""` templates use
    /// `\` continuations — the two rules agree.
    ///
    /// `maxLength` is cut by `Character`, not by UTF-16 units or bytes, so an
    /// emoji ZWJ sequence or a CJK glyph can't be split; a non-positive value
    /// disables the cap. The ellipsis is appended by us: once the string is cut
    /// it fits the row, so `.lineLimit(1)` would render it as if nothing had
    /// been dropped.
    static func previewLine(from content: String, maxLength: Int = previewCharacterLimit) -> String {
        var firstLine = ""
        for raw in content.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                firstLine = trimmed
                break
            }
        }
        guard !firstLine.isEmpty else { return "" }

        let collapsed = firstLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard maxLength > 0, collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)) + "…"
    }
}
