import XCTest

@testable import NanoTeams

/// Wave 11 — what the per-step DEBUG accessors answer for a step that does not exist.
///
/// `LLMExecutionService+TestHelpers` is the seam roughly forty suites read per-step runtime state
/// through, and every reader ends in a `??` fallback for "no execution state under this key".
/// Those fallbacks had never run, so nothing stated what they mean — and they do not all mean the
/// same thing:
///
///   - the five COUNTERS answer `-1`, a value no live step can hold (every one of them is a
///     monotonic count seeded at 0), so "no such step" stays distinguishable from any real reading;
///   - the two FLAGS answer `false`, and the capture counter answers `0` — values a live step holds
///     routinely, so for them the distinction is LOST.
///
/// That asymmetry is the finding, and it is a trap for test authors rather than for users.
/// `TaskStepKey` is `(taskID, stepID)` and `stepID` is the ROLE id (CLAUDE.md invariant #5, which
/// exists because two tasks on one team share stepID strings), so a suite that mistypes either half
/// — or reads after `cancelAllExecutions` tore the entry down — gets `false` back and reads it as
/// "the flag was cleared". Every assertion of the shape `XCTAssertFalse(_testFinishRequested(...))`
/// in this repo is satisfied by a step that never existed. The counters cannot be fooled that way;
/// the flags can, because `Bool` has no spare value to spend on a sentinel. This file is where that
/// is written down, and `testFlagsCannotDistinguish...` fails the moment a counter loses its.
///
/// `@MainActor` + `async` per the documented sync-test abort: constructing the `@MainActor`
/// `LLMExecutionService` from a synchronous test method aborts the process. `setUp` is immune.
@MainActor
final class StepStateAccessorCoverageTests: XCTestCase {

    var service: LLMExecutionService!

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    private static let unknownStep = "no-such-role"
    private static let unknownTask = 987_654

    /// Every counter answers the out-of-band sentinel for a step with no execution state, and the
    /// existence probe agrees with them.
    ///
    /// RED: change `?? -1` to `?? 0` in any one of the five counter accessors in
    /// `LLMExecutionService+TestHelpers` → that counter's assertion below fails.
    func testCounters_forAnUnknownStep_answerTheOutOfBandSentinel() async {
        let s = Self.unknownStep
        let t = Self.unknownTask

        XCTAssertFalse(service._testHasExecutionState(stepID: s, taskID: t),
                       "setup: this key must have no execution state")

        XCTAssertEqual(service._testThinkingLoopBreakCount(stepID: s, taskID: t), -1)
        XCTAssertEqual(service._testComputerUseActionsSinceCapture(stepID: s, taskID: t), -1)
        XCTAssertEqual(service._testDriftCounter(stepID: s, taskID: t), -1)
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: s, taskID: t), -1)
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: s, taskID: t), -1)
    }

    /// The other half of the same read: the flags and the capture count answer values a live step
    /// holds, so they cannot report "no such step" at all.
    ///
    /// Stated as a DIFFERENTIAL against a freshly seeded step whose every counter and flag is at
    /// its default, because that is the confusion in the field — not "what does an absent step
    /// return" but "can the caller tell an absent step from a quiet one". The counters can; the
    /// flags cannot. Asserting both halves in one test is what makes the point falsifiable.
    ///
    /// RED: change `?? -1` to `?? 0` in `_testDriftCounter` → the counters-distinguish assertion
    /// fails, because the absent step and the quiet step now read alike.
    func testFlagsCannotDistinguishAnAbsentStepFromAQuietOne_butCountersCan() async {
        let absentStep = Self.unknownStep
        let absentTask = Self.unknownTask
        let liveStep = "software_engineer"
        let liveTask = 1

        // A step that exists and has never been touched: every counter 0, every flag false.
        // Seeding through the production-shaped helper also exercises its create-if-absent arm,
        // which no suite had reached — every existing caller seeds a step that already exists.
        service._testSetPrefixCacheState(stepID: liveStep, taskID: liveTask)
        XCTAssertTrue(service._testHasExecutionState(stepID: liveStep, taskID: liveTask),
                      "setup: the seeder must have created the entry")

        // Counters: the two readings differ, so the caller can tell them apart.
        XCTAssertNotEqual(
            service._testDriftCounter(stepID: absentStep, taskID: absentTask),
            service._testDriftCounter(stepID: liveStep, taskID: liveTask),
            "an absent step must not read the same as a live step whose counter is still 0")
        XCTAssertEqual(service._testDriftCounter(stepID: liveStep, taskID: liveTask), 0)

        // Flags: the two readings are identical. This is the documented limitation, not a defect
        // to fix here — `Bool` has no third value — but a suite asserting `false` to prove a flag
        // was CLEARED proves nothing about which step it read.
        XCTAssertEqual(
            service._testFinishRequested(stepID: absentStep, taskID: absentTask),
            service._testFinishRequested(stepID: liveStep, taskID: liveTask),
            "an absent step and a quiet step are indistinguishable through a Bool accessor")
        XCTAssertEqual(
            service._testParkForEventsRequested(stepID: absentStep, taskID: absentTask),
            service._testParkForEventsRequested(stepID: liveStep, taskID: liveTask))

        // The capture counter is keyed by TASK alone and has the same limitation.
        XCTAssertEqual(service._testComputerUseCaptureCount(taskID: absentTask), 0)
        XCTAssertEqual(service._testComputerUseCaptureCount(taskID: liveTask), 0)
    }

    /// The idle-park arming helper on a service that has never seen the step. Same create-if-absent
    /// arm as above, on the accessor pair the `wait_for_events` park is driven through — and here
    /// the flag readers ARE trustworthy, because the caller just established the step exists.
    ///
    /// RED: delete the `if executionStates[key] == nil { executionStates[key] = StepExecutionState() }`
    /// line from `_testArmParkForEvents` → the optional-chained writes below it become no-ops on a
    /// fresh service and both assertions fail.
    func testArmParkForEvents_onAFreshService_createsTheStateItWritesThrough() async {
        let step = "assistant"
        let task = 42

        XCTAssertFalse(service._testHasExecutionState(stepID: step, taskID: task),
                       "setup: nothing has touched this step")

        service._testArmParkForEvents(stepID: step, taskID: task, questionOverride: "loop terminal")

        XCTAssertTrue(service._testParkForEventsRequested(stepID: step, taskID: task))
        XCTAssertEqual(service._testParkQuestionOverride(stepID: step, taskID: task), "loop terminal")
    }
}
