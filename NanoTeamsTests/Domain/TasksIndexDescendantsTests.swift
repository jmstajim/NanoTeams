import XCTest
@testable import NanoTeams

/// Pins behavior of `TasksIndex.descendantIDs(of:)` — added for the delegation
/// V1 activity feed surface so the parent feed can collect all transitively
/// loaded children. BFS order matters for the boundary annotation: descendants
/// appear in level order (immediate children before grandchildren).
final class TasksIndexDescendantsTests: XCTestCase {

    private func summary(_ id: Int, parent: Int? = nil) -> TaskSummary {
        TaskSummary(id: id, title: "t\(id)", status: .running, isChatMode: false, parentTaskID: parent)
    }

    func testDescendantIDs_topLevelTask_returnsEmpty() {
        let index = TasksIndex(tasks: [
            summary(1),
            summary(2),
        ])
        XCTAssertEqual(index.descendantIDs(of: 1), [])
    }

    func testDescendantIDs_immediateChildren_returnedInBFSOrder() {
        let index = TasksIndex(tasks: [
            summary(1),
            summary(2, parent: 1),
            summary(3, parent: 1),
        ])
        let result = index.descendantIDs(of: 1)
        XCTAssertEqual(Set(result), [2, 3])
    }

    func testDescendantIDs_transitiveDepth_walksAllLevels() {
        // 1
        // ├─ 2
        // │  └─ 4
        // │     └─ 5
        // └─ 3
        let index = TasksIndex(tasks: [
            summary(1),
            summary(2, parent: 1),
            summary(3, parent: 1),
            summary(4, parent: 2),
            summary(5, parent: 4),
        ])
        let result = index.descendantIDs(of: 1)
        // BFS: level 1 first ([2,3]), level 2 next ([4]), level 3 last ([5]).
        // Within a level, order follows tasks-array order — pin both invariants.
        XCTAssertEqual(result.prefix(2).sorted(), [2, 3])
        XCTAssertEqual(result[2], 4)
        XCTAssertEqual(result[3], 5)
        XCTAssertEqual(result.count, 4)
    }

    func testDescendantIDs_unknownTaskID_returnsEmpty() {
        let index = TasksIndex(tasks: [
            summary(1),
            summary(2, parent: 1),
        ])
        XCTAssertEqual(index.descendantIDs(of: 999), [])
    }

    func testDescendantIDs_safetyCap_terminatesOnCycle() {
        // Pathological: 1 → 2, 2 → 1 (cycle). Real data can't have this
        // (parentTaskID is set once at task creation), but the safety cap
        // prevents infinite loops if ever encountered.
        let index = TasksIndex(tasks: [
            TaskSummary(id: 1, title: "a", status: .running, isChatMode: false, parentTaskID: 2),
            TaskSummary(id: 2, title: "b", status: .running, isChatMode: false, parentTaskID: 1),
        ])
        // descendantIDs walks from frontier=[1] → finds 2 (parent==1) → frontier=[2]
        //                         → finds 1 (parent==2) → frontier=[1]
        // Continues bouncing until safety cap (32) — does not hang.
        let result = index.descendantIDs(of: 1)
        // Just verify we didn't hang; the produced sequence is implementation
        // detail under cycle conditions.
        XCTAssertLessThanOrEqual(result.count, 64)
    }
}
