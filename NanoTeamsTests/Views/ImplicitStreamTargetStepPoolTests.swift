import XCTest

@testable import NanoTeams

/// Pins the cross-task independence of `implicitStreamTargetIDs` in the merged
/// delegation timeline.
///
/// `StepExecution.id` equals the team role ID, so a descendant's step shares its
/// id with the parent's same-role step. Pre-fix, every bubble's implicit-stream
/// target was resolved against the ACTIVE task's steps only, so a descendant
/// bubble was matched against the parent's same-named step and its live "latest
/// message of a running step" indicator came from the wrong task's conversation.
///
/// The fix's current home is structural: `ActivityFeedBuilder.buildTimeline`
/// derives the set inside the per-step message walk of `emitItems`, once for the
/// active task and once per descendant, indexed by step POSITION — so a
/// descendant's target can only ever be one of the descendant's own messages,
/// and `LLMMessage.id`s are globally unique UUIDs. No per-task pool exists to
/// pick wrongly from; these tests pin the guarantee the fold gives instead.
@MainActor
final class ImplicitStreamTargetStepPoolTests: XCTestCase, @unchecked Sendable {

    private var viewModel: TeamActivityFeedViewModel!
    private let sharedStepID = "startup_software_engineer"
    private let parentTaskID = 1
    private let childTaskID = 2

    override func setUp() async throws {
        try await super.setUp()
        viewModel = TeamActivityFeedViewModel()
    }

    override func tearDown() async throws {
        viewModel = nil
        try await super.tearDown()
    }

