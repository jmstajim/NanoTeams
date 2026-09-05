import XCTest
@testable import NanoTeams

/// The verbatim body of the per-step resolver the fold in
/// `ActivityFeedBuilder.emitItems` replaced (`TeamActivityFeedView.implicitStreamTargetID(in:)`
/// until 2026-09-04). Kept here as the INDEPENDENT oracle of the OLD law — the
/// `ThinkingResolverTests` idiom — so the fold is checked against something it
/// does not share a part with (CLAUDE.md #158). `max(by: createdAt)` with strict
/// `>` (the FIRST maximum wins), visible roles only, `.running` steps only.
private func implicitTargetOracle(_ step: StepExecution) -> UUID? {
    guard step.status == .running else { return nil }
    var latest: LLMMessage?
    for message in step.llmConversation
        where message.role != .system && message.role != .tool {
        if latest == nil || message.createdAt > latest!.createdAt { latest = message }
    }
    return latest?.id
}

/// The production seam: the set `buildTimeline` derives for these steps.
private func implicitTargets(of steps: [StepExecution]) -> Set<UUID> {
    ActivityFeedBuilder.buildTimeline(
        steps: steps, run: nil,
        stepArtifactContentCache: [:], debugModeEnabled: false,
        isStreaming: { _ in false }
    ).implicitStreamTargetIDs
}

