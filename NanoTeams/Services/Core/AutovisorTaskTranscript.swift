import Foundation

/// A task's latest run as an external agent reads it, oldest first: what each role said, what the
/// Supervisor side said to it and who that was, the questions asked, every tool call with the
/// outcome of those whose outcome is the news (a command's exit code and last line, a test run's
/// failures, a build's errors), meetings, consultations, change requests — and each Accept, Close,
/// Pause and Resume with its author.
///
/// `task_log` pages it; `task_result.recent_messages` takes the latest conversational entries.
/// One builder, so the two cannot disagree on who said what: until 2026-11-09 `recent_messages`
/// listed every step message under the step's role — a Supervisor's revision as the role's own
/// words — while `task_log` named the author, and neither read the run's timeline, so a Pause or a
/// Resume reached the agent only as an event.
nonisolated enum AutovisorTaskTranscript {

    enum Kind: String, CaseIterable, Sendable {
        case message
        case question
        case answer
        case supervisorMessage = "supervisor_message"
        case supervisorFeedback = "supervisor_feedback"
        case toolCall = "tool_call"
        case meeting
        case meetingDecision = "meeting_decision"
        case consultation
        case changeRequest = "change_request"
        case accepted
        case closed
        case paused
        case resumed

        /// A turn of the conversation proper, between a role and whoever supervises it — what
        /// `recent_messages` lists. Tool calls, meetings and the Supervisor's control actions
        /// are the work around it.
        var isConversational: Bool {
            switch self {
            case .message, .question, .answer, .supervisorMessage, .supervisorFeedback: true
            case .toolCall, .meeting, .meetingDecision, .consultation, .changeRequest,
                 .accepted, .closed, .paused, .resumed: false
            }
        }
    }

    struct Entry: Equatable, Sendable {
        let at: Date
        /// A role's id, the external agent's label, `autovisor` for an automated Supervisor in
        /// the person's place, or `supervisor` for the person.
        let from: String
        let kind: Kind
        let text: String

        /// When the entry was recorded, in whole milliseconds since 1970 — `task_log`'s cursor.
        /// Every entry is stamped by `MonotonicClock`, which never repeats a millisecond within
        /// a process, so in practice a moment names one entry.
        var cursor: Int { Int((at.timeIntervalSince1970 * 1000).rounded(.down)) }
    }

    /// Every entry of `task`'s latest run, oldest first — entries of one moment in the order they
    /// were recorded. `role` keeps that role's own entries and an Accept of it, and leaves out the
    /// run-wide ones: meetings, consultations, change requests, Close, Pause and Resume.
    static func entries(of task: NTMSTask, role: String? = nil) -> [Entry] {
        guard let run = task.runs.last else { return [] }
        let roleFilter = role.flatMap { $0.isEmpty ? nil : $0 }
        var collected: [(entry: Entry, order: Int)] = []
        func append(_ at: Date, _ from: String, _ kind: Kind, _ text: String) {
            collected.append((Entry(at: at, from: from, kind: kind, text: MCPTextSanitizer.sanitizeData(text)),
                              collected.count))
        }

        for step in run.steps where roleFilter.map({ step.effectiveRoleID == $0 }) ?? true {
            appendStep(step, to: append)
        }
        for event in run.supervisorEvents {
            if let roleFilter, event.roleID != roleFilter { continue }
            append(event.createdAt, from(event), kind(of: event), event.actionText(roleName: event.roleID))
        }
        if roleFilter == nil {
            appendRunWide(run, to: append)
        }

        return collected
            .sorted { $0.entry.at != $1.entry.at ? $0.entry.at < $1.entry.at : $0.order < $1.order }
            .map(\.entry)
    }

    private typealias Append = (Date, String, Kind, String) -> Void

    private static func appendStep(_ step: StepExecution, to append: Append) {
        let roleID = step.effectiveRoleID
        // The step's messages are the role's own turns and the notes its completion recorded —
        // and, under the role `.supervisor`, what the Supervisor side told it for the wire to
        // relay: revision feedback, an amendment, an upstream notice, the comment left for this
        // role when the previous one was accepted. Those are not the role's words. Most also get
        // a display turn of their own (`.supervisorFeedback`, appended when the step re-enters),
        // which the conversation pass below lists with its author, so each is listed from here
        // only while it has none.
        let feedbackTurns = Set(step.llmConversation
            .filter { $0.sourceContext == .supervisorFeedback }
            .map { MessageSourceContext.rawFeedback($0.content) })
        let pendingRevision = step.revisionComment.map(MessageSourceContext.rawFeedback)
        for msg in step.messages {
            guard msg.role == .supervisor else {
                append(msg.createdAt, roleID, .message, msg.content)
                continue
            }
            let said = MessageSourceContext.rawFeedback(msg.content)
            guard !feedbackTurns.contains(said) else { continue }
            append(msg.createdAt,
                   supervisorStepMessageAuthor(msg, in: step, isPendingRevision: said == pendingRevision),
                   .supervisorFeedback, said)
        }
        for call in step.toolCalls {
            if call.isSupervisorAsk && !call.isRefusedAsk {
                append(call.createdAt, roleID, .question, call.parsedSupervisorQuestion ?? call.argumentsJSON)
            } else if let recordedAt = call.resultRecordedAt, recordedAt > call.createdAt,
                      let outcome = toolCallOutcomeLine(call) {
                append(call.createdAt, roleID, .toolCall, toolCallInvocationLine(call))
                append(recordedAt, roleID, .toolCall, outcome)
            } else {
                append(call.createdAt, roleID, .toolCall, toolCallLine(call))
            }
        }
        // What the Supervisor said to the role, each at the time it was said. The answer slot
        // (`step.supervisorAnswer`) holds only the latest answer and the step's `updatedAt` is its
        // last write, so reading the slot put an answer after the work it had shaped and dropped
        // every earlier one; the conversation keeps each turn.
        for msg in step.llmConversation {
            guard let kind = msg.sourceContext.flatMap(kind(forSupervisorTurn:)) else { continue }
            append(msg.createdAt, supervisorTurnAuthor(msg, in: step), kind, msg.displayContent)
        }
    }

    private static func appendRunWide(_ run: Run, to append: Append) {
        for meeting in run.meetings {
            for turn in meeting.messages {
                append(turn.createdAt, turn.role.baseID, .meeting, turn.content)
            }
            for decision in meeting.decisions {
                append(decision.createdAt, decision.proposedBy.baseID, .meetingDecision, decision.summary)
            }
        }
        for (consultRoleID, chat) in run.consultationChats {
            for msg in chat.messages where msg.role != .system {
                append(msg.createdAt, consultRoleID, .consultation, msg.content)
            }
        }
        for changeReq in run.changeRequests {
            // A change request is a VOTE with its own budget, and it can be rejected, escalated or
            // fail outright with no impartial chair. Without the status three identical lines
            // cannot tell a team that is self-correcting from one deadlocked on a vote that never
            // lands — the exact judgement the stuck/failed triage asks the agent to make.
            if let resolvedAt = changeReq.resolvedAt, resolvedAt > changeReq.createdAt {
                append(changeReq.createdAt, changeReq.requestingRoleID, .changeRequest,
                       "\(changeReq.targetRoleID) [\(ChangeRequestStatus.pending.rawValue)]: \(changeReq.changes)")
                append(resolvedAt, changeReq.requestingRoleID, .changeRequest,
                       "\(changeReq.targetRoleID) [\(changeReq.status.rawValue)]: \(changeReq.changes)")
            } else {
                append(changeReq.createdAt, changeReq.requestingRoleID, .changeRequest,
                       "\(changeReq.targetRoleID) [\(changeReq.status.rawValue)]: \(changeReq.changes)")
            }
        }
    }

    // MARK: - Tool call formatting

    /// The invocation line for a tool call (name and arguments), omitting any outcome.
    static func toolCallInvocationLine(_ call: StepToolCall) -> String {
        var line = call.name
        let summary = ToolCallSummarizer.cardSummary(
            toolName: call.name,
            argumentsJSON: call.argumentsJSON,
            resultJSON: nil,
            isError: false
        )
        if !summary.isEmpty {
            line += " \(summary)"
        } else if call.name == ToolNames.createArtifact,
                  let name = JSONUtilities.parseJSONDictionary(call.argumentsJSON)?["name"] as? String,
                  !name.isEmpty {
            line += " \(MCPTextSanitizer.singleLine(name))"
        }
        return line
    }

    /// The outcome line for a tool call when recorded after invocation.
    /// Returns nil if no outcome exists or if the call produced no distinct summary.
    static func toolCallOutcomeLine(_ call: StepToolCall) -> String? {
        if call.isError == true {
            let reason = [call.errorCode, call.errorMessage].compactMap { $0 }.joined(separator: ": ")
            let invocation = toolCallInvocationLine(call)
            return reason.isEmpty ? "\(invocation) → error" : "\(invocation) → error \(reason)"
        }
        guard let resultJSON = call.resultJSON,
              let outcome = ToolCallSummarizer.outcomeSummary(toolName: call.name, resultJSON: resultJSON)
        else { return nil }
        return "\(toolCallInvocationLine(call)) → \(outcome)"
    }

    /// `name` and what its arguments say; for `create_artifact` the artifact's name, which the
    /// activity feed draws as a card of its own and the card summary therefore leaves out; the
    /// outcome where it is the news (`ToolCallSummarizer.outcomeSummary`); and why the call
    /// failed, when it did.
    static func toolCallLine(_ call: StepToolCall) -> String {
        var line = call.name
        let summary = ToolCallSummarizer.cardSummary(
            toolName: call.name,
            argumentsJSON: call.argumentsJSON,
            resultJSON: call.resultJSON,
            isError: call.isError ?? false
        )
        if !summary.isEmpty {
            line += " \(summary)"
        } else if call.name == ToolNames.createArtifact,
                  let name = JSONUtilities.parseJSONDictionary(call.argumentsJSON)?["name"] as? String,
                  !name.isEmpty {
            line += " \(MCPTextSanitizer.singleLine(name))"
        }
        if call.isError != true, let resultJSON = call.resultJSON,
           let outcome = ToolCallSummarizer.outcomeSummary(toolName: call.name, resultJSON: resultJSON) {
            line += " → \(outcome)"
        }
        return withFailureOutcome(line, of: call)
    }

    /// `line` plus why the call failed, when it did — a refused or unknown tool otherwise reads
    /// exactly like one that worked.
    static func withFailureOutcome(_ line: String, of call: StepToolCall) -> String {
        guard call.isError == true else { return line }
        let reason = [call.errorCode, call.errorMessage].compactMap { $0 }.joined(separator: ": ")
        return reason.isEmpty ? "\(line) → error" : "\(line) → error \(reason)"
    }

    // MARK: - Who

    /// The kind for a turn the SUPERVISOR put into a role's conversation, or `nil` for every
    /// other turn. Exhaustive so a context added later is classified by whoever adds it.
    static func kind(forSupervisorTurn context: MessageSourceContext) -> Kind? {
        switch context {
        case .supervisorAnswer: .answer
        case .supervisorMessage: .supervisorMessage
        case .supervisorFeedback: .supervisorFeedback
        case .consultation, .meeting, .changeRequest, .delegatedQuestion, .delegationEscalation,
             .serverError, .loopCorrection, .retryNudge, .toolAcknowledgement, .runtimeWarning,
             .autovisorEvent, .screenDescription, .compaction, .questionnaireRequest:
            nil
        }
    }

    /// Who said a Supervisor turn: the external agent's label when one wrote it; "autovisor" when
    /// an automated path wrote it in the person's place — the built-in manager, the team's
    /// auto-answer under `.autonomous`, a delegating parent — read off the TURN
    /// (`StepExecution.supervisorTurnWasAutomated`, the reader the question card's
    /// "Auto-answered" badge shares); otherwise "supervisor", the person. Reading the label alone
    /// credited every automated answer to the person; reading the step's flag credited every
    /// answer of the step to whoever answered last (DEBTS D-M15).
    static func supervisorTurnAuthor(_ msg: LLMMessage, in step: StepExecution) -> String {
        if let label = msg.authorLabel { return label }
        return step.supervisorTurnWasAutomated(msg) ? "autovisor" : "supervisor"
    }

    /// `from` for a `.supervisor` step message — a restart comment, a revision or correction not
    /// yet delivered, the comment left for the next role. The message records its author since
    /// 2026-11-07 (DEBTS D-M15); one written before then names only the author of the pending
    /// revision it is, if it is one, and is otherwise the person's.
    static func supervisorStepMessageAuthor(
        _ msg: StepMessage, in step: StepExecution, isPendingRevision: Bool
    ) -> String {
        if let label = msg.authorLabel { return label }
        if let automated = msg.isFromAutomatedSupervisor { return automated ? "autovisor" : "supervisor" }
        guard isPendingRevision else { return "supervisor" }
        if let label = step.revisionCommentAuthor { return label }
        return step.revisionCommentIsFromAutomatedSupervisor == true ? "autovisor" : "supervisor"
    }

    /// `from` for a Supervisor action on the run's timeline, in the words the turns use. An event
    /// recorded before its actor (an external agent's accept or close) names its author label.
    static func from(_ event: SupervisorTimelineEvent) -> String {
        switch event.actor {
        case .person?: "supervisor"
        case .builtInAutovisor?: "autovisor"
        case .externalAgent?, nil: event.authorLabel
        }
    }

    private static func kind(of event: SupervisorTimelineEvent) -> Kind {
        switch event.kind {
        case .roleAccepted: .accepted
        case .taskClosed: .closed
        case .runPaused: .paused
        case .runResumed: .resumed
        }
    }
}
