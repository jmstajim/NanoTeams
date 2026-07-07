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

    /// The sibling half of the fix: a settle-scroll must never apply a
    /// bottom target stashed from the PREVIOUS task's geometry. The stash
    /// is `Optional` and cleared on task switch; the settle falls back to
    /// an edge-scroll when no tick has run yet.
    func testFeed_bottomTargetStash_isOptionalAndClearedOnTaskSwitch() throws {
        let source = try feedViewSource()
        XCTAssertTrue(
            source.contains("@State private var lastBottomTargetY: CGFloat?"),
            "lastBottomTargetY must be Optional — a non-optional stash survives task switches and flies the offset past a shorter feed's end."
        )
        XCTAssertTrue(
            source.contains("lastBottomTargetY = nil"),
            "Task switch must clear the stashed bottom target."
        )
    }
}
