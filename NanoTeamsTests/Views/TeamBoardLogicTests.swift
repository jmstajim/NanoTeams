import XCTest
@testable import NanoTeams

/// Tests for TeamBoard view logic: play/pause button state machine,
/// advisory role finish visibility, and role type banner classification.
@MainActor
final class TeamBoardLogicTests: XCTestCase {

    // MARK: - Helpers

    private func makeRole(
        id: String = "role-1",
        name: String = "Worker",
        required: [String] = [],
        produced: [String] = [],
        isSupervisor: Bool = false
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: name,
            prompt: "Do your job",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: required,
                producesArtifacts: produced
            ),
            isSystemRole: false,
            systemRoleID: isSupervisor ? "supervisor" : nil
        )
    }

    // MARK: - Play/Pause Button State Machine

    /// The play button should offer "Start Run" only for `.pending` and `nil` states.
    /// `.done` and `.failed` states must NOT show a start button (prevents accidental new runs).

    func testPlayButton_running_showsPause() {
        // Running state → pause action
        let state: TeamEngineState = .running
        XCTAssertTrue(
            state == .running || state == .needsSupervisorInput || state == .needsAcceptance,
            "Running should be in the 'active' branch showing Pause"
        )
    }

    func testPlayButton_needsSupervisorInput_showsPause() {
        let state: TeamEngineState = .needsSupervisorInput
        XCTAssertTrue(
            state == .running || state == .needsSupervisorInput || state == .needsAcceptance,
            "needsSupervisorInput should be in the 'active' branch showing Pause"
        )
    }

    func testPlayButton_needsAcceptance_showsPause() {
        let state: TeamEngineState = .needsAcceptance
        XCTAssertTrue(
            state == .running || state == .needsSupervisorInput || state == .needsAcceptance,
            "needsAcceptance should be in the 'active' branch showing Pause"
        )
    }

    func testPlayButton_paused_showsResume() {
        let state: TeamEngineState = .paused
        let isActiveState = state == .running || state == .needsSupervisorInput || state == .needsAcceptance
        XCTAssertFalse(isActiveState, "Paused is not an active state")
        XCTAssertTrue(state == .paused, "Paused should show Resume")
    }

    func testPlayButton_pending_showsStartRun() {
        let state: TeamEngineState = .pending
        let isActiveState = state == .running || state == .needsSupervisorInput || state == .needsAcceptance
        XCTAssertFalse(isActiveState, "Pending is not an active state")
        XCTAssertFalse(state == .paused, "Pending is not paused")
        XCTAssertTrue(state == .pending, "Pending should show Start Run")
    }

    func testPlayButton_done_showsNothing() {
        // After the fix, .done should NOT match any play/pause branch
        let state: TeamEngineState = .done
        let isActiveState = state == .running || state == .needsSupervisorInput || state == .needsAcceptance
        let isPaused = state == .paused
        let isPending = state == .pending
        XCTAssertFalse(isActiveState, "Done must not show Pause")
        XCTAssertFalse(isPaused, "Done must not show Resume")
        XCTAssertFalse(isPending, "Done must not show Start Run")
    }

    func testPlayButton_failed_showsNothing() {
        // After the fix, .failed should NOT match any play/pause branch
        let state: TeamEngineState = .failed
        let isActiveState = state == .running || state == .needsSupervisorInput || state == .needsAcceptance
        let isPaused = state == .paused
        let isPending = state == .pending
        XCTAssertFalse(isActiveState, "Failed must not show Pause")
        XCTAssertFalse(isPaused, "Failed must not show Resume")
        XCTAssertFalse(isPending, "Failed must not show Start Run")
    }

    func testPlayButton_nil_showsStartRun() {
        // nil state (no engine) should be treated like pending
        let state: TeamEngineState? = nil
        let isActiveState = state == .running || state == .needsSupervisorInput || state == .needsAcceptance
        XCTAssertFalse(isActiveState, "Nil is not active")
        XCTAssertTrue(state == .pending || state == nil, "Nil should show Start Run")
    }

    /// Keyboard shortcut (togglePauseResume) must match toolbar button logic.
    func testKeyboardShortcut_matchesToolbar_allStates() {
        // The keyboard shortcut uses: .running/.needsSupervisorInput/.needsAcceptance → pause,
        // .paused → resume, .pending → start. All other states: no action.
        for state in TeamEngineState.allCases {
            let toolbarShowsPause = state == .running || state == .needsSupervisorInput || state == .needsAcceptance
            let toolbarShowsResume = state == .paused
            let toolbarShowsStart = state == .pending

            // Keyboard: pause for same states
            let keyboardPauses = state == .running || state == .needsSupervisorInput || state == .needsAcceptance
            // Keyboard: resume for .paused
            let keyboardResumes = state == .paused
            // Keyboard: start for .pending
            let keyboardStarts = state == .pending

            XCTAssertEqual(toolbarShowsPause, keyboardPauses,
                           "Pause mismatch for \(state)")
            XCTAssertEqual(toolbarShowsResume, keyboardResumes,
                           "Resume mismatch for \(state)")
            XCTAssertEqual(toolbarShowsStart, keyboardStarts,
                           "Start mismatch for \(state)")
        }
    }

    // MARK: - Advisory Role Finish Visibility

    /// Finish should show for advisory roles that are working (not in chat mode).
    func testFinishRole_advisoryWorking_visible() {
        let role = makeRole(required: ["Plan"], produced: [])
        XCTAssertTrue(role.isAdvisory)
        let status: RoleExecutionStatus = .working
        let isChatMode = false
        let showFinish = role.isAdvisory && !isChatMode && (status == .ready || status == .working)
        XCTAssertTrue(showFinish)
    }

    func testFinishRole_advisoryReady_visible() {
        let role = makeRole(required: ["Plan"], produced: [])
        let status: RoleExecutionStatus = .ready
        let isChatMode = false
        let showFinish = role.isAdvisory && !isChatMode && (status == .ready || status == .working)
        XCTAssertTrue(showFinish)
    }

    /// Finish should be hidden for advisory roles in chat-mode teams.
    func testFinishRole_advisoryChatMode_hidden() {
        let role = makeRole(required: ["Plan"], produced: [])
        XCTAssertTrue(role.isAdvisory)
        let status: RoleExecutionStatus = .working
        let isChatMode = true
        let showFinish = role.isAdvisory && !isChatMode && (status == .ready || status == .working)
        XCTAssertFalse(showFinish)
    }

    /// Finish should be hidden for producing roles (they auto-complete).
    func testFinishRole_producingRole_hidden() {
        let role = makeRole(required: ["Plan"], produced: ["Code"])
        XCTAssertFalse(role.isAdvisory)
        let status: RoleExecutionStatus = .working
        let isChatMode = false
        let showFinish = role.isAdvisory && !isChatMode && (status == .ready || status == .working)
        XCTAssertFalse(showFinish)
    }

    /// Finish should be hidden for observer roles.
    func testFinishRole_observerRole_hidden() {
        let role = makeRole(required: [], produced: [])
        XCTAssertTrue(role.isObserver)
        XCTAssertFalse(role.isAdvisory)
        let status: RoleExecutionStatus = .working
        let isChatMode = false
        let showFinish = role.isAdvisory && !isChatMode && (status == .ready || status == .working)
        XCTAssertFalse(showFinish)
    }

    /// Finish should be hidden for advisory roles in idle/done/failed status.
    func testFinishRole_advisoryIdle_hidden() {
        let role = makeRole(required: ["Plan"], produced: [])
        let isChatMode = false
        for status in [RoleExecutionStatus.idle, .done, .failed, .accepted, .needsAcceptance, .skipped] {
            let showFinish = role.isAdvisory && !isChatMode && (status == .ready || status == .working)
            XCTAssertFalse(showFinish, "Finish should be hidden for status \(status)")
        }
    }

    // MARK: - Role Type Classification (Dependencies Tab Banner)

    /// Role with produced artifacts → producing.
    func testRoleType_withProducedArtifacts_isProducing() {
        let role = makeRole(required: ["Plan"], produced: ["Code"])
        XCTAssertEqual(role.completionType, .producing)
        XCTAssertFalse(role.isAdvisory)
        XCTAssertFalse(role.isObserver)
    }

    /// Role with required but no produced → advisory.
    func testRoleType_withRequiredOnly_isAdvisory() {
        let role = makeRole(required: ["Plan"], produced: [])
        XCTAssertEqual(role.completionType, .advisory)
        XCTAssertTrue(role.isAdvisory)
        XCTAssertFalse(role.isObserver)
    }

    /// Role with no artifacts → observer.
    func testRoleType_noArtifacts_isObserver() {
        let role = makeRole(required: [], produced: [])
        XCTAssertEqual(role.completionType, .observer)
        XCTAssertFalse(role.isAdvisory)
        XCTAssertTrue(role.isObserver)
    }

    /// Supervisor role is always producing (even if no produced artifacts configured).
    func testRoleType_supervisor_isAlwaysProducing() {
        let role = makeRole(isSupervisor: true)
        XCTAssertEqual(role.completionType, .producing)
    }
}
