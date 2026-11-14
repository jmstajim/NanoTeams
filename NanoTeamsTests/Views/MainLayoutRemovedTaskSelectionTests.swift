import XCTest

@testable import NanoTeams

/// `MainLayoutView.selection(_:afterTaskListChange:)` — where the board goes when the folder's
/// task list changes under it. A task removed by someone other than this window's sidebar (an
/// external agent's `control_task delete`, the manager's) left the selection on the removed id,
/// and the detail kept a loader up for a task that would never load (D-M18, 2026-11-12).
@MainActor
final class MainLayoutRemovedTaskSelectionTests: XCTestCase {

    func testSelectedTaskNoLongerListed_fallsBackToTheWatchtower() {
        XCTAssertEqual(MainLayoutView.selection(.task(22)) { $0 == 18 }, .watchtower)
    }

    func testSelectedTaskStillListed_staysSelected() {
        XCTAssertEqual(MainLayoutView.selection(.task(18)) { $0 == 18 }, .task(18))
    }

    func testNonTaskDestinations_areNeverMoved() {
        XCTAssertEqual(MainLayoutView.selection(.autovisor) { _ in false }, .autovisor)
        XCTAssertEqual(MainLayoutView.selection(.watchtower) { _ in false }, .watchtower)
        XCTAssertNil(MainLayoutView.selection(nil) { _ in false })
    }

    /// An empty list — the folder closed, or its last task removed — moves a task selection too.
    func testEmptyList_movesATaskSelection() {
        XCTAssertEqual(MainLayoutView.selection(.task(1)) { _ in false }, .watchtower)
    }
}
