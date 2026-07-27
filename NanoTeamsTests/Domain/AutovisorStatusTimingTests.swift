import XCTest
@testable import NanoTeams

/// Pins the pure timing helpers on `AutovisorStatus` that feed `task_status` and the
/// stuck-detector. Their precedence/clamp logic is load-bearing: a regression here
/// silently mis-reports idle/elapsed to the manager LLM or flips a hang verdict.
final class AutovisorStatusTimingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func step(
        createdAt: Date,
        completedAt: Date? = nil,
        status: StepStatus = .running,
        messages: [StepMessage] = [],
        toolCalls: [StepToolCall] = [],
        llm: [LLMMessage] = []
    ) -> StepExecution {
        StepExecution(
            id: "r", role: .codingAgent, title: "r",
            status: status, createdAt: createdAt, updatedAt: createdAt, completedAt: completedAt,
            messages: messages, toolCalls: toolCalls, llmConversation: llm
        )
    }

    // MARK: - Clock agreement (idle must be measured on the stamping clock)

    /// Every activity source `lastActivity` reads — `step.createdAt`,
    /// `messages.createdAt`, `toolCalls.createdAt` — is stamped with
    /// `MonotonicClock.shared.now()`, which runs AHEAD of wall clock by the drift
    /// accumulated at stamp time (measured: p99 37s, max 40s in a live parallel
    /// worker). Measuring idle with a wall-clock `now` therefore UNDERSTATES it by
    /// exactly that drift, and `max(0, ...)` turns the shortfall into a hard 0 — so
    /// a genuinely hung role can sit below the 180s HANG threshold forever.
    ///
    /// Here the role has been silent for 190s IN THE FRAME ITS OWN TIMESTAMPS USE,
    /// which is past the threshold. A wall-clock `now` reads only 150s and misses it.
    func testIdleSeconds_isMeasuredOnTheStampingClock_notWallClock() {
        defer { MonotonicClock.shared.reset() }

        // Simulate a process that has accumulated drift before the role acted.
        for _ in 0..<40_000 { _ = MonotonicClock.shared.now() }
        let drift = MonotonicClock.shared.now().timeIntervalSince(Date())
        XCTAssertGreaterThan(drift, 10, "Setup invariant: need drift > 10s to separate the two clocks")

        // Last activity: 190s ago on the clock that stamps model timestamps.
        let stamp = MonotonicClock.shared.now().addingTimeInterval(-190)
        let s = step(createdAt: stamp)

        let idle = AutovisorStatus.idleSeconds(step: s, lastStreamActivityAt: nil)

        XCTAssertGreaterThan(
            idle, Int(AutovisorConstants.stuckHangSeconds),
            "A role idle 190s on its own timestamp clock must clear the 180s HANG threshold; a wall-clock `now` understates it by the drift and suppresses the detector")
    }

    // MARK: - lastActivity precedence

    func testLastActivity_picksLatestSource() {
        let s = step(
            createdAt: now.addingTimeInterval(-100),
            messages: [StepMessage(createdAt: now.addingTimeInterval(-40), role: .codingAgent, content: "m")],
            toolCalls: [StepToolCall(createdAt: now.addingTimeInterval(-20), name: "read_file", argumentsJSON: "{}")]
        )
        // Live stream signal is the newest → wins.
        XCTAssertEqual(
            AutovisorStatus.lastActivity(step: s, lastStreamActivityAt: now.addingTimeInterval(-5)),
            now.addingTimeInterval(-5))
        // No live signal → newest persisted (the tool call at -20) wins over message (-40)/createdAt (-100).
        XCTAssertEqual(
            AutovisorStatus.lastActivity(step: s, lastStreamActivityAt: nil),
            now.addingTimeInterval(-20))
    }

    func testLastActivity_ignoresLLMConversation() {
        // A very recent llmConversation entry (pre-created at response START) must NOT
        // count as activity — only finalized `messages` / `toolCalls` do.
        let s = step(
            createdAt: now.addingTimeInterval(-300),
            llm: [LLMMessage(createdAt: now, role: .assistant, content: "")]
        )
        XCTAssertEqual(
            AutovisorStatus.lastActivity(step: s, lastStreamActivityAt: nil),
            now.addingTimeInterval(-300),
            "llmConversation must not float lastActivity to now")
    }

    // MARK: - hasToolInFlight

    func testHasToolInFlight_nilResult_true() {
        let s = step(createdAt: now, toolCalls: [
            StepToolCall(createdAt: now, name: "run_xcodebuild", argumentsJSON: "{}", resultJSON: nil)
        ])
        XCTAssertTrue(AutovisorStatus.hasToolInFlight(step: s))
    }

    func testHasToolInFlight_interimPlaceholderResult_false() {
        // analyze_image / create_team placeholders carry a NON-nil interim resultJSON,
        // so they read as "done" (not in-flight) and must not suppress a hang.
        let s = step(createdAt: now, toolCalls: [
            StepToolCall(createdAt: now, name: "analyze_image", argumentsJSON: "{}",
                         resultJSON: #"{"status":"analyzing"}"#)
        ])
        XCTAssertFalse(AutovisorStatus.hasToolInFlight(step: s))
    }

    func testHasToolInFlight_noCalls_false() {
        XCTAssertFalse(AutovisorStatus.hasToolInFlight(step: step(createdAt: now)))
    }

    // MARK: - roleElapsedSeconds

    func testRoleElapsed_running_usesNow() {
        let s = step(createdAt: now.addingTimeInterval(-90))
        XCTAssertEqual(AutovisorStatus.roleElapsedSeconds(step: s, now: now), 90)
    }

    func testRoleElapsed_done_usesCompletedAt() {
        let s = step(createdAt: now.addingTimeInterval(-90),
                     completedAt: now.addingTimeInterval(-30), status: .done)
        // Frozen at completion (30s before now) → 60s, not 90s.
        XCTAssertEqual(AutovisorStatus.roleElapsedSeconds(step: s, now: now), 60)
    }

    // MARK: - taskElapsedSeconds

    func testTaskElapsed_nilRun_nil() {
        XCTAssertNil(AutovisorStatus.taskElapsedSeconds(run: nil, now: now))
    }

    func testTaskElapsed_usesRunCreatedAt() {
        let run = Run(id: 0, createdAt: now.addingTimeInterval(-120))
        XCTAssertEqual(AutovisorStatus.taskElapsedSeconds(run: run, now: now), 120)
    }

    // MARK: - isResumable

    /// Truth table. This predicate mirrors `resumeRun` branch 3; the manager acts on
    /// it, so a false positive advertises a resume the runtime silently drops and a
    /// false negative pushes it back toward the destructive `manage_role restart`.

    /// Deliberate pause (`control_task pause` / UI): `pauseStep` never touches role
    /// status, so the role stays `.working`.
    func testIsResumable_pausedStepWithWorkingRole_isResumable() {
        let s = step(createdAt: now, status: .paused)
        XCTAssertTrue(AutovisorStatus.isResumable(step: s, roleStatus: .working, taskIsClosed: false))
    }

    /// The incident shape: app quit mid-run, `StatusRecoveryService` demoted the role
    /// to `.idle` while the step kept its history.
    func testIsResumable_appQuitShape_idleRoleWithHistory_isResumable() {
        let withMessages = step(
            createdAt: now, status: .paused,
            messages: [StepMessage(role: .softwareEngineer, content: "working")])
        XCTAssertTrue(
            AutovisorStatus.isResumable(step: withMessages, roleStatus: .idle, taskIsClosed: false))

        // `llmConversation` alone is enough — a Harmony tool loop can fill it while
        // `messages` stays empty (envelope-only assistant turns never land there).
        let withConversation = step(
            createdAt: now, status: .paused,
            llm: [LLMMessage(role: .user, content: "brief")])
        XCTAssertTrue(
            AutovisorStatus.isResumable(step: withConversation, roleStatus: .idle, taskIsClosed: false))
    }

    /// An idle role with nothing to replay is a step that never ran — resume would
    /// find no transcript, so the manager must not be told it can continue one.
    func testIsResumable_idleRoleWithNoHistory_isNotResumable() {
        let s = step(createdAt: now, status: .paused)
        XCTAssertFalse(AutovisorStatus.isResumable(step: s, roleStatus: .idle, taskIsClosed: false))
    }

    /// Only `.paused` is resumable — every other status has its own triage branch.
    func testIsResumable_nonPausedStatuses_areNotResumable() {
        for status: StepStatus in [.running, .pending, .done, .failed] {
            let s = step(
                createdAt: now, status: status,
                messages: [StepMessage(role: .softwareEngineer, content: "x")])
            XCTAssertFalse(
                AutovisorStatus.isResumable(step: s, roleStatus: .working, taskIsClosed: false),
                "\(status.rawValue) must not advertise resume")
        }
    }

    /// `resumeRun` bails on a closed task, so the hint must too.
    func testIsResumable_closedTask_isNotResumable() {
        let s = step(
            createdAt: now, status: .paused,
            messages: [StepMessage(role: .softwareEngineer, content: "x")])
        XCTAssertFalse(AutovisorStatus.isResumable(step: s, roleStatus: .working, taskIsClosed: true))
        XCTAssertFalse(AutovisorStatus.isResumable(step: s, roleStatus: .idle, taskIsClosed: true))
    }

    /// A role status the run doesn't carry (unresolvable role id) is not a licence.
    func testIsResumable_unknownRoleStatus_isNotResumable() {
        let s = step(
            createdAt: now, status: .paused,
            messages: [StepMessage(role: .softwareEngineer, content: "x")])
        XCTAssertFalse(AutovisorStatus.isResumable(step: s, roleStatus: nil, taskIsClosed: false))
    }
}
