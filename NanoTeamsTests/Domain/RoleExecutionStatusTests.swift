import XCTest
@testable import NanoTeams

final class RoleExecutionStatusTests: XCTestCase {

    // MARK: - Display Name Tests

    func testDisplayName_AllCases() {
        XCTAssertEqual(RoleExecutionStatus.idle.displayName, "Standby")
        XCTAssertEqual(RoleExecutionStatus.ready.displayName, "Ready")
        XCTAssertEqual(RoleExecutionStatus.working.displayName, "Working")
        XCTAssertEqual(RoleExecutionStatus.needsAcceptance.displayName, "Needs Review")
        XCTAssertEqual(RoleExecutionStatus.accepted.displayName, "Accepted")
        XCTAssertEqual(RoleExecutionStatus.revisionRequested.displayName, "Revision Requested")
        XCTAssertEqual(RoleExecutionStatus.done.displayName, "Done")
        XCTAssertEqual(RoleExecutionStatus.failed.displayName, "Failed")
        XCTAssertEqual(RoleExecutionStatus.skipped.displayName, "Skipped")
    }

    // MARK: - Icon Tests

    func testIcon_AllCases() {
        XCTAssertEqual(RoleExecutionStatus.idle.icon, "circle")
        XCTAssertEqual(RoleExecutionStatus.ready.icon, "circle.lefthalf.filled")
        XCTAssertEqual(RoleExecutionStatus.working.icon, "arrow.triangle.2.circlepath")
        XCTAssertEqual(RoleExecutionStatus.needsAcceptance.icon, "hand.raised.circle.fill")
        XCTAssertEqual(RoleExecutionStatus.accepted.icon, "checkmark.circle")
        XCTAssertEqual(RoleExecutionStatus.revisionRequested.icon, "arrow.counterclockwise")
        XCTAssertEqual(RoleExecutionStatus.done.icon, "checkmark.circle.fill")
        XCTAssertEqual(RoleExecutionStatus.failed.icon, "xmark.circle")
        XCTAssertEqual(RoleExecutionStatus.skipped.icon, "forward.circle")
    }

    // MARK: - isActive Tests

    func testIsActive_Working() {
        XCTAssertTrue(RoleExecutionStatus.working.isActive)
    }

    func testIsActive_NeedsAcceptance() {
        XCTAssertTrue(RoleExecutionStatus.needsAcceptance.isActive)
    }

    func testIsActive_RevisionRequested() {
        XCTAssertTrue(RoleExecutionStatus.revisionRequested.isActive)
    }

    func testIsActive_Idle() {
        XCTAssertFalse(RoleExecutionStatus.idle.isActive)
    }

    func testIsActive_Ready() {
        XCTAssertFalse(RoleExecutionStatus.ready.isActive)
    }

    func testIsActive_Accepted() {
        XCTAssertFalse(RoleExecutionStatus.accepted.isActive)
    }

    func testIsActive_Done() {
        XCTAssertFalse(RoleExecutionStatus.done.isActive)
    }

    func testIsActive_Failed() {
        XCTAssertFalse(RoleExecutionStatus.failed.isActive)
    }

    func testIsActive_Skipped() {
        XCTAssertFalse(RoleExecutionStatus.skipped.isActive)
    }

    // MARK: - isComplete Tests

    func testIsComplete_Accepted() {
        XCTAssertTrue(RoleExecutionStatus.accepted.isComplete)
    }

    func testIsComplete_Done() {
        XCTAssertTrue(RoleExecutionStatus.done.isComplete)
    }

    func testIsComplete_Skipped() {
        XCTAssertTrue(RoleExecutionStatus.skipped.isComplete)
    }

    func testIsComplete_Idle() {
        XCTAssertFalse(RoleExecutionStatus.idle.isComplete)
    }

    func testIsComplete_Ready() {
        XCTAssertFalse(RoleExecutionStatus.ready.isComplete)
    }

    func testIsComplete_Working() {
        XCTAssertFalse(RoleExecutionStatus.working.isComplete)
    }

