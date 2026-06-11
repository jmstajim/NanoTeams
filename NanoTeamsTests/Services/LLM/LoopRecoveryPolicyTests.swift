import XCTest
@testable import NanoTeams

/// Pins `LoopRecoveryPolicy` — the pure top-level stream-loop decision
/// (retry within budget → mode-aware terminal).
final class LoopRecoveryPolicyTests: XCTestCase {

    private let signal = LoopSignal.withinMessage(diagnostic: "looped")

    private func decide(
        breakCount: Int,
        mode: SupervisorMode = .autonomous,
        isChatMode: Bool = true
    ) -> LoopRecoveryPolicy.Decision {
        LoopRecoveryPolicy.decide(
            signal: signal, breakCount: breakCount,
            maxRetries: LLMConstants.maxThinkingLoopBreaks,
            supervisorMode: mode, isChatMode: isChatMode, roleName: "Autovisor")
    }

    func testWithinBudget_retriesStateless() {
        // breakCount 1 < maxThinkingLoopBreaks (2) → stateless replay.
        XCTAssertEqual(decide(breakCount: 1), .retryStateless)
    }

    func testAtBudget_manual_escalatesSupervisor() {
        let d = decide(breakCount: LLMConstants.maxThinkingLoopBreaks, mode: .manual)
        guard case .terminal(.escalateSupervisor) = d else {
            return XCTFail("manual + budget-exhausted must escalate to Supervisor, got \(d)")
        }
    }

    func testAtBudget_autonomousChat_finishesGraceful() {
        let d = decide(breakCount: LLMConstants.maxThinkingLoopBreaks, mode: .autonomous, isChatMode: true)
        XCTAssertEqual(d, .terminal(.finishGraceful))
    }

    func testAtBudget_autonomousNonChat_failsStep() {
        let d = decide(breakCount: LLMConstants.maxThinkingLoopBreaks, mode: .autonomous, isChatMode: false)
        guard case .terminal(.failStep) = d else {
            return XCTFail("autonomous + non-chat must fail the step, got \(d)")
        }
    }

    // MARK: - Boundaries

    /// breakCount strictly above the budget still terminates (not an infinite-retry
    /// off-by-one). Defends `breakCount < maxRetries` against a `<=` slip.
    func testAboveBudget_stillTerminal() {
        let d = decide(breakCount: LLMConstants.maxThinkingLoopBreaks + 5, mode: .autonomous, isChatMode: false)
        guard case .terminal = d else { return XCTFail("above-budget must be terminal, got \(d)") }
    }

    /// The retry-budget boundary is exclusive: with maxRetries == 1 the FIRST break
    /// (breakCount 1) is already terminal — no stateless retry is granted.
    func testMaxRetriesOne_firstBreakIsTerminal() {
        let d = LoopRecoveryPolicy.decide(
            signal: signal, breakCount: 1, maxRetries: 1,
            supervisorMode: .autonomous, isChatMode: false, roleName: "R")
        guard case .terminal(.failStep) = d else {
            return XCTFail("maxRetries==1 → breakCount 1 is terminal, got \(d)")
        }
    }

    /// The terminal message/question carries the signal's scope + diagnostic so the
    /// human/role sees WHAT looped.
    func testTerminalText_carriesSignalDiagnostic() {
        let s = LoopSignal.identicalToolCallSequence(diagnostic: "called read_file 3x")
        let d = LoopRecoveryPolicy.decide(
            signal: s, breakCount: 9, maxRetries: 2,
            supervisorMode: .manual, isChatMode: false, roleName: "Autovisor")
        guard case .terminal(.escalateSupervisor(let q)) = d else { return XCTFail() }
        XCTAssertTrue(q.contains("Autovisor"), "question names the role")
        XCTAssertTrue(q.contains("called read_file 3x"), "question carries the diagnostic")
        XCTAssertTrue(q.contains(s.scope), "question carries the scope")
    }
}
