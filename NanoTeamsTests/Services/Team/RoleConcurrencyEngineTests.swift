import XCTest

@testable import NanoTeams

/// The concurrency cap where it meets the engine: who actually gets dispatched, what the
/// waiting roles are published as, and the two ways a naive implementation turns a healthy
/// run into a failure (a false "Execution stalled", and a role that wins the only slot on
/// every pass without ever using it).
@MainActor
final class RoleConcurrencyEngineTests: XCTestCase {

    var sut: TeamEngine!
    var mockStore: MockTeamEngineStore!

    override func setUp() async throws {
        try await super.setUp()
        mockStore = MockTeamEngineStore()
        sut = TeamEngine(store: mockStore)
    }

    override func tearDown() async throws {
        sut.stop()
        sut = nil
        mockStore = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func worker(_ id: String, requires: [String] = ["Supervisor Task"]) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: id.capitalized,
            prompt: "You are \(id).",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: requires, producesArtifacts: ["\(id) Notes"]))
    }

    private func supervisorRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "supervisor-role",
            name: "Supervisor",
            prompt: "You are the Supervisor.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Final Deliverable"], producesArtifacts: ["Supervisor Task"]),
            isSystemRole: true,
            systemRoleID: "supervisor")
    }

    /// Two independent workers, both ready the moment the run starts, and both wired so their
    /// step never finishes — so whatever the first pass dispatches stays dispatched.
    private func seedTwoReadyRoles(cap: Int?) {
        let roles = [supervisorRole(), worker("alpha"), worker("bravo")]
        mockStore.activeTeam = Team(
            name: "Test Team", roles: roles, artifacts: [], settings: .default,
            graphLayout: TeamGraphLayout())
        mockStore.activeTask = NTMSTask(
            id: 0, title: "T", supervisorTask: "Build",
            runs: [Run(id: 0, roleStatuses: ["alpha": .idle, "bravo": .idle])])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]
        mockStore.findOrCreateStepResults = ["alpha": "alpha", "bravo": "bravo"]
        mockStore.stepStatusResults = ["alpha": .running, "bravo": .running]
        mockStore.maxConcurrentRoles = cap
    }

    private func startedRoleIDs() -> [String] {
        mockStore.updateRoleStatusCalls.filter { $0.status == .working }.map(\.roleID)
    }

    @discardableResult
    private func waitUntil(
        _ timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - Dispatch width

    /// The shipping default: unchanged behaviour, both roles at once (CLAUDE.md #45).
    func testProviderLimited_startsEveryReadyRole() async {
        seedTwoReadyRoles(cap: nil)
        sut.start()

        let bothStarted = await waitUntil { self.startedRoleIDs().count == 2 }
        XCTAssertTrue(bothStarted, "got \(startedRoleIDs())")
        XCTAssertEqual(Set(startedRoleIDs()), ["alpha", "bravo"])
    }

    func testCapOfOne_startsExactlyOneOfTwoReadyRoles() async {
        seedTwoReadyRoles(cap: 1)
        sut.start()

        let oneStarted = await waitUntil { self.startedRoleIDs().count == 1 }
        XCTAssertTrue(oneStarted, "got \(startedRoleIDs())")
        // Hold past several dispatch passes (250 ms each) — a cap that only held for the
        // first pass would let the second role in here.
        try? await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(startedRoleIDs(), ["alpha"],
                       "roster order decides who gets the only slot")
    }

    /// The whole point of a separate throttle branch: the `readyRoleIDs.isEmpty` analysis
    /// still sees the UNTRUNCATED list, so a run whose only ready role is waiting for a slot
    /// is never mistaken for a dependency deadlock.
    func testCapOfOne_waitingForASlot_isNotAStall() async {
        seedTwoReadyRoles(cap: 1)
        var terminal: [TeamEngineState] = []
        sut.onStateChanged = { if $0 == .failed || $0 == .done { terminal.append($0) } }
        sut.start()

        try? await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(sut.state, .running)
        XCTAssertTrue(terminal.isEmpty, "got \(terminal)")
        XCTAssertTrue(mockStore.setLastErrorMessageCalls.isEmpty,
                      "got \(mockStore.setLastErrorMessageCalls)")
    }

    // MARK: - The Queued projection

    func testCapOfOne_publishesTheWaitingRoleAsQueued() async {
        seedTwoReadyRoles(cap: 1)
        var published: [Set<String>] = []
        sut.onQueuedRolesChanged = { published.append($0) }
        sut.start()

        let queued = await waitUntil { self.sut.queuedRoleIDs == ["bravo"] }
        XCTAssertTrue(queued, "got \(sut.queuedRoleIDs)")
        XCTAssertEqual(published.last, ["bravo"])
    }

    /// The engine is asked four times a second while a role waits; publishing on every pass
    /// would be four observation ticks a second through every graph node for a value that
    /// did not move (CLAUDE.md #106).
    func testQueue_isPublishedOnlyWhenItChanges() async {
        seedTwoReadyRoles(cap: 1)
        var publishCount = 0
        sut.onQueuedRolesChanged = { _ in publishCount += 1 }
        sut.start()

        let queued = await waitUntil { self.sut.queuedRoleIDs == ["bravo"] }
        XCTAssertTrue(queued)
        let afterFirst = publishCount
        try? await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(publishCount, afterFirst,
                       "the set never changed, so nothing should have been published again")
    }

    func testPause_clearsTheQueue() async {
        seedTwoReadyRoles(cap: 1)
        sut.start()
        let queued = await waitUntil { self.sut.queuedRoleIDs == ["bravo"] }
        XCTAssertTrue(queued)

        sut.pause()
        XCTAssertTrue(sut.queuedRoleIDs.isEmpty, "nothing waits for a slot in a paused run")
    }

    func testProviderLimited_neverQueuesAnything() async {
        seedTwoReadyRoles(cap: nil)
        sut.start()
        let bothStarted = await waitUntil { self.startedRoleIDs().count == 2 }
        XCTAssertTrue(bothStarted)
        XCTAssertTrue(sut.queuedRoleIDs.isEmpty)
    }

    // MARK: - The livelock the old skip-guard would have caused

    /// A `Task` that RETURNED is not `.isCancelled`, so its record used to linger in
    /// `roleTasks` forever and the start guard skipped the role. Harmless while every ready
    /// role started anyway; under a cap the same role would win the only slot on every pass
    /// and never use it — a spin at 10 Hz with no `.done` and no `.failed` at the end.
    func testFinishedRoleTask_isEvicted_soItCannotHoldASlot() async {
        let roles = [supervisorRole(), worker("alpha")]
        mockStore.activeTeam = Team(
            name: "T", roles: roles, artifacts: [], settings: .default,
            graphLayout: TeamGraphLayout())
        mockStore.activeTask = NTMSTask(
            id: 0, title: "T", supervisorTask: "Build",
            runs: [Run(id: 0, roleStatuses: ["alpha": .idle])])
        mockStore.findOrCreateStepResults = ["alpha": "alpha"]
        mockStore.stepStatusResults = ["alpha": .done]

        let started = await sut.startRoles(roleIDs: ["alpha"])
        XCTAssertEqual(started, ["alpha"])

        let evicted = await waitUntil { !self.sut.hasLiveRoleTask("alpha") }
        XCTAssertTrue(evicted, "a finished execution must not leave a record behind")
        XCTAssertNil(sut.roleTasks["alpha"])
    }

    /// `startRoles` reports what it STARTED, not what it was handed — the run loop needs the
    /// difference to tell "dispatched work" from "found every candidate already busy".
    func testStartRoles_reportsOnlyWhatItActuallyStarted() async {
        let roles = [supervisorRole(), worker("alpha")]
        mockStore.activeTeam = Team(
            name: "T", roles: roles, artifacts: [], settings: .default,
            graphLayout: TeamGraphLayout())
        mockStore.activeTask = NTMSTask(
            id: 0, title: "T", supervisorTask: "Build",
            runs: [Run(id: 0, roleStatuses: ["alpha": .idle])])
        mockStore.findOrCreateStepResults = ["alpha": "alpha"]
        mockStore.stepStatusResults = ["alpha": .running]

        let first = await sut.startRoles(roleIDs: ["alpha"])
        XCTAssertEqual(first, ["alpha"])
        let second = await sut.startRoles(roleIDs: ["alpha"])
        XCTAssertTrue(second.isEmpty, "the second call found it already executing")
    }

    // MARK: - Parked roles (Pause -> Resume)

    /// Two roles left `.working` next to `.paused` steps — what a pause, an answered
    /// question, or an app restart leaves behind. Without the cap here the setting fails on
    /// its most common path: four roles running, the user picks "One at a time", Pause,
    /// Resume, four roles running again, permanently.
    private func seedTwoParkedRoles(cap: Int?) {
        let roles = [supervisorRole(), worker("alpha"), worker("bravo")]
        mockStore.activeTeam = Team(
            name: "Test Team", roles: roles, artifacts: [], settings: .default,
            graphLayout: TeamGraphLayout())
        let alphaStep = StepExecution(
            id: "alpha", role: .custom(id: "alpha"), title: "A", status: .paused)
        let bravoStep = StepExecution(
            id: "bravo", role: .custom(id: "bravo"), title: "B", status: .paused)
        mockStore.activeTask = NTMSTask(
            id: 0, title: "T", supervisorTask: "Build",
            runs: [Run(
                id: 0, steps: [alphaStep, bravoStep],
                roleStatuses: ["alpha": .working, "bravo": .working])])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]
        // Held `.running` so the restarted execution keeps its slot instead of returning at
        // once and being restarted again on the next pass.
        mockStore.stepStatusResults = ["alpha": .running, "bravo": .running]
        mockStore.maxConcurrentRoles = cap
    }

    func testCapOfOne_restartsOneParkedRoleAtATime() async {
        seedTwoParkedRoles(cap: 1)
        sut.start()

        let oneRestarted = await waitUntil { !self.mockStore.runStepCalls.isEmpty }
        XCTAssertTrue(oneRestarted)
        try? await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(mockStore.runStepCalls, ["alpha"],
                       "the second parked role must wait for the slot")
    }

    func testProviderLimited_restartsEveryParkedRole() async {
        seedTwoParkedRoles(cap: nil)
        sut.start()

        let bothRestarted = await waitUntil { self.mockStore.runStepCalls.count == 2 }
        XCTAssertTrue(bothRestarted, "got \(mockStore.runStepCalls)")
        XCTAssertEqual(Set(mockStore.runStepCalls), ["alpha", "bravo"])
    }

    /// A parked role that missed the slot is shown as Queued, not as silently stuck.
    func testCapOfOne_publishesTheWaitingParkedRoleAsQueued() async {
        seedTwoParkedRoles(cap: 1)
        sut.start()

        let queued = await waitUntil { self.sut.queuedRoleIDs == ["bravo"] }
        XCTAssertTrue(queued, "got \(sut.queuedRoleIDs)")
    }

    // MARK: - Per-task semantics

    /// DOCUMENTED SEMANTICS, pinned so the first reader does not "fix" it into a global
    /// stopper: the cap is per TASK. A global one would deadlock the moment a role delegates
    /// — the parent stays suspended in `delegate_to_team` for up to thirty minutes holding
    /// the only slot its child needs.
    func testTheCapIsPerTask_twoTasksAtCapOneRunTwoRoles() async {
        seedTwoReadyRoles(cap: 1)

        let otherStore = MockTeamEngineStore()
        otherStore.activeTeam = mockStore.activeTeam
        otherStore.activeTask = NTMSTask(
            id: 1, title: "Other", supervisorTask: "Build",
            runs: [Run(id: 0, roleStatuses: ["alpha": .idle, "bravo": .idle])])
        otherStore.producedArtifactNamesResult = ["Supervisor Task"]
        otherStore.findOrCreateStepResults = ["alpha": "alpha", "bravo": "bravo"]
        otherStore.stepStatusResults = ["alpha": .running, "bravo": .running]
        otherStore.maxConcurrentRoles = 1
        let otherEngine = TeamEngine(store: otherStore)
        defer { otherEngine.stop() }

        sut.start()
        otherEngine.start()

        let bothTasksStartedOne = await waitUntil {
            self.startedRoleIDs().count == 1
                && otherStore.updateRoleStatusCalls.filter({ $0.status == .working }).count == 1
        }
        XCTAssertTrue(bothTasksStartedOne, "each task gets its own allowance")
    }

    // MARK: - Revision order

    /// Was `Dictionary` iteration order, which is not a function of the dictionary's
    /// contents: the same run chose a different role on different launches. Harmless while
    /// every startable role started anyway — load-bearing the moment this list decides who
    /// gets the only slot.
    func testStartableRevisionRoles_areReturnedInRosterOrder() {
        let roles = [supervisorRole(), worker("zulu"), worker("alpha"), worker("mike")]
        let statuses: [String: RoleExecutionStatus] = [
            "zulu": .revisionRequested, "alpha": .revisionRequested, "mike": .revisionRequested,
        ]
        // Rebuilt many times: a dictionary's iteration order varies per instance, so a single
        // call could pass by luck.
        for _ in 0..<50 {
            let shuffled = Dictionary(uniqueKeysWithValues: statuses.shuffled())
            XCTAssertEqual(
                TeamEngine.startableRevisionRoleIDs(roleStatuses: shuffled, roles: roles),
                ["zulu", "alpha", "mike"])
        }
    }

    /// A role the roster dropped mid-run is kept (sorted, after the roster) rather than
    /// filtered out — it still has to reach `startRevisionRoles`, whose "step not found"
    /// failure is truthful, where dropping it would have the run loop announce a dependency
    /// cycle that does not exist.
    func testStartableRevisionRoles_keepOrphansAfterTheRoster() {
        let roles = [supervisorRole(), worker("alpha")]
        let statuses: [String: RoleExecutionStatus] = [
            "alpha": .revisionRequested, "ghost": .revisionRequested, "phantom": .revisionRequested,
        ]
        XCTAssertEqual(
            TeamEngine.startableRevisionRoleIDs(roleStatuses: statuses, roles: roles),
            ["alpha", "ghost", "phantom"])
    }

    func testStartableRevisionRoles_noneRequested_isEmpty() {
        let roles = [supervisorRole(), worker("alpha")]
        XCTAssertTrue(
            TeamEngine.startableRevisionRoleIDs(
                roleStatuses: ["alpha": .working], roles: roles).isEmpty)
    }
}
