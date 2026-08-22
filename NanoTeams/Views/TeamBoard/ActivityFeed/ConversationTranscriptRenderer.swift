import SwiftUI

/// Renders a **flat chronological transcript of what the user actually sees** in the
/// activity feed — the displayed side of the audit pair whose wire side is
/// `network_log.json`. A reviewer (LLM or human, e.g. the `train-app` skill) puts the
/// two files side-by-side to catch cleaning / suppression / rendering discrepancies
/// ("the model said X on the wire, but the user saw Y / nothing").
///
/// Single source of truth: it serializes the timeline items produced by
/// `ActivityFeedBuilder.buildTimelineItems` (the same builder the live feed uses), so
/// the transcript can never silently drift from the real feed.
///
/// **Fidelity = default-collapsed view only.** Only what the user sees at a glance:
/// no thinking/reasoning (collapsed behind a disclosure), no full tool args/result JSON
/// (window-only) — tool calls render as the same one-line summary the card shows, and
/// artifacts render header-only (their content is window-only too).
///
/// Step-scoped entries are anchored with `time · role · step` using the same identifiers
/// `network_log.json` carries (full `stepID`, role, ISO-8601 timestamp) so entries can be
/// mechanically aligned with the wire request/response that produced them. Entries with no
/// step (supervisor task, meeting messages, change requests) carry `time · role` only.
nonisolated enum ConversationTranscriptRenderer {

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// - Parameters:
    ///   - items: chronologically-ordered timeline items from `ActivityFeedBuilder.buildTimelineItems`.
    ///   - pending: unanswered supervisor questions (owned by the docked composer, NOT in
    ///     `items`) from `ActivityFeedBuilder.activeSupervisorQuestions` — the user sees these
    ///     in the composer, and the wire shows the `ask_supervisor` request immediately, so
    ///     they're surfaced here too.
    ///   - teamRoles: for resolving role display names by step id (matches the feed).
    ///   - isChatMode: feeds the supervisor-input header copy.
    ///   - generatedAt: file header timestamp.
    static func render(
        items: [ActivityFeedBuilder.TaggedItem],
        pending: [ActivityFeedBuilder.ActiveSupervisorQuestion],
        teamRoles: [TeamRoleDefinition],
        isChatMode: Bool,
        generatedAt: Date
    ) -> String {
        var lines: [String] = []
        lines.append("# Conversation Log — what the user sees")
        lines.append("")
        lines.append("_Generated: \(isoFormatter.string(from: generatedAt))_")
        lines.append("")
        lines.append("_The displayed side of the audit pair. Compare against `network_log.json` "
            + "(same run, the wire side) using each entry's `time · role · step` anchor._")
        lines.append("")
        lines.append("---")
        lines.append("")

        if items.isEmpty && pending.isEmpty {
            lines.append("_No activity recorded._")
            return lines.joined(separator: "\n")
        }

        for tagged in items {
            renderItem(tagged.item, teamRoles: teamRoles, isChatMode: isChatMode, lines: &lines)
        }

        if !pending.isEmpty {
            lines.append("## ⏳ Pending supervisor input (shown in the composer)")
            lines.append("")
            for q in pending {
                let anchor = makeAnchor(time: q.askedAt, roleName: roleName(for: q.stepID, fallback: q.role, teamRoles: teamRoles), stepID: q.stepID)
                lines.append("\(anchor) waiting for the Supervisor")
                lines.append(quote(q.question))
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Per-item

    private static func renderItem(
        _ item: TeamActivityTimelineItem,
        teamRoles: [TeamRoleDefinition],
        isChatMode: Bool,
        lines: inout [String]
    ) {
        switch item {
        case let .supervisorTask(brief, taskCreatedAt, supervisorTask, clippedTexts, attachmentPaths, _, _):
            let anchor = makeAnchor(time: taskCreatedAt, roleName: "Supervisor", stepID: nil)
            lines.append("\(anchor) Task")
            let body = supervisorTask.isEmpty ? brief : supervisorTask
            lines.append(quote(body))
            appendAttachments(paths: attachmentPaths, clips: clippedTexts, into: &lines)
            lines.append("")

        case let .llmMessage(message, role, stepID, _):
            // `role` is already the DISPLAY role (sourceRole ?? step role) set by the builder.
            let name = roleName(for: stepID, fallback: role, teamRoles: teamRoles, preferRole: message.sourceRole != nil)
            let label = message.sourceContextDisplayLabel.map { " (\($0))" } ?? ""
            let anchor = makeAnchor(time: message.createdAt, roleName: name + label, stepID: stepID)
            lines.append(anchor)
            // Same transform the bubble applies (`MessageBubbleView`): strip the
            // `Supervisor:\n` prefix (displayContent), then — for `.supervisorMessage`
            // turns only — pull out attached-file / clip sections.
            let inputs = ActivityFeedBuilder.bubbleDisplayInputs(
                raw: message.displayContent,
                isSupervisorMessage: message.sourceContext == .supervisorMessage
            )
            lines.append(quote(inputs.text))
            appendAttachments(paths: inputs.paths, clips: inputs.clippedTexts, into: &lines)
            lines.append("")

        case let .toolCall(call, role, stepID, _):
            let name = roleName(for: stepID, fallback: role, teamRoles: teamRoles)
            let anchor = makeAnchor(time: call.createdAt, roleName: name, stepID: stepID)
            let canonical = ToolRegistry.resolveToolName(call.name)
            // `cardSummary`, not `summarizeArguments`: this file's header promises the same
            // one-line summary the card shows, and a successful `edit_file` shows where it
            // landed rather than what it searched for.
            let summary = ToolCallSummarizer.cardSummary(
                toolName: canonical,
                argumentsJSON: call.argumentsJSON,
                resultJSON: call.resultJSON,
                isError: call.isError == true,
                resolveRoleName: { teamRoles.roleName(for: $0) }
            )
            let summaryStr = summary.isEmpty ? "" : "  \(summary)"
            lines.append("\(anchor) 🔧 \(canonical) \(toolStatus(call))\(summaryStr)")
            lines.append("")

        case let .artifact(artifact, role, stepID, _):
            let name = roleName(for: stepID, fallback: role, teamRoles: teamRoles)
            let anchor = makeAnchor(time: artifact.createdAt, roleName: name, stepID: stepID)
            lines.append("\(anchor) 📄 artifact: \(artifact.name) (\(artifact.mimeType))")
            lines.append("")

        case let .meetingMessage(message, meetingTopic, _):
            let anchor = makeAnchor(time: message.createdAt, roleName: message.role.displayName, stepID: nil)
            lines.append("\(anchor) 💬 meeting · \(meetingTopic) · \(message.messageType.rawValue)")
            lines.append(quote(message.content))
            lines.append("")

        case let .changeRequest(request, targetRoleName, _):
            let anchor = makeAnchor(time: request.createdAt, roleName: "Change Request", stepID: nil)
            lines.append("\(anchor) → \(targetRoleName) [\(request.status.rawValue)]")
            lines.append(quote(request.changes))
            lines.append("")

        case let .notification(stepID, role, type, createdAt, _):
            let name = roleName(for: stepID, fallback: role, teamRoles: teamRoles)
            let anchor = makeAnchor(time: createdAt, roleName: name, stepID: stepID)
            switch type {
            case let .supervisorInput(question, answer, answerAttachmentPaths, answerClippedTexts, _, _, wasAutoAnswered):
                lines.append("\(anchor) \(type.title(for: role, isChatMode: isChatMode))")
                lines.append(quote(question))
                if let answer, !answer.isEmpty {
                    let who = wasAutoAnswered ? "answer (auto)" : "answer"
                    lines.append("  \(who): \(singleLine(answer))")
                    appendAttachments(paths: answerAttachmentPaths, clips: answerClippedTexts, into: &lines)
                }
            case let .failed(errorMessage):
                lines.append("\(anchor) ⚠️ error")
                if let errorMessage, !errorMessage.isEmpty {
                    lines.append(quote(errorMessage))
                }
            }
            lines.append("")
        }
    }

    // MARK: - Helpers

    private static func makeAnchor(time: Date, roleName: String, stepID: String?) -> String {
        let stepStr = stepID.map { " · step \($0)" } ?? ""
        return "**[\(isoFormatter.string(from: time)) · \(roleName)\(stepStr)]**"
    }

    /// `preferRole` forces the `Role` fallback (used for consultation bubbles whose
    /// displayed actor is the `sourceRole`, not the step's own role).
    private static func roleName(
        for stepID: String,
        fallback role: Role,
        teamRoles: [TeamRoleDefinition],
        preferRole: Bool = false
    ) -> String {
        if preferRole { return role.displayName }
        let resolved = teamRoles.roleName(for: stepID)
        return resolved.isEmpty ? role.displayName : resolved
    }

    private static func toolStatus(_ call: StepToolCall) -> String {
        if call.resultJSON == nil || call.isAnalyzing || call.isGeneratingTeam { return "…" }
        return call.isError == true ? "✗" : "✓"
    }

    private static func appendAttachments(paths: [String], clips: [String], into lines: inout [String]) {
        if !paths.isEmpty {
            lines.append("  attachments: \(paths.joined(separator: ", "))")
        }
        for clip in clips {
            lines.append("  clip: \(singleLine(clip))")
        }
    }

    /// Blockquote a (possibly multi-line) body so it reads as the user-visible text.
    private static func quote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "> _(empty)_" }
        return trimmed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }

    private static func singleLine(_ text: String) -> String {
        let collapsed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        // `dropFirst(K).isEmpty` == `count <= K` but stops at K graphemes; `String.count` walks
        // the WHOLE receiver to answer a bounded question (see `ModelTokenCleaner.isTokenSpan`).
        return collapsed.dropFirst(200).isEmpty ? collapsed : String(collapsed.prefix(200)) + "…"
    }
}
