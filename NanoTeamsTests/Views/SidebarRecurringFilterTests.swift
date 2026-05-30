import XCTest

@testable import NanoTeams

/// The sidebar "Recurring" filter (icon-only chip) and its `filteredTasks` logic.
@MainActor
final class SidebarRecurringFilterTests: XCTestCase {

    var state: TaskManagementState!

    override func setUp() {
        super.setUp()
        state = TaskManagementState()
    }

    override func tearDown() {
        state = nil
        super.tearDown()
    }

    private func item(_ id: Int, recurring: Bool, status: TaskStatus = .running) -> SidebarTaskItem {
        SidebarTaskItem(id: id, title: "T\(id)", status: status, updatedAt: Date(), isRecurring: recurring)
    }

    func testRecurringFilter_keepsOnlyRecurring_regardlessOfStatus() {
        let items = [
            item(1, recurring: true),
            item(2, recurring: false),
            item(3, recurring: true, status: .done),
        ]
        state.taskFilter = .recurring
        XCTAssertEqual(Set(state.filteredTasks(from: items).map(\.id)), [1, 3])
    }

    func testAllFilter_keepsEverything() {
        let items = [item(1, recurring: true), item(2, recurring: false)]
        state.taskFilter = .all
        XCTAssertEqual(state.filteredTasks(from: items).count, 2)
    }

    func testSearch_overridesRecurringFilter() {
        let items = [item(1, recurring: true), item(2, recurring: false)]
        state.taskFilter = .recurring
        state.taskSearchText = "T2"
        XCTAssertEqual(state.filteredTasks(from: items).map(\.id), [2], "search spans all tasks, ignoring the filter tab")
    }

    func testRecurringFilter_metadata() {
        XCTAssertTrue(TaskFilter.recurring.isIconOnly, "recurring is an icon-only chip")
        XCTAssertFalse(TaskFilter.all.isIconOnly)
        XCTAssertEqual(TaskFilter.recurring.icon, "repeat")
        XCTAssertEqual(TaskFilter.recurring.displayName, "Recurring")
    }
}
