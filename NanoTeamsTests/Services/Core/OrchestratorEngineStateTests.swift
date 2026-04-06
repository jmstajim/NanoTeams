import XCTest
@testable import NanoTeams

@MainActor
final class OrchestratorEngineStateTests: XCTestCase {

    var sut: OrchestratorEngineState!
    let taskID = 0

    override func setUp() {
        super.setUp()
        sut = OrchestratorEngineState()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - isEngineActive

    func testIsEngineActive_noState_returnsFalse() {
        XCTAssertFalse(sut.isEngineActive(for: taskID))
    }

    func testIsEngineActive_running_returnsTrue() {
        sut[taskID] = .running
        XCTAssertTrue(sut.isEngineActive(for: taskID))
    }

    func testIsEngineActive_paused_returnsTrue() {
        sut[taskID] = .paused
        XCTAssertTrue(sut.isEngineActive(for: taskID))
    }

    func testIsEngineActive_needsSupervisorInput_returnsTrue() {
        sut[taskID] = .needsSupervisorInput
        XCTAssertTrue(sut.isEngineActive(for: taskID))
    }

    func testIsEngineActive_needsAcceptance_returnsTrue() {
        sut[taskID] = .needsAcceptance
        XCTAssertTrue(sut.isEngineActive(for: taskID))
    }

    func testIsEngineActive_pending_returnsFalse() {
        sut[taskID] = .pending
        XCTAssertFalse(sut.isEngineActive(for: taskID))
    }

    func testIsEngineActive_done_returnsFalse() {
        sut[taskID] = .done
        XCTAssertFalse(sut.isEngineActive(for: taskID))
    }

    func testIsEngineActive_failed_returnsFalse() {
        sut[taskID] = .failed
        XCTAssertFalse(sut.isEngineActive(for: taskID))
    }

    // MARK: - isNewRunBlocked

    func testIsNewRunBlocked_noState_returnsFalse() {
        XCTAssertFalse(sut.isNewRunBlocked(for: taskID))
    }

    func testIsNewRunBlocked_running_returnsTrue() {
        sut[taskID] = .running
        XCTAssertTrue(sut.isNewRunBlocked(for: taskID))
    }

    func testIsNewRunBlocked_needsSupervisorInput_returnsTrue() {
        sut[taskID] = .needsSupervisorInput
        XCTAssertTrue(sut.isNewRunBlocked(for: taskID))
    }

    func testIsNewRunBlocked_needsAcceptance_returnsTrue() {
        sut[taskID] = .needsAcceptance
        XCTAssertTrue(sut.isNewRunBlocked(for: taskID))
    }

    func testIsNewRunBlocked_paused_returnsFalse() {
        sut[taskID] = .paused
        XCTAssertFalse(sut.isNewRunBlocked(for: taskID))
    }

    func testIsNewRunBlocked_pending_returnsFalse() {
        sut[taskID] = .pending
        XCTAssertFalse(sut.isNewRunBlocked(for: taskID))
    }

    func testIsNewRunBlocked_done_returnsFalse() {
        sut[taskID] = .done
        XCTAssertFalse(sut.isNewRunBlocked(for: taskID))
    }

    func testIsNewRunBlocked_failed_returnsFalse() {
        sut[taskID] = .failed
        XCTAssertFalse(sut.isNewRunBlocked(for: taskID))
    }

    // MARK: - Key difference: paused

    func testPausedState_isActive_butDoesNotBlockNewRun() {
        sut[taskID] = .paused
        XCTAssertTrue(sut.isEngineActive(for: taskID), "Paused engine is still active")
        XCTAssertFalse(sut.isNewRunBlocked(for: taskID), "Paused engine should NOT block new run")
    }
}
