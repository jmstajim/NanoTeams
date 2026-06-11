import XCTest

@testable import NanoTeams

/// Pins the per-ORIGIN-task step pools behind `resolveImplicitStreamTarget`.
///
/// `StepExecution.id` equals the team role ID, so in the merged delegation
/// timeline a descendant's step shares its id with the parent's same-role step.
/// Pre-fix, `messageBubble` resolved EVERY bubble's implicit-stream-target
/// against `viewModel.cachedAllSteps` (the ACTIVE task's steps only) — a
/// descendant bubble was matched against the parent's same-named step, so the
/// descendant's live "latest message of a running step" indicator resolved
/// from the wrong task's conversation.
@MainActor
final class ImplicitStreamTargetStepPoolTests: XCTestCase, @unchecked Sendable {

    private var viewModel: TeamActivityFeedViewModel!
    private let sharedStepID = "startup_software_engineer"
    private let parentTaskID = 1
    private let childTaskID = 2

    override func setUp() {
        super.setUp()
        viewModel = TeamActivityFeedViewModel()
    }

    override func tearDown() {
        viewModel = nil
        super.tearDown()
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

    private func makeDescendant(run: Run) -> ActivityFeedBuilder.DescendantTask {
        ActivityFeedBuilder.DescendantTask(
            task: NTMSTask(
                id: childTaskID, title: "Child", supervisorTask: "G", runs: [run],
                parentTaskID: parentTaskID, parentRoleID: sharedStepID, delegationDepth: 1),
            run: run,
            teamRoles: [makeRole()],
            teamName: "Startup",
            delegationDepth: 1,
            delegatedFromRoleName: "Software Engineer"
        )
    }

    // MARK: - Pool construction

    func testRecomputeSteps_buildsPerOriginTaskPools() {
        let parentRun = Run(id: 0, steps: [makeStep(status: .done)])
        let childRun = Run(id: 0, steps: [makeStep(status: .running)])
        let context = makeContext(run: parentRun, descendants: [makeDescendant(run: childRun)])

        viewModel.recomputeSteps(context: context)

        XCTAssertEqual(viewModel.steps(forOriginTaskID: parentTaskID).first?.status, .done)
        XCTAssertEqual(
            viewModel.steps(forOriginTaskID: childTaskID).first?.status, .running,
            "The descendant's pool must come from the descendant's run, not the parent's")
        XCTAssertTrue(
            viewModel.steps(forOriginTaskID: 999).isEmpty,
            "Unknown origin (stale item mid-transition) must yield an empty pool — no cross-task fallback")
    }

    func testResetForTaskSwitch_clearsPerTaskPools() {
        let parentRun = Run(id: 0, steps: [makeStep(status: .running)])
        viewModel.recomputeSteps(context: makeContext(run: parentRun))
        XCTAssertFalse(viewModel.steps(forOriginTaskID: parentTaskID).isEmpty)

        viewModel.resetForTaskSwitch()

        XCTAssertTrue(viewModel.steps(forOriginTaskID: parentTaskID).isEmpty)
    }

    // MARK: - The bug: descendant bubble resolved against the parent's step

    /// Parent's same-named step is `.done`; the descendant's is `.running` with a
    /// live latest message. Resolving the descendant's bubble against the
    /// DESCENDANT pool finds the implicit stream target; resolving against the
    /// parent pool (the pre-fix behavior) silently answers false — the
    /// descendant bubble loses its implicit streaming affordance.
    func testDescendantBubble_resolvesAgainstDescendantPool_notParentsSameNamedStep() {
        let descendantMessage = LLMMessage(role: .assistant, content: "child is working")
        let parentRun = Run(id: 0, steps: [makeStep(status: .done)])
        let childRun = Run(id: 0, steps: [makeStep(status: .running, conversation: [descendantMessage])])
        let context = makeContext(run: parentRun, descendants: [makeDescendant(run: childRun)])
        viewModel.recomputeSteps(context: context)

        let viaDescendantPool = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: sharedStepID,
            messageID: descendantMessage.id,
            isPreviewTarget: false,
            allSteps: viewModel.steps(forOriginTaskID: childTaskID))
        XCTAssertTrue(
            viaDescendantPool,
            "The descendant's latest message on its running step IS the implicit stream target")

        let viaParentPool = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: sharedStepID,
            messageID: descendantMessage.id,
            isPreviewTarget: false,
            allSteps: viewModel.steps(forOriginTaskID: parentTaskID))
        XCTAssertFalse(
            viaParentPool,
            "Pre-fix behavior pinned for contrast: the parent's same-named .done step hides the descendant's live state")
    }

    /// The inverse cross-talk: the PARENT's latest message must not become an
    /// implicit target through the DESCENDANT's running step.
    func testParentBubble_doesNotBorrowDescendantsRunningStep() {
        let parentMessage = LLMMessage(role: .assistant, content: "parent finished earlier")
        let parentRun = Run(id: 0, steps: [makeStep(status: .done, conversation: [parentMessage])])
        let childRun = Run(id: 0, steps: [makeStep(status: .running)])
        let context = makeContext(run: parentRun, descendants: [makeDescendant(run: childRun)])
        viewModel.recomputeSteps(context: context)

        let resolved = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: sharedStepID,
            messageID: parentMessage.id,
            isPreviewTarget: false,
            allSteps: viewModel.steps(forOriginTaskID: parentTaskID))

        XCTAssertFalse(
            resolved,
            "Parent's .done step must not look 'running' just because the descendant's same-named step is")
    }
}

// MARK: - Indicator corner: implicit target with zero signals

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
            processingProgress: nil,
            hasStreamActivity: false
        )
        XCTAssertNil(status)
    }
}
