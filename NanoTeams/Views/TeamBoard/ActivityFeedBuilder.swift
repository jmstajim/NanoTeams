import SwiftUI

// MARK: - Paired Assistant Message

/// Snapshot of the assistant turn that emitted an active `ask_supervisor`.
/// Shared between `ActivityFeedBuilder.ActiveSupervisorQuestion` (used to
/// suppress the bubble in the timeline) and `TeamActivityActiveQuestion`
/// (rendered in the composer's preview).
///
/// Pairs `id` and `thinking` atomically so they can't drift: the outer
/// `Optional<PairedAssistantMessage>` is the only "paired data is missing"
/// state. `id` drives feed-bubble suppression while the question is active;
/// `thinking` feeds the composer's thinking disclosure.
///
/// `thinking` is trim-to-nil at construction: whitespace-only input collapses
/// to nil so `thinking != nil` reliably means "there is something to render."
/// Consumers don't need to re-trim before checking emptiness.
nonisolated struct PairedAssistantMessage: Equatable {
    let id: UUID
    let thinking: String?

    init(id: UUID, thinking: String?) {
        self.id = id
        let trimmed = thinking?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.thinking = (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

// MARK: - Activity Feed Builder

/// Pure transformation layer: converts raw domain data into display-ready timeline items.
/// Stateless and testable — no environment dependencies.
nonisolated enum ActivityFeedBuilder {

    // MARK: - Constants

    /// Canonical placeholder surfaced when a step is waiting for supervisor
    /// input but no question text is recoverable from either `step.toolCalls`
    /// (no `ask_supervisor` call) or `step.supervisorQuestion` (nil/whitespace).
    /// Centralized so the chip in the composer and any future log line / UI
    /// banner stay in sync.
    static let escalationFallbackQuestion = "Role is waiting for input — original question text lost. Please advise."

    // MARK: - Tagged Item

    /// A timeline item annotated with section header visibility and (optionally) a
    /// team-boundary band that should render above the item. The boundary fires
    /// when the previous item belonged to a different `originTaskID`, marking
    /// transitions into / back out of a delegated child team's activity.
    nonisolated struct TaggedItem: Identifiable {
        let item: TeamActivityTimelineItem
        let showSectionHeader: Bool
        /// `nil` for items at parent→same-task continuations; non-nil at team
        /// boundaries (e.g. transitioning into a delegated child team or returning
        /// to the parent). The view renders a slim band labeled with the team
        /// name and the delegating role for transitions into a child.
        let boundary: TeamBoundary?
        var id: String { item.id }
    }

    /// Visual marker for a team-boundary transition between consecutive items.
    /// `direction` is set by the builder based on whether the new item descends
    /// further into delegated activity (`.intoChild`) or returns up the chain
    /// (`.backToParent`).
    nonisolated struct TeamBoundary: Equatable {
        enum Direction: Equatable { case intoChild, backToParent }
        let direction: Direction
        let teamName: String
        let delegatedFromRoleName: String?
        let delegationDepth: Int
    }

    // MARK: - Descendant input

    /// One delegated descendant of the active task contributing items to the
    /// merged timeline. The view resolves these by walking the *displayed run's*
    /// per-step delegation history (`runScopedDescendantIDs`) and threads the
    /// resolved `(task, run, teamRoles)` triple here so the builder doesn't need
    /// to know about `NTMSOrchestrator`.
    nonisolated struct DescendantTask {
        let task: NTMSTask
        let run: Run
        let teamRoles: [TeamRoleDefinition]
        let teamName: String?
        let delegationDepth: Int
        /// Display name of the role in the parent task that issued the
        /// `delegate_to_team` call producing this descendant. Used for the
        /// "delegated by …" subtitle on the boundary band.
        let delegatedFromRoleName: String?
    }

    /// Child task ids delegated within ONE specific parent run, transitively
    /// (direct children + their nested delegations). Walks each step's
    /// `delegationChildIDs` — the append-only history that includes both
    /// completed and in-flight delegations — so a fresh run with empty
    /// histories yields `[]` (the fix: old-run children never leak into a new
    /// run's feed).
    ///
    /// Run-scoped on purpose: `TasksIndex.descendantIDs(of:)` is run-agnostic
    /// (every descendant the parent ever spawned), which is what caused a new
    /// run to keep showing the previous run's delegated-team activity.
    ///
    /// The walk is transitive, not a flat one-level pass, because a
    /// grandchild's id lives in the *child's* run step history, not the parent
    /// run's — a flat filter would drop depth-2/3 descendants that the feed
    /// shows today.
    ///
    /// Two independent guards, doing different jobs:
    /// - **Termination** is provided entirely by `result`-membership dedup:
    ///   `tasksByID` is finite and each id is inserted at most once, so even a
    ///   corrupted-tasks-index self-cycle (a child whose history points back at
    ///   an ancestor) cannot loop. `maxDepth` is NOT needed for this.
    /// - **`maxDepth`** is a depth-scoping bound mirroring the delegation depth
    ///   cap (`DelegationConstants.maxDelegationDepth`) — it stops the walk
    ///   surfacing descendants beyond the cap, not cycles. (Loose analogy to the
    ///   cycle guards in `TasksIndex.descendantIDs` / `ancestorIDs`, though those
    ///   use a separate `visited` set and the wider `treeTraversalSafetyCap`.)
    ///
    /// Each child contributes its latest run (`runs.last`). Benign today: a
    /// delegation child has exactly one run (created fresh on delegate; resume /
    /// forward / cancel reuse it; the recurrence scheduler skips child tasks), so
    /// `runs.last` is the run contemporaneous with `parentRun`.
    static func runScopedDescendantIDs(
        parentRun: Run,
        tasksByID: [Int: NTMSTask],
        maxDepth: Int = DelegationConstants.maxDelegationDepth
    ) -> Set<Int> {
        var result: Set<Int> = []
        var frontier: [(run: Run, depth: Int)] = [(parentRun, 0)]
        while let (run, depth) = frontier.popLast() {
            guard depth < maxDepth else { continue }
            for step in run.steps {
                for childID in step.delegationChildIDs where !result.contains(childID) {
                    result.insert(childID)
                    if let childRun = tasksByID[childID]?.runs.last {
                        frontier.append((childRun, depth + 1))
                    }
                }
            }
        }
        return result
    }

    /// Build the `DescendantTask` list for the feed, scoped to `displayedRun`.
    /// Wraps `runScopedDescendantIDs` (which decides *which* children belong to
    /// the displayed run) and hydrates each into a `DescendantTask` carrying the
    /// child's latest run, team roster, team name, and the delegating role's
    /// display name for the boundary band.
    ///
    /// `resolveTeam` is injected (rather than reaching into `NTMSOrchestrator`)
    /// so this stays a pure, testable function — same closure-injection pattern
    /// as `buildTimelineItems(isStreaming:)`. The view passes
    /// `{ store.resolvedTeam(for: $0) }`.
    ///
    /// A scoped id whose task isn't in `tasksByID`, or whose task has no runs,
    /// is skipped — it has no run to render (graceful degradation for an evicted
    /// child; matches the prior behavior).
    static func resolveRunScopedDescendants(
        displayedRun: Run,
        tasksByID: [Int: NTMSTask],
        resolveTeam: (NTMSTask) -> Team,
        maxDepth: Int = DelegationConstants.maxDelegationDepth
    ) -> [DescendantTask] {
        let scopedIDs = runScopedDescendantIDs(parentRun: displayedRun, tasksByID: tasksByID, maxDepth: maxDepth)
        guard !scopedIDs.isEmpty else { return [] }

        var descendants: [DescendantTask] = []
        descendants.reserveCapacity(scopedIDs.count)
        for childID in scopedIDs {
            guard let childTask = tasksByID[childID],
                  let childRun = childTask.runs.last
            else { continue }
            let childTeam = resolveTeam(childTask)
            // Resolve the delegating role's name in the parent team for the
            // boundary-band subtitle. `parentRoleID` on the child is the
            // canonical seeded TeamRoleDefinition.id of the role that called
            // delegate_to_team.
            let parentRoleName: String?
            if let parentRoleID = childTask.parentRoleID,
               let parentTask = tasksByID[childTask.parentTaskID ?? -1] {
                parentRoleName = resolveTeam(parentTask).roles.roleName(for: parentRoleID)
            } else {
                parentRoleName = nil
            }
            descendants.append(DescendantTask(
                task: childTask,
                run: childRun,
                teamRoles: childTeam.roles,
                teamName: childTeam.name,
                delegationDepth: childTask.delegationDepth,
                delegatedFromRoleName: parentRoleName
            ))
        }
        return descendants
    }

    // MARK: - Build

    /// Builds the sorted, annotated activity timeline from domain data.
    /// - Parameters:
    ///   - steps: Pre-filtered step executions for the active team members.
    ///   - run: The active run (for meetings and change requests).
    ///   - activeTaskID: Origin task ID stamped onto every item from `steps`/`run`.
    ///     When the caller renders for a "no project loaded" preview the value is
    ///     irrelevant; the parameter defaults to `0` so existing tests/callers
    ///     that don't care about delegation can omit it.
    ///   - descendantTasks: Optional list of delegated descendants to interleave
    ///     into the timeline. Items from each descendant are stamped with that
    ///     descendant's task ID.
    ///   - stepArtifactContentCache: Maps step IDs to artifact file contents
    ///     (for hiding redundant messages whose content equals a step artifact).
    ///     Keyed by `step.id` — descendants share the same lookup space; same-name
    ///     artifact-content collisions across teams are accepted as dormant
    ///     V1 cosmetic risk.
    ///   - debugModeEnabled: When true, includes all messages without filtering.
    ///   - isStreaming: Returns true if the message with the given ID is actively streaming.
    static func buildTimelineItems(
        steps: [StepExecution],
        run: Run?,
        teamRoles: [TeamRoleDefinition] = [],
        activeTaskID: Int = 0,
        descendantTasks: [DescendantTask] = [],
        supervisorBrief: String? = nil,
        supervisorBriefDate: Date? = nil,
        supervisorTask: String? = nil,
        supervisorClippedTexts: [String] = [],
        supervisorAttachmentPaths: [String] = [],
        supervisorProjectFolderURL: URL? = nil,
        stepArtifactContentCache: [String: Set<String>],
        debugModeEnabled: Bool,
        activeQuestions: [ActiveSupervisorQuestion] = [],
        isStreaming: (UUID) -> Bool
    ) -> [TaggedItem] {
        var items: [TeamActivityTimelineItem] = []

        // Compute once — `emitItems` matches `msg.id` against this set to suppress
        // the assistant bubble whose turn the question card is currently fronting.
        // Same precomputed list as the composer's chips, so the two surfaces can
        // never drift ("question card visible but feed still shows the bubble" or
        // vice versa). Active task + descendants share the same set since
        // `paired.id` (i.e. `LLMMessage.id`) is a globally-unique UUID.
        let suppressedMessageIDs: Set<UUID> = Set(activeQuestions.compactMap { $0.paired?.id })

        // Active task: emit items as before, stamped with activeTaskID.
        emitItems(
            into: &items,
            steps: steps,
            run: run,
            teamRoles: teamRoles,
            originTaskID: activeTaskID,
            stepArtifactContentCache: stepArtifactContentCache,
            debugModeEnabled: debugModeEnabled,
            suppressedMessageIDs: suppressedMessageIDs,
            isStreaming: isStreaming
        )

        // Descendants: same emission logic, stamped per descendant's task ID.
        // Each descendant's `run` contributes its meetings, change requests,
        // and supervisor-input notifications; the builder does NOT emit the
        // descendant's supervisor-task brief (would visually duplicate the
        // parent's `delegate_to_team` tool-call card).
        for descendant in descendantTasks {
            emitItems(
                into: &items,
                steps: descendant.run.steps,
                run: descendant.run,
                teamRoles: descendant.teamRoles,
                originTaskID: descendant.task.id,
                stepArtifactContentCache: stepArtifactContentCache,
                debugModeEnabled: debugModeEnabled,
                suppressedMessageIDs: suppressedMessageIDs,
                isStreaming: isStreaming
            )
        }

        // Supervisor task (always first — task.createdAt predates any step execution).
        // Only emitted for the ACTIVE task; descendants don't get their own card.
        if let brief = supervisorBrief,
           !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let date = supervisorBriefDate {
            // Strip embedded file/clip sections from display text (content is inline for LLM only)
            let rawTask = supervisorTask ?? brief
            let stripped = stripAttachedFiles(from: rawTask)
            let displayTask = stripped.text ?? rawTask
            // Merge clip/attachment paths from both the stripped text and the structured fields
            let allClips = supervisorClippedTexts.isEmpty ? stripped.clippedTexts : supervisorClippedTexts
            let allPaths = supervisorAttachmentPaths.isEmpty ? stripped.paths : supervisorAttachmentPaths
            items.append(.supervisorTask(
                brief: brief,
                taskCreatedAt: date,
                supervisorTask: displayTask,
                clippedTexts: allClips,
                attachmentPaths: allPaths,
                workFolderURL: supervisorProjectFolderURL,
                originTaskID: activeTaskID
            ))
        }

        // Two-key sort: (pinnedToEnd ascending, createdAt ascending). The active
        // task's streaming preview bubbles pin to the bottom of the feed even when
        // their `createdAt` is mid-history — necessary because a streaming item's
        // `createdAt` is not guaranteed to be the latest in the step (later
        // non-streaming items like retry-error messages can land while the
        // preview is alive). Descendant-task streaming items are NOT pinned: the
        // `annotate` pass below emits a `TeamBoundary` band on every
        // `originTaskID` transition, so pinning a descendant stream past parent
        // items would synthesize a spurious cross-team band right before a
        // content-less "Waiting" bubble. Concurrent streaming items in the
        // active task order among themselves by `createdAt`.
        let sorted = items.sorted { lhs, rhs in
            let lhsPinned = lhs.isStreamingItem(isStreaming: isStreaming) && lhs.originTaskID == activeTaskID
            let rhsPinned = rhs.isStreamingItem(isStreaming: isStreaming) && rhs.originTaskID == activeTaskID
            if lhsPinned != rhsPinned { return !lhsPinned }
            return lhs.createdAt < rhs.createdAt
        }

        // Index descendants by task ID for boundary annotation lookups.
        var descendantsByID: [Int: DescendantTask] = [:]
        for d in descendantTasks { descendantsByID[d.task.id] = d }
        return annotate(sorted, activeTaskID: activeTaskID, descendantsByID: descendantsByID)
    }

    // MARK: - Per-task emission

    private static func emitItems(
        into items: inout [TeamActivityTimelineItem],
        steps: [StepExecution],
        run: Run?,
        teamRoles: [TeamRoleDefinition],
        originTaskID: Int,
        stepArtifactContentCache: [String: Set<String>],
        debugModeEnabled: Bool,
        suppressedMessageIDs: Set<UUID> = [],
        isStreaming: (UUID) -> Bool
    ) {
        // Step messages, tool calls, and artifacts
        for step in steps {
            let role = step.role
            // nil = cache not loaded yet → don't filter (messages stay visible until cache ready)
            let artifactContents: Set<String> = debugModeEnabled ? [] : (stepArtifactContentCache[step.id] ?? [])

            for msg in step.llmConversation where msg.role != .system && msg.role != .tool {
                let hasThinking = msg.thinking.map {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } ?? false
                let isActivelyStreaming = isStreaming(msg.id)
                if msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !hasThinking && !isActivelyStreaming
                {
                    continue
                }
                if !debugModeEnabled && msg.role == .user {
                    if msg.sourceRole == nil && msg.sourceContext == nil { continue }
                    if msg.sourceContext == .supervisorAnswer { continue }
                }
                if !debugModeEnabled && !msg.content.isEmpty
                    && artifactContents.contains(msg.content) && !hasThinking
                {
                    continue
                }
                // Drop ghost `.supervisorMessage` turns that resolve to
                // nothing after attribution-prefix strip + marker strip.
                // Streaming turns are exempt — the indicator row needs
                // the bubble alive even before first delta lands.
                if !isActivelyStreaming && shouldSuppressEmptySupervisorMessage(msg) {
                    continue
                }
                // Suppress the assistant turn paired with an active `ask_supervisor`
                // — its substantive reply lives in the composer's preview while the
                // question is unanswered. Once `supervisorAnswer` is set, the id
                // drops out of `suppressedMessageIDs` and the bubble reappears as
                // history. Streaming exemption: while the preview is live the user
                // is watching the response come in; the composer chip only takes
                // over after commit. See plan `replied-structured-petal.md`.
                if !isActivelyStreaming && suppressedMessageIDs.contains(msg.id) {
                    continue
                }
                let displayRole = msg.sourceRole ?? role
                items.append(.llmMessage(message: msg, role: displayRole, stepID: step.id, originTaskID: originTaskID))
            }

            for call in step.toolCalls {
                items.append(.toolCall(call: call, role: role, stepID: step.id, originTaskID: originTaskID))
            }

            for artifact in step.artifacts {
                items.append(.artifact(artifact: artifact, role: role, stepID: step.id, originTaskID: originTaskID))
            }
        }

        // Meeting messages
        for meeting in run?.meetings ?? [] {
            for msg in meeting.messages {
                items.append(.meetingMessage(message: msg, meetingTopic: meeting.topic, originTaskID: originTaskID))
            }
        }

        // Change requests
        for cr in run?.changeRequests ?? [] {
            let targetName = teamRoles.roleName(for: cr.targetRoleID)
            items.append(.changeRequest(request: cr, targetRoleName: targetName, originTaskID: originTaskID))
        }

        // Answered supervisor-input notifications. Active / in-flight questions
        // (including the multi-round race where `step.supervisorAnswer` is
        // stale from a previous round) are owned by the docked composer and
        // skipped here. `stepHasActiveSupervisorInput` is the shared predicate.
        for step in steps {
            let askCalls = step.toolCalls.filter { $0.name == ToolNames.askSupervisor }
            let answerMessages = step.llmConversation.filter { $0.sourceContext == .supervisorAnswer }
            let stepIsActive = Self.stepHasActiveSupervisorInput(step)

            for (index, call) in askCalls.enumerated() {
                let isLast = index == askCalls.count - 1
                if isLast && stepIsActive { continue }

                let question: String
                if let parsed = parseAskSupervisorQuestion(from: call.argumentsJSON) {
                    question = parsed
                } else if isLast {
                    question = step.supervisorQuestion
                        .flatMap { parseAskSupervisorQuestion(from: $0) }
                        ?? step.supervisorQuestion ?? "?"
                } else {
                    question = "?"
                }

                let rawAnswer: String?
                if index < answerMessages.count {
                    let content = answerMessages[index].content
                    rawAnswer = content.hasPrefix("Supervisor answer: ")
                        ? String(content.dropFirst("Supervisor answer: ".count))
                        : content
                } else if isLast {
                    rawAnswer = step.supervisorAnswer
                } else {
                    rawAnswer = "(answered)"
                }

                let thinking = step.llmConversation
                    .last(where: {
                        $0.role == .assistant && $0.thinking != nil && $0.createdAt <= call.createdAt
                    })?.thinking

                // Use answer timestamp (when Supervisor responded), fall back to call timestamp
                let answerTimestamp = index < answerMessages.count
                    ? answerMessages[index].createdAt
                    : call.createdAt

                appendSupervisorInputNotification(
                    into: &items,
                    step: step,
                    rawAnswer: rawAnswer,
                    question: question,
                    toolCallID: call.id,
                    thinking: thinking,
                    timestamp: answerTimestamp,
                    mergeStructuredAttachmentPaths: isLast,
                    originTaskID: originTaskID
                )
            }

            // Escalation-path answered Q&A: `setNeedsSupervisorInput` from a
            // drift / refusal-loop / parse-failure cap writes
            // `supervisorQuestion` + flag-true WITHOUT appending an
            // `ask_supervisor` tool call, then `answerSupervisorQuestion` writes
            // `supervisorAnswer` + flips the flag to false. Without this
            // synthesized notification, the answered Q&A would vanish from feed
            // history (the inner loop above iterates `askCalls`, which is empty
            // for the escalation path). Active state is owned by
            // `activeSupervisorQuestions` (composer chip), so we only emit
            // history once the step is no longer active.
            if askCalls.isEmpty,
               !stepIsActive,
               let escalationQ = step.supervisorQuestion?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !escalationQ.isEmpty,
               step.supervisorAnswer != nil {
                // Latest answer turn = the stable anchor for sort position, item
                // identity, AND the thinking bound. `step.updatedAt` is re-stamped
                // by every later mutation (tool calls, messages), which made the
                // card drift below items that happened AFTER the answer; a fresh
                // UUID() per rebuild broke item identity + the supervisorThinking
                // window dedup; an unbounded thinking lookup re-bound the card's
                // "Thinking" row to post-answer reasoning as the step kept running.
                // The `??` arms are reachable only for task.json persisted before
                // `StepMessagingService.answerSupervisorQuestion` started appending
                // the `.supervisorAnswer` message in the same mutation that sets
                // `supervisorAnswer` — every live escalation-path writer routes
                // through it, so legacy data keeps the old behavior and new data
                // never hits the fallback.
                let answerMsg = answerMessages.last
                let anchor = answerMsg?.createdAt ?? step.updatedAt
                let thinking = step.llmConversation
                    .last(where: {
                        $0.role == .assistant && $0.thinking != nil && $0.createdAt <= anchor
                    })?.thinking
                appendSupervisorInputNotification(
                    into: &items,
                    step: step,
                    rawAnswer: step.supervisorAnswer,
                    question: escalationQ,
                    toolCallID: answerMsg?.id ?? UUID(),
                    thinking: thinking,
                    timestamp: anchor,
                    mergeStructuredAttachmentPaths: true,
                    originTaskID: originTaskID
                )
            }

            if step.status == .failed {
                items.append(.notification(
                    stepID: step.id,
                    role: step.role,
                    type: .failed(errorMessage: nil),
                    createdAt: step.completedAt ?? step.updatedAt,
                    originTaskID: originTaskID
                ))
            }
        }
    }

    /// Shared notification-emission for both the per-`ask_supervisor` inner loop
    /// (normal path) and the escalation-path step exit. `stripAttachedFiles` +
    /// structured-paths merge + clipped-text extraction are identical between
    /// the two; only the inputs (toolCallID, thinking lookup, timestamp,
    /// raw-answer source, whether to merge structured paths) differ — those
    /// are passed in explicitly so the helper has no branching.
    private static func appendSupervisorInputNotification(
        into items: inout [TeamActivityTimelineItem],
        step: StepExecution,
        rawAnswer: String?,
        question: String,
        toolCallID: UUID,
        thinking: String?,
        timestamp: Date,
        mergeStructuredAttachmentPaths: Bool,
        originTaskID: Int
    ) {
        let answer: String?
        var attachmentPaths: [String] = []
        var answerClippedTexts: [String] = []
        if let raw = rawAnswer {
            let stripped = stripAttachedFiles(from: raw)
            answer = stripped.text ?? (stripped.paths.isEmpty && stripped.clippedTexts.isEmpty ? nil : "")
            attachmentPaths = stripped.paths
            answerClippedTexts = stripped.clippedTexts
        } else {
            answer = nil
        }
        if mergeStructuredAttachmentPaths {
            let structuredPaths = step.supervisorAnswerAttachmentPaths
            if !structuredPaths.isEmpty {
                let existing = Set(attachmentPaths)
                for path in structuredPaths where !existing.contains(path) {
                    attachmentPaths.append(path)
                }
            }
        }
        items.append(.notification(
            stepID: step.id,
            role: step.role,
            type: .supervisorInput(
                question: question, answer: answer,
                answerAttachmentPaths: attachmentPaths,
                answerClippedTexts: answerClippedTexts,
                toolCallID: toolCallID, thinking: thinking,
                wasAutoAnswered: step.supervisorAnswerWasAuto
            ),
            createdAt: timestamp,
            originTaskID: originTaskID
        ))
    }

    // MARK: - Helpers

    /// Annotates sorted items with `showSectionHeader` and `boundary` flags.
    ///
    /// Section header fires when the consecutive `(roleID, originTaskID)` tuple
    /// changes — NOT just `roleID`. Without the originTaskID component, two roles
    /// in different teams that share the same `Role` enum case (e.g. both teams
    /// using `.softwareEngineer`) would visually merge into one continuous block
    /// after interleave; the role.baseID-based grouping was designed for a single
    /// team's timeline.
    ///
    /// Boundary band fires whenever the originTaskID changes between consecutive
    /// items. Direction is `.intoChild` when the new task is a descendant of the
    /// previous item's task (or the active task), `.backToParent` otherwise.
    private static func annotate(
        _ items: [TeamActivityTimelineItem],
        activeTaskID: Int,
        descendantsByID: [Int: DescendantTask]
    ) -> [TaggedItem] {
        var tagged: [TaggedItem] = []
        tagged.reserveCapacity(items.count)
        var prevRoleID: String? = nil
        var prevOriginTaskID: Int? = nil
        var prevHadRoleID: Bool = false

        for item in items {
            let curRoleID = item.roleID
            let curOriginTaskID = item.originTaskID

            // Section header rule (extended): fire on first item, when curRoleID is
            // nil (notifications/changeRequests always break grouping), or when
            // either roleID or originTaskID differs from the previous item.
            let showHeader = tagged.isEmpty
                || curRoleID == nil
                || !prevHadRoleID
                || prevRoleID != curRoleID
                || prevOriginTaskID != curOriginTaskID

            // Boundary band: emitted on origin-task transitions only (never on
            // the very first item).
            let boundary: TeamBoundary?
            if let prevID = prevOriginTaskID, prevID != curOriginTaskID {
                if let entered = descendantsByID[curOriginTaskID] {
                    boundary = TeamBoundary(
                        direction: .intoChild,
                        teamName: entered.teamName ?? "Delegated Team",
                        delegatedFromRoleName: entered.delegatedFromRoleName,
                        delegationDepth: entered.delegationDepth
                    )
                } else if curOriginTaskID == activeTaskID {
                    // Returning to the active task. Use the leaving descendant's
                    // team name to label the band ("back from <team>").
                    let leaving = descendantsByID[prevID]
                    boundary = TeamBoundary(
                        direction: .backToParent,
                        teamName: leaving?.teamName ?? "parent team",
                        delegatedFromRoleName: leaving?.delegatedFromRoleName,
                        delegationDepth: leaving?.delegationDepth ?? 0
                    )
                } else {
                    // Cross-descendant transition (deep recursion). Show as
                    // .intoChild with whatever metadata we have.
                    let entered = descendantsByID[curOriginTaskID]
                    boundary = TeamBoundary(
                        direction: .intoChild,
                        teamName: entered?.teamName ?? "Delegated Team",
                        delegatedFromRoleName: entered?.delegatedFromRoleName,
                        delegationDepth: entered?.delegationDepth ?? 0
                    )
                }
            } else {
                boundary = nil
            }

            tagged.append(TaggedItem(item: item, showSectionHeader: showHeader, boundary: boundary))
            prevRoleID = curRoleID
            prevOriginTaskID = curOriginTaskID
            prevHadRoleID = curRoleID != nil
        }
        return tagged
    }

    // MARK: - Active Supervisor Questions (for banner)

    /// Data for an active (unanswered) supervisor question, displayed as a banner.
    ///
    /// `paired` identifies the assistant turn that emitted the question — used by
    /// `emitItems` to suppress that bubble from the feed (so the question card
    /// is the sole surface for that turn while unanswered) and by the composer
    /// to surface the turn's `thinking` in its disclosure row. Existing convention
    /// is `active = hidden from feed, answered = visible` (see "Answered
    /// supervisor-input notifications" branch in `emitItems`).
    ///
    /// `paired == nil` covers the case where no assistant turn precedes the tool
    /// call (e.g. ask landed on turn 1 with no preamble) — composer falls back
    /// to rendering `question` alone, and there's no bubble to suppress.
    struct ActiveSupervisorQuestion {
        let stepID: String
        let role: Role
        let question: String
        let paired: PairedAssistantMessage?
        let toolCallID: UUID
        /// Timestamp of the active `ask_supervisor` tool call (i.e. the LAST one in
        /// the step's tool-call list, not the first — a role can ask twice). Builder
        /// emits results sorted ascending by this field; UI ordering is the consumer's
        /// concern (e.g. `TeamActivityComposer.computeChipOptions` preserves order).
        let askedAt: Date
    }

    /// Single source of truth for "this step has an unanswered `ask_supervisor`
    /// question that the docked composer should own". Shared by `emitItems`'s
    /// supervisor-input skip, `activeSupervisorQuestions`, and the
    /// `supervisorInputCount` fingerprint — all three must agree, otherwise
    /// the composer chip, the feed skip, and the rebuild trigger fall out of
    /// sync (which is exactly the bug the multi-round race produced).
    ///
    /// Criterion: the trailing tool call is `ask_supervisor` AND there are
    /// more `ask_supervisor` calls than `Supervisor answer: …` messages in
    /// `llmConversation`. `needsSupervisorInput` is OR'd in as defensive
    /// backstop for any engine path that sets the flag without a matching
    /// tool call.
    ///
    /// The count check is critical for the multi-round race: after the
    /// supervisor answers iter N, `step.supervisorAnswer` retains the iter-N
    /// answer until `setNeedsSupervisorInput` runs for iter N+1. Between
    /// `appendToolCalls(N+1)` and that clear, the iter N+1 question is
    /// in-flight but `step.supervisorAnswer` is still non-nil — a
    /// `supervisorAnswer == nil` guard misclassifies it as resolved.
    /// Counting answer messages against ask calls is invariant to that
    /// lifecycle (both fields are written together — see
    /// `LLMExecutionService+StepLifecycle.swift`).
    static func stepHasActiveSupervisorInput(_ step: StepExecution) -> Bool {
        let askCalls = step.toolCalls.filter { $0.name == ToolNames.askSupervisor }
        guard !askCalls.isEmpty else { return step.needsSupervisorInput }
        let answerMessages = step.llmConversation.filter { $0.sourceContext == .supervisorAnswer }
        let trailingIsAsk = step.toolCalls.last?.name == ToolNames.askSupervisor
        let trailingUnanswered = trailingIsAsk && answerMessages.count < askCalls.count
        return trailingUnanswered || step.needsSupervisorInput
    }

    /// Extracts active (unanswered) supervisor questions from steps. Result is sorted
    /// ascending by `askedAt`, with `stepID` as a deterministic tie-breaker — two
    /// `ask_supervisor` calls landing in the same monotonic tick must produce a stable
    /// order across recomputes, otherwise the leftmost chip flips and any draft typed
    /// into the auto-selected recipient would silently retarget on the next refresh.
    ///
    /// Uses `stepHasActiveSupervisorInput` for the active-state check.
    ///
    /// Two surfacing paths:
    /// 1. **Trailing `ask_supervisor` tool call** — normal path. Question text
    ///    parsed from the call's argumentsJSON; `toolCallID`/`askedAt` come
    ///    from that call; `paired` is the assistant turn that emitted it.
    /// 2. **Escalation path** (no tool call) — the engine's drift / refusal-
    ///    loop / parse-failure caps in `LLMExecutionService+StepFlowControl.swift`
    ///    call `setNeedsSupervisorInput(stepID:question:sessionID:)` directly,
    ///    flipping the flag without appending a tool call. Without this branch,
    ///    `activeSupervisorQuestions` silently returned `[]` for these steps
    ///    even though `stepHasActiveSupervisorInput` agreed they were waiting —
    ///    composer chip never appeared, question card never rendered, and the
    ///    user had to switch tasks to force a fresh view rebuild.
    ///    Pinned by `ActivityFeedBuilderTests.testEscalationPath_emptyAskCalls_flagSet_surfacesStoredQuestion`.
    static func activeSupervisorQuestions(steps: [StepExecution]) -> [ActiveSupervisorQuestion] {
        var result: [ActiveSupervisorQuestion] = []
        for step in steps {
            guard stepHasActiveSupervisorInput(step) else { continue }
            let askCalls = step.toolCalls.filter { $0.name == ToolNames.askSupervisor }

            let question: String
            let toolCallID: UUID
            let askedAt: Date
            let paired: PairedAssistantMessage?

            if let lastCall = askCalls.last {
                // Normal path: trailing ask_supervisor tool call.
                //
                // Preference order:
                //   1. `step.supervisorQuestion` when `step.needsSupervisorInput == true`
                //      — only `setNeedsSupervisorInput` / `recordAutoSupervisorAnswer`
                //      write both fields atomically, so the flag-true state guarantees
                //      `supervisorQuestion` is the CURRENT text (covers escalation
                //      overwriting an earlier `ask_supervisor` arg).
                //   2. Otherwise the tool-call `argumentsJSON` — fresher than a flag-
                //      false `supervisorQuestion`, which is STALE from the previous
                //      round (`StepMessagingService.answerSupervisorQuestion` doesn't
                //      clear it on user answer). This is the transient window
                //      between `appendToolCalls(newAsk)` and the matching
                //      `setNeedsSupervisorInput` — without the flag gate, the prior
                //      round's question text would flash for a frame before snapping
                //      to the new one.
                //   3. Last-resort fallback: even a possibly-stale `supervisorQuestion`
                //      beats showing `"?"` to the user.
                //
                // Pinned by `testActiveSupervisorQuestions_prefersStepSupervisorQuestionOverStaleToolCallArg`
                // (case 1 — escalation) and
                // `testActiveSupervisorQuestions_transientWindow_staleSupervisorQuestion_doesNotShadowNewToolCall`
                // (case 2 — mid-round flicker). Both surfaces must agree with
                // `DefaultQuickCaptureModeCoordinator.resolveMode`, which reads
                // `step.supervisorQuestion` directly but is itself gated by
                // `step.needsSupervisorInput == true`.
                let storedQ = step.supervisorQuestion?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if step.needsSupervisorInput, !storedQ.isEmpty {
                    question = storedQ
                } else if let parsed = parseAskSupervisorQuestion(from: lastCall.argumentsJSON) {
                    question = parsed
                } else if !storedQ.isEmpty {
                    question = storedQ
                } else {
                    question = "?"
                }
                toolCallID = lastCall.id
                askedAt = lastCall.createdAt
                // Pair with the most-recent assistant turn at or before the
                // active ask. `id` drives bubble-suppression in `emitItems`;
                // `thinking` feeds the composer's thinking disclosure.
                paired = step.llmConversation
                    .last(where: { $0.role == .assistant && $0.createdAt <= lastCall.createdAt })
                    .map {
                        PairedAssistantMessage(id: $0.id, thinking: $0.thinking)
                    }
            } else {
                // Escalation path: `setNeedsSupervisorInput` from drift /
                // refusal-loop / parse-failure cap. No tool call, so the
                // question text lives only on `step.supervisorQuestion`. If
                // that's also empty/nil (future engine paths could regress —
                // the companion guard at LLMExecutionService+TaskStateMutations.swift
                // only protects today's writer), fall back to a canonical
                // placeholder. Silently `continue`ing here would wedge the
                // engine in `.needsSupervisorInput` forever — defense-in-depth.
                let trimmedQ = step.supervisorQuestion?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                question = trimmedQ.isEmpty ? Self.escalationFallbackQuestion : trimmedQ
                toolCallID = UUID()  // synthetic — escalation path has no real tool call
                askedAt = step.updatedAt
                // Pair with the last assistant turn (the one that triggered
                // the cap) so its bubble is suppressed and its thinking shows
                // in the composer's disclosure.
                paired = step.llmConversation
                    .last(where: { $0.role == .assistant })
                    .map {
                        PairedAssistantMessage(id: $0.id, thinking: $0.thinking)
                    }
            }

            result.append(ActiveSupervisorQuestion(
                stepID: step.id, role: step.role,
                question: question,
                paired: paired,
                toolCallID: toolCallID,
                askedAt: askedAt
            ))
        }
        return result.sorted { lhs, rhs in
            if lhs.askedAt != rhs.askedAt { return lhs.askedAt < rhs.askedAt }
            return lhs.stepID < rhs.stepID
        }
    }

    /// Strips the `## Attached Files` section from an answer string.
    /// Returns the cleaned text (nil if empty after stripping) and extracted file paths.
    /// All header patterns are line-anchored — bare phrases inside body text don't trigger.
    static func stripAttachedFiles(from text: String) -> (text: String?, paths: [String], clippedTexts: [String]) {
        var remaining = text
        var paths: [String] = []
        var clippedTexts: [String] = []

        // Extract "## Attached Files" section (line-anchored).
        let fileSepPattern = "^## Attached Files$"
        if let regex = try? NSRegularExpression(pattern: fileSepPattern, options: [.anchorsMatchLines]) {
            let nsRemaining = remaining as NSString
            let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsRemaining.length))
            if let firstMatch = matches.first {
                let after = nsRemaining.substring(from: firstMatch.range.upperBound)
                remaining = nsRemaining.substring(to: firstMatch.range.location)
                paths = after
                    .components(separatedBy: .newlines)
                    .compactMap { line -> String? in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("- ") else { return nil }
                        let path = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        return path.isEmpty ? nil : path
                    }
            }
        }

        // Strip "## Attached File: filename" sections (embedded file contents) — before clips
        // so embedded file content doesn't leak into the last clip's body.
        let embeddedFilePattern = "^## Attached File: [^\n]+$"
        if let regex = try? NSRegularExpression(pattern: embeddedFilePattern, options: [.anchorsMatchLines]) {
            let nsRemaining = remaining as NSString
            let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsRemaining.length))
            if let firstMatch = matches.first {
                remaining = nsRemaining.substring(to: firstMatch.range.location)
            }
        }

        // Extract "## Clipped Text" / "## Clipped Text — metadata" sections (line-anchored).
        let clipPattern = "^## Clipped Text(?: \u{2014} [^\n]+)?$"
        if let regex = try? NSRegularExpression(pattern: clipPattern, options: [.anchorsMatchLines]) {
            let nsRemaining = remaining as NSString
            let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsRemaining.length))
            if !matches.isEmpty {
                // Collect clip content between headers (or after last header until end).
                let headerRanges = matches.map { $0.range }
                for i in 0..<headerRanges.count {
                    let contentStart = headerRanges[i].upperBound
                    let contentEnd = i + 1 < headerRanges.count
                        ? headerRanges[i + 1].location
                        : nsRemaining.length
                    let clip = nsRemaining.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clip.isEmpty {
                        clippedTexts.append(clip)
                    }
                }
                // Remove all clip sections from remaining text.
                if let firstMatch = headerRanges.first {
                    remaining = nsRemaining.substring(to: firstMatch.location)
                }
            }
        }

        let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? nil : trimmed, paths, clippedTexts)
    }

    /// Resolves the bubble inputs for a message turn. For
    /// `.supervisorMessage` turns it strips the embedded `## Attached Files`
    /// / `## Clipped Text` markers and returns the cleaned text alongside
    /// the extracted paths/clips. For all other turns it returns `raw`
    /// verbatim with empty paths/clips.
    ///
    /// The non-obvious bit: when `isSupervisorMessage` is true and the user
    /// attached a file but typed nothing, `stripAttachedFiles` returns
    /// `text == nil`. The caller (and this helper) must treat that as
    /// "the cleaned text is empty" — falling back to `raw` here would
    /// re-render the marker section the strip just removed.
    static func bubbleDisplayInputs(
        raw: String,
        isSupervisorMessage: Bool
    ) -> (text: String, paths: [String], clippedTexts: [String]) {
        guard isSupervisorMessage else { return (raw, [], []) }
        let stripped = stripAttachedFiles(from: raw)
        return (stripped.text ?? "", stripped.paths, stripped.clippedTexts)
    }

    /// Whether a `.supervisorMessage` turn has nothing committed-side to
    /// render — no body, no thinking, no attachments, no clips. The C4
    /// atomicity race (queued chat / `forward_to_team`) can briefly emit
    /// a turn whose raw `content` is just `"Supervisor:\n"` plus an empty
    /// marker section; after `displayContent` strips the prefix and
    /// `stripAttachedFiles` removes the section, every channel resolves
    /// to empty.
    ///
    /// Predicate is narrowed to `.supervisorMessage` on purpose: empty
    /// content from any other source context indicates a real bug
    /// upstream and should surface as a visible avatar-only bubble so
    /// the regression doesn't get swallowed.
    ///
    /// Filtering at the builder (rather than the dispatcher) keeps the
    /// feed dispatcher's `MessageBubbleView` slot at one structural
    /// position — preserving SwiftUI view identity for the underlying
    /// `NSTextView` across the streaming → committed flip. Branching at
    /// the dispatcher between `EmptyView()` and `MessageBubbleView` would
    /// cross `_ConditionalContent` arms and remount the text view.
    static func shouldSuppressEmptySupervisorMessage(_ msg: LLMMessage) -> Bool {
        guard msg.sourceContext == .supervisorMessage else { return false }
        let hasThinking = msg.thinking
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? false
        if hasThinking { return false }
        let inputs = bubbleDisplayInputs(raw: msg.displayContent, isSupervisorMessage: true)
        let textEmpty = inputs.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return textEmpty && inputs.paths.isEmpty && inputs.clippedTexts.isEmpty
    }

    /// Extracts the question string from an `ask_supervisor` tool call's argumentsJSON.
    /// Handles both valid JSON and malformed/truncated JSON from streaming.
    static func parseAskSupervisorQuestion(from text: String) -> String? {
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let question = json["question"] as? String,
           !question.isEmpty
        {
            return question
        }

        guard let prefixRange = text.range(
            of: #""question"\s*:\s*""#, options: .regularExpression
        ) else { return nil }

        var extracted = String(text[prefixRange.upperBound...])
        if extracted.hasSuffix("\"}") {
            extracted = String(extracted.dropLast(2))
        } else if extracted.hasSuffix("\"") {
            extracted = String(extracted.dropLast(1))
        }
        extracted = extracted
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
        return extracted.isEmpty ? nil : extracted
    }
}
