import XCTest

@testable import NanoTeams

/// Pins `ScrollFollowState` — the feed's bottom-follow bookkeeping, moved out of four `@State`
/// values on 2026-09-15 so a geometry tick stops scheduling SwiftUI transactions. Until then the
/// settle timing had no test at all.
@MainActor
final class ScrollFollowStateTests: XCTestCase {

    var sut: ScrollFollowState!

    override func setUp() async throws {
        try await super.setUp()
        sut = ScrollFollowState()
    }

    override func tearDown() async throws {
        sut?.resetForTaskSwitch()
        sut = nil
        try await super.tearDown()
    }

    private static let start = Date(timeIntervalSince1970: 1_000_000)

    private func delay(afterBurstStartMs ms: Double) -> Int {
        ScrollFollowState.settleDelayMs(now: Self.start.addingTimeInterval(ms / 1000), burstStart: Self.start)
    }

    // MARK: - Settle timing

    func testSettleDelay_isTheQuietWindow_atTheStartOfABurst() async {
        XCTAssertEqual(delay(afterBurstStartMs: 0), 70)
        XCTAssertEqual(delay(afterBurstStartMs: 100), 70, "quiet window still ends before the cap")
    }

    /// RED: drop the max-wait cap → continuous streaming (a geometry tick every few ms) keeps
    /// pushing the scroll 70 ms out and the feed never follows.
    func testSettleDelay_isCappedByTheBurstMaxWait() async {
        XCTAssertEqual(delay(afterBurstStartMs: 200), 20)
        XCTAssertEqual(delay(afterBurstStartMs: 219), 1)
    }

    func testSettleDelay_neverGoesNegative() async {
        XCTAssertEqual(delay(afterBurstStartMs: 220), 0)
        XCTAssertEqual(delay(afterBurstStartMs: 5_000), 0)
    }

    func testTuning_isTheDocumentedValues() async {
        XCTAssertEqual(ScrollFollowState.gateReleaseDelayMs, 160)
        XCTAssertEqual(ScrollFollowState.scrollSettleQuietMs, 70)
        XCTAssertEqual(ScrollFollowState.scrollSettleMaxWaitMs, 220)
    }

    // MARK: - Settle decision

    func testSettleScroll_whenNotPinned_doesNothing() async {
        for target in [nil, 400] as [CGFloat?] {
            for distance in [nil, 0, 300] as [CGFloat?] {
                XCTAssertNil(ScrollFollowState.settleScroll(
                    isNearBottom: false, bottomTargetY: target, distanceFromBottom: distance))
            }
        }
    }

    /// A fresh task switch has no target yet: edge-scroll, even if a distance reads 0.
    func testSettleScroll_withoutATarget_edgeScrolls() async {
        XCTAssertEqual(ScrollFollowState.settleScroll(isNearBottom: true, bottomTargetY: nil, distanceFromBottom: nil),
                       .toBottomEdge)
        XCTAssertEqual(ScrollFollowState.settleScroll(isNearBottom: true, bottomTargetY: nil, distanceFromBottom: 0),
                       .toBottomEdge)
    }

    /// RED: drop the settled-distance guard → a feed already at its bottom writes the scroll
    /// position on every settle, which is a transaction and a scroll commit per geometry burst.
    func testSettleScroll_alreadyAtTheBottom_doesNothing() async {
        for distance in [0, 0.5, -0.5, 0.3] as [CGFloat] {
            XCTAssertNil(ScrollFollowState.settleScroll(isNearBottom: true, bottomTargetY: 400, distanceFromBottom: distance),
                         "distance \(distance)")
        }
    }

    /// The `insTop` undershoot that once latched follow off leaves the distance at the full top
    /// inset — far above the settled band — so the corrective scroll still fires.
    func testSettleScroll_offTheBottom_scrollsToTheTarget() async {
        for distance in [0.6, -0.6, 79, -550] as [CGFloat] {
            XCTAssertEqual(ScrollFollowState.settleScroll(isNearBottom: true, bottomTargetY: 400, distanceFromBottom: distance),
                           .toY(400), "distance \(distance)")
        }
        XCTAssertEqual(ScrollFollowState.settleScroll(isNearBottom: true, bottomTargetY: 400, distanceFromBottom: nil),
                       .toY(400), "no distance measured yet — scroll rather than assume")
    }

    // MARK: - Lifecycle

    /// RED: cancel `gateReleaseTask` without clearing it → the handle stays non-nil and the
    /// geometry action (`gateReleaseTask == nil`) never schedules another release.
    func testCancelPending_cancelsAndClearsBothTasks_butKeepsTheGeometry() async {
        let settle = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        let gate = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        sut.scrollSettleTask = settle
        sut.gateReleaseTask = gate
        sut.settleBurstStart = Self.start
        sut.lastBottomTargetY = 400
        sut.lastDistanceFromBottom = 12

        sut.cancelPending()

        XCTAssertTrue(settle.isCancelled)
        XCTAssertTrue(gate.isCancelled)
        XCTAssertNil(sut.scrollSettleTask)
        XCTAssertNil(sut.gateReleaseTask)
        XCTAssertNil(sut.settleBurstStart)
        XCTAssertEqual(sut.lastBottomTargetY, 400)
        XCTAssertEqual(sut.lastDistanceFromBottom, 12)
    }

    /// The pin `TeamActivityFeedContainerInvariantTests` used to hold on a `@State` literal: a
    /// task switch clears the stashed target, so the next task's first settle edge-scrolls.
    func testResetForTaskSwitch_clearsTheStashedGeometry() async {
        sut.lastBottomTargetY = 400
        sut.lastDistanceFromBottom = 12
        sut.gateReleaseTask = Task<Void, Never> {}
        sut.resetForTaskSwitch()
        XCTAssertNil(sut.lastBottomTargetY)
        XCTAssertNil(sut.lastDistanceFromBottom)
        XCTAssertNil(sut.gateReleaseTask)
        XCTAssertEqual(
            ScrollFollowState.settleScroll(isNearBottom: true, bottomTargetY: sut.lastBottomTargetY,
                                           distanceFromBottom: sut.lastDistanceFromBottom),
            .toBottomEdge)
    }
}