/// Pins the implicit-stream-target law at its LIVE seam —
/// `ActivityFeedBuilder.buildTimeline(...).implicitStreamTargetIDs`, the set the view
/// reads through `TeamActivityFeedViewModel.implicitStreamTargetIDs`.
///
/// These used to call a separate per-step function; that function is gone (the law is
/// folded into the builder's own message walk) and its body survives only as
/// `implicitTargetOracle` above. Every case asserts BOTH the production set's answer
/// and its parity with the oracle. The `isPreviewTarget` term is spelled at the call
/// site and pinned by `testReturnsFalse_whenIsPreviewTarget` below.
@MainActor
final class TeamActivityFeedImplicitStreamTargetTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Fixture

    private func makeRunningStep(stepID: String = "step.1", messages: [LLMMessage]) -> StepExecution {
        var step = StepExecution.make(for: makeRoleDef(id: stepID))
        step.status = .running
        step.llmConversation = messages
        return step
    }

    private func makeRoleDef(id: String) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: "Coding Agent",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
    }

    private func makeMsg(content: String, createdAt: Date) -> LLMMessage {
        LLMMessage(
            id: UUID(),
            createdAt: createdAt,
            role: .assistant,
            content: content
        )
    }

    /// The set for ONE step, checked against the oracle for every message of the step
    /// (including the non-targets) before it is returned.
    private func targets(
        of step: StepExecution, file: StaticString = #filePath, line: UInt = #line
    ) -> Set<UUID> {
        let set = implicitTargets(of: [step])
        let expected = implicitTargetOracle(step)
        XCTAssertEqual(set, Set([expected].compactMap { $0 }),
                       "the fold disagrees with the verbatim oracle", file: file, line: line)
        return set
    }

    // MARK: - Happy path

    /// Latest message in a running step, not the preview target → true.
    func testReturnsTrue_whenLatestMessageInRunningStepAndNotPreviewTarget() {
        let msg = makeMsg(content: "Создам простой веб-калькулятор…", createdAt: MonotonicClock.shared.now())
        let step = makeRunningStep(messages: [msg])
        XCTAssertTrue(targets(of: step).contains(msg.id))
    }

    /// Multiple committed messages — only the latest by `createdAt` is the
    /// implicit target. Older messages in the same running step stay quiet.
    func testReturnsTrue_onlyForLatestMessage_whenSeveralExist() {
        let older  = makeMsg(content: "first", createdAt: MonotonicClock.shared.now())
        let newer  = makeMsg(content: "second", createdAt: MonotonicClock.shared.now())
        let step   = makeRunningStep(messages: [older, newer])
        let set = targets(of: step)
        XCTAssertTrue(set.contains(newer.id), "Latest by createdAt picks up the implicit target")
        XCTAssertFalse(set.contains(older.id), "Older messages in the same step must not surface the pill")
    }

    // MARK: - Negative cases (each guards a single condition)

    /// When the streaming preview manager is actively targeting this bubble,
    /// the regular `isStreaming` path handles indicator priority — implicit-
    /// target must NOT also fire (would conflate with the actively-growing
    /// content case, where content visibility intentionally suppresses the
    /// pill).
    ///
    /// This is a WIRING pin, not a behaviour one: the short-circuit lives at the call
    /// site, not in the builder's fold, so a test that calls the builder could never
    /// see it (CLAUDE.md #57). It used to be asserted against a wrapper with no
    /// production callers, which is the same blindness wearing a green tick.
    func testReturnsFalse_whenIsPreviewTarget() throws {
        let code = RatchetSourceScan.strippingLineComments(
            try String(contentsOf: RatchetSourceScan.repoRoot.appendingPathComponent(
                "NanoTeams/Views/TeamBoard/TeamActivityFeedView.swift"), encoding: .utf8))
        XCTAssertTrue(code.contains("viewModel.implicitStreamTargetIDs.contains(msg.id)"), """
        anti-vacuum: the implicit-target membership test is gone from \
        `TeamActivityFeedView` — this pin is asserting nothing. Re-aim it at whatever \
        now decides the pill, do not delete it.
        """)
        // Whitespace-collapsed on both sides: a multiline literal is de-indented relative
        // to its own closing delimiter, so comparing it against the FILE's text fails on
        // the continuation line's indentation rather than on the property under test
        // (CLAUDE.md #105 — the diff shows the source, never the value).
        let flat = code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains(
            "let isImplicitStreamTarget = !scheduleIsStreaming "
                + "&& viewModel.implicitStreamTargetIDs.contains(msg.id)"), """
        The `!scheduleIsStreaming` short-circuit is gone from the implicit-target term. \
        When the streaming preview manager is actively targeting this bubble the regular \
        `isStreaming` path owns indicator priority; without the guard both fire and the \
        pill conflates with the actively-growing content case.
        """)
    }

    func testReturnsFalse_whenStepNotRunning() {
        let msg = makeMsg(content: "final answer", createdAt: MonotonicClock.shared.now())
        var step = makeRunningStep(messages: [msg])
        step.status = .done
        XCTAssertFalse(targets(of: step).contains(msg.id),
                       "Done steps have no LLM work in flight — pill stays hidden")
    }

    /// A message whose step is gone (removed mid-rebuild, descendant detached) must NOT
    /// surface a pill. With the set derived from the build's own walk that is a
    /// membership miss rather than a lookup failure: only steps walked at rebuild
    /// contribute ids, so an orphan's id is never named by any of them.
    func testReturnsFalse_whenStepNotFound() {
        let orphan = makeMsg(content: "orphan", createdAt: MonotonicClock.shared.now())
        let survivor = makeMsg(content: "still here", createdAt: MonotonicClock.shared.now())
        let step = makeRunningStep(messages: [survivor])
        let set = targets(of: step)
        XCTAssertFalse(set.contains(orphan.id))
        XCTAssertTrue(set.contains(survivor.id),
                      "anti-vacuum: the surviving step must still name ITS latest message, "
                          + "or the assertion above passes because nothing is ever named")
    }

    /// Even when the step is running and not preview-targeted, a stale
    /// message id (one that's not the latest) must not pick up the pill.
    /// Defends against a future change to the dispatcher that might call
    /// the resolver for every bubble in the step regardless of position.
    func testReturnsFalse_whenMessageIDDoesNotMatchLatest() {
        let msg     = makeMsg(content: "real", createdAt: MonotonicClock.shared.now())
        let stranger = UUID()
        let step = makeRunningStep(messages: [msg])
        XCTAssertFalse(targets(of: step).contains(stranger))
    }

    /// `system` and `tool` turns are skipped by the dispatcher — `tool` turns
    /// in particular are persisted at the latest `createdAt` after a tool
    /// call lands. The fold mirrors the dispatcher's filter so the user-
    /// facing "latest message" matches what's actually rendered.
    func testReturnsTrue_whenLatestVisibleMessage_evenIfToolTurnHasLaterTimestamp() {
        let visible = makeMsg(content: "i'll write the file", createdAt: MonotonicClock.shared.now())
        let toolTurn = LLMMessage(
            id: UUID(),
            createdAt: MonotonicClock.shared.now(),
            role: .tool,
            content: "{\"ok\":true}"
        )
        let step = makeRunningStep(messages: [visible, toolTurn])
        XCTAssertTrue(targets(of: step).contains(visible.id),
                      "Tool-role turns are filtered from the visible set — the latest assistant bubble stays the implicit target")
    }

    /// Step with ONLY tool/system messages (no visible assistant turn). Defends
    /// against a refactor that switches `.max(by:)` → `.last` or relaxes the
    /// role filter — either would silently surface a pill on a hidden turn.
    func testReturnsFalse_whenStepHasNoVisibleMessages() {
        let toolTurn = LLMMessage(
            id: UUID(), createdAt: MonotonicClock.shared.now(),
            role: .tool, content: "{\"ok\":true}"
        )
        let step = makeRunningStep(messages: [toolTurn])
        XCTAssertTrue(targets(of: step).isEmpty)
    }

    /// The conversation is OUT of time order (a re-stamped commit landed a
    /// later-created turn at an earlier array position) — `max(by: createdAt)`
    /// and `last` disagree, and the law is the former.
    ///
    /// RED: replace the strict-`>` running max in the fold with "the last visible
    /// message wins" → the set names `early`.
    func testLatestByCreatedAt_notByArrayPosition() {
        let late = makeMsg(content: "committed later", createdAt: Date(timeIntervalSinceReferenceDate: 100))
        let early = makeMsg(content: "created earlier", createdAt: Date(timeIntervalSinceReferenceDate: 50))
        let step = makeRunningStep(messages: [late, early])
        XCTAssertEqual(targets(of: step), [late.id])
    }

    /// Equal timestamps: the FIRST maximum wins (strict `>`), so a two-turn tie
    /// resolves to the earlier array position.
    ///
    /// RED: change `>` to `>=` in the fold → the second turn wins and parity fails.
    func testEqualTimestamps_firstMaximumWins() {
        let same = Date(timeIntervalSinceReferenceDate: 100)
        let first = makeMsg(content: "first", createdAt: same)
        let second = makeMsg(content: "second", createdAt: same)
        let step = makeRunningStep(messages: [first, second])
        XCTAssertEqual(targets(of: step), [first.id])
    }
}

