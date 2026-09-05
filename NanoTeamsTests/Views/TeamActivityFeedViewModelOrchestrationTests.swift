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

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        viewModel = TeamActivityFeedViewModel()
    }

    override func tearDown() async throws {
        viewModel = nil
        try await super.tearDown()
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
    /// and the scroll-to-bottom button. Threshold is 50pt.
    func testIsNearBottom_exactlyAtBottom() {
        // content 1000, container 400 → max offset 600; sitting exactly there.
        XCTAssertTrue(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 600, contentHeight: 1000, containerHeight: 400, bottomInset: 0))
    }

    func testIsNearBottom_withinThreshold() {
        // 49pt above the bottom (max offset 600) — still counts as at bottom.
        XCTAssertTrue(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 551, contentHeight: 1000, containerHeight: 400, bottomInset: 0))
    }

    func testIsNearBottom_exactlyAtThreshold() {
        // Exactly 50pt above the bottom — the contract is ≤, so this counts.
        XCTAssertTrue(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 550, contentHeight: 1000, containerHeight: 400, bottomInset: 0))
    }

    func testIsNearBottom_beyondThreshold() {
        // 51pt above the bottom — user has scrolled up.
        XCTAssertFalse(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 549, contentHeight: 1000, containerHeight: 400, bottomInset: 0))
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

    /// A top safe-area inset (TeamBoardTopBar) shifts the resting bottom offset
    /// down by its own height. Verbatim numbers from the live geometry trace that
    /// surfaced the bug: at the TRUE bottom the raw distance equals `insetTop`, so
    /// without subtracting `topInset` the gate reads 79 > 60 and latches false.
    func testIsNearBottom_topInset_atTrueBottom_isTrue() {
        // contentH 1348, containerH 904.5, insetTop 79 → resting bottom offset 364.5.
        // Raw distance = 1348 - 904.5 - 364.5 = 79 (== insetTop); corrected = 0.
        XCTAssertTrue(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 364.5, contentHeight: 1348, containerHeight: 904.5,
            bottomInset: 0, topInset: 79))
        // The pre-fix formula (topInset omitted) wrongly read this as NOT at bottom:
        XCTAssertFalse(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 364.5, contentHeight: 1348, containerHeight: 904.5,
            bottomInset: 0, topInset: 0))
    }

    /// With the top inset accounted for, a genuine scroll-up past the threshold is
    /// still detected as "not at bottom" (the button must still appear).
    func testIsNearBottom_topInset_scrolledUp_isFalse() {
        // 100pt above the corrected bottom (offset 264.5 vs resting 364.5).
        XCTAssertFalse(TeamActivityFeedViewModel.isNearBottom(
            contentOffsetY: 264.5, contentHeight: 1348, containerHeight: 904.5,
            bottomInset: 0, topInset: 79))
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

    // MARK: - distanceFromBottom (single source of truth)

    /// `isNearBottom` must DELEGATE to `distanceFromBottom` so the production path
    /// (which builds the snapshot from `distanceFromBottom`) and the pinned tests
    /// share ONE formula — guards the multi-surface-divergence trap the repo's own
    /// Грабли log warns about.
    func testDistanceFromBottom_isTheSourceForIsNearBottom() {
        // contentH 1348, containerH 904.5, insetTop 79 → resting bottom offset 364.5.
        let d = TeamActivityFeedViewModel.distanceFromBottom(
            contentHeight: 1348, bottomInset: 0, topInset: 79,
            containerHeight: 904.5, contentOffsetY: 364.5)
        XCTAssertEqual(d, 0, accuracy: 0.0001)  // at the true bottom under a 79pt top inset
        // isNearBottom is exactly `distanceFromBottom <= threshold`.
        XCTAssertEqual(
            TeamActivityFeedViewModel.isNearBottom(
                contentOffsetY: 364.5, contentHeight: 1348, containerHeight: 904.5,
                bottomInset: 0, topInset: 79),
            d <= TeamActivityFeedViewModel.nearBottomThreshold)
    }

    /// The top inset is subtracted: the SAME geometry minus the inset term reads as
    /// `topInset` farther from the bottom (the pre-fix latch-out bug).
    func testDistanceFromBottom_subtractsTopInset() {
        let withInset = TeamActivityFeedViewModel.distanceFromBottom(
            contentHeight: 1348, bottomInset: 0, topInset: 79,
            containerHeight: 904.5, contentOffsetY: 364.5)
        let withoutInset = TeamActivityFeedViewModel.distanceFromBottom(
            contentHeight: 1348, bottomInset: 0, topInset: 0,
            containerHeight: 904.5, contentOffsetY: 364.5)
        XCTAssertEqual(withoutInset - withInset, 79, accuracy: 0.0001)
    }

    // MARK: - bottomTargetY (scroll-target ↔ at-bottom gate consistency)

    /// THE regression for the "autoscroll stopped / can't re-pin" bug. The settle
    /// scroll passes `bottomTargetY` to `scrollTo(y:)`, which lands `topInset`
    /// SHORT of its argument; the landed offset must read `distanceFromBottom == 0`
    /// (the at-bottom gate's zero). Uses the SAME numbers as the pinned
    /// `distanceFromBottom` true-bottom test: cH 1348, container 904.5, insTop 79
    /// → resting bottom offset 364.5. `bottomTargetY` must therefore be 443.5
    /// (364.5 + insTop) so that `scrollTo` undershoots back to exactly 364.5.
    func testBottomTargetY_scrollLandsWhereGateReadsZero() {
        let cH: CGFloat = 1348, container: CGFloat = 904.5, insTop: CGFloat = 79, insBot: CGFloat = 0
        let target = TeamActivityFeedViewModel.bottomTargetY(
            contentHeight: cH, bottomInset: insBot, containerHeight: container)
        XCTAssertEqual(target, 443.5, accuracy: 0.0001,
                       "target must be the resting bottom offset PLUS topInset (cancels the inset term)")
        // `scrollTo(y:)` lands `insTop` short of its argument (verified in the live trace).
        let landedOffset = target - insTop
        XCTAssertEqual(landedOffset, 364.5, accuracy: 0.0001, "lands at the pinned true-bottom offset")
        let distAfterScroll = TeamActivityFeedViewModel.distanceFromBottom(
            contentHeight: cH, bottomInset: insBot, topInset: insTop,
            containerHeight: container, contentOffsetY: landedOffset)
        XCTAssertEqual(distAfterScroll, 0, accuracy: 0.0001,
                       "the settle-scroll must land where the at-bottom gate reads 0 — not topInset short")
        XCTAssertLessThanOrEqual(distAfterScroll, TeamActivityFeedViewModel.nearBottomThreshold,
                                 "landed within the at-bottom band → gate stays pinned, no latch-out")
    }

    /// Pins the BUG the fix removes: passing the resting bottom offset directly
    /// (the pre-fix `cH + insBot - insTop - container`) lands `insTop` short, so
    /// the post-scroll distance equals `insTop` — above the at-bottom threshold, which
    /// latched the feed out of auto-follow. The fixed `bottomTargetY` is exactly
    /// `insTop` higher, which cancels that residual.
    func testBottomTargetY_correctsTopInsetUndershoot() {
        let cH: CGFloat = 1348, container: CGFloat = 904.5, insTop: CGFloat = 79, insBot: CGFloat = 0
        let restingOffset = cH + insBot - insTop - container  // the pre-fix (buggy) target
        let fixed = TeamActivityFeedViewModel.bottomTargetY(
            contentHeight: cH, bottomInset: insBot, containerHeight: container)
        XCTAssertEqual(fixed - restingOffset, insTop, accuracy: 0.0001,
                       "fix adds back exactly topInset to compensate scrollTo's undershoot")
        // Pre-fix landing (restingOffset - insTop) read dist == insTop (> threshold → latch).
        let buggyDist = TeamActivityFeedViewModel.distanceFromBottom(
            contentHeight: cH, bottomInset: insBot, topInset: insTop,
            containerHeight: container, contentOffsetY: restingOffset - insTop)
        XCTAssertEqual(buggyDist, insTop, accuracy: 0.0001)
        XCTAssertGreaterThan(buggyDist, TeamActivityFeedViewModel.nearBottomThreshold,
                             "the pre-fix target latched the gate false — this is the bug being fixed")
    }

    /// A bottom inset extends the scrollable range, so the target grows by exactly
    /// the inset (more content reachable below the fold before the true bottom).
    func testBottomTargetY_bottomInsetExtendsTarget() {
        let withoutInset = TeamActivityFeedViewModel.bottomTargetY(
            contentHeight: 1000, bottomInset: 0, containerHeight: 400)
        let withInset = TeamActivityFeedViewModel.bottomTargetY(
            contentHeight: 1000, bottomInset: 100, containerHeight: 400)
        XCTAssertEqual(withoutInset, 600, accuracy: 0.0001)
        XCTAssertEqual(withInset - withoutInset, 100, accuracy: 0.0001)
    }

    /// Content shorter than the container yields a negative target (nothing to
    /// scroll). `scrollTo(y:)` clamps to the top; the gate already reads at-bottom
    /// for short content, so this is benign — pin the value so a future refactor
    /// can't silently make it positive (which would scroll past empty content).
    func testBottomTargetY_contentShorterThanContainer_isNonPositive() {
        let target = TeamActivityFeedViewModel.bottomTargetY(
            contentHeight: 200, bottomInset: 0, containerHeight: 400)
        XCTAssertEqual(target, -200, accuracy: 0.0001)
    }

    // MARK: - Content-Growth Follow (shouldFollowGrowth keeps the bottom-pin)

    /// Pure content growth under a pinned scroll: the offset is frozen, so the distance
    /// grows by EXACTLY the content growth (+80/+80) → keep the pin (the deferred
    /// settle-scroll will land at the bottom once the layout quiesces).
    func testShouldFollowGrowth_growthUnderPinnedScroll_isTrue() {
        XCTAssertTrue(TeamActivityFeedViewModel.shouldFollowGrowth(
            oldContentHeight: 1000, newContentHeight: 1080,
            oldDistanceFromBottom: 0, newDistanceFromBottom: 80,
            wasAtBottom: true))
    }

    /// Growth where the offset auto-followed PART of it (distance grew less than the
    /// content) → still a pure-growth tick, keep the pin.
    func testShouldFollowGrowth_growthWithPartialOffsetFollow_isTrue() {
        XCTAssertTrue(TeamActivityFeedViewModel.shouldFollowGrowth(
            oldContentHeight: 1000, newContentHeight: 1080,
            oldDistanceFromBottom: 0, newDistanceFromBottom: 30,
            wasAtBottom: true))
    }

    /// Content grew AND the user dragged up on the same coalesced geometry tick —
    /// distance grows by MORE than the content did (+80 height, +180 distance ⇒ ~100pt
    /// drag) → release the pin, never yank.
    func testShouldFollowGrowth_growthPlusUserDragUp_isFalse() {
        XCTAssertFalse(TeamActivityFeedViewModel.shouldFollowGrowth(
            oldContentHeight: 1000, newContentHeight: 1080,
            oldDistanceFromBottom: 0, newDistanceFromBottom: 180,
            wasAtBottom: true))
    }

    /// A drag-up WITHIN the slack tolerance (sub-pixel / fractional jitter) keeps the
    /// pin — the slack must not be so tight that float noise flips the decision.
    func testShouldFollowGrowth_growthPlusJitterWithinSlack_isTrue() {
        XCTAssertTrue(TeamActivityFeedViewModel.shouldFollowGrowth(
            oldContentHeight: 1000, newContentHeight: 1080,
            oldDistanceFromBottom: 0, newDistanceFromBottom: 82,
            wasAtBottom: true))
    }

    /// A drag-up JUST beyond the slack tolerance flips to "release pin" — pins the
    /// boundary so the slack can't silently widen into "always follow".
    func testShouldFollowGrowth_growthPlusDragJustBeyondSlack_isFalse() {
        // +80 height, +85 distance (5pt > 80 + slack(4)) → user wins, release.
        XCTAssertFalse(TeamActivityFeedViewModel.shouldFollowGrowth(
            oldContentHeight: 1000, newContentHeight: 1080,
            oldDistanceFromBottom: 0, newDistanceFromBottom: 85,
            wasAtBottom: true))
    }

    /// Content grew but the user had ALREADY scrolled up (pin released) → stays released.
    func testShouldFollowGrowth_grewWhileScrolledUp_isFalse() {
        XCTAssertFalse(TeamActivityFeedViewModel.shouldFollowGrowth(
            oldContentHeight: 1000, newContentHeight: 1080,
            oldDistanceFromBottom: 200, newDistanceFromBottom: 280,
            wasAtBottom: false))
    }

    /// Content shrank (a commit collapsing the transient spike, or an item collapsing)
    /// while at bottom → not a growth tick; the caller recomputes the gate instead.
    func testShouldFollowGrowth_shrankWhileAtBottom_isFalse() {
        XCTAssertFalse(TeamActivityFeedViewModel.shouldFollowGrowth(
            oldContentHeight: 1080, newContentHeight: 1000,
            oldDistanceFromBottom: 0, newDistanceFromBottom: 0,
            wasAtBottom: true))
    }

    /// Pure offset change (height unchanged) while at bottom → not a growth tick; the
    /// gate-recompute path owns this, shouldFollowGrowth must say false.
    func testShouldFollowGrowth_sameHeightWhileAtBottom_isFalse() {
        XCTAssertFalse(TeamActivityFeedViewModel.shouldFollowGrowth(
            oldContentHeight: 1000, newContentHeight: 1000,
            oldDistanceFromBottom: 0, newDistanceFromBottom: 120,
            wasAtBottom: true))
    }

    /// The Equatable snapshot must distinguish a growth tick from a pure offset tick so
    /// `onScrollGeometryChange`'s `action` fires on both.
    func testScrollFollowSnapshot_equatable() {
        let a = TeamActivityFeedViewModel.ScrollFollowSnapshot(distanceFromBottom: 0, contentHeight: 1000, bottomTargetY: 250)
        let sameOffsetGrew = TeamActivityFeedViewModel.ScrollFollowSnapshot(distanceFromBottom: 0, contentHeight: 1080, bottomTargetY: 330)
        let movedSameHeight = TeamActivityFeedViewModel.ScrollFollowSnapshot(distanceFromBottom: 120, contentHeight: 1000, bottomTargetY: 250)
        let sameButDifferentTarget = TeamActivityFeedViewModel.ScrollFollowSnapshot(distanceFromBottom: 0, contentHeight: 1000, bottomTargetY: 999)
        XCTAssertNotEqual(a, sameOffsetGrew)
        XCTAssertNotEqual(a, movedSameHeight)
        XCTAssertNotEqual(a, sameButDifferentTarget)
        XCTAssertEqual(a, TeamActivityFeedViewModel.ScrollFollowSnapshot(distanceFromBottom: 0, contentHeight: 1000, bottomTargetY: 250))
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

    // MARK: - Ask-index cache and escalation-thinking memo

    /// A step parked WITHOUT an ask (drift / refusal cap, Autovisor idle park) used to
    /// pay `toolCalls.last(where: ask)` — an absence proof over the whole array — on
    /// EVERY `recomputeSteps` tick, before the fingerprint short-circuit. The view
    /// model's `AskCallIndex` cache makes the steady-state tick examine nothing.
    ///
    /// RED: in `TeamActivityFeedViewModel.askIndex(taskID:step:)` pass `extending: nil`
    /// (or drop the `askIndexByStep[key] = index` store) → examined reads 192.
    func testRecomputeSteps_parkedStepWithoutAsk_examinesToolCallsOnceAcrossTicks() {
        let role = makeRole(id: "r1")
        let context = makeContext(
            run: Run(id: 0, steps: [parkedStepWithoutAsk(id: "r1", toolCallCount: 64)]), roles: [role])

        AskCallIndexProbe.reset()
        viewModel.recomputeSteps(context: context)
        XCTAssertEqual(AskCallIndexProbe.examined(), 64, "anti-vacuum: the first tick scans the array")

        AskCallIndexProbe.reset()
        for _ in 0..<3 { viewModel.recomputeSteps(context: context) }

        XCTAssertEqual(AskCallIndexProbe.examined(), 0, "an unchanged array is never re-examined")
        XCTAssertEqual(viewModel.cachedSupervisorQuestions.count, 1, "and the chip is still there")
    }

    /// RED: in `TeamActivityFeedViewModel.askIndex(taskID:step:)` pass `extending: nil`
    /// → the tick after the append rescans all 66 calls, not the 2 appended.
    func testRecomputeSteps_afterToolCallAppend_examinesOnlyTheDelta() {
        let role = makeRole(id: "r1")
        var step = parkedStepWithoutAsk(id: "r1", toolCallCount: 64)
        viewModel.recomputeSteps(context: makeContext(run: Run(id: 0, steps: [step]), roles: [role]))

        step.toolCalls += [
            StepToolCall(name: "read_file", argumentsJSON: "{}"),
            StepToolCall(name: "read_file", argumentsJSON: "{}"),
        ]
        AskCallIndexProbe.reset()
        viewModel.recomputeSteps(context: makeContext(run: Run(id: 0, steps: [step]), roles: [role]))

        XCTAssertEqual(AskCallIndexProbe.examined(), 2, "only the two appended calls are examined")
    }

    /// The escalation card's `thinking` is resolved by a fresh `ThinkingResolver`
    /// build — an O(k log k) sort — on every rebuild, at the feed's 50 ms streaming
    /// cadence. The value cannot change once the answer exists, so it is memoized.
    ///
    /// RED: in `escalationThinking(step:answerMessageID:compute:)` return `compute()`
    /// without consulting or storing the dictionary → builds reads 1 on the second rebuild.
    func testRebuildTimeline_escalationCardThinking_resolvedOnceAcrossRebuilds() {
        let step = settledEscalationStep(
            id: "r1",
            messages: [
                LLMMessage(createdAt: date(50), role: .assistant, content: "Going idle.", thinking: "T1"),
                LLMMessage(createdAt: date(200), role: .user, content: "Supervisor answer: fix", sourceContext: .supervisorAnswer),
                LLMMessage(createdAt: date(300), role: .assistant, content: "Investigating.", thinking: "T2"),
            ],
            answer: "fix", updatedAt: date(310))

        ThinkingResolverBuildProbe.reset()
        viewModel.rebuildTimeline(steps: [step], run: nil, activeTaskID: 1, debugModeEnabled: false, isStreaming: { _ in false })
        XCTAssertEqual(ThinkingResolverBuildProbe.builds(), 1, "anti-vacuum: the first rebuild resolves")
        XCTAssertEqual(escalationCard(in: viewModel.cachedTimelineItems)?.thinking, "T1")

        ThinkingResolverBuildProbe.reset()
        viewModel.rebuildTimeline(steps: [step], run: nil, activeTaskID: 1, debugModeEnabled: false, isStreaming: { _ in false })

        XCTAssertEqual(ThinkingResolverBuildProbe.builds(), 0, "the second rebuild is a memo hit")
        XCTAssertEqual(escalationCard(in: viewModel.cachedTimelineItems)?.thinking, "T1")
    }

    /// A new answer cycle is a NEW key: the card re-anchors on the latest answer
    /// (the law of `testEscalationAnsweredCard_multiRound_anchorsOnLatestAnswer`).
    ///
    /// RED: key the memo by `TaskStepKey` alone (drop `answerMessageID` from
    /// `EscalationThinkingKey`) → the stale "round1" is served.
    func testEscalationThinkingMemo_newAnswerCycle_reResolvesToTheLatestAnchor() {
        let round1 = LLMMessage(createdAt: date(50), role: .assistant, content: "Parking.", thinking: "round1")
        let answer1 = LLMMessage(createdAt: date(100), role: .user, content: "Supervisor answer: one", sourceContext: .supervisorAnswer)
        var step = settledEscalationStep(id: "r1", messages: [round1, answer1], answer: "one", updatedAt: date(110))
        viewModel.rebuildTimeline(steps: [step], run: nil, activeTaskID: 1, debugModeEnabled: false, isStreaming: { _ in false })
        XCTAssertEqual(escalationCard(in: viewModel.cachedTimelineItems)?.thinking, "round1", "anti-vacuum")

        let round2 = LLMMessage(createdAt: date(250), role: .assistant, content: "Parking again.", thinking: "round2")
        let answer2 = LLMMessage(createdAt: date(300), role: .user, content: "Supervisor answer: two", sourceContext: .supervisorAnswer)
        step.llmConversation += [round2, answer2]
        step.supervisorAnswer = "two"
        step.updatedAt = date(310)
        viewModel.rebuildTimeline(steps: [step], run: nil, activeTaskID: 1, debugModeEnabled: false, isStreaming: { _ in false })

        let card = escalationCard(in: viewModel.cachedTimelineItems)
        XCTAssertEqual(card?.thinking, "round2")
        XCTAssertEqual(card?.createdAt, answer2.createdAt)
    }

    /// The memoized value must equal a FRESH resolution even after the step keeps
    /// running past the answer — the candidates at or before the answer are frozen.
    /// The oracle is the verbatim resolver over the live conversation, computed here.
    ///
    /// The step already carries post-answer turns (and an `updatedAt` stamped after
    /// them) at the FIRST rebuild — the one that POPULATES the memo — so the anchor
    /// matters at population time. With the post-answer turns appended only after
    /// the first rebuild, a memo anchored on `step.updatedAt` also read "pre-answer"
    /// and the mutation below stayed green (measured: M12 of the 2026-09-04 matrix).
    ///
    /// RED: memoize under the legacy anchor (`step.updatedAt`) instead of
    /// `answerMsg.createdAt` inside the `compute` closure → the memo is populated
    /// with "post-answer 1", so `first` is not "pre-answer" and, after the append,
    /// the hit disagrees with the fresh oracle.
    func testEscalationThinkingMemo_valueEqualsFreshResolution_afterPostAnswerTurnsAppend() {
        // Construction order IS timestamp order: `LLMMessage.init` stamps `createdAt`
        // from `MonotonicClock`, so the pre-answer turn must be built before the answer
        // and the post-answer turns after it.
        let preAnswer = LLMMessage(role: .assistant, content: "Idle.", thinking: "pre-answer")
        let answer = LLMMessage(role: .user, content: "Supervisor answer: go", sourceContext: .supervisorAnswer)
        func postAnswerTurn(_ turn: Int) -> LLMMessage {
            LLMMessage(role: .assistant, content: "turn \(turn)", thinking: "post-answer \(turn)")
        }
        var step = settledEscalationStep(
            id: "r1", messages: [preAnswer, answer, postAnswerTurn(0), postAnswerTurn(1)],
            answer: "go", updatedAt: MonotonicClock.shared.now())
        viewModel.rebuildTimeline(steps: [step], run: nil, activeTaskID: 1, debugModeEnabled: false, isStreaming: { _ in false })
        let first = escalationCard(in: viewModel.cachedTimelineItems)?.thinking
        XCTAssertEqual(first, "pre-answer", "the memo is populated with the answer-anchored value")

        for turn in 2..<5 { step.llmConversation.append(postAnswerTurn(turn)) }
        step.updatedAt = MonotonicClock.shared.now()
        viewModel.rebuildTimeline(steps: [step], run: nil, activeTaskID: 1, debugModeEnabled: false, isStreaming: { _ in false })

        let fresh = ThinkingResolver(conversation: step.llmConversation).thinking(atOrBefore: answer.createdAt)
        let memoized = escalationCard(in: viewModel.cachedTimelineItems)?.thinking
        XCTAssertEqual(fresh, "pre-answer", "oracle sanity")
        XCTAssertEqual(memoized, fresh)
        XCTAssertEqual(memoized, first, "unchanged from the first rebuild")
    }

    /// RED: remove the two `removeAll()` lines from `resetForTaskSwitch` → both
    /// counters read 0 on the second pass.
    func testResetForTaskSwitch_clearsAskIndexAndThinkingMemo() {
        let roles = [makeRole(id: "r1"), makeRole(id: "r2")]
        let parked = parkedStepWithoutAsk(id: "r1", toolCallCount: 64)
        let settled = settledEscalationStep(
            id: "r2",
            messages: [
                LLMMessage(createdAt: date(50), role: .assistant, content: "Idle.", thinking: "T1"),
                LLMMessage(createdAt: date(200), role: .user, content: "Supervisor answer: go", sourceContext: .supervisorAnswer),
            ],
            answer: "go", updatedAt: date(210))
        let context = makeContext(run: Run(id: 0, steps: [parked, settled]), roles: roles)

        viewModel.recomputeAndRebuild(context: context)
        AskCallIndexProbe.reset()
        ThinkingResolverBuildProbe.reset()
        // A second pass that REALLY rebuilds: `composerVisible` is a fingerprint
        // component, so flipping it defeats the short-circuit while leaving the
        // steps identical. (`debugModeEnabled` is not in the fingerprint — a pass
        // that only flipped it never rebuilt, and `builds == 0` was vacuous for the
        // memo; measured by the M10 mutation reading 1 red where 2 were predicted.)
        var warm = context
        warm.composerVisible = false
        viewModel.recomputeAndRebuild(context: warm)
        XCTAssertGreaterThan(viewModel.timelineVersion, 1, "anti-vacuum: the warm pass rebuilt")
        XCTAssertEqual(AskCallIndexProbe.examined(), 0, "anti-vacuum: warm caches examine nothing")
        XCTAssertEqual(ThinkingResolverBuildProbe.builds(), 0, "anti-vacuum: warm memo builds nothing")

        viewModel.resetForTaskSwitch()
        AskCallIndexProbe.reset()
        ThinkingResolverBuildProbe.reset()
        viewModel.recomputeAndRebuild(context: context)

        XCTAssertEqual(AskCallIndexProbe.examined(), parked.toolCalls.count, "the index was rebuilt from scratch")
        XCTAssertEqual(ThinkingResolverBuildProbe.builds(), 1, "the card's thinking was re-resolved")
    }

    /// The two runtime caches are keyed by `TaskStepKey`, so a descendant's entries
    /// survive only as long as the feed walks that descendant. When the walked set
    /// shrinks (a child unloads) `pruneRuntimeCaches` drops its entries — otherwise
    /// the dictionaries grow with every descendant the feed ever showed.
    ///
    /// Eviction is proved by the work that re-appears: after the descendant is
    /// walked again, its 64-call array is rescanned in full and its escalation
    /// card's thinking is re-resolved — both would be cache hits had the entries
    /// survived. Probes are snapshotted BEFORE the pass that does the work.
    ///
    /// RED: replace the body of `pruneRuntimeCaches(walkedTaskIDs:)` with `return`
    /// (never prune) → both counters read 0 on the third pass.
    func testRecomputeAndRebuild_descendantUnloaded_dropsItsCacheEntries() {
        let roles = [makeRole(id: "r1"), makeRole(id: "r2")]
        let activeRun = Run(id: 0, steps: [makeStep(roleDefinitionID: "r1")])
        let child = makeDescendant(
            taskID: 7, roles: roles,
            run: Run(id: 0, steps: [parkedStepWithoutAsk(id: "r1", toolCallCount: 64), warmableSettledStep()]))
        let withChild = makeContext(run: activeRun, roles: roles, descendants: [child])
        let withoutChild = makeContext(run: activeRun, roles: roles)

        AskCallIndexProbe.reset()
        ThinkingResolverBuildProbe.reset()
        viewModel.recomputeAndRebuild(context: withChild)
        XCTAssertEqual(AskCallIndexProbe.examined(), 64, "anti-vacuum: the child's array is scanned once")
        XCTAssertEqual(ThinkingResolverBuildProbe.builds(), 1, "anti-vacuum: the child's card is resolved once")

        // The child unloads: the walked set shrinks to the active task alone.
        viewModel.recomputeAndRebuild(context: withoutChild)

        // It comes back: its entries must be gone, so the work is paid again.
        AskCallIndexProbe.reset()
        ThinkingResolverBuildProbe.reset()
        viewModel.recomputeAndRebuild(context: withChild)
        XCTAssertEqual(AskCallIndexProbe.examined(), 64, "the child's ask index was evicted and rebuilt")
        XCTAssertEqual(ThinkingResolverBuildProbe.builds(), 1, "the child's thinking memo was evicted and re-resolved")
    }

    /// The steady-state tick: the same active task and the same descendant walked
    /// twice keep both caches warm — an unchanged walked set never prunes.
    ///
    /// RED: drop the `guard walkedTaskIDs != cachedWalkedTaskIDs` line AND replace
    /// the two `filter` predicates with `false` (prune everything on every tick) →
    /// the second pass rescans 64 and resolves 1.
    func testRecomputeAndRebuild_sameWalkedSet_keepsWarmCaches() {
        let roles = [makeRole(id: "r1"), makeRole(id: "r2")]
        let activeRun = Run(id: 0, steps: [makeStep(roleDefinitionID: "r1")])
        let child = makeDescendant(
            taskID: 7, roles: roles,
            run: Run(id: 0, steps: [parkedStepWithoutAsk(id: "r1", toolCallCount: 64), warmableSettledStep()]))
        let context = makeContext(run: activeRun, roles: roles, descendants: [child])
        viewModel.recomputeAndRebuild(context: context)
        let version = viewModel.timelineVersion

        AskCallIndexProbe.reset()
        ThinkingResolverBuildProbe.reset()
        // A pass that REALLY rebuilds (see `testResetForTaskSwitch_clearsAskIndexAndThinkingMemo`).
        var again = context
        again.composerVisible = false
        viewModel.recomputeAndRebuild(context: again)

        XCTAssertGreaterThan(viewModel.timelineVersion, version, "anti-vacuum: the second pass rebuilt")
        XCTAssertEqual(AskCallIndexProbe.examined(), 0, "the child's ask index stayed warm")
        XCTAssertEqual(ThinkingResolverBuildProbe.builds(), 0, "the child's thinking memo stayed warm")
    }

    /// A settled escalation step whose card has exactly one thinking candidate.
    private func warmableSettledStep() -> StepExecution {
        settledEscalationStep(
            id: "r2",
            messages: [
                LLMMessage(createdAt: date(50), role: .assistant, content: "Idle.", thinking: "T1"),
                LLMMessage(createdAt: date(200), role: .user, content: "Supervisor answer: go", sourceContext: .supervisorAnswer),
            ],
            answer: "go", updatedAt: date(210))
    }

    /// A delegated child of the active task (`activeTaskID` is `Int()` == 0 in
    /// `makeContext`). Its steps share ids with the parent's on purpose —
    /// `StepExecution.id` is the role id (CLAUDE.md invariant #5).
    private func makeDescendant(
        taskID: Int, roles: [TeamRoleDefinition], run: Run
    ) -> ActivityFeedBuilder.DescendantTask {
        ActivityFeedBuilder.DescendantTask(
            task: NTMSTask(
                id: taskID, title: "Child", supervisorTask: "G", runs: [run],
                parentTaskID: 0, parentRoleID: "r1", delegationDepth: 1),
            run: run,
            teamRoles: roles,
            teamName: "Startup",
            delegationDepth: 1,
            delegatedFromRoleName: "Role r1"
        )
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: offset)
    }

    /// A step parked by a cap: flag set, stored question, NO `ask_supervisor` call.
    private func parkedStepWithoutAsk(id: String, toolCallCount: Int) -> StepExecution {
        StepExecution(
            id: id, role: .custom(id: id), title: "Parked", status: .needsSupervisorInput,
            toolCalls: (0..<toolCallCount).map { _ in StepToolCall(name: "read_file", argumentsJSON: "{}") },
            needsSupervisorInput: true, supervisorQuestion: "cap"
        )
    }

    /// An answered escalation: no ask calls, flag cleared, question + answer set.
    private func settledEscalationStep(
        id: String, messages: [LLMMessage], answer: String, updatedAt: Date
    ) -> StepExecution {
        StepExecution(
            id: id, role: .custom(id: id), title: "Settled", status: .running, updatedAt: updatedAt,
            toolCalls: [], needsSupervisorInput: false,
            supervisorQuestion: "Idle — waiting for events.", supervisorAnswer: answer,
            llmConversation: messages
        )
    }

    private func escalationCard(
        in items: [ActivityFeedBuilder.TaggedItem]
    ) -> (thinking: String?, createdAt: Date)? {
        for tagged in items {
            if case let .notification(_, _, .supervisorInput(_, _, _, _, _, thinking, _), createdAt, _) = tagged.item {
                return (thinking, createdAt)
            }
        }
        return nil
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
        debug: Bool = false,
        descendants: [ActivityFeedBuilder.DescendantTask] = []
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
            isStreaming: { _ in false },
            descendantTasks: descendants
        )
    }

    // MARK: - D-24: how many FULL rebuilds does one turn actually cost?

    /// A deterministic model of ONE tool-loop turn, driving the same VM entry points the
    /// view drives, and counting the rebuilds that are actually performed.
    ///
    /// This is the measurement DEBTS.md D-24 asked for and could not have: it prescribed
    /// "a rebuild counter on a real headless run", but `run_headless.sh` drives an XCTest
    /// that never mounts SwiftUI — `TeamActivityFeedViewModel` is never instantiated
    /// there and the count would read 0. The instrument had to be deterministic and
    /// in-process, and the counter had to be separate from `timelineVersion` so that
    /// gating a path could not turn the coalescing pin vacuously green.
    ///
    /// Events per turn, in the order the orchestrator produces them:
    ///  1. `beginStreaming` — pre-creates the assistant message (`runDataVersion` moves)
    ///     AND creates a preview (`structuralVersion` moves → debounced schedule)
    ///  2. `commitStreaming` — re-stamps the message (`runDataVersion`) AND removes the
    ///     preview (`structuralVersion` → a second debounced schedule)
    ///  3. `appendToolCalls` — tool call count moves
    ///  4. the tool-result message lands
    func testOneTurn_performedRebuildCount() async {
        let role = makeRole(id: "r1")
        var step = makeStep(roleDefinitionID: "r1")
        step.status = .running
        var run = Run(id: 0, steps: [step])

        func context(_ run: Run) -> TeamActivityFeedViewModel.BuildContext {
            makeContext(run: run, roles: [role])
        }
        func mutateStep(_ body: (inout StepExecution) -> Void) {
            var s = run.steps[0]
            body(&s)
            run.steps[0] = s
        }

        // Seed: the feed is already showing this run.
        viewModel.recomputeAndRebuild(context: context(run))
        TimelineRebuildProbe.reset()

        // 1. beginStreaming
        mutateStep { $0.llmConversation.append(
            LLMMessage(role: .assistant, content: "")) }
        viewModel.recomputeAndRebuild(context: context(run))
        viewModel.scheduleStructuralRebuild(context: context(run), delayMilliseconds: 10)

        // 2. commitStreaming
        mutateStep { $0.llmConversation[0] = LLMMessage(role: .assistant, content: "hello") }
        viewModel.recomputeAndRebuild(context: context(run))
        viewModel.scheduleStructuralRebuild(context: context(run), delayMilliseconds: 10)

        // 3. appendToolCalls
        mutateStep { $0.toolCalls.append(
            StepToolCall(name: "read_file", argumentsJSON: "{}")) }
        viewModel.recomputeAndRebuild(context: context(run))

        // 4. tool result
        mutateStep { $0.llmConversation.append(
            LLMMessage(role: .tool, content: "result")) }
        viewModel.recomputeAndRebuild(context: context(run))

        try? await Task.sleep(for: .milliseconds(200))
        let performed = TimelineRebuildProbe.performed()

        XCTAssertGreaterThan(
            performed, 0,
            "anti-vacuum: if a turn costs zero rebuilds the model above is not driving the "
                + "VM at all, and every bound asserted here is meaningless")
        // Recorded rather than merely bounded: the point of the measurement is the NUMBER,
        // and a bound with no recorded value is what let D-24 carry an estimate for a day.
        XCTAssertLessThanOrEqual(
            performed, 5,
            "one turn performed \(performed) full timeline rebuilds. Each walks every "
                + "message, tool call, artifact, meeting turn and change request of the "
                + "displayed run plus every loaded descendant, and sorts with a comparator "
                + "that calls an escaping isStreaming closure twice per comparison")
    }

}
