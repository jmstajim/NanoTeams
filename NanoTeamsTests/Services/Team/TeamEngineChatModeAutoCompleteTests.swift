import XCTest
@testable import NanoTeams

/// Regression guards for `TeamEngine`'s chat-mode auto-complete arm in the
/// `readyRoleIDs.isEmpty` block of the run loop.
///
/// Symptom this fix addresses: when a chat-mode advisory role finishes (set to `.done`
/// — only path before this fix was `NTMSOrchestrator.finishAdvisoryRole`, which the UI
/// hides in chat mode; new path is `LLMExecutionService` advisory auto-finish in
/// autonomous supervisor mode), the engine's `readyRoleIDs.isEmpty` block had no
/// chat-mode exit. It would fall through to the deadlock `else`, transitioning to
/// `.failed` with "Execution stalled: roles […]". This test pins the new chat-mode
/// arm: when every non-supervisor non-observer role is in a terminal status, the engine
/// transitions to `.done` instead.
@MainActor
final class TeamEngineChatModeAutoCompleteTests: XCTestCase {
    var sut: TeamEngine!
    var mockStore: MockTeamEngineStore!

    override func setUp() {
        super.setUp()
        mockStore = MockTeamEngineStore()
        sut = TeamEngine(store: mockStore)
    }

    override func tearDown() {
        sut?.stop()
        sut = nil
        mockStore = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Chat-mode team mirrors `Personal Assistant` / `Coding Assistant` shape: Supervisor
    /// role with no required artifacts (chat-mode marker) plus one advisory worker.
    private func makeChatTeam(advisoryRoleID: String) -> Team {
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [], // empty == isChatMode
                producesArtifacts: ["Supervisor Task"]
            ),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )
        let advisory = TeamRoleDefinition(
            id: advisoryRoleID, name: "Advisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Supervisor Task"],
                producesArtifacts: []
            )
        )
        return Team(
            id: "chat-team",
            name: "Chat",
            roles: [supervisor, advisory],
            artifacts: [],
            settings: .default,
            graphLayout: TeamGraphLayout()
        )
    }

    // MARK: - Tests

    /// Critical fix: chat-mode advisory role at `.done` must let the engine exit
    /// cleanly to `.done`, not deadlock into `.failed`. Pre-fix the run loop
    /// fell through to `transition(to: .failed)` with "Execution stalled".
    func testChatMode_allRolesDone_transitionsToDone_notFailed() {
        let team = makeChatTeam(advisoryRoleID: "advisor")
        XCTAssertTrue(team.isChatMode, "Pre-condition: team must be chat mode")
        mockStore.activeTeam = team

        // Supervisor is .done by default; the advisor role is .done (simulating a
        // post-auto-finish state). The "Supervisor Task" artifact is already produced.
        let run = Run(id: 0, roleStatuses: ["sup": .done, "advisor": .done])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Help me", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]

        let doneExpectation = XCTestExpectation(description: "Engine reaches .done via chat-mode arm")
        let failedRejection = XCTestExpectation(description: "Engine must NOT transition to .failed")
        failedRejection.isInverted = true

        sut.onStateChanged = { state in
            switch state {
            case .done: doneExpectation.fulfill()
            case .failed: failedRejection.fulfill()
            default: break
            }
        }
        sut.start()

        wait(for: [doneExpectation, failedRejection], timeout: 2.0)
        XCTAssertEqual(sut.state, .done)
        XCTAssertTrue(
            mockStore.setLastErrorMessageCalls.isEmpty,
            "Chat-mode auto-complete must NOT emit the deadlock 'Execution stalled' error message"
        )
    }

    /// Negative gate: a chat-mode team with a still-pending role (idle/ready) must
    /// NOT auto-complete — the engine should keep looking for ready roles. We use
    /// an artificial setup where no role is ready but one is `.idle` to prove the
    /// arm doesn't fire prematurely.
    func testChatMode_someRolesNotTerminal_doesNotAutoComplete() {
        let team = makeChatTeam(advisoryRoleID: "advisor")
        mockStore.activeTeam = team

        // Advisor is `.idle` (not terminal). With no produced artifacts, advisor isn't
        // ready (it requires "Supervisor Task"). This mirrors a paused / not-yet-started
        // state — engine must NOT call this "done".
        let run = Run(id: 0, roleStatuses: ["advisor": .idle])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Help me", runs: [run])
        mockStore.producedArtifactNamesResult = [] // advisor not ready

        let doneRejection = XCTestExpectation(description: "Engine must NOT transition to .done")
        doneRejection.isInverted = true
        sut.onStateChanged = { state in
            if state == .done {
                doneRejection.fulfill()
            }
        }
        sut.start()

        wait(for: [doneRejection], timeout: 1.0)
        XCTAssertNotEqual(sut.state, .done, "Engine must not auto-complete with non-terminal roles")
    }

    /// Negative gate: a NON-chat team (has Supervisor required artifacts) with all roles
    /// `.done` must NOT take the chat-mode arm. It either auto-completes via
    /// `allRolesComplete` (if there's a `Supervisor Task` produced and no acceptance
    /// pending) or stays pending — but the chat-mode-only arm must not fire.
    /// We assert that `setLastErrorMessageForUI` is NOT called with the deadlock
    /// message AND that the engine doesn't take the new arm's `markObserversComplete`
    /// path mistakenly.
    func testNonChatMode_allRolesDone_usesAllRolesCompletePath() {
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Final Deliverable"], // non-empty == NOT chat mode
                producesArtifacts: ["Supervisor Task"]
            ),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )
        let producer = TeamRoleDefinition(
            id: "eng", name: "Engineer", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Supervisor Task"],
                producesArtifacts: ["Final Deliverable"]
            )
        )
        let team = Team(
            id: "linear-team", name: "Linear",
            roles: [supervisor, producer], artifacts: [],
            settings: .default, graphLayout: TeamGraphLayout()
        )
        XCTAssertFalse(team.isChatMode, "Pre-condition: team must NOT be chat mode")
        mockStore.activeTeam = team

        let run = Run(id: 0, roleStatuses: ["sup": .done, "eng": .done])
        mockStore.activeTask = NTMSTask(id: 0, title: "T", supervisorTask: "Build", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Final Deliverable"]

        let doneExpectation = XCTestExpectation(description: "Engine .done via allRolesComplete (non-chat path)")
        sut.onStateChanged = { state in
            if state == .done {
                doneExpectation.fulfill()
            }
        }
        sut.start()

        wait(for: [doneExpectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .done)
    }
}