    func testIsComplete_NeedsAcceptance() {
        XCTAssertFalse(RoleExecutionStatus.needsAcceptance.isComplete)
    }

    func testIsComplete_RevisionRequested() {
        XCTAssertFalse(RoleExecutionStatus.revisionRequested.isComplete)
    }

    func testIsComplete_Failed() {
        XCTAssertFalse(RoleExecutionStatus.failed.isComplete)
    }

    // MARK: - requiresSupervisorAttention Tests

    func testRequiresSupervisorAttention_NeedsAcceptance() {
        XCTAssertTrue(RoleExecutionStatus.needsAcceptance.requiresSupervisorAttention)
    }

    func testRequiresSupervisorAttention_Failed() {
        XCTAssertTrue(RoleExecutionStatus.failed.requiresSupervisorAttention)
    }

    func testRequiresSupervisorAttention_Idle() {
        XCTAssertFalse(RoleExecutionStatus.idle.requiresSupervisorAttention)
    }

    func testRequiresSupervisorAttention_Ready() {
        XCTAssertFalse(RoleExecutionStatus.ready.requiresSupervisorAttention)
    }

    func testRequiresSupervisorAttention_Working() {
        XCTAssertFalse(RoleExecutionStatus.working.requiresSupervisorAttention)
    }

    func testRequiresSupervisorAttention_Accepted() {
        XCTAssertFalse(RoleExecutionStatus.accepted.requiresSupervisorAttention)
    }

    func testRequiresSupervisorAttention_RevisionRequested() {
        XCTAssertFalse(RoleExecutionStatus.revisionRequested.requiresSupervisorAttention)
    }

    func testRequiresSupervisorAttention_Done() {
        XCTAssertFalse(RoleExecutionStatus.done.requiresSupervisorAttention)
    }

    func testRequiresSupervisorAttention_Skipped() {
        XCTAssertFalse(RoleExecutionStatus.skipped.requiresSupervisorAttention)
    }

    // MARK: - canStart Tests

    func testCanStart_Ready() {
        XCTAssertTrue(RoleExecutionStatus.ready.canStart)
    }

    func testCanStart_RevisionRequested() {
        XCTAssertTrue(RoleExecutionStatus.revisionRequested.canStart)
    }

    func testCanStart_Idle() {
        XCTAssertFalse(RoleExecutionStatus.idle.canStart)
    }

    func testCanStart_Working() {
        XCTAssertFalse(RoleExecutionStatus.working.canStart)
    }

    func testCanStart_NeedsAcceptance() {
        XCTAssertFalse(RoleExecutionStatus.needsAcceptance.canStart)
    }

    func testCanStart_Accepted() {
        XCTAssertFalse(RoleExecutionStatus.accepted.canStart)
    }

    func testCanStart_Done() {
        XCTAssertFalse(RoleExecutionStatus.done.canStart)
    }

    func testCanStart_Failed() {
        XCTAssertFalse(RoleExecutionStatus.failed.canStart)
    }

    func testCanStart_Skipped() {
        XCTAssertFalse(RoleExecutionStatus.skipped.canStart)
    }

    // MARK: - Codable Tests