/// Pins the HOIST of the implicit-stream-target resolution out of the per-bubble
/// path into `TeamActivityFeedViewModel`.
///
/// The feed's container is deliberately non-lazy (`TeamActivityFeedView` realizes
/// every row on every body pass — see its rationale comment), so the per-bubble
/// spelling walked the step's whole conversation once per bubble. In chat mode a
/// single `.running` step holds the entire session, so bubbles ≈ messages and the
/// cost was Θ(M²) per body pass, i.e. per `mutateTask`.
@MainActor
final class ImplicitStreamTargetHoistTests: XCTestCase, @unchecked Sendable {

    private let stepID = "startup_software_engineer"
    private let taskID = 1

    private func role() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: stepID, name: "Software Engineer", prompt: "p",
            toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies())
    }

    private func step(id: String, status: StepStatus, visibleTurns: Int) -> StepExecution {
        var s = StepExecution(id: id, role: .softwareEngineer, title: "Impl", status: status)
        s.llmConversation = (0..<visibleTurns).map {
            LLMMessage(role: .assistant, content: "turn \($0)")
        }
        return s
    }

    private func context(
        run: Run,
        descendants: [ActivityFeedBuilder.DescendantTask] = []
    ) -> TeamActivityFeedViewModel.BuildContext {
        TeamActivityFeedViewModel.BuildContext(
            run: run,
            roleDefinitions: [role()],
            filterRoleID: nil,
            activeTaskID: taskID,
            supervisorBrief: nil,
            supervisorBriefDate: nil,
            supervisorTask: nil,
            supervisorClippedTexts: [],
            supervisorAttachmentPaths: [],
            supervisorProjectFolderURL: nil,
            workFolderURL: nil,
            debugModeEnabled: true,
            isStreaming: { _ in false },
            descendantTasks: descendants
        )
    }

    /// A delegated child of `taskID` whose run is `run`. Same role id as the parent's
    /// step on purpose — `StepExecution.id` is the role id and repeats across tasks.
    private func descendant(run: Run) -> ActivityFeedBuilder.DescendantTask {
        ActivityFeedBuilder.DescendantTask(
            task: NTMSTask(
                id: taskID + 1, title: "Child", supervisorTask: "G", runs: [run],
                parentTaskID: taskID, parentRoleID: stepID, delegationDepth: 1),
            run: run,
            teamRoles: [role()],
            teamName: "Startup",
            delegationDepth: 1,
            delegatedFromRoleName: "Software Engineer"
        )
    }

    /// Waits for the debounced structural rebuild scheduled with `delayMilliseconds: 0`
    /// to land, bounded by a fixed number of yields (no wall-clock assertion — the
    /// caller asserts on `timelineVersion`, which the rebuild bumps unconditionally).
    private func awaitStructuralRebuild(
        of vm: TeamActivityFeedViewModel, past version: Int
    ) async {
        for _ in 0..<400 where vm.timelineVersion == version {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Parity with the OLD per-step law — the set must hold exactly the ids the
    /// oracle names, for every message including the non-target ones.
    func testSetAgreesWithThePerBubbleResolver() {
        let s = step(id: stepID, status: .running, visibleTurns: 6)
        let vm = TeamActivityFeedViewModel()
        vm.recomputeAndRebuild(context: context(run: Run(id: 0, steps: [s])))

        XCTAssertFalse(vm.implicitStreamTargetIDs.isEmpty,
                       "anti-vacuum: an always-empty set would satisfy every negative case")
        let target = implicitTargetOracle(s)
        for msg in s.llmConversation {
            XCTAssertEqual(vm.implicitStreamTargetIDs.contains(msg.id), target == msg.id,
                           "hoisted set disagrees with the per-step oracle for \(msg.content)")
        }
    }

    /// A step that is not `.running` contributes nothing — the guard the resolver
    /// applied per bubble must survive the hoist.
    func testNonRunningStepContributesNoTarget() {
        let s = step(id: stepID, status: .done, visibleTurns: 3)
        let vm = TeamActivityFeedViewModel()
        vm.recomputeAndRebuild(context: context(run: Run(id: 0, steps: [s])))
        XCTAssertTrue(vm.implicitStreamTargetIDs.isEmpty)
    }

    /// THE work bound. Reading the answer for every bubble must cost NOTHING
    /// beyond the single per-rebuild pass — that is the property the non-lazy
    /// container depends on. Red against the per-bubble spelling, where each read
    /// re-walked the conversation.
    func testReadingTheAnswerPerBubbleCostsNoAdditionalScan() {
        let s = step(id: stepID, status: .running, visibleTurns: 200)
        let vm = TeamActivityFeedViewModel()
        vm.recomputeAndRebuild(context: context(run: Run(id: 0, steps: [s])))

        ImplicitStreamTargetProbe._testResetExamined()
        var hits = 0
        for msg in s.llmConversation where vm.implicitStreamTargetIDs.contains(msg.id) { hits += 1 }
        let examinedWhileRendering = ImplicitStreamTargetProbe._testExamined()

        XCTAssertEqual(hits, 1, "exactly one bubble is the implicit target")
        XCTAssertEqual(
            examinedWhileRendering, 0,
            "rendering B bubbles must not re-walk the conversation — the pass "
                + "belongs to the rebuild, not to the row. examined=\(examinedWhileRendering)")
    }

    /// Anti-vacuum for the counter the assertion above rests on: the rebuild
    /// itself MUST examine the conversation, or `examined == 0` would be
    /// satisfied by a probe that never fires (CLAUDE.md #57).
    func testRebuildItselfExaminesTheConversation() {
        let s = step(id: stepID, status: .running, visibleTurns: 50)
        let vm = TeamActivityFeedViewModel()
        ImplicitStreamTargetProbe._testResetExamined()
        vm.recomputeAndRebuild(context: context(run: Run(id: 0, steps: [s])))
        XCTAssertGreaterThanOrEqual(ImplicitStreamTargetProbe._testExamined(), 50)
    }

    /// …and it must examine it exactly ONCE.
    ///
    /// The set is a by-product of the builder's single message walk over the active
    /// task's steps. Until 2026-09-04 the view model derived it in a SEPARATE pass over
    /// per-task step pools, and for a while walked the active pool twice — so the
    /// active task's whole conversation was scanned two or three times per rebuild,
    /// and a turn performs several. The anti-vacuum test above cannot see this:
    /// `>= 50` is satisfied by 50 and by 100.
    ///
    /// RED: restore a separate view-model pass (calling the oracle law per step of
    /// `cachedAllSteps` after `buildTimeline`, with the probe inside it) alongside
    /// the fold → the count doubles and this fails.
    func testRebuildExaminesTheActiveConversationOnlyOnce() {
        let turns = 50
        let s = step(id: stepID, status: .running, visibleTurns: turns)
        let vm = TeamActivityFeedViewModel()
        ImplicitStreamTargetProbe._testResetExamined()
        vm.recomputeAndRebuild(context: context(run: Run(id: 0, steps: [s])))
        let examined = ImplicitStreamTargetProbe._testExamined()
        // VISIBLE messages, not `llmConversation.count`: the probe fires only for turns
        // the fold actually inspects (`.system` and `.tool` are skipped). Bounding by
        // the whole conversation was measured NON-discriminating — the fixture carries a
        // tool turn per visible turn, so `2 × visible` still fits under `count` and the
        // "walk twice" mutation stayed green (CLAUDE.md #56, reading 3).
        let visible = s.llmConversation
            .filter { $0.role != .system && $0.role != .tool }
            .count

        XCTAssertGreaterThan(examined, 0, "anti-vacuum: the probe must be reached")
        XCTAssertEqual(
            examined, visible,
            "the rebuild examined \(examined) visible messages for a conversation with "
                + "\(visible) of them — the active task's conversation is being walked more "
                + "than once per rebuild")
    }

    /// THE stale-pill fix. The debounced structural path
    /// (`scheduleStructuralRebuild` → `rebuildTimeline(context:)`) is handed a FRESH
    /// context for the DESCENDANTS' items (the active task's items still come from
    /// `cachedAllSteps`) but never runs `recomputeSteps`, so a set derived from step
    /// pools filed at the PREVIOUS `recomputeSteps` described the descendants as of
    /// that earlier tick. A child step that went `.running` with a new turn in
    /// between showed the new bubble without its stream pill, while the set still
    /// named the turn before it.
    ///
    /// The law that survives: the implicit targets come from the SAME steps whose
    /// items the rebuild emits — never from a step set cached at another time.
    ///
    /// RED: derive the descendants' targets from steps cached at `recomputeSteps`
    /// (a per-task pool) instead of the rebuild's own `descendantTasks` → the set
    /// holds `m1`, not `m2`, while `cachedTimelineItems` already renders `m2`.
    func testStructuralRebuild_targetsComeFromTheStepsThatProducedTheItems() async {
        let m1 = LLMMessage(role: .assistant, content: "child turn 1")
        let m2 = LLMMessage(role: .assistant, content: "child turn 2")
        let parentRun = Run(id: 0, steps: [step(id: stepID, status: .done, visibleTurns: 1)])
        var childStep = step(id: stepID, status: .running, visibleTurns: 0)
        childStep.llmConversation = [m1]
        let vm = TeamActivityFeedViewModel()

        vm.recomputeAndRebuild(context: context(
            run: parentRun, descendants: [descendant(run: Run(id: 0, steps: [childStep]))]))
        XCTAssertTrue(vm.implicitStreamTargetIDs.contains(m1.id),
                      "anti-vacuum: before the new turn lands, m1 IS the descendant's target")

        // The descendant gains a turn; only the debounced structural path sees it.
        childStep.llmConversation = [m1, m2]
        let fresh = context(
            run: parentRun, descendants: [descendant(run: Run(id: 0, steps: [childStep]))])
        let version = vm.timelineVersion
        vm.scheduleStructuralRebuild(context: fresh, delayMilliseconds: 0)
        await awaitStructuralRebuild(of: vm, past: version)
        XCTAssertGreaterThan(vm.timelineVersion, version, "anti-vacuum: the rebuild must have run")

        let renderedIDs = vm.cachedTimelineItems.compactMap { tagged -> UUID? in
            if case let .llmMessage(message, _, _, _) = tagged.item { return message.id }
            return nil
        }
        XCTAssertTrue(renderedIDs.contains(m2.id), "the items already show the new turn")
        XCTAssertTrue(vm.implicitStreamTargetIDs.contains(m2.id),
                      "the pill must move to the turn the items render")
        XCTAssertFalse(vm.implicitStreamTargetIDs.contains(m1.id),
                       "the previous turn is no longer the latest visible one")
    }
}
