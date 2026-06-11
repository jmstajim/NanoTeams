import XCTest
@testable import NanoTeams

/// Pins the pure idle-park predicate (`NTMSOrchestrator.taskHasIdleParkStep`) that
/// gates the sidebar Autovisor icon's attention pulse. A `wait_for_events` park
/// shares the `.needsSupervisorInput` engine state with genuine escalation
/// questions; the only durable marker is the parked step's `supervisorQuestion`
/// matching `AutovisorConstants.idleParkQuestion`. The predicate must:
/// • match ONLY the idle park (a real question keeps the attention pulse),
/// • match by EXACT equality — no trimmed/substring/fuzzy matching (the write
///   side persists the trimmed question, so padded variants are not idle parks,
///   and a real question merely quoting the idle text must keep the pulse),
/// • require the step to actually be waiting (`needsSupervisorInput == true`),
/// • match on the persistent FLAG, not step status (a restart-recovered park is
///   `.paused` with the flag still set — callers gate on live engine state),
/// • consider the LATEST run only (an idle park in history is not current state).
final class AutovisorIdleParkTests: XCTestCase {

    // MARK: - Helpers

    private func step(needsInput: Bool, question: String?,
                      status: StepStatus = .pending) -> StepExecution {
        StepExecution(
            id: "autovisor_role",
            role: .custom(id: "autovisor_role"),
            title: "Autovisor",
            status: status,
            needsSupervisorInput: needsInput,
            supervisorQuestion: question
        )
    }

    private func task(runs: [Run]) -> NTMSTask {
        NTMSTask(id: 1, title: "Autovisor", supervisorTask: "manage", runs: runs, isChatMode: true)
    }

    // MARK: - Matching

    func testIdleParkStep_matches() {
        let t = task(runs: [Run(id: 0, steps: [
            step(needsInput: true, question: AutovisorConstants.idleParkQuestion)
        ])])
        XCTAssertTrue(NTMSOrchestrator.taskHasIdleParkStep(t),
                      "a step parked on wait_for_events must be recognized as the idle park")
    }

    func testRealQuestion_doesNotMatch() {
        let t = task(runs: [Run(id: 0, steps: [
            step(needsInput: true, question: "Should task #3 be closed or restarted?")
        ])])
        XCTAssertFalse(NTMSOrchestrator.taskHasIdleParkStep(t),
                       "a genuine escalation question must keep the attention treatment")
    }

    func testStaleIdleQuestionWithoutWaiting_doesNotMatch() {
        // Answering the park clears `needsSupervisorInput` but the question text can
        // linger on the step — text alone must not count as an active idle park.
        let t = task(runs: [Run(id: 0, steps: [
            step(needsInput: false, question: AutovisorConstants.idleParkQuestion)
        ])])
        XCTAssertFalse(NTMSOrchestrator.taskHasIdleParkStep(t))
    }

    func testRecoveredPausedPark_stillMatchesFlag() {
        // Restart recovery (`StatusRecoveryService`) flips step STATUS to `.paused`
        // but keeps the `needsSupervisorInput` flag + question. The predicate keys
        // on the flag, so it still matches — callers (like `autovisorIsIdleParked`)
        // must gate on live engine state, which is nil/non-parked in this window.
        let t = task(runs: [Run(id: 0, steps: [
            step(needsInput: true, question: AutovisorConstants.idleParkQuestion, status: .paused)
        ])])
        XCTAssertTrue(NTMSOrchestrator.taskHasIdleParkStep(t),
                      "flag-not-status semantics: a recovered paused park still matches")
    }

    func testIdleParkQuestionConstant_isTrimStable() {
        // The write side (`setNeedsSupervisorInput`) persists the TRIMMED question;
        // the predicate compares against the raw constant. Reformatting the constant
        // (e.g. a `\"\"\"` literal with a trailing newline) would silently make every
        // future park unmatchable — pin trim-stability directly.
        let q = AutovisorConstants.idleParkQuestion
        XCTAssertEqual(q.trimmingCharacters(in: .whitespacesAndNewlines), q)
    }

    // MARK: - Degenerate shapes

