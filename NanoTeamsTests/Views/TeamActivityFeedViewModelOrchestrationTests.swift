import XCTest

@testable import NanoTeams

/// Regression guards for the VM orchestration API introduced when state was
/// consolidated off `TeamActivityFeedView` and into `TeamActivityFeedViewModel`.
///
/// These tests protect three invariants that used to live inline in the view:
///
/// 1. `recomputeAndRebuild` short-circuits via `TimelineFingerprint` equality —
///    a no-op when nothing structural has changed. Regression would rebuild the
///    timeline on every `onChange` tick (reintroduces the scroll-lag bug fixed
///    in commit 30c830c).
///
/// 2. `resetForTaskSwitch()` cancels any in-flight debounced rebuild Task.
///    Regression would let a rebuild from task A land after the user switched
///    to task B, overwriting B's cached items with A's data (CLAUDE.md Rule #40).
///
/// 3. `scheduleStructuralRebuild` debounce coalescing — two calls within the
///    debounce window must collapse to a single rebuild. Regression would turn
///    every streaming token into a full timeline rebuild.
@MainActor
final class TeamActivityFeedViewModelOrchestrationTests: XCTestCase {

    var viewModel: TeamActivityFeedViewModel!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        viewModel = TeamActivityFeedViewModel()
    }

    override func tearDown() {
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Fingerprint Short-Circuit

    /// First `recomputeAndRebuild` populates the fingerprint and builds the timeline.
    /// A second call with identical inputs must NOT trigger a rebuild.
    func testRecomputeAndRebuild_identicalContext_shortCircuits() {
        let role = makeRole(id: "r1")
        let step = makeStep(roleDefinitionID: "r1")
        let run = Run(id: 0, steps: [step])
        let context = makeContext(run: run, roles: [role])

        viewModel.recomputeAndRebuild(context: context)
        let firstFingerprint = viewModel.lastFingerprint
        let firstItemCount = viewModel.cachedTimelineItems.count
        XCTAssertNotNil(firstFingerprint, "First call must seed the fingerprint")

        // Mutate an unrelated cache the fingerprint does not track. The short-circuit
        // should fire because `TimelineFingerprint` only tracks structural counts.
        viewModel.loadArtifactContentIfNeeded(
            Artifact(name: "x", createdAt: Date(), updatedAt: Date()),
            workFolderURL: nil
        )

        viewModel.recomputeAndRebuild(context: context)
        XCTAssertEqual(viewModel.lastFingerprint, firstFingerprint,
                       "Fingerprint must be unchanged when inputs are identical")
        XCTAssertEqual(viewModel.cachedTimelineItems.count, firstItemCount,
                       "Timeline must not be rebuilt when fingerprint is unchanged")
    }

    /// When a step is added, the fingerprint changes and the timeline rebuilds.
    func testRecomputeAndRebuild_stepAdded_rebuildsTimeline() {
        let role = makeRole(id: "r1")
        let run1 = Run(id: 0, steps: [makeStep(roleDefinitionID: "r1")])
        let context1 = makeContext(run: run1, roles: [role])
        viewModel.recomputeAndRebuild(context: context1)
        let firstFingerprint = viewModel.lastFingerprint

        let run2 = Run(id: 0, steps: [
            makeStep(roleDefinitionID: "r1"),
            makeStep(roleDefinitionID: "r1"),
        ])
        let context2 = makeContext(run: run2, roles: [role])
        viewModel.recomputeAndRebuild(context: context2)

        XCTAssertNotEqual(viewModel.lastFingerprint, firstFingerprint,
                          "Fingerprint must change when step count changes")
        XCTAssertEqual(viewModel.cachedAllSteps.count, 2)
    }

    // MARK: - Task Switch Cancellation (Rule #40 regression guard)

    /// `resetForTaskSwitch()` must cancel any in-flight debounced rebuild so
    /// stale work from the previous task cannot overwrite the fresh VM state.
    func testResetForTaskSwitch_cancelsInflightStructuralRebuild() async {
        let role = makeRole(id: "r1")
        let runA = Run(id: 0, steps: [makeStep(roleDefinitionID: "r1")])
        let contextA = makeContext(run: runA, roles: [role])

        // Seed caches so we have something visible to wipe.
        viewModel.recomputeAndRebuild(context: contextA)
        XCTAssertNotNil(viewModel.lastFingerprint, "Initial rebuild must seed the fingerprint")
        XCTAssertFalse(viewModel.cachedAllSteps.isEmpty, "Initial rebuild must cache the step list")

        // Schedule a rebuild with a large delay, then immediately reset.
        viewModel.scheduleStructuralRebuild(
            context: contextA,
            delayMilliseconds: 200
        )
        viewModel.resetForTaskSwitch()

        // Wait well past the debounce window to let any un-cancelled task land.
        try? await Task.sleep(for: .milliseconds(400))

        // After reset, caches are empty AND the pending rebuild did not resurrect them.
        XCTAssertTrue(viewModel.cachedTimelineItems.isEmpty,
                      "Reset must clear cache and in-flight rebuild must not repopulate it")
        XCTAssertTrue(viewModel.cachedAllSteps.isEmpty)
        XCTAssertTrue(viewModel.cachedSupervisorQuestions.isEmpty)
        XCTAssertNil(viewModel.lastFingerprint)
    }

    // MARK: - Debounce Coalescing

    /// Two rapid calls to `scheduleStructuralRebuild` within the debounce window
    /// must collapse into a single rebuild. We assert this indirectly: the first
    /// call's onComplete must NOT fire (it was cancelled), only the second one does.
    func testScheduleStructuralRebuild_rapidCalls_coalesce() async {
        let role = makeRole(id: "r1")
        let run = Run(id: 0, steps: [makeStep(roleDefinitionID: "r1")])
        let context = makeContext(run: run, roles: [role])

        // Seed fingerprint so rebuild has inputs to work with.
        viewModel.recomputeAndRebuild(context: context)

        let firstCompleted = expectation(description: "first onComplete")
        firstCompleted.isInverted = true  // must NOT fire
        let secondCompleted = expectation(description: "second onComplete")

        viewModel.scheduleStructuralRebuild(context: context, delayMilliseconds: 50) {
            firstCompleted.fulfill()
        }
        // Immediately re-schedule — this must cancel the first task.
        viewModel.scheduleStructuralRebuild(context: context, delayMilliseconds: 50) {
            secondCompleted.fulfill()
        }

        await fulfillment(of: [firstCompleted, secondCompleted], timeout: 0.5)
    }

    // MARK: - Step Filtering (computeAllSteps via recomputeSteps)

    /// Happy path: with a `filterRoleID` set, only steps for that role land in the cache.
    func testRecomputeSteps_filterRoleID_onlyMatchingStepsIncluded() {
        let r1 = makeRole(id: "r1")
        let r2 = makeRole(id: "r2")
        let run = Run(id: 0, steps: [
            makeStep(roleDefinitionID: "r1"),
            makeStep(roleDefinitionID: "r2"),
            makeStep(roleDefinitionID: "r1"),
        ])
        var ctx = makeContext(run: run, roles: [r1, r2])
        ctx.filterRoleID = "r1"

        viewModel.recomputeSteps(context: ctx)

        XCTAssertEqual(viewModel.cachedAllSteps.count, 2, "Only the two r1 steps should be included")
        XCTAssertTrue(viewModel.cachedAllSteps.allSatisfy { $0.effectiveRoleID == "r1" })
    }

    /// Filter with no matches returns empty (no false positives from membership-only filtering).
    func testRecomputeSteps_filterRoleID_noMatch_returnsEmpty() {
        let r1 = makeRole(id: "r1")
        let run = Run(id: 0, steps: [makeStep(roleDefinitionID: "r1")])
        var ctx = makeContext(run: run, roles: [r1])
        ctx.filterRoleID = "nonexistent"

        viewModel.recomputeSteps(context: ctx)

        XCTAssertTrue(viewModel.cachedAllSteps.isEmpty,
                      "Filter with no match and no systemRoleID fallback must return empty")
    }

    /// systemRoleID bridge — a step whose role.baseID matches a team member's systemRoleID
    /// must be included even when the team membership UUIDs don't match directly.
    /// This handles the team-restore / migration edge case documented in `computeAllSteps`.
    func testRecomputeSteps_systemRoleIDBridge_includesMismatchedUUIDStep() {
        // Team has a role with an opaque UUID id but a stable systemRoleID.
        let role = TeamRoleDefinition(
            id: "uuid-after-restore",
            name: "Software Engineer",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []),
            systemRoleID: "softwareEngineer"
        )
        // Step was created with a built-in Role enum, so effectiveRoleID == role.baseID == "softwareEngineer",
        // which does NOT directly match "uuid-after-restore".
        let step = StepExecution(
            id: Role.softwareEngineer.baseID,
            role: .softwareEngineer,
            title: "Engineer work",
            status: .done,
            updatedAt: MonotonicClock.shared.now()
        )
        let ctx = makeContext(run: Run(id: 0, steps: [step]), roles: [role])

        viewModel.recomputeSteps(context: ctx)

        XCTAssertEqual(viewModel.cachedAllSteps.count, 1,
                       "systemRoleID bridge must include step whose role.baseID matches systemRoleID")
    }

    /// filterRoleID fallback — filtering by a UUID id for which no step has a direct match
    /// must still succeed via the systemRoleID bridge.
    func testRecomputeSteps_filterRoleID_systemRoleIDFallback() {
        let role = TeamRoleDefinition(
            id: "uuid-after-restore",
            name: "Software Engineer",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []),
            systemRoleID: "softwareEngineer"
        )
        let step = StepExecution(
            id: Role.softwareEngineer.baseID,
            role: .softwareEngineer,
            title: "Engineer work",
            status: .done,
            updatedAt: MonotonicClock.shared.now()
        )
        var ctx = makeContext(run: Run(id: 0, steps: [step]), roles: [role])
        ctx.filterRoleID = "uuid-after-restore"  // direct match fails (step.id is "softwareEngineer"), systemRoleID bridge matches

        viewModel.recomputeSteps(context: ctx)

        XCTAssertEqual(viewModel.cachedAllSteps.count, 1,
                       "filterRoleID fallback via systemRoleID must match the step")
    }

    // MARK: - Fingerprint Sensitivity

    /// Each tracked field in `TimelineFingerprint` must actually flip the fingerprint when changed.
    /// Prevents the regression where someone adds a new data source to the run but forgets to
    /// plumb it through `computeFingerprint`, silently making change detection blind to it.
    func testComputeFingerprint_trackedFields_flipOnChange() {
        let baseStep = makeStep(roleDefinitionID: "r1")
        let taskID = 0
        let base = viewModel.computeFingerprint(
            steps: [baseStep], run: Run(id: 0, steps: [baseStep]), activeTaskID: taskID
        )

        // stepCount
        let twoSteps = viewModel.computeFingerprint(
            steps: [baseStep, baseStep], run: Run(id: 0, steps: [baseStep, baseStep]), activeTaskID: taskID
        )
        XCTAssertNotEqual(base, twoSteps, "stepCount must affect fingerprint")

        // activeTaskID
        let differentTask = viewModel.computeFingerprint(
            steps: [baseStep], run: Run(id: 0, steps: [baseStep]), activeTaskID: 999
        )
        XCTAssertNotEqual(base, differentTask, "activeTaskID must affect fingerprint")

        // failedStepCount
        var failedStep = baseStep
        failedStep.status = .failed
        let failed = viewModel.computeFingerprint(
            steps: [failedStep], run: Run(id: 0, steps: [failedStep]), activeTaskID: taskID
        )
        XCTAssertNotEqual(base, failed, "failedStepCount must affect fingerprint")

        // changeRequestCount
        let cr = ChangeRequest(
            createdAt: MonotonicClock.shared.now(),
            requestingRoleID: "a", targetRoleID: "b",
            changes: "x", reasoning: "y"
        )
        let withCR = viewModel.computeFingerprint(
            steps: [baseStep],
            run: Run(id: 0, steps: [baseStep], changeRequests: [cr]),
            activeTaskID: taskID
        )
        XCTAssertNotEqual(base, withCR, "changeRequestCount must affect fingerprint")

        // meetingMessageCount
        let meeting = TeamMeeting(
            topic: "x", initiatedBy: .softwareEngineer,
            participants: [.softwareEngineer],
            messages: [TeamMessage(createdAt: MonotonicClock.shared.now(), role: .softwareEngineer, content: "hi")]
        )
        let withMeeting = viewModel.computeFingerprint(
            steps: [baseStep],
            run: Run(id: 0, steps: [baseStep], meetings: [meeting]),
            activeTaskID: taskID
        )
        XCTAssertNotEqual(base, withMeeting, "meetingMessageCount must affect fingerprint")
    }

    // MARK: - Fixtures

    private func makeRole(id: String) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: "Role \(id)",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
    }

    private func makeStep(roleDefinitionID: String) -> StepExecution {
        // `teamRoleID` feeds `effectiveRoleID`, which is what `computeAllSteps`
        // matches against team membership. Pass the role definition's id here
        // so the step is included in the filtered step list.
        StepExecution(
            id: roleDefinitionID,
            role: .custom(id: roleDefinitionID),
            title: "Step for \(roleDefinitionID)",
            status: .done,
            updatedAt: MonotonicClock.shared.now(),
            completedAt: MonotonicClock.shared.now()
        )
    }

    private func makeContext(
        run: Run?,
        roles: [TeamRoleDefinition],
        debug: Bool = false
    ) -> TeamActivityFeedViewModel.BuildContext {
        TeamActivityFeedViewModel.BuildContext(
            run: run,
            roleDefinitions: roles,
            filterRoleID: nil,
            activeTaskID: Int(),
            supervisorBrief: nil,
            supervisorBriefDate: nil,
            supervisorTask: nil,
            supervisorClippedTexts: [],
            supervisorAttachmentPaths: [],
            supervisorProjectFolderURL: nil,
            workFolderURL: nil,
            debugModeEnabled: debug,
            thinkingExpandedByDefault: false,
            toolCallsExpandedByDefault: false,
            artifactsExpandedByDefault: false,
            isStreaming: { _ in false }
        )
    }
}