    func testCodable_AllCases() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for status in RoleExecutionStatus.allCases {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(RoleExecutionStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    func testCodable_RawValueEncoding() throws {
        let encoder = JSONEncoder()

        let data = try encoder.encode(RoleExecutionStatus.needsAcceptance)
        let jsonString = String(data: data, encoding: .utf8)

        XCTAssertEqual(jsonString, "\"needsAcceptance\"")
    }

    // MARK: - Hashable Tests

    func testHashable_Set() {
        let statuses: Set<RoleExecutionStatus> = [.idle, .ready, .working, .done]

        XCTAssertEqual(statuses.count, 4)
        XCTAssertTrue(statuses.contains(.idle))
        XCTAssertTrue(statuses.contains(.ready))
        XCTAssertTrue(statuses.contains(.working))
        XCTAssertTrue(statuses.contains(.done))
    }

    func testHashable_Dictionary() {
        var counts: [RoleExecutionStatus: Int] = [:]
        counts[.working] = 5
        counts[.done] = 10

        XCTAssertEqual(counts[.working], 5)
        XCTAssertEqual(counts[.done], 10)
        XCTAssertNil(counts[.idle])
    }

    // MARK: - CaseIterable Tests

    func testCaseIterable_AllCases() {
        let allCases = RoleExecutionStatus.allCases

        XCTAssertEqual(allCases.count, 9)
        XCTAssertTrue(allCases.contains(.idle))
        XCTAssertTrue(allCases.contains(.ready))
        XCTAssertTrue(allCases.contains(.working))
        XCTAssertTrue(allCases.contains(.needsAcceptance))
        XCTAssertTrue(allCases.contains(.accepted))
        XCTAssertTrue(allCases.contains(.revisionRequested))
        XCTAssertTrue(allCases.contains(.done))
        XCTAssertTrue(allCases.contains(.failed))
        XCTAssertTrue(allCases.contains(.skipped))
    }

    // MARK: - State Transition Logic Tests

    func testStateTransitions_NormalFlow() {
        // Test that logical state transitions are possible
        let startState = RoleExecutionStatus.idle
        XCTAssertFalse(startState.canStart) // Can't start from idle

        let readyState = RoleExecutionStatus.ready
        XCTAssertTrue(readyState.canStart) // Can start from ready

        let workingState = RoleExecutionStatus.working
        XCTAssertTrue(workingState.isActive) // Is active while working

        let doneState = RoleExecutionStatus.done
        XCTAssertTrue(doneState.isComplete) // Is complete when done
    }

    func testStateTransitions_AcceptanceFlow() {
        let needsAcceptance = RoleExecutionStatus.needsAcceptance
        XCTAssertTrue(needsAcceptance.isActive)
        XCTAssertTrue(needsAcceptance.requiresSupervisorAttention)
        XCTAssertFalse(needsAcceptance.isComplete)

        let accepted = RoleExecutionStatus.accepted
        XCTAssertFalse(accepted.isActive)
        XCTAssertTrue(accepted.isComplete)

        let revisionRequested = RoleExecutionStatus.revisionRequested
        XCTAssertTrue(revisionRequested.isActive)
        XCTAssertTrue(revisionRequested.canStart)
    }

    func testStateTransitions_FailureFlow() {
        let failed = RoleExecutionStatus.failed
        XCTAssertFalse(failed.isActive)
        XCTAssertFalse(failed.isComplete)
        XCTAssertFalse(failed.canStart)
        XCTAssertTrue(failed.requiresSupervisorAttention)
    }

    func testStateTransitions_SkippedFlow() {
        let skipped = RoleExecutionStatus.skipped
        XCTAssertFalse(skipped.isActive)
        XCTAssertTrue(skipped.isComplete)
        XCTAssertFalse(skipped.canStart)
        XCTAssertTrue(skipped.canRestart, "Skipped roles should be restartable via Restart Role")
        XCTAssertFalse(skipped.requiresSupervisorAttention)
    }
}

// MARK: - ConnectionStatus Tests

final class ConnectionStatusTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(ConnectionStatus.waiting.rawValue, "waiting")
        XCTAssertEqual(ConnectionStatus.satisfied.rawValue, "satisfied")
        XCTAssertEqual(ConnectionStatus.error.rawValue, "error")
    }

    func testIsDashed() {
        XCTAssertTrue(ConnectionStatus.waiting.isDashed)
        XCTAssertFalse(ConnectionStatus.satisfied.isDashed)
        XCTAssertTrue(ConnectionStatus.error.isDashed)
    }

    func testCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for status in [ConnectionStatus.waiting, .satisfied, .error] {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(ConnectionStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    func testHashable() {
        let statuses: Set<ConnectionStatus> = [.waiting, .satisfied, .error]
        XCTAssertEqual(statuses.count, 3)
    }
}