    func testNilTask_isFalse() {
        XCTAssertFalse(NTMSOrchestrator.taskHasIdleParkStep(nil))
    }

    func testTaskWithoutRuns_isFalse() {
        XCTAssertFalse(NTMSOrchestrator.taskHasIdleParkStep(task(runs: [])))
    }

    func testNilQuestion_doesNotMatch() {
        let t = task(runs: [Run(id: 0, steps: [step(needsInput: true, question: nil)])])
        XCTAssertFalse(NTMSOrchestrator.taskHasIdleParkStep(t))
    }

    func testEmptyStringQuestion_doesNotMatch() {
        let t = task(runs: [Run(id: 0, steps: [step(needsInput: true, question: "")])])
        XCTAssertFalse(NTMSOrchestrator.taskHasIdleParkStep(t))
    }

    // MARK: - Exact equality (no trimmed/substring matching)

    func testWhitespacePaddedIdleText_doesNotMatch() {
        // The write side (`setNeedsSupervisorInput`) persists the TRIMMED question,
        // so a padded variant can never be a genuine park — exact equality must
        // reject it rather than "helpfully" trimming before comparing.
        let padded = " \(AutovisorConstants.idleParkQuestion)\n"
        let t = task(runs: [Run(id: 0, steps: [step(needsInput: true, question: padded)])])
        XCTAssertFalse(NTMSOrchestrator.taskHasIdleParkStep(t))
    }

    func testIdleTextEmbeddedInLargerQuestion_doesNotMatch() {
        // A genuine escalation that QUOTES the idle text (e.g. the model echoing
        // its own park message) is still a real question — substring matching
        // would wrongly suppress the attention pulse for it.
        let embedded = "\(AutovisorConstants.idleParkQuestion) Also: close task #3 or restart it?"
        let t = task(runs: [Run(id: 0, steps: [step(needsInput: true, question: embedded)])])
        XCTAssertFalse(NTMSOrchestrator.taskHasIdleParkStep(t))
    }

    // MARK: - Latest run only

    func testIdleParkInEarlierRunOnly_isFalse() {
        let t = task(runs: [
            Run(id: 0, steps: [step(needsInput: true, question: AutovisorConstants.idleParkQuestion)]),
            Run(id: 1, steps: [step(needsInput: false, question: nil)])
        ])
        XCTAssertFalse(NTMSOrchestrator.taskHasIdleParkStep(t),
                       "an idle park in a superseded run is history, not current state")
    }

    func testIdleParkInLatestOfSeveralRuns_isTrue() {
        let t = task(runs: [
            Run(id: 0, steps: [step(needsInput: false, question: nil)]),
            Run(id: 1, steps: [step(needsInput: true, question: AutovisorConstants.idleParkQuestion)])
        ])
        XCTAssertTrue(NTMSOrchestrator.taskHasIdleParkStep(t))
    }

    func testLatestRunWithNoStepsYet_isFalse() {
        // Real window: a supersede (`fireRecurrence` / `startAutovisorPass`) appends
        // a fresh run via `createNewRun` BEFORE any step is created. The old run's
        // park is history; with no steps yet the manager isn't idle — pulse stays.
        let t = task(runs: [
            Run(id: 0, steps: [step(needsInput: true, question: AutovisorConstants.idleParkQuestion)]),
            Run(id: 1, steps: [])
        ])
        XCTAssertFalse(NTMSOrchestrator.taskHasIdleParkStep(t))
    }

    // MARK: - Mixed steps (documented `contains` semantics)

    func testMixedSteps_idleParkAlongsideRealQuestion_stillMatches() {
        // Structurally unreachable today (the manager team is single-role → one
        // step per run), but the predicate is a standalone API: this pins the
        // documented choice that with hypothetical mixed steps, idle-park
        // suppression wins over a sibling's real question. If that ever becomes
        // reachable, this test is the prompt to revisit the semantics.
        let t = task(runs: [Run(id: 0, steps: [
            step(needsInput: true, question: "Deploy to prod?"),
            step(needsInput: true, question: AutovisorConstants.idleParkQuestion)
        ])])
        XCTAssertTrue(NTMSOrchestrator.taskHasIdleParkStep(t))
    }
}
