import XCTest

@testable import NanoTeams

/// The engine's iteration watchdog must not put a ceiling on how long ONE step may take.
///
/// `iterationCount` is incremented on every pass of `runLoop`, and the working-wait branch
/// sleeps 250 ms and loops. At `autoIterationLimit` (10 000 by default) that is ≈ 41.7 minutes
/// of a single long state, after which the run pauses with "iteration limit reached. Press
/// Resume" — and under `.autonomous`, or in a headless run, there is nobody to press it. An
/// engineer driving a build to green on its own can exceed that; `XcodeBuildGate` lengthens
/// every wave whose builds queue.
///
/// The slot-wait branch had already solved this by resetting on progress (an occupancy
/// change). The working-wait branch had not. It resets on the newest `updatedAt` across
/// in-flight steps — not unconditionally, because an unconditional refund would disarm the
/// engine's only watchdog and a genuinely wedged step would hold the loop forever in silence.
@MainActor
final class RunLoopWatchdogTests: XCTestCase {

    private var store: MockTeamEngineStore!
    private var engine: TeamEngine!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        store = MockTeamEngineStore()
        engine = TeamEngine()
        engine.attach(store: store)
    }

    override func tearDown() async throws {
        engine.stop()
        engine = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures: one worker, permanently `.working`, so the loop parks in the wait branch

    private func seed(stepUpdatedAt: Date) {
        let supervisor = TeamRoleDefinition(
            id: "supervisor", name: "Supervisor", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Supervisor Task"]),
            systemRoleID: "supervisor")
        let worker = TeamRoleDefinition(
            id: "worker", name: "Worker", prompt: "p", toolIDs: [ToolNames.createArtifact],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Supervisor Task"],
                                           producesArtifacts: ["Notes"]))
        let team = Team(
            name: "T", roles: [supervisor, worker], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout())
        var step = StepExecution(id: "worker", role: .custom(id: "Worker"), title: "W",
                                 expectedArtifacts: ["Notes"], status: .running)
        step.updatedAt = stepUpdatedAt
        let run = Run(id: 0, steps: [step], roleStatuses: ["worker": .working])
        store.activeTeam = team
        store.teamSettings = team.settings
        store.activeTask = NTMSTask(id: 1, title: "T", supervisorTask: "do", runs: [run])
        store.stepStatusResults["worker"] = .running
        store.producedArtifactNamesResult = ["Supervisor Task"]
    }

    private func bumpStepUpdatedAt() {
        guard var task = store.activeTask, var run = task.runs.last else { return }
        run.steps[0].updatedAt = MonotonicClock.shared.now()
        task.runs[task.runs.count - 1] = run
        store.activeTask = task
    }

    // MARK: - Tests

    /// A step that is DOING something — every mutation stamps `updatedAt` — must not be
    /// counted out. RED: drop the progress reset from the working-wait branch → the limit is
    /// reached and the engine pauses.
    func testStepThatKeepsMakingProgress_isNotCountedOut() async {
        seed(stepUpdatedAt: MonotonicClock.shared.now())
        engine.setAutoIterationLimitForTesting(6)

        engine.start()
        // Longer than 6 × 250 ms, with the step reporting progress throughout.
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(120))
            bumpStepUpdatedAt()
        }

        XCTAssertEqual(engine.state, .running,
                       "a step still stamping `updatedAt` must not trip the watchdog")
        XCTAssertTrue(store.setLastErrorMessageCalls.isEmpty,
                      "got: \(store.setLastErrorMessageCalls)")
    }

    /// …and a step that has gone SILENT still trips it. This is the assertion that keeps the
    /// one above from being a refund: without it, "reset on progress" and "never count" are
    /// indistinguishable.
    func testSilentStep_stillTripsTheWatchdog() async {
        seed(stepUpdatedAt: MonotonicClock.shared.now())
        engine.setAutoIterationLimitForTesting(4)

        engine.start()
        try? await Task.sleep(for: .milliseconds(1800))

        XCTAssertEqual(engine.state, .paused,
                       "a wedged step must still be caught — the watchdog is the engine's only one")
        XCTAssertTrue(
            store.setLastErrorMessageCalls.contains { $0.contains("iteration limit") },
            "got: \(store.setLastErrorMessageCalls)")
    }
}
