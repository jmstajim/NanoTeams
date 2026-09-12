import XCTest

@testable import NanoTeams

/// The "Queued" projection: the ephemeral set of roles the engine is holding back for want
/// of a concurrency slot, and the seam that carries it from the engine to the graph.
///
/// Modelled on `activeMeetingParticipants` and deliberately NOT a `RoleExecutionStatus` case
/// — that would be persisted into `task.json`, where a build without the case could no longer
/// decode the run at all.
@MainActor
final class QueuedRolesProjectionTests: XCTestCase {

    private var state: OrchestratorEngineState!

    override func setUp() async throws {
        try await super.setUp()
        state = OrchestratorEngineState()
    }

    override func tearDown() async throws {
        state = nil
        try await super.tearDown()
    }

    func testSetQueuedRoles_storesPerTask() {
        state.setQueuedRoles(["a", "b"], for: 1)
        state.setQueuedRoles(["c"], for: 2)

        XCTAssertEqual(state.queuedRoleIDs[1], ["a", "b"])
        XCTAssertEqual(state.queuedRoleIDs[2], ["c"],
                       "keyed by task id — `StepExecution.id == roleID`, so two tasks on one "
                           + "team share every role id (invariant #5)")
    }

    /// The engine asks four times a second while a role waits. An unconditional write would
    /// be four observation ticks a second through every graph node for a value that did not
    /// move (CLAUDE.md #106) — so an unchanged set must not even reach the stored property.
    func testSetQueuedRoles_unchangedSet_leavesTheEntryIdentical() {
        state.setQueuedRoles(["a"], for: 1)
        state.setQueuedRoles(["a"], for: 1)
        XCTAssertEqual(state.queuedRoleIDs[1], ["a"])
    }

    func testSetQueuedRoles_empty_removesTheEntry() {
        state.setQueuedRoles(["a"], for: 1)
        state.setQueuedRoles([], for: 1)
        XCTAssertNil(state.queuedRoleIDs[1], "an empty queue is an ABSENT entry, not an empty set")
    }

    func testSetQueuedRoles_emptyForATaskThatHadNone_isANoOp() {
        state.setQueuedRoles([], for: 7)
        XCTAssertNil(state.queuedRoleIDs[7])
        XCTAssertTrue(state.queuedRoleIDs.isEmpty)
    }

    func testClearQueuedRoles_dropsOnlyThatTask() {
        state.setQueuedRoles(["a"], for: 1)
        state.setQueuedRoles(["b"], for: 2)

        state.clearQueuedRoles(for: 1)

        XCTAssertNil(state.queuedRoleIDs[1])
        XCTAssertEqual(state.queuedRoleIDs[2], ["b"])
    }

    /// Nothing survives the work-folder boundary — `NTMSTask.id` is sequential PER FOLDER, so
    /// a leftover entry would decorate a DIFFERENT task's graph after a switch.
    func testRemoveAllEngines_dropsEveryQueue() {
        state.setQueuedRoles(["a"], for: 1)
        state.setQueuedRoles(["b"], for: 2)

        state.removeAllEngines()

        XCTAssertTrue(state.queuedRoleIDs.isEmpty)
    }
}
