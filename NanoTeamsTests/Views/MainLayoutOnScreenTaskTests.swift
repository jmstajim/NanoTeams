import XCTest

@testable import NanoTeams

/// `MainLayoutView.onScreenTaskID` — the mirror that tells `PrefixCacheReporter` which task the
/// user is actually LOOKING at.
///
/// Worth its own pin because the alternative it replaced (`NTMSOrchestrator.activeTaskID`) is
/// "last task ever opened", is never reset to nil, and is written by the Autovisor pane's own
/// `switchTask(to:)` — so a manager waking every 60 s would banner about its cache misses while
/// the user sat on the Watchtower.
@MainActor
final class MainLayoutOnScreenTaskTests: XCTestCase {

    private let managerID = 99

    func testTaskDestination_mirrorsThatTask() {
        XCTAssertEqual(
            MainLayoutView.onScreenTaskID(for: .task(7), autovisorTaskID: managerID), 7)
    }

    /// The manager's chat is a real on-screen task even though it is hidden from every task
    /// enumeration — while the user is reading it, its misses are the ones worth a banner.
    func testAutovisorDestination_mirrorsTheManagerTask() {
        XCTAssertEqual(
            MainLayoutView.onScreenTaskID(for: .autovisor, autovisorTaskID: managerID), managerID)
    }

    /// Before `ensureAutovisorTask` has run there is no manager task to mirror.
    func testAutovisorDestination_beforeTheManagerExists_isNil() {
        XCTAssertNil(MainLayoutView.onScreenTaskID(for: .autovisor, autovisorTaskID: nil))
    }

    /// The Watchtower is nobody's task. A banner fired here would be about work the user is not
    /// looking at.
    func testWatchtowerAndNoSelection_areNotATask() {
        XCTAssertNil(
            MainLayoutView.onScreenTaskID(for: .watchtower, autovisorTaskID: managerID))
        XCTAssertNil(MainLayoutView.onScreenTaskID(for: nil, autovisorTaskID: managerID))
    }
}
