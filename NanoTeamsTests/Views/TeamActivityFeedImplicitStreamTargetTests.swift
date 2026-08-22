import XCTest
@testable import NanoTeams

/// Pins `TeamActivityFeedView.resolveImplicitStreamTarget(...)`.
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

    // MARK: - Happy path

    /// Latest message in a running step, not the preview target → true.
    func testReturnsTrue_whenLatestMessageInRunningStepAndNotPreviewTarget() {
        let msg = makeMsg(content: "Создам простой веб-калькулятор…", createdAt: MonotonicClock.shared.now())
        let step = makeRunningStep(messages: [msg])
        let result = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id,
            messageID: msg.id,
            isPreviewTarget: false,
            allSteps: [step]
        )
        XCTAssertTrue(result)
    }

    /// Multiple committed messages — only the latest by `createdAt` is the
    /// implicit target. Older messages in the same running step stay quiet.
    func testReturnsTrue_onlyForLatestMessage_whenSeveralExist() {
        let older  = makeMsg(content: "first", createdAt: MonotonicClock.shared.now())
        let newer  = makeMsg(content: "second", createdAt: MonotonicClock.shared.now())
        let step   = makeRunningStep(messages: [older, newer])
        let latest = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id, messageID: newer.id, isPreviewTarget: false, allSteps: [step]
        )
        let stale  = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id, messageID: older.id, isPreviewTarget: false, allSteps: [step]
        )
        XCTAssertTrue(latest, "Latest by createdAt picks up the implicit target")
        XCTAssertFalse(stale, "Older messages in the same step must not surface the pill")
    }

    // MARK: - Negative cases (each guards a single condition)

    /// When the streaming preview manager is actively targeting this bubble,
    /// the regular `isStreaming` path handles indicator priority — implicit-
    /// target must NOT also fire (would conflate with the actively-growing
    /// content case, where content visibility intentionally suppresses the
    /// pill).
    func testReturnsFalse_whenIsPreviewTarget() {
        let msg = makeMsg(content: "live tokens", createdAt: MonotonicClock.shared.now())
        let step = makeRunningStep(messages: [msg])
        let result = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id,
            messageID: msg.id,
            isPreviewTarget: true,
            allSteps: [step]
        )
        XCTAssertFalse(result, "Preview-target case is handled by the regular `isStreaming` branch — implicit target must short-circuit")
    }

    func testReturnsFalse_whenStepNotRunning() {
        let msg = makeMsg(content: "final answer", createdAt: MonotonicClock.shared.now())
        var step = makeRunningStep(messages: [msg])
        step.status = .done
        let result = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id, messageID: msg.id, isPreviewTarget: false, allSteps: [step]
        )
        XCTAssertFalse(result, "Done steps have no LLM work in flight — pill stays hidden")
    }

    /// Stale `stepID` reference (step removed mid-rebuild, descendant detached,
    /// etc.) must NOT crash and must NOT surface a pill. Indicator falls back
    /// to nil — safer than a stale "Generating" that never clears.
    func testReturnsFalse_whenStepNotFound() {
        let msg = makeMsg(content: "orphan", createdAt: MonotonicClock.shared.now())
        let result = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: "missing.step", messageID: msg.id, isPreviewTarget: false, allSteps: []
        )
        XCTAssertFalse(result)
    }

    /// Even when the step is running and not preview-targeted, a stale
    /// message id (one that's not the latest) must not pick up the pill.
    /// Defends against a future change to the dispatcher that might call
    /// the resolver for every bubble in the step regardless of position.
    func testReturnsFalse_whenMessageIDDoesNotMatchLatest() {
        let msg     = makeMsg(content: "real", createdAt: MonotonicClock.shared.now())
        let stranger = UUID()
        let step = makeRunningStep(messages: [msg])
        let result = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id,
            messageID: stranger,
            isPreviewTarget: false,
            allSteps: [step]
        )
        XCTAssertFalse(result)
    }

    /// `system` and `tool` turns are skipped by the dispatcher — `tool` turns
    /// in particular are persisted at the latest `createdAt` after a tool
    /// call lands. The resolver mirrors the dispatcher's filter so the user-
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
        let result = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id, messageID: visible.id, isPreviewTarget: false, allSteps: [step]
        )
        XCTAssertTrue(result, "Tool-role turns are filtered from the visible set — the latest assistant bubble stays the implicit target")
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
        XCTAssertFalse(TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id, messageID: UUID(), isPreviewTarget: false, allSteps: [step]
        ))
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

    private func context(run: Run) -> TeamActivityFeedViewModel.BuildContext {
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
            descendantTasks: []
        )
    }

    /// Parity with the per-bubble resolver it replaces — same answer for every
    /// message, including the non-target ones.
    func testSetAgreesWithThePerBubbleResolver() {
        let s = step(id: stepID, status: .running, visibleTurns: 6)
        let vm = TeamActivityFeedViewModel()
        vm.recomputeAndRebuild(context: context(run: Run(id: 0, steps: [s])))

        XCTAssertFalse(vm.implicitStreamTargetIDs.isEmpty,
                       "anti-vacuum: an always-empty set would satisfy every negative case")
        for msg in s.llmConversation {
            let viaResolver = TeamActivityFeedView.resolveImplicitStreamTarget(
                stepID: s.id, messageID: msg.id, isPreviewTarget: false, allSteps: [s])
            XCTAssertEqual(vm.implicitStreamTargetIDs.contains(msg.id), viaResolver,
                           "hoisted set disagrees with the resolver for \(msg.content)")
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
}
