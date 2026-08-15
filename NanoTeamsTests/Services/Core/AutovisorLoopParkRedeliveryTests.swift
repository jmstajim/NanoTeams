import XCTest

@testable import NanoTeams

/// `autovisorLastPassAttentionKeys` encodes "the manager has REVIEWED this condition",
/// and it is written at pass START. A pass that dies in a reasoning loop reviewed
/// nothing — so its baseline is a false claim, and every later wake reads a still-open
/// condition as old news. On 2026-07-25 that left a `.failed` worker and a loop-parked
/// manager with no recovery until the 10-minute recurrence, and none at all once the
/// auto-off timer fired.
///
/// These pin the bounded rollback: one extra pass per key per loop-park episode, never
/// a tight wake loop.
@MainActor
final class AutovisorLoopParkRedeliveryTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func pinManager() async -> Int {
        await sut.openWorkFolder(tempDir)
        let mgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)!
        await sut.mutateWorkFolder { $0.state.autovisorTaskID = mgrID }
        return mgrID
    }

    /// Parks the manager with the question the loop terminal produces.
    private func parkManagerWithLoopQuestion(_ mgrID: Int) async {
        await sut.ensureTaskLoaded(mgrID)
        await sut.mutateTask(taskID: mgrID) { task in
            var step = StepExecution(id: "autovisor_autovisor", role: .autovisor,
                                     title: "Autovisor", status: .paused)
            step.needsSupervisorInput = true
            step.supervisorQuestion =
                "Role Autovisor \(LoopRecoveryPolicy.stuckQuestionMarker) (within-message): "
                + "substring \"x\" repeated 4 times consecutively. Please advise how to proceed."
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["autovisor_autovisor": .working])]
        }
    }

    /// Parks the manager the HEALTHY way — `wait_for_events`.
    private func parkManagerIdle(_ mgrID: Int) async {
        await sut.ensureTaskLoaded(mgrID)
        await sut.mutateTask(taskID: mgrID) { task in
            var step = StepExecution(id: "autovisor_autovisor", role: .autovisor,
                                     title: "Autovisor", status: .paused)
            step.needsSupervisorInput = true
            step.supervisorQuestion = AutovisorConstants.idleParkQuestion
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["autovisor_autovisor": .working])]
        }
    }

    private func key(_ taskID: Int) -> NTMSOrchestrator.AutovisorAttentionKey {
        .init(taskID: taskID, trigger: .failed)
    }

    // MARK: - The rollback

    func testLoopPark_rollsBackBaseline_soTheConditionIsFreshAgain() async {
        let mgrID = await pinManager()
        await parkManagerWithLoopQuestion(mgrID)
        sut.autovisorLastPassAttentionKeys = [key(42)]

        sut.noteAutovisorLoopPark(mgrID)

        XCTAssertFalse(sut.autovisorLastPassAttentionKeys.contains(key(42)),
            "a pass that died mid-thought reviewed nothing — its baseline must not claim otherwise")
        XCTAssertTrue(sut.autovisorLoopParkRedelivered.contains(key(42)),
            "the rolled-back key must be recorded as spent, or the bound is unenforceable")
    }

    /// **The guard on the deliver-once invariant.** A manager that loops on every pass
    /// must not roll back its own baseline forever — that would restart it every poll,
    /// which is precisely the tight wake loop deliver-once exists to prevent.
    func testLoopPark_rollBackIsOncePerKey_secondParkDoesNotReDeliver() async {
        let mgrID = await pinManager()
        await parkManagerWithLoopQuestion(mgrID)
        sut.autovisorLastPassAttentionKeys = [key(42)]

        sut.noteAutovisorLoopPark(mgrID)                    // episode 1 — spends the key
        sut.autovisorLastPassAttentionKeys = [key(42)]      // next pass re-baselines it
        sut.noteAutovisorLoopPark(mgrID)                    // episode 2 — must be a no-op

        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(key(42)),
            "the second consecutive loop park must re-deliver nothing and fall through to the recurrence")
    }

    /// A healthy terminal means a pass really completed, so the one free re-delivery
    /// is re-armed for any future episode.
    func testHealthyTerminal_clearsTheLedger_reArmingOneRedelivery() async {
        let mgrID = await pinManager()
        await parkManagerWithLoopQuestion(mgrID)
        sut.autovisorLastPassAttentionKeys = [key(42)]
        sut.noteAutovisorLoopPark(mgrID)
        XCTAssertFalse(sut.autovisorLoopParkRedelivered.isEmpty)

        sut.clearAutovisorLoopParkLedger(mgrID)
        XCTAssertTrue(sut.autovisorLoopParkRedelivered.isEmpty)

        sut.autovisorLastPassAttentionKeys = [key(42)]
        sut.noteAutovisorLoopPark(mgrID)
        XCTAssertFalse(sut.autovisorLastPassAttentionKeys.contains(key(42)),
            "after a completed pass the next loop park gets its re-delivery back")
    }

    // MARK: - Scope

    /// `wait_for_events` is a healthy terminal: the manager finished its pass and
    /// genuinely reviewed the conditions it baselined. Rolling those back would
    /// re-wake it for work it already handled.
    func testIdlePark_doesNotRollBackBaseline() async {
        let mgrID = await pinManager()
        await parkManagerIdle(mgrID)
        sut.autovisorLastPassAttentionKeys = [key(42)]

        sut.noteAutovisorLoopPark(mgrID)

        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(key(42)),
            "an idle park reviewed its conditions — the baseline is honest and must stand")
        XCTAssertTrue(sut.autovisorLoopParkRedelivered.isEmpty)
    }

    /// Only the manager has an attention baseline; a worker parking on its own
    /// `ask_supervisor` must not touch it.
    func testNonManagerTask_isIgnored() async {
        _ = await pinManager()
        let otherID = await sut.createTask(title: "Real", supervisorTask: "x", makeActive: false)!
        await parkManagerWithLoopQuestion(otherID)   // same shape, wrong task
        sut.autovisorLastPassAttentionKeys = [key(42)]

        sut.noteAutovisorLoopPark(otherID)

        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(key(42)))
    }

    /// A manager parked on a real `ask_supervisor` question (not a loop) is also a
    /// healthy state — the marker match must not be a loose "any park".
    func testOrdinaryQuestionPark_doesNotRollBackBaseline() async {
        let mgrID = await pinManager()
        await sut.ensureTaskLoaded(mgrID)
        await sut.mutateTask(taskID: mgrID) { task in
            var step = StepExecution(id: "autovisor_autovisor", role: .autovisor,
                                     title: "Autovisor", status: .paused)
            step.needsSupervisorInput = true
            step.supervisorQuestion = "Which milestone should I start next?"
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["autovisor_autovisor": .working])]
        }
        sut.autovisorLastPassAttentionKeys = [key(42)]

        sut.noteAutovisorLoopPark(mgrID)

        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(key(42)))
    }

    // MARK: - The marker contract

    /// `taskHasLoopParkStep` and `taskHasIdleParkStep` must be mutually exclusive —
    /// they select opposite recovery behaviours off the same field.
    func testParkPredicates_areMutuallyExclusive() async {
        let mgrID = await pinManager()

        await parkManagerWithLoopQuestion(mgrID)
        var task = sut.loadedTask(mgrID)
        XCTAssertTrue(NTMSOrchestrator.taskHasLoopParkStep(task))
        XCTAssertFalse(NTMSOrchestrator.taskHasIdleParkStep(task))

        await parkManagerIdle(mgrID)
        task = sut.loadedTask(mgrID)
        XCTAssertFalse(NTMSOrchestrator.taskHasLoopParkStep(task))
        XCTAssertTrue(NTMSOrchestrator.taskHasIdleParkStep(task))
    }

    /// The marker is a contract between `LoopRecoveryPolicy` and the orchestrator: the
    /// question the policy actually produces must be recognised by the predicate. A
    /// copy-edit to either side that breaks this silently disables the whole recovery.
    func testPolicyStuckQuestion_carriesTheMarkerThePredicateMatches() {
        let decision = LoopRecoveryPolicy.decide(
            signal: .withinMessage(diagnostic: "substring \"x\" repeated 4 times consecutively"),
            breakCount: 99, maxRetries: 2,
            supervisorMode: .autonomous, isChatMode: true,
            canParkForSupervisor: true, roleName: "Autovisor")

        guard case .terminal(.parkForSupervisor(let question)) = decision else {
            return XCTFail("an exhausted autonomous chat manager must park, got \(decision)")
        }
        XCTAssertTrue(question.contains(LoopRecoveryPolicy.stuckQuestionMarker))
        XCTAssertNotEqual(question, AutovisorConstants.idleParkQuestion)
    }
}
