import XCTest
@testable import NanoTeams

/// Structural pin: the activity feed's timeline container must be a plain
/// (non-lazy) `VStack`, never `LazyVStack`.
///
/// Why (2026-07-07, two live blank-feed reproductions): `LazyVStack`
/// ESTIMATES unrealized row heights from the average of realized ones. One
/// >viewport realized row (a long supervisor brief or LLM message) skews
/// every estimate 4-12x (trace: ~2200px/item vs ~186px real). The feed's
/// bottom-pin then `scrollTo(y:)`s the offset into estimated "phantom"
/// space where no realized row exists — a blank feed. From scroll geometry
/// alone that state is indistinguishable from the user scrolling up
/// (distance-from-bottom large positive), so the follow gate releases and
/// nothing recovers until a manual scroll forces realization. A plain
/// `VStack` realizes every row: contentSize is always exact and phantom
/// space cannot exist.
///
/// The container choice lives inside a `some View` body — not reachable by
/// behavioral XCTest — so this pins the SOURCE, mirroring the
/// structural-pin approach of `PromptTemplateEditorLagInvariantTests`.
/// If a future perf pass needs virtualization back, it must solve the
/// phantom-space problem first (see docs/activity-feed-scroll-investigation.md)
/// and then update this pin deliberately.
final class TeamActivityFeedContainerInvariantTests: XCTestCase {

    private func feedViewSource() throws -> String {
        // NanoTeamsTests/Views/<this file> → repo root → production file.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Views/
            .deletingLastPathComponent() // NanoTeamsTests/
            .deletingLastPathComponent() // repo root
        let production = repoRoot
            .appendingPathComponent("NanoTeams/Views/TeamBoard/TeamActivityFeedView.swift")
        return try String(contentsOf: production, encoding: .utf8)
    }

    func testTimelineFeed_doesNotUseLazyVStack() throws {
        let source = try feedViewSource()
        XCTAssertFalse(
            source.contains("LazyVStack("),
            "TeamActivityFeedView must not construct a LazyVStack — its unrealized-row height estimation strands the bottom-pinned offset in phantom space (blank feed). See the container comment in timelineScrollView and docs/activity-feed-scroll-investigation.md."
        )
    }

    /// Rows are not timelines. Until 2026-09-15 every message bubble — committed ones too — sat
    /// inside `TimelineView(BubbleSchedule)`, which ties a non-lazy feed of rows to the graph's
    /// clock; `LiveMessageBubble` polls only while its message streams.
    ///
    /// Also carries the structural-identity guarantee `BubbleScheduleStructuralIdentityTests`
    /// used to pin through the schedule type: `MessageBubbleView` is built in exactly ONE place,
    /// outside any conditional, so the streaming → committed flip never remounts its NSTextView.
    ///
    /// RED: wrap the bubble back in a `TimelineView` → the first assertion fails. Split the
    /// bubble into a streaming and a committed `MessageBubbleView` → the count fails. Put the one
    /// construction behind an `if` → the conditional check fails.
    func testMessageBubbles_areNotTimelines_andKeepOneUnconditionalSlot() throws {
        let feed = try feedViewSource()
        XCTAssertFalse(feed.contains("TimelineView("),
                       "TeamActivityFeedView must not put feed rows in a TimelineView.")
        XCTAssertEqual(feed.components(separatedBy: "LiveMessageBubble(").count - 1, 1,
                       "Every LLM message must render through exactly one LiveMessageBubble site.")

        let bubble = try source("NanoTeams/Views/TeamBoard/ActivityFeed/LiveMessageBubble.swift")
        let code = RatchetSourceScan.strippingLineComments(bubble)
        XCTAssertFalse(code.contains("TimelineView("), "LiveMessageBubble must poll, not follow a timeline.")
        XCTAssertEqual(code.components(separatedBy: "MessageBubbleView(").count - 1, 1,
                       "MessageBubbleView must be constructed exactly once, or the flip remounts it.")
        guard let body = RatchetSourceScan.functionBody(after: "var body: some View", in: code) else {
            return XCTFail("LiveMessageBubble.body not found — re-aim this pin, do not delete it")
        }
        for conditional in ["if ", "switch ", "? MessageBubbleView"] {
            XCTAssertFalse(body.contains(conditional),
                           "LiveMessageBubble.body contains `\(conditional)` — the bubble's slot must be unconditional.")
        }
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: RatchetSourceScan.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The sibling half of the fix: a settle-scroll must never apply a
    /// bottom target stashed from the PREVIOUS task's geometry. The stash
    /// is `Optional` and cleared on task switch; the settle falls back to
    /// an edge-scroll when no tick has run yet.
    ///
    /// Retargeted 2026-09-15: the stash moved from a `@State` in the view into
    /// `ScrollFollowState` (a geometry tick writing `@State` scheduled a transaction per
    /// tick). The clearing is behaviour now and is also pinned by
    /// `ScrollFollowStateTests.testResetForTaskSwitch_clearsTheStashedGeometry`; this pin keeps
    /// the WIRING — the view must call the reset on task switch.
    func testFeed_bottomTargetStash_isOptionalAndClearedOnTaskSwitch() throws {
        let state = try source("NanoTeams/Views/TeamBoard/ScrollFollowState.swift")
        XCTAssertTrue(
            state.contains("var lastBottomTargetY: CGFloat?"),
            "lastBottomTargetY must be Optional — a non-optional stash survives task switches and flies the offset past a shorter feed's end."
        )
        XCTAssertTrue(
            state.contains("lastBottomTargetY = nil"),
            "ScrollFollowState.resetForTaskSwitch must clear the stashed bottom target."
        )
        let feed = RatchetSourceScan.strippingLineComments(try feedViewSource())
        XCTAssertTrue(feed.contains(".onChange(of: store.activeTaskID)"),
                      "anti-vacuum: the feed's task-switch onChange is gone — re-aim this pin")
        XCTAssertTrue(feed.contains("scrollFollow.resetForTaskSwitch()"),
                      "Task switch must call `scrollFollow.resetForTaskSwitch()` in the feed view.")
        XCTAssertFalse(feed.contains("@State private var lastBottomTargetY"),
                       "The bottom target is back in @State — every geometry tick schedules a transaction again.")
    }
}
