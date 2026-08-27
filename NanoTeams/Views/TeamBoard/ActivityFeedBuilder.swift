import SwiftUI
#if DEBUG
import Synchronization
#endif

// MARK: - Paired Assistant Message

/// Snapshot of the assistant turn that emitted an active `ask_supervisor`.
/// Shared between `ActivityFeedBuilder.ActiveSupervisorQuestion` (which decides
/// whether to suppress the bubble in the timeline) and
/// `TeamActivityActiveQuestion` (the composer's question card).
///
/// Pairs `id`, `thinking` and `content` atomically so they can't drift: the
/// outer `Optional<PairedAssistantMessage>` is the only "paired data is
/// missing" state. `id` identifies the feed bubble;
/// `isFullyRenderedByQuestionCard` decides whether that bubble may be dropped;
/// `thinking` feeds the card's thinking disclosure when it owns the turn.
///
/// Both `thinking` and `content` are trim-to-nil at construction: whitespace-
/// only input collapses to nil so `!= nil` reliably means "there is something
/// to render." Consumers don't need to re-trim before checking emptiness.
nonisolated struct PairedAssistantMessage: Equatable {
    let id: UUID
    let thinking: String?
    /// The turn's prose, trim-to-nil. Read only through
    /// `isFullyRenderedByQuestionCard` — stored rather than reduced to a `Bool`
    /// so the type stays a faithful snapshot of the turn.
    let content: String?

    /// Whether the composer's question card fully covers this turn. True when the
    /// turn carries no prose: the card's question plus this turn's `thinking` is
    /// then everything there is to render, and the feed may drop the bubble.
    /// False when the turn carries prose the card does not render (since
    /// `cfe23f5b` it renders none) — the bubble is that prose's only surface.
    var isFullyRenderedByQuestionCard: Bool { content == nil }

    /// `content` deliberately has NO default. A `nil` default reads as
    /// "suppressible", silently reproducing the pre-fix behaviour at any site
    /// that forgets to pass it — the wrong direction for the defect this type
    /// now guards against. Both production sites and every test pass it.
    init(id: UUID, thinking: String?, content: String?) {
        self.id = id
        let trimmedThinking = thinking?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.thinking = (trimmedThinking?.isEmpty == false) ? trimmedThinking : nil
        let trimmedContent = content?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.content = (trimmedContent?.isEmpty == false) ? trimmedContent : nil
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
        /// True when this item CONTINUES the model turn opened by the item
        /// above it — a tool call, or the artifact that call produced, emitted
        /// by the assistant message directly above.
        ///
        /// The feed hugs continuations to their turn
        /// (`ActivityCardTokens.turnHugSpacing`) and opens a clear gap before
        /// the next one (`turnGapSpacing`), so a bubble that is nothing but a
        /// `Thinking` row visibly belongs to the calls BELOW it rather than
        /// floating equidistant between two cards.
        ///
        /// `var` with a default because four test helpers construct this type
        /// with three arguments. `false` means "opens a turn", i.e. the larger
        /// gap — the safe side for a hand-built item.
        var continuesTurn: Bool = false
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
    /// Dictionary-shaped convenience for callers that already hold a map (the tests, and
    /// anything that needs every task anyway). Production goes through the closure form:
    /// only a handful of ids are ever looked up, so building a map of every loaded task
    /// costs more than the walk it serves.
    static func runScopedDescendantIDs(
        parentRun: Run,
        tasksByID: [Int: NTMSTask],
        maxDepth: Int = DelegationConstants.maxDelegationDepth
    ) -> Set<Int> {
        runScopedDescendantIDs(parentRun: parentRun, maxDepth: maxDepth) { tasksByID[$0] }
    }

    static func runScopedDescendantIDs(
        parentRun: Run,
        maxDepth: Int = DelegationConstants.maxDelegationDepth,
        resolveTask: (Int) -> NTMSTask?
    ) -> Set<Int> {
        var result: Set<Int> = []
        var frontier: [(run: Run, depth: Int)] = [(parentRun, 0)]
        while let (run, depth) = frontier.popLast() {
            guard depth < maxDepth else { continue }
            for step in run.steps {
                for childID in step.delegationChildIDs where !result.contains(childID) {
                    result.insert(childID)
                    if let childRun = resolveTask(childID)?.runs.last {
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
    /// Dictionary-shaped convenience — see `runScopedDescendantIDs(parentRun:tasksByID:)`.
    static func resolveRunScopedDescendants(
        displayedRun: Run,
        tasksByID: [Int: NTMSTask],
        resolveTeam: (NTMSTask) -> Team,
        maxDepth: Int = DelegationConstants.maxDelegationDepth
    ) -> [DescendantTask] {
        resolveRunScopedDescendants(
            displayedRun: displayedRun, resolveTeam: resolveTeam, maxDepth: maxDepth,
            resolveTask: { tasksByID[$0] })
    }

    static func resolveRunScopedDescendants(
        displayedRun: Run,
        resolveTeam: (NTMSTask) -> Team,
        maxDepth: Int = DelegationConstants.maxDelegationDepth,
        resolveTask: (Int) -> NTMSTask?
    ) -> [DescendantTask] {
        let scopedIDs = runScopedDescendantIDs(
            parentRun: displayedRun, maxDepth: maxDepth, resolveTask: resolveTask)
        guard !scopedIDs.isEmpty else { return [] }

        var descendants: [DescendantTask] = []
        descendants.reserveCapacity(scopedIDs.count)
        for childID in scopedIDs {
            guard let childTask = resolveTask(childID),
                  let childRun = childTask.runs.last
            else { continue }
            let childTeam = resolveTeam(childTask)
            // Resolve the delegating role's name in the parent team for the
            // boundary-band subtitle. `parentRoleID` on the child is the
            // canonical seeded TeamRoleDefinition.id of the role that called
            // delegate_to_team.
            let parentRoleName: String?
            if let parentRoleID = childTask.parentRoleID,
               let parentTask = resolveTask(childTask.parentTaskID ?? -1) {
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
        isStreaming isStreamingQuery: (UUID) -> Bool
    ) -> [TaggedItem] {
        // Every ask of the caller's closure goes through here so `StreamQueryProbe`
        // can count them — the seam `ActivityFeedBuilderSortCostTests` uses to pin
        // the ask at Θ(N) rather than Θ(N log N). A local FUNCTION, not a closure
        // literal: `isStreamingQuery` is non-escaping, and a closure that captured
        // it would be an escaping capture of a non-escaping parameter. The probe
        // call compiles away in release; the indirection stays in both so the two
        // configurations run the same shape.
        func isStreaming(_ id: UUID) -> Bool {
            #if DEBUG
            StreamQueryProbe.note()
            #endif
            return isStreamingQuery(id)
        }
        var items: [TeamActivityTimelineItem] = []

        // Compute once — `emitItems` matches `msg.id` against this set to suppress
        // the assistant bubble whose turn the question card is currently fronting.
        // Same precomputed list as the composer's chips, so the two surfaces can
        // never drift ("question card visible but feed still shows the bubble" or
        // vice versa). Active task + descendants share the same set since
        // `paired.id` (i.e. `LLMMessage.id`) is a globally-unique UUID.
        //
        // Only turns the card FULLY renders are suppressible. A turn that also
        // carried prose keeps its bubble: the card renders `question` + `thinking`
        // and nothing else, so suppressing it would leave that prose with no
        // surface at all. Each active question decides independently.
        let suppressedMessageIDs: Set<UUID> = Set(activeQuestions.compactMap { q -> UUID? in
            guard let paired = q.paired, paired.isFullyRenderedByQuestionCard else { return nil }
            return paired.id
        })

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
        //
        // Decorate–sort–undecorate: the pin flag is computed ONCE per item, not
        // twice per comparison. `isStreaming` is the caller's closure and reaches
        // `StreamingPreviewManager` (an `@Observable`), and `sorted` performs
        // Θ(N log N) comparisons, so asking inside the comparator asked it
        // 2·N·log₂N times per rebuild — at four rebuilds per model turn
        // (`TimelineRebuildProbe`) over a conversation that only grows. Now Θ(N).
        //
        // The permutation is identical by construction, not by luck: the
        // comparator is still a pure function of the same two values, so every
        // comparison returns exactly what it returned before — which is what
        // discharges DEBTS D-24's requirement that the equal-key order be pinned
        // before this sort is touched (`continuesTurn` derives turn grouping from
        // adjacency here). `ActivityFeedBuilderSortCostTests` pins it anyway,
        // because "identical by construction" is an argument and a pin is a
        // mechanism.
        let sorted = zip(items, items.map {
            $0.isStreamingItem(isStreaming: isStreaming) && $0.originTaskID == activeTaskID
        })
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return !lhs.1 }
            return lhs.0.createdAt < rhs.0.createdAt
        }
        .map(\.0)

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

            // Pairing-aware `.supervisorAnswer` suppression. The first
            // `askCallCount` answer messages (conversation order — the SAME index
            // rule the answered-notification loop below uses, so the two surfaces
            // can't disagree) pair with `ask_supervisor` tool calls and render
            // inside their Q&A cards. The escalation card (no ask calls — drift
            // caps / Autovisor idle park) owns at most the LATEST answer, and only
            // while its gate holds (`escalationCard(for:)`). Every OTHER answer is
            // UNPAIRED and falls through to a durable Supervisor bubble — without
            // this, a re-park clearing `step.supervisorAnswer` (single-slot) made
            // the user's answer vanish from the feed entirely, even though the LLM
            // had already consumed it.
            let askCallCount = step.toolCalls.count { $0.name == ToolNames.askSupervisor }
            // Materialize the answer ids ONLY when a card can actually own one. With no
            // `ask_supervisor` call — the overwhelming majority of steps — `prefix(0)`
            // discarded the whole array, so the filter+map was a full pass over an
            // UNBOUNDED conversation (`maxToolIterations == 0`; nothing prunes it) paid on
            // every feed rebuild, i.e. on every appended turn. Same shape, same reason, as
            // the `last(where:)`-not-`filter{}.last` note in
            // `ActivityFeedBuilder+SupervisorQuestions` — that fix was never swept here.
            let pairedAnswerIDs: Set<UUID> = askCallCount == 0 ? [] : Set(
                step.llmConversation
                    .lazy
                    .filter { $0.sourceContext == .supervisorAnswer }
                    .map(\.id)
                    .prefix(askCallCount))
            let cardOwnedAnswerID = Self.escalationCard(for: step)?.answerMessage?.id

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
                    if msg.sourceContext == .supervisorAnswer,
                       pairedAnswerIDs.contains(msg.id) || msg.id == cardOwnedAnswerID {
                        continue  // rendered inside its ask card / the escalation Q&A card
                    }
                }
                // `artifactContents.isEmpty` FIRST: `Set.contains` hashes the whole
                // message body, so without this the rebuild re-hashed every message of
                // every step on every appended turn — for a set that is empty on any step
                // that produced no artifact.
                if !debugModeEnabled && !artifactContents.isEmpty && !msg.content.isEmpty
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
                // — but only when the composer's question card renders everything
                // that turn had to say (see `isFullyRenderedByQuestionCard`, applied
                // when `suppressedMessageIDs` is built). A turn carrying prose is
                // never in the set: the card has rendered no body since `cfe23f5b`,
                // so this bubble is that prose's only surface. Once `supervisorAnswer`
                // is set, the id drops out of the set and a suppressed bubble
                // reappears as history. Streaming exemption: while the preview is
                // live the user is watching the response come in; the composer chip
                // only takes over after commit. See plan `replied-structured-petal.md`.
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
        // skipped here. `StepExecution.hasActiveSupervisorInput` is the shared predicate.
        for step in steps {
            let askCalls = step.toolCalls.filter { $0.name == ToolNames.askSupervisor }
            // Gated on the discriminator computed one line above, mirroring the
            // fixed sibling ~80 lines up: `answerMessages` is read ONLY inside the
            // `askCalls.enumerated()` loop below, so on a step with no ask call —
            // the overwhelming majority — this whole pass was discarded. Emptiness
            // only, never a `prefix`: the INDEX pairing between `askCalls` and
            // `answerMessages` is load-bearing (see the note above `pairedAnswerIDs`),
            // and narrowing the array would silently re-pair answers to asks.
            //
            // Honest weight: `emitItems` already walks `step.llmConversation`
            // unconditionally in its first loop, and `items.sorted` dominates both,
            // so this removes a constant factor under Θ(N log N) — not an order.
            let answerMessages = askCalls.isEmpty
                ? []
                : step.llmConversation.filter { $0.sourceContext == .supervisorAnswer }
            let stepIsActive = step.hasActiveSupervisorInput

            // Built LAZILY — only a step that actually renders an ask card pays
            // the O(k log k) build; steps with no ask calls pay nothing, exactly
            // as the per-call reverse scans this replaces cost nothing there.
            var thinkingResolver: ThinkingResolver?

            for (index, call) in askCalls.enumerated() {
                let isLast = index == askCalls.count - 1
                if isLast && stepIsActive { continue }

                let question: String
                if let parsed = call.parsedSupervisorQuestion {
                    question = parsed
                } else if isLast {
                    question = step.supervisorQuestion
                        .flatMap { StepToolCall.parseSupervisorQuestion(from: $0) }
                        ?? step.supervisorQuestion ?? "?"
                } else {
                    question = "?"
                }

                let rawAnswer: String?
                if index < answerMessages.count {
                    let content = answerMessages[index].content
                    let prefix = MessageSourceContext.supervisorAnswerPrefix
                    rawAnswer = content.hasPrefix(prefix)
                        ? String(content.dropFirst(prefix.count))
                        : content
                } else if isLast {
                    rawAnswer = step.supervisorAnswer
                } else {
                    rawAnswer = "(answered)"
                }

                if thinkingResolver == nil {
                    thinkingResolver = ThinkingResolver(conversation: step.llmConversation)
                }
                let thinking = thinkingResolver?.thinking(atOrBefore: call.createdAt)

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
            // drift / refusal-loop / parse-failure cap (or the Autovisor idle
            // park) writes `supervisorQuestion` + flag-true WITHOUT appending an
            // `ask_supervisor` tool call, then `answerSupervisorQuestion` writes
            // `supervisorAnswer` + flips the flag to false. Without this
            // synthesized notification, the answered Q&A would vanish from feed
            // history (the inner loop above iterates `askCalls`, which is empty
            // for the escalation path). Active state is owned by
            // `activeSupervisorQuestions` (composer chip), so we only emit
            // history once the step is no longer active.
            //
            // Gate + answer message come from `escalationCard(for:)` — the SAME
            // helper the message loop's bubble suppression consults, so the card
            // and the durable answer bubble can never both render (or both drop).
            // Once a re-park clears `supervisorAnswer`, the helper returns nil:
            // this card yields and the answer survives as a Supervisor bubble.
            if let card = Self.escalationCard(for: step) {
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
                let answerMsg = card.answerMessage
                let anchor = answerMsg?.createdAt ?? step.updatedAt
                let thinking = ThinkingResolver(conversation: step.llmConversation)
                    .thinking(atOrBefore: anchor)
                appendSupervisorInputNotification(
                    into: &items,
                    step: step,
                    rawAnswer: step.supervisorAnswer,
                    question: card.question,
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
                    type: .failed(errorMessage: failureMessage(for: step)),
                    createdAt: step.completedAt ?? step.updatedAt,
                    originTaskID: originTaskID
                ))
            }
        }
    }

    /// Gate + payload for the synthesized escalation Q&A card — the single
    /// source of truth shared by the message-loop bubble suppression and the
    /// card emission in `emitItems`, so the two surfaces can never double-render
    /// an answer or both drop it.
    ///
    /// The card fronts a PURE-escalation step's latest answered Q&A: no
    /// `ask_supervisor` tool calls at all (drift / refusal-loop / parse-failure
    /// caps and the Autovisor idle park write `supervisorQuestion` + the flag
    /// directly), not currently awaiting input, non-empty stored question, and
    /// `supervisorAnswer` still set. The moment a RE-park clears
    /// `supervisorAnswer` (single-slot — see `setNeedsSupervisorInput`), this
    /// returns nil: the card yields and every unpaired `.supervisorAnswer`
    /// message renders as a durable Supervisor bubble instead. That handoff is
    /// the fix for answers vanishing from the feed across the Autovisor's
    /// park → answer → re-park cycle.
    struct EscalationCard {
        let question: String
        /// The `.supervisorAnswer` conversation message the card absorbs — nil
        /// only for legacy task.json persisted before
        /// `StepMessagingService.answerSupervisorQuestion` started appending the
        /// message (the card then falls back to `step.supervisorAnswer` alone).
        let answerMessage: LLMMessage?
    }

    static func escalationCard(for step: StepExecution) -> EscalationCard? {
        guard !step.toolCalls.contains(where: { $0.name == ToolNames.askSupervisor }),
              !step.hasActiveSupervisorInput,
              let question = step.supervisorQuestion?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty,
              step.supervisorAnswer != nil
        else { return nil }
        return EscalationCard(
            question: question,
            answerMessage: step.llmConversation.last(where: { $0.sourceContext == .supervisorAnswer })
        )
    }

    /// Reverse-extracts the failure reason for a `.failed` step's bubble.
    /// `completeStepFailure` records the reason into `step.messages` as
    /// `"\(StepExecution.llmErrorNotePrefix): <reason>"` (covers the LLM-error,
    /// tool-failure, and supervisor-persist-failure paths — all share this
    /// prefix). Returns the reason with the prefix stripped, or `nil` when no
    /// such note exists (the card then falls back to its generic hint).
    static func failureMessage(for step: StepExecution) -> String? {
        let prefix = "\(StepExecution.llmErrorNotePrefix): "
        guard let note = step.messages.last(where: { $0.content.hasPrefix(prefix) }) else {
            return nil
        }
        let reason = String(note.content.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
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

    /// Whether `item` continues the model turn opened by `previous`.
    ///
    /// A model turn is one assistant utterance plus everything it emitted: the
    /// `.llmMessage` (whose bubble carries the `Thinking` row and the status
    /// row) and the `.toolCall` / `.artifact` items that message produced.
    /// Reasoning PRECEDES its own calls, so a continuation hugs UPWARD to the
    /// message that produced it — which is what puts the visual gap ABOVE a
    /// lone `Thinking` row instead of below it.
    ///
    /// Derived from SEQUENCE, not from a key: `StepToolCall` carries no turn
    /// index and `stepID` is the whole role step (an entire tool loop), so
    /// there is no id to group on. Adjacency is sound here because
    /// `buildTimelineItems` has already sorted by `createdAt` and
    /// `NTMSOrchestrator.beginStreaming` pre-creates the assistant message
    /// before any of that turn's calls can be appended.
    ///
    /// Conservative at the edges: meetings, change requests, notifications and
    /// the supervisor brief are not part of any model turn, and a role or
    /// origin-task change always breaks one.
    ///
    /// Known imprecision, not a regression: a tool-loop iteration that emits no
    /// VISIBLE assistant message leaves two consecutive `.toolCall`s reading as
    /// one turn. The literal `2` this rule replaces did exactly the same.
    static func continuesTurn(
        item: TeamActivityTimelineItem,
        previous: TeamActivityTimelineItem?
    ) -> Bool {
        guard let previous else { return false }
        switch item {
        case .toolCall, .artifact: break
        case .llmMessage, .meetingMessage, .changeRequest, .notification, .supervisorTask:
            return false
        }
        switch previous {
        case .llmMessage, .toolCall, .artifact: break
        case .meetingMessage, .changeRequest, .notification, .supervisorTask:
            return false
        }
        return item.roleID == previous.roleID
            && item.originTaskID == previous.originTaskID
    }

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
        var prevItem: TeamActivityTimelineItem? = nil

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

            // Belt and braces: a header or a boundary band already separates the
            // item visually, and both fire on exactly the role / origin-task
            // changes `continuesTurn` rejects anyway.
            let continues = !showHeader
                && boundary == nil
                && Self.continuesTurn(item: item, previous: prevItem)

            tagged.append(TaggedItem(
                item: item,
                showSectionHeader: showHeader,
                boundary: boundary,
                continuesTurn: continues
            ))
            prevRoleID = curRoleID
            prevOriginTaskID = curOriginTaskID
            prevHadRoleID = curRoleID != nil
            prevItem = item
        }
        return tagged
    }
}

#if DEBUG
/// Counts how many times `buildTimelineItems` asks the caller's `isStreaming`
/// closure. A work counter, not a clock — this repo pins performance as work
/// done (`Ratchet/WallClockPerformancePinTests`).
///
/// The number is the point: the closure reaches `StreamingPreviewManager`, an
/// `@Observable`, and until 2026-08-25 the pin-to-bottom sort asked it TWICE PER
/// COMPARISON, i.e. `2 · N · log N` times per rebuild for a feed of N items, at
/// four rebuilds per model turn. It is now asked once per item.
nonisolated enum StreamQueryProbe {
    private static let _queries = Atomic<Int>(0)
    static func note() { _queries.wrappingAdd(1, ordering: .relaxed) }
    static func queries() -> Int { _queries.load(ordering: .relaxed) }
    static func reset() { _queries.store(0, ordering: .relaxed) }
}
#endif
