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
///    to task B, overwriting B's cached items with A's data (CLAUDE.md
///    "Async cache invalidation pattern" rule).
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

    // MARK: - Task Switch Cancellation (stale-async-overwrite regression guard)

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
        let versionAfterReset = viewModel.timelineVersion

        // Wait well past the debounce window to let any un-cancelled task land.
        try? await Task.sleep(for: .milliseconds(400))

        // An un-cancelled rebuild would bump `timelineVersion` (rebuildTimeline
        // increments unconditionally) — the cache assertions alone can't catch
        // it because a stale rebuild of the cleared context produces empty items.
        XCTAssertEqual(viewModel.timelineVersion, versionAfterReset,
                       "Cancelled rebuild must not fire after task switch")

        // After reset, caches are empty AND the pending rebuild did not resurrect them.
        XCTAssertTrue(viewModel.cachedTimelineItems.isEmpty,
                      "Reset must clear cache and in-flight rebuild must not repopulate it")
        XCTAssertTrue(viewModel.cachedAllSteps.isEmpty)
        XCTAssertTrue(viewModel.cachedSupervisorQuestions.isEmpty)
        XCTAssertNil(viewModel.lastFingerprint)
    }

    // MARK: - Debounce Coalescing

    /// Two rapid calls to `scheduleStructuralRebuild` within the debounce window
    /// must collapse into a single rebuild. Each rebuild bumps `timelineVersion`,
    /// so after both calls settle the version must have advanced exactly once.
    /// Relies on `rebuildTimeline` bumping unconditionally (no fingerprint guard
    /// on the scheduled path) — if that changes, this assertion no longer
    /// distinguishes coalescing from a no-op second rebuild.
    func testScheduleStructuralRebuild_rapidCalls_coalesce() async {
        let role = makeRole(id: "r1")
        let run = Run(id: 0, steps: [makeStep(roleDefinitionID: "r1")])
        let context = makeContext(run: run, roles: [role])

        // Seed fingerprint so rebuild has inputs to work with.
        viewModel.recomputeAndRebuild(context: context)
        let seededVersion = viewModel.timelineVersion

        viewModel.scheduleStructuralRebuild(context: context, delayMilliseconds: 50)
        // Immediately re-schedule — this must cancel the first task.
        viewModel.scheduleStructuralRebuild(context: context, delayMilliseconds: 50)

        // Wait well past the debounce window so any un-cancelled task lands.
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(viewModel.timelineVersion, seededVersion + 1,
                       "Coalesced schedules must produce exactly one rebuild")
    }

    // MARK: - At-Bottom Detection (isNearBottom geometry helper)

    /// Truth table for the pure geometry helper that drives auto-scroll gating
    /// and the scroll-to-bottom button. Threshold is 60pt.
    func testIsNearBottom_exactlyAtBottom() {
        // content 1000, container 400 → max offset 600; sitting exactly there.
        XCTAssertTrue(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 600, contentHeight: 1000, containerHeight: 400, bottomInset: 0))
    }

    func testIsNearBottom_withinThreshold() {
        // 59pt above the bottom — still counts as at bottom.
        XCTAssertTrue(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 541, contentHeight: 1000, containerHeight: 400, bottomInset: 0))
    }

    func testIsNearBottom_exactlyAtThreshold() {
        // Exactly 60pt above the bottom — the contract is ≤, so this counts.
        XCTAssertTrue(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 540, contentHeight: 1000, containerHeight: 400, bottomInset: 0))
    }

    func testIsNearBottom_beyondThreshold() {
        // 61pt above the bottom — user has scrolled up.
        XCTAssertFalse(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 539, contentHeight: 1000, containerHeight: 400, bottomInset: 0))
    }

    func testIsNearBottom_bottomOvershoot_rubberBand_isTrue() {
        // Trackpad bounce past the bottom (offset > max 600) — distance goes
        // negative; bouncing at the bottom must not flash the button.
        XCTAssertTrue(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 650, contentHeight: 1000, containerHeight: 400, bottomInset: 0))
    }

    func testIsNearBottom_topRubberBand_isFalse() {
        // Negative offset (rubber-banding at the top of long content) must not
        // read as "at bottom".
        XCTAssertFalse(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: -50, contentHeight: 1000, containerHeight: 400, bottomInset: 0))
    }

    func testIsNearBottom_contentShorterThanContainer_alwaysTrue() {
        // Nothing to scroll — distance is negative.
        XCTAssertTrue(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 0, contentHeight: 200, containerHeight: 400, bottomInset: 0))
    }

    func testIsNearBottom_bottomInsetExtendsScrollableRange() {
        // With a 100pt bottom inset, max offset is 700; 600 is 100pt short → not at bottom.
        XCTAssertFalse(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 600, contentHeight: 1000, containerHeight: 400, bottomInset: 100))
        // At the inset-extended bottom, it is.
        XCTAssertTrue(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 700, contentHeight: 1000, containerHeight: 400, bottomInset: 100))
    }

    /// Task switch must reset `isNearBottom` to true — a stale `false` carried
    /// from the previous task would flash the scroll-to-bottom button before
    /// the new task's geometry lands.
    func testResetForTaskSwitch_restoresIsNearBottom() {
        viewModel.isNearBottom = false
        viewModel.resetForTaskSwitch()
        XCTAssertTrue(viewModel.isNearBottom)
        XCTAssertTrue(viewModel.needsScrollToBottom)
    }

    // MARK: - Scroll Action Policy (consumeScrollAction)

    /// Task-switch flag outranks the at-bottom gate and produces an instant jump —
    /// even when the user was scrolled up in the previous task.
    func testConsumeScrollAction_needsScrollToBottom_jumpsAndOutranksGate() {
        viewModel.needsScrollToBottom = true
        viewModel.isNearBottom = false
        XCTAssertEqual(viewModel.consumeScrollAction(), .jump)
    }

    /// The task-switch flag is consumed exactly once — the next rebuild falls
    /// through to the regular at-bottom gate.
    func testConsumeScrollAction_jumpConsumedExactlyOnce() {
        viewModel.needsScrollToBottom = true
        viewModel.isNearBottom = false
        XCTAssertEqual(viewModel.consumeScrollAction(), .jump)
        XCTAssertFalse(viewModel.needsScrollToBottom)
        XCTAssertNil(viewModel.consumeScrollAction(),
                     "Second rebuild must not jump again — flag was consumed")
    }

    /// New items while the user sits at the bottom → smooth animated scroll.
    func testConsumeScrollAction_atBottom_animates() {
        viewModel.needsScrollToBottom = false
        viewModel.isNearBottom = true
        XCTAssertEqual(viewModel.consumeScrollAction(), .animate)
        // The gate is level-based, not one-shot: staying at the bottom keeps scrolling.
        XCTAssertEqual(viewModel.consumeScrollAction(), .animate)
    }

    /// User scrolled up to read history → no scroll at all (the core
    /// "never yank the user down" contract of this feature).
    func testConsumeScrollAction_scrolledUp_doesNothing() {
        viewModel.needsScrollToBottom = false
        viewModel.isNearBottom = false
        XCTAssertNil(viewModel.consumeScrollAction())
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

    // MARK: - Single-run rendering (Autovisor passes are isolated per run)

    /// The displayed run's parked step surfaces as the live composer question.
    func testRecomputeSteps_latestRunPark_surfacedAsActiveQuestion() {
        let role = makeRole(id: "r1")
        let parked = StepExecution(id: "r1", role: .custom(id: "r1"), title: "latest",
                                   status: .needsSupervisorInput, needsSupervisorInput: true,
                                   supervisorQuestion: AutovisorConstants.idleParkQuestion)
        let ctx = makeContext(run: Run(id: 1, steps: [parked]), roles: [role])

        viewModel.recomputeSteps(context: ctx)

        XCTAssertEqual(viewModel.cachedSupervisorQuestions.count, 1,
                       "the displayed run's park is the live question")
    }

    /// A freshly-appended Autovisor pass (a new run) renders ONLY the displayed
    /// (latest) run's steps — prior passes are not merged into the live feed; they
    /// remain reachable via the run-history picker. The displayed run is `runs.last`.
    func testRecomputeSteps_freshPass_rendersOnlyLatestRunSteps() {
        let role = makeRole(id: "r1")
        let priorRun = Run(id: 0, steps: [makeStep(roleDefinitionID: "r1")])
        let latestRun = Run(id: 1, steps: [makeStep(roleDefinitionID: "r1"),
                                           makeStep(roleDefinitionID: "r1")])
        let runs = [priorRun, latestRun]
        let ctx = makeContext(run: runs.last, roles: [role])

        viewModel.recomputeSteps(context: ctx)

        XCTAssertEqual(viewModel.cachedAllSteps.count, latestRun.steps.count,
                       "only the latest run's steps render; the prior pass is not merged")
    }

    /// Mirror image: selecting a PRIOR Autovisor run via the run-history picker
    /// renders THAT run's steps, not the latest. Pins the read-only/history path —
    /// the behavioral contract the continuous-merge removal actually changed (the
    /// merge used to be suppressed for historical runs; now it's simply absent, so
    /// the displayed run is rendered verbatim regardless of which run is selected).
    func testRecomputeSteps_historicalRunSelected_rendersThatRunsSteps() {
        let role = makeRole(id: "r1")
        let priorRun = Run(id: 0, steps: [makeStep(roleDefinitionID: "r1")])
        let latestRun = Run(id: 1, steps: [makeStep(roleDefinitionID: "r1"),
                                           makeStep(roleDefinitionID: "r1")])
        _ = latestRun  // exists in task.runs but is NOT the displayed run
        let ctx = makeContext(run: priorRun, roles: [role])  // history picker chose run 0

        viewModel.recomputeSteps(context: ctx)

        XCTAssertEqual(viewModel.cachedAllSteps.count, priorRun.steps.count,
                       "the selected historical run's steps render, not the latest run's")
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
            isStreaming: { _ in false }
        )
    }
}
