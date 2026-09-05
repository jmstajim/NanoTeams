import XCTest
@testable import NanoTeams

/// User-path: delegated child tasks are stored under their parent's directory tree
/// at `.nanoteams/tasks/{parentID}/subtasks/{childID}/...` (and recursively for
/// deeper chains). Top-level tasks remain at the original flat layout.
@MainActor
final class NestedTaskStorageTests: XCTestCase {

    var workFolderRoot: URL!
    var repository: NTMSRepository!
    var paths: NTMSPaths!

    override func setUp() async throws {
        try await super.setUp()
        workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-nested-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        repository = NTMSRepository()
        paths = NTMSPaths(workFolderRoot: workFolderRoot)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workFolderRoot)
        repository = nil
        paths = nil
        workFolderRoot = nil
        try await super.tearDown()
    }

    // MARK: - Path computation

    func testPaths_topLevel_isFlat() {
        let url = paths.taskDir(taskID: 7)
        XCTAssertEqual(
            url.path,
            paths.tasksDir.appendingPathComponent("7", isDirectory: true).path,
            "Top-level task path is `.nanoteams/tasks/7/`"
        )
    }

    func testPaths_oneLevelChild_nestsUnderParent() {
        let url = paths.taskDir(taskID: 12, ancestors: [7])
        XCTAssertEqual(
            url.path,
            paths.tasksDir.appendingPathComponent("7", isDirectory: true)
                .appendingPathComponent("subtasks", isDirectory: true)
                .appendingPathComponent("12", isDirectory: true).path,
            "Child path is `.nanoteams/tasks/7/subtasks/12/`"
        )
    }

    func testPaths_twoLevelGrandchild_nestsRecursively() {
        let url = paths.taskDir(taskID: 33, ancestors: [7, 12])
        XCTAssertEqual(
            url.path,
            paths.tasksDir.appendingPathComponent("7", isDirectory: true)
                .appendingPathComponent("subtasks", isDirectory: true)
                .appendingPathComponent("12", isDirectory: true)
                .appendingPathComponent("subtasks", isDirectory: true)
                .appendingPathComponent("33", isDirectory: true).path,
            "Grandchild path is `.nanoteams/tasks/7/subtasks/12/subtasks/33/`"
        )
    }

    func testPaths_runDir_nestsUnderTaskPath() {
        let url = paths.runDir(taskID: 12, runID: 0, ancestors: [7])
        XCTAssertTrue(url.path.contains("/tasks/7/subtasks/12/runs/0"),
                      "Run directories live under nested task paths: \(url.path)")
    }

    func testPaths_internalTaskDir_nestsUnderInternalTree() {
        let url = paths.internalTaskDir(taskID: 12, ancestors: [7])
        XCTAssertEqual(
            url.path,
            paths.internalTasksDir.appendingPathComponent("7", isDirectory: true)
                .appendingPathComponent("subtasks", isDirectory: true)
                .appendingPathComponent("12", isDirectory: true).path,
            "Internal nesting mirrors public nesting under .nanoteams/internal/tasks/"
        )
    }

    // MARK: - TasksIndex.ancestorIDs

    func testAncestorIDs_topLevel_isEmpty() {
        var index = TasksIndex()
        index.tasks = [TaskSummary(id: 1, title: "Top", status: .running)]
        XCTAssertEqual(index.ancestorIDs(of: 1), [])
    }

    func testAncestorIDs_oneLevelChild_returnsParent() {
        var index = TasksIndex()
        index.tasks = [
            TaskSummary(id: 1, title: "Parent", status: .running, parentTaskID: nil),
            TaskSummary(id: 2, title: "Child", status: .running, parentTaskID: 1),
        ]
        XCTAssertEqual(index.ancestorIDs(of: 2), [1])
    }

    func testAncestorIDs_grandchild_returnsRootFirst() {
        var index = TasksIndex()
        index.tasks = [
            TaskSummary(id: 1, title: "Root", status: .running, parentTaskID: nil),
            TaskSummary(id: 2, title: "Mid", status: .running, parentTaskID: 1),
            TaskSummary(id: 3, title: "Leaf", status: .running, parentTaskID: 2),
        ]
        XCTAssertEqual(index.ancestorIDs(of: 3), [1, 2],
                       "Ancestor chain is root-first, excluding self.")
    }

    func testAncestorIDs_unknownTask_returnsEmpty() {
        let index = TasksIndex()
        XCTAssertEqual(index.ancestorIDs(of: 999), [],
                       "Unknown task ID treated as top-level.")
    }

    func testAncestorIDs_safetyCap_breaksCycles() {
        // Defensive: a malformed index with a cycle should not infinite-loop.
        var index = TasksIndex()
        index.tasks = [
            TaskSummary(id: 1, title: "A", status: .running, parentTaskID: 2),
            TaskSummary(id: 2, title: "B", status: .running, parentTaskID: 1),
        ]
        // The 32-step safety cap prevents infinite recursion; we just check it terminates.
        let chain = index.ancestorIDs(of: 1)
        XCTAssertLessThanOrEqual(chain.count, 32, "Safety cap kicks in on cycles.")
    }

    // MARK: - parentLinks / childLinks (id-keyed hop maps)

    /// A corrupted index can carry two rows with one id. `tasks.first(where:)`
    /// resolves the FIRST row — including a first row whose parent is nil — and
    /// the links map must reproduce that exactly, or the two spellings of the
    /// walk would nest one task's storage at two different paths.
    ///
    /// RED: build `parentLinks()` with a plain `links[s.id] = pid` assignment
    /// (last-wins, or first-non-nil-wins) → the nil-first fixture returns [1].
    func testParentLinks_duplicateID_firstOccurrenceWins_evenWhenFirstHasNoParent() {
        var index = TasksIndex()
        index.tasks = [
            TaskSummary(id: 1, title: "Root", status: .running, parentTaskID: nil),
            TaskSummary(id: 5, title: "First (top-level)", status: .running, parentTaskID: nil),
            TaskSummary(id: 5, title: "Duplicate (claims a parent)", status: .running, parentTaskID: 1),
        ]
        XCTAssertEqual(index.ancestorIDs(of: 5), [],
                       "legacy walk: first(where:) sees the nil-parent row")
        XCTAssertEqual(index.ancestorIDs(of: 5, links: index.parentLinks()), [],
                       "links walk must agree with first-occurrence-wins")

        // The fused builder `updateTaskOnly` feeds from: same map, plus the row slot.
        // RED: capture `position` OUTSIDE the `seen.insert(...).inserted` guard (last
        // occurrence wins) → this reads 2, and upsert(_:at:) would replace the wrong row.
        let located = index.parentLinks(locating: 5)
        XCTAssertEqual(located.links, index.parentLinks(),
                       "the fused builder hands back the same hop map")
        XCTAssertEqual(located.position, 1,
                       "the slot is the FIRST row with that id — the row upsert(_:) would replace")
        XCTAssertNil(index.parentLinks(locating: 9_999).position, "an unknown id has no slot")
        XCTAssertNil(index.parentLinks(locating: nil).position, "and nil asks for none")
        XCTAssertNil(TasksIndex().parentLinks(locating: 1).position, "empty index, no slot")
    }

    func testParentLinks_duplicateID_firstOccurrenceWins_whenFirstHasParent() {
        var index = TasksIndex()
        index.tasks = [
            TaskSummary(id: 1, title: "Root", status: .running, parentTaskID: nil),
            TaskSummary(id: 5, title: "First (child of 1)", status: .running, parentTaskID: 1),
            TaskSummary(id: 5, title: "Duplicate (top-level)", status: .running, parentTaskID: nil),
        ]
        XCTAssertEqual(index.ancestorIDs(of: 5), [1])
        XCTAssertEqual(index.ancestorIDs(of: 5, links: index.parentLinks()), [1])
    }

    /// Reference oracle: the pre-2026-08-21 linear-scan walks, verbatim. The
    /// production wrappers now route through the links bodies, so comparing
    /// wrapper vs links would compare a function with itself — the oracle must
    /// live HERE, independent of production.
    private func oracleAncestorIDs(_ index: TasksIndex, of taskID: Int) -> [Int] {
        var ancestors: [Int] = []
        var visited: Set<Int> = [taskID]
        var current: Int? = index.tasks.first(where: { $0.id == taskID })?.parentTaskID
        var safety = 0
        while let pid = current, safety < DelegationConstants.treeTraversalSafetyCap {
            if visited.contains(pid) { break }
            visited.insert(pid)
            ancestors.insert(pid, at: 0)
            current = index.tasks.first(where: { $0.id == pid })?.parentTaskID
            safety += 1
        }
        return ancestors
    }

    private func oracleDescendantIDs(_ index: TasksIndex, of taskID: Int) -> [Int] {
        var result: [Int] = []
        var visited: Set<Int> = [taskID]
        var frontier: [Int] = [taskID]
        var safety = 0
        while !frontier.isEmpty && safety < DelegationConstants.treeTraversalSafetyCap {
            var next: [Int] = []
            for parentID in frontier {
                for summary in index.tasks where summary.parentTaskID == parentID {
                    if visited.contains(summary.id) { continue }
                    visited.insert(summary.id)
                    result.append(summary.id)
                    next.append(summary.id)
                }
            }
            frontier = next
            safety += 1
        }
        return result
    }

    /// Property parity: on random forests — including a planted cycle and an
    /// over-cap chain — the links-based walk must equal the legacy linear-scan
    /// oracle for EVERY id, in both directions (ancestors and descendants,
    /// including element order).
    func testLinkWalks_parity_randomForestsWithCycleAndOverCapChain() {
        // Deterministic LCG — seeded, no process-random dependence.
        var state: UInt64 = 0x5DEECE66D
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % bound
        }

        for trial in 0..<20 {
            var index = TasksIndex()
            let n = 3 + next(40)
            for id in 0..<n {
                // ~1/3 top-level; otherwise parent is any id (self-links and
                // forward links included — corruption shapes are the point).
                let parent: Int? = next(3) == 0 ? nil : next(n)
                index.tasks.append(TaskSummary(
                    id: id, title: "t\(id)", status: .running, parentTaskID: parent))
            }
            // Planted cycle pair and an over-cap chain tail.
            index.tasks.append(TaskSummary(id: 100, title: "c", status: .running, parentTaskID: 101))
            index.tasks.append(TaskSummary(id: 101, title: "c", status: .running, parentTaskID: 100))
            let chainBase = 200
            for k in 0..<(DelegationConstants.treeTraversalSafetyCap + 5) {
                index.tasks.append(TaskSummary(
                    id: chainBase + k, title: "chain", status: .running,
                    parentTaskID: k == 0 ? nil : chainBase + k - 1))
            }
            // A planted duplicate-id row (corruption shape): the fused position must
            // still name the FIRST row, exactly as `firstIndex(where:)` does.
            index.tasks.append(TaskSummary(id: 0, title: "dup", status: .running, parentTaskID: n - 1))

            let links = index.parentLinks()
            let children = index.childLinks()
            for id in index.tasks.map(\.id) {
                XCTAssertEqual(oracleAncestorIDs(index, of: id), index.ancestorIDs(of: id, links: links),
                               "ancestor parity broke for id \(id) in trial \(trial)")
                XCTAssertEqual(oracleDescendantIDs(index, of: id), index.descendantIDs(of: id, children: children),
                               "descendant parity broke for id \(id) in trial \(trial)")
                let located = index.parentLinks(locating: id)
                XCTAssertEqual(located.links, links,
                               "fused hop map diverged for id \(id) in trial \(trial)")
                XCTAssertEqual(located.position, index.tasks.firstIndex { $0.id == id },
                               "fused position is not firstIndex(where:) for id \(id) in trial \(trial)")
            }
        }
    }

    // MARK: - Repository round-trip

    func testRepository_topLevelCreate_writesAtFlatPath() throws {
        let (_, topTaskID) = try repository.createTask(
            at: workFolderRoot,
            title: "Top Task",
            supervisorTask: "Brief",
            preferredTeamID: nil,
            parentTaskID: nil,
            parentRoleID: nil,
            delegationDepth: 0
        )
        let expectedPath = paths.taskJSON(taskID: topTaskID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPath.path),
                      "Top-level task.json must be at the flat path: \(expectedPath.path)")
    }

    func testRepository_childCreate_writesNestedPath_andDoesNotChangeActiveTask() throws {
        // 1. Top-level parent.
        let (parentSnapshot, parentID) = try repository.createTask(
            at: workFolderRoot,
            title: "Parent",
            supervisorTask: "Build it",
            preferredTeamID: nil,
            parentTaskID: nil,
            parentRoleID: nil,
            delegationDepth: 0
        )
        XCTAssertEqual(parentSnapshot.activeTaskID, parentID,
                       "Top-level task creation makes the new task active.")

        // 2. Delegated child — parentage supplied at creation; activeTaskID should remain parent's.
        let (childSnapshot, childID) = try repository.createTask(
            at: workFolderRoot,
            title: "Delegated",
            supervisorTask: "Sub-brief",
            preferredTeamID: nil,
            parentTaskID: parentID,
            parentRoleID: "pm",
            delegationDepth: 1
        )
        XCTAssertEqual(childSnapshot.activeTaskID, parentID,
                       "Creating a child task must NOT change activeTaskID — supervisor stays focused on parent.")

        // 3. Child's task.json must live at nested path.
        let childPath = paths.taskJSON(taskID: childID, ancestors: [parentID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: childPath.path),
                      "Child task.json must be at nested path: \(childPath.path)")

        // 4. The flat path for the child does NOT exist (we never wrote it there).
        let flatChildPath = paths.taskJSON(taskID: childID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flatChildPath.path),
                       "Child must NOT have a stale flat task.json at \(flatChildPath.path)")

        // 5. Reading the child back via repository preserves parentage.
        let reloaded = try repository.loadTask(at: workFolderRoot, taskID: childID)
        XCTAssertEqual(reloaded.parentTaskID, parentID)
        XCTAssertEqual(reloaded.parentRoleID, "pm")
        XCTAssertEqual(reloaded.delegationDepth, 1)
    }

    func testRepository_deleteParent_recursivelyClearsNestedSubtree() throws {
        // Parent + child setup
        let (_, parentID) = try repository.createTask(
            at: workFolderRoot,
            title: "Parent",
            supervisorTask: "Brief",
            preferredTeamID: nil,
            parentTaskID: nil,
            parentRoleID: nil,
            delegationDepth: 0
        )
        let (_, childID) = try repository.createTask(
            at: workFolderRoot,
            title: "Child",
            supervisorTask: "Sub-brief",
            preferredTeamID: nil,
            parentTaskID: parentID,
            parentRoleID: "pm",
            delegationDepth: 1
        )
        let childPath = paths.taskJSON(taskID: childID, ancestors: [parentID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: childPath.path),
                      "Sanity: child file exists before parent deletion.")

        // Delete parent → entire subtree disappears (rm -rf of parent dir cascades to children).
        _ = try repository.deleteTask(at: workFolderRoot, taskID: parentID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: childPath.path),
                       "Deleting the parent removes the nested child files via tree deletion.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.taskDir(taskID: parentID).path),
                       "Parent's task dir is gone.")
    }
}