    private func makeRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: sharedStepID, name: "Software Engineer", prompt: "p",
            toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies()
        )
    }

    private func makeStep(status: StepStatus, conversation: [LLMMessage] = []) -> StepExecution {
        var step = StepExecution(
            id: sharedStepID, role: .softwareEngineer, title: "Impl", status: status)
        step.llmConversation = conversation
        return step
    }

    private func makeContext(
        run: Run?,
        descendants: [ActivityFeedBuilder.DescendantTask] = []
    ) -> TeamActivityFeedViewModel.BuildContext {
        TeamActivityFeedViewModel.BuildContext(
            run: run,
            roleDefinitions: [makeRole()],
            filterRoleID: nil,
            activeTaskID: parentTaskID,
            supervisorBrief: nil,
            supervisorBriefDate: nil,
            supervisorTask: nil,
            supervisorClippedTexts: [],
            supervisorAttachmentPaths: [],
            supervisorProjectFolderURL: nil,
            workFolderURL: nil,
            debugModeEnabled: false,
            isStreaming: { _ in false },
            descendantTasks: descendants
        )
    }

    private func makeDescendant(taskID: Int? = nil, run: Run) -> ActivityFeedBuilder.DescendantTask {
        ActivityFeedBuilder.DescendantTask(
            task: NTMSTask(
                id: taskID ?? childTaskID, title: "Child", supervisorTask: "G", runs: [run],
                parentTaskID: parentTaskID, parentRoleID: sharedStepID, delegationDepth: 1),
            run: run,
            teamRoles: [makeRole()],
            teamName: "Startup",
            delegationDepth: 1,
            delegatedFromRoleName: "Software Engineer"
        )
    }

    /// The builder's set for a parent run plus descendants — the production seam.
    private func targets(
        parentRun: Run, descendants: [ActivityFeedBuilder.DescendantTask]
    ) -> Set<UUID> {
        ActivityFeedBuilder.buildTimeline(
            steps: parentRun.steps, run: parentRun,
            activeTaskID: parentTaskID, descendantTasks: descendants,
            stepArtifactContentCache: [:], debugModeEnabled: false,
            isStreaming: { _ in false }
        ).implicitStreamTargetIDs
    }

    // MARK: - Each walked task contributes from its OWN run

    /// Two descendants with the SAME step id, each `.running` with its own latest
    /// message: the set holds both, one per descendant — the step-position aux
    /// cannot conflate them.
    ///
    /// RED: in `emitItems` insert the target only for the FIRST step of a given id
    /// per build (e.g. track seen ids in a `Set<String>` and skip repeats) → the
    /// second descendant's message is missing.
    func testEachDescendantContributesItsOwnRunningStepsTarget() {
        let c2 = LLMMessage(role: .assistant, content: "child 2 working")
        let c3 = LLMMessage(role: .assistant, content: "child 3 working")
        let parentRun = Run(id: 0, steps: [makeStep(status: .done)])
        let d2 = makeDescendant(taskID: 2, run: Run(id: 0, steps: [makeStep(status: .running, conversation: [c2])]))
        let d3 = makeDescendant(taskID: 3, run: Run(id: 0, steps: [makeStep(status: .running, conversation: [c3])]))

        XCTAssertEqual(targets(parentRun: parentRun, descendants: [d2, d3]), [c2.id, c3.id])
    }

    /// After a task switch there is no build, so there are no targets — the set is a
    /// by-product of `cachedTimelineItems` and must be cleared with it.
    ///
    /// RED: drop `implicitStreamTargetIDs = []` from `resetForTaskSwitch` → the
    /// previous task's id survives the switch.
    func testResetForTaskSwitch_clearsImplicitStreamTargets() {
        let running = LLMMessage(role: .assistant, content: "working")
        let parentRun = Run(id: 0, steps: [makeStep(status: .running, conversation: [running])])
        viewModel.recomputeAndRebuild(context: makeContext(run: parentRun))
        XCTAssertEqual(viewModel.implicitStreamTargetIDs, [running.id], "anti-vacuum")

        viewModel.resetForTaskSwitch()

        XCTAssertTrue(viewModel.implicitStreamTargetIDs.isEmpty)
    }

    // MARK: - The bug: descendant bubble resolved against the parent's step

    /// Parent's same-named step is `.done`; the descendant's is `.running` with a
    /// live latest message. The set names the DESCENDANT's message and nothing of
    /// the parent's — the pre-fix resolution against the parent pool silently
    /// answered false and the descendant bubble lost its streaming affordance.
    ///
    /// RED: drop the `trackImplicitTarget = step.status == .running` guard in the
    /// fold → `p1.id` appears in the set.
    func testDescendantTarget_isTheDescendantsMessage_notTheParentsSameNamedDoneStep() {
        let p1 = LLMMessage(role: .assistant, content: "parent finished earlier")
        let c1 = LLMMessage(role: .assistant, content: "child is working")
        let parentRun = Run(id: 0, steps: [makeStep(status: .done, conversation: [p1])])
        let childRun = Run(id: 0, steps: [makeStep(status: .running, conversation: [c1])])

        let set = targets(parentRun: parentRun, descendants: [makeDescendant(run: childRun)])

        XCTAssertEqual(set, [c1.id],
                       "The descendant's latest message on its running step IS the implicit stream target, "
                           + "and the parent's same-named .done step contributes nothing")
    }

    /// The inverse cross-talk: the PARENT's latest message must not become an
    /// implicit target through the DESCENDANT's running step.
    ///
    /// RED: drop the `trackImplicitTarget = step.status == .running` guard in the
    /// fold → the parent's `.done` step names `parentMessage` and the set is not empty.
    func testParentBubble_doesNotBorrowDescendantsRunningStep() {
        let parentMessage = LLMMessage(role: .assistant, content: "parent finished earlier")
        let parentRun = Run(id: 0, steps: [makeStep(status: .done, conversation: [parentMessage])])
        let childRun = Run(id: 0, steps: [makeStep(status: .running)])

        let set = targets(parentRun: parentRun, descendants: [makeDescendant(run: childRun)])

        XCTAssertFalse(set.contains(parentMessage.id),
                       "Parent's .done step must not look 'running' just because the descendant's same-named step is")
        XCTAssertTrue(set.isEmpty, "the child's running step has no visible turn to name")
    }
}

// MARK: - Indicator corner: implicit target with zero signals

@MainActor
final class MessageBubbleIndicatorImplicitTargetCornerTests: XCTestCase {

    /// All existing implicit-target status tests carry message content; this pins
    /// the empty corner — an implicit stream target with NO content, NO thinking,
    /// NO progress, and NO activity must show no status row at all (returning
    /// "Waiting" here would flash a bogus status on a freshly-committed bubble).
    func testImplicitTarget_notStreaming_noSignals_showsNoStatus() {
        let status = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: true,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingStatus: nil,
            hasStreamActivity: false
        )
        XCTAssertNil(status)
    }
}
