import XCTest

@testable import NanoTeams

/// `.repetitiveTool` is structurally incapable of seeing a run of identical FAILURES —
/// `visibleCalls` filters on `wasSuccessful`, so the trailing run of N identical failing
/// calls is 0 for any N, and the entry guard needs six calls before it looks at all.
/// That blindness is correct for the question that arm answers (a failed edit changed
/// nothing, so identical rebuilds around it still describe an unchanged state). It was
/// not correct as the system's whole answer: in the 2026-08-13 gemma run four byte-
/// identical failing `edit_file` calls produced no warning, leaving `maxNonProductiveTurns`
/// — twenty turns out — as the only backstop, and the human hit Pause at six.
///
/// `.repetitiveFailure` is a separate arm precisely so `.repetitiveTool`'s documented
/// semantics stay untouched; the last two tests pin that they did.
final class RepetitiveFailureDetectionTests: XCTestCase {

    private func call(
        _ tool: String,
        args: String,
        ok: Bool,
        result: String = #"{"ok":false,"error":{"code":"INVALID_ARGS","message":"Missing required argument: path"}}"#,
        epoch: Int = 0
    ) -> ToolCallTracker.TrackedCall {
        ToolCallTracker.TrackedCall(
            toolName: tool,
            argumentsSummary: args,
            argumentsIdentity: args.hashValue,
            resultSummary: "",
            resultJSON: ok ? #"{"ok":true}"# : result,
            wasSuccessful: ok,
            informationEpoch: epoch)
    }

    // MARK: - Firing

    /// The headline: three is enough, and three is BELOW the six-call window guard that
    /// `.repetitiveTool` sits behind. This is the exact shape of the production run.
    /// RED: move the failure check below the `recentCalls.count >= windowSize` guard →
    /// nothing fires until six calls exist, i.e. after twice as many wasted turns.
    func testThreeIdenticalFailures_fireBelowTheSixCallWindow() {
        let calls = Array(repeating: call("edit_file", args: #"{"new_text":"B"}"#, ok: false), count: 3)
        guard case .repetitiveFailure(let tool, let count, let code)? =
            ToolCallLoopDetector.detectLoopPattern(in: calls)
        else {
            return XCTFail("three identical failures must be reported")
        }
        XCTAssertEqual(tool, "edit_file")
        XCTAssertEqual(count, 3)
        XCTAssertEqual(code, "INVALID_ARGS")
    }

    /// RED: lower the threshold below `repetitionMinIdenticalToolCalls` → an ordinary
    /// retry-once-after-a-failure is reported as a loop.
    func testTwoIdenticalFailures_areNotYetALoop() {
        let calls = Array(repeating: call("edit_file", args: #"{"a":"1"}"#, ok: false), count: 2)
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    /// A success between the failures means the model DID something — the run is broken.
    /// RED: drop the `wasSuccessful` break from the trailing-run walk → a model that
    /// acted between two failures is accused of looping.
    func testSuccessBetweenFailures_breaksTheRun() {
        let failing = call("edit_file", args: #"{"a":"1"}"#, ok: false)
        let calls = [failing, failing, call("read_file", args: #"{"path":"x"}"#, ok: true), failing]
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    /// Different arguments are different attempts, so THIS arm — whose whole message is
    /// "with identical arguments" — must not claim them.
    ///
    /// It used to assert nil outright, on the reading that varying the arguments is
    /// always progress. MeditationApp task 28 measured the counter-example: three
    /// consecutive `edit_file` failures carrying one anchor and a perturbed replacement,
    /// same typed code every time, nothing fired, and the model spent 30% of the run
    /// there. Varying arguments is progress only if the variation touches what is
    /// wrong; the shared error code is the evidence that it did not. `.persistentToolError`
    /// owns that case and says the opposite thing.
    func testDifferentArgumentsFailing_isNotAnIdenticalArgumentsRun() {
        let calls = [
            call("edit_file", args: #"{"a":"1"}"#, ok: false),
            call("edit_file", args: #"{"a":"2"}"#, ok: false),
            call("edit_file", args: #"{"a":"3"}"#, ok: false),
        ]
        if case .repetitiveFailure? = ToolCallLoopDetector.detectLoopPattern(in: calls) {
            XCTFail("varied arguments must not be reported as identical ones")
        }
    }

    /// Identity is the CALL, not the outcome: the same broken call is the same broken
    /// call whether the runtime rejects it early or the tool rejects it late.
    func testSameCallFailingWithDifferentCodes_stillFires() {
        let anchor = #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","message":"nope"}}"#
        let calls = [
            call("edit_file", args: #"{"a":"1"}"#, ok: false),
            call("edit_file", args: #"{"a":"1"}"#, ok: false, result: anchor),
            call("edit_file", args: #"{"a":"1"}"#, ok: false, result: anchor),
        ]
        guard case .repetitiveFailure(_, let count, let code)? =
            ToolCallLoopDetector.detectLoopPattern(in: calls)
        else { return XCTFail("the run is defined by the call, not the error") }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(code, "ANCHOR_NOT_FOUND", "the code reported is the newest one")
    }

    /// Information arriving that no call of the model's own asked for starts a new
    /// situation, exactly as it does for `.repetitiveTool`.
    /// RED: drop the epoch break from the failure walk → a role told the world moved and
    /// re-checking it is warned about a run made entirely before the news.
    func testInformationEpochChange_resetsTheFailureRun() {
        let calls = [
            call("edit_file", args: #"{"a":"1"}"#, ok: false, epoch: 0),
            call("edit_file", args: #"{"a":"1"}"#, ok: false, epoch: 0),
            call("edit_file", args: #"{"a":"1"}"#, ok: false, epoch: 1),
        ]
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    /// …and the boundary is not immunity: three failures AFTER it still fire.
    func testThreeFailuresAfterAnEpochBoundary_stillFire() {
        let calls = [
            call("edit_file", args: #"{"a":"1"}"#, ok: false, epoch: 0),
            call("edit_file", args: #"{"a":"1"}"#, ok: false, epoch: 1),
            call("edit_file", args: #"{"a":"1"}"#, ok: false, epoch: 1),
            call("edit_file", args: #"{"a":"1"}"#, ok: false, epoch: 1),
        ]
        guard case .repetitiveFailure(_, let count, _)? =
            ToolCallLoopDetector.detectLoopPattern(in: calls)
        else { return XCTFail("the boundary resets the count, it does not grant immunity") }
        XCTAssertEqual(count, 3)
    }

    /// The gate that lets a post-boundary run be reported a second time has to key on the
    /// FAILURE run's epoch — `visibleCalls` answers 0 for a pure-failure window.
    /// RED: revert `epochOfTrailingRun` to the visible-calls-only form → the epoch reads
    /// 0 for every failure window, freezing the once-per-condition gate forever.
    func testEpochOfTrailingRun_tracksTheFailureRun() {
        let calls = Array(
            repeating: call("edit_file", args: #"{"a":"1"}"#, ok: false, epoch: 4), count: 3)
        XCTAssertEqual(ToolCallLoopDetector.epochOfTrailingRun(in: calls), 4)
    }

    /// A tool excluded from repetition counting is excluded because repeating identical
    /// ARGUMENTS is its contract — not because failing three times running is.
    func testExcludedTool_failingRepeatedly_stillFires() {
        let calls = Array(
            repeating: call(ToolNames.bashOutput, args: #"{"command_id":"1"}"#, ok: false), count: 3)
        guard case .repetitiveFailure? = ToolCallLoopDetector.detectLoopPattern(in: calls) else {
            return XCTFail("no tool's contract covers failing identically three times")
        }
    }

    // MARK: - `.repetitiveTool` is untouched

    /// RED: any change that lets the failure arm swallow the success arm → identical
    /// SUCCESSES stop being reported as `.repetitiveTool`.
    func testThreeIdenticalSuccesses_stillReportRepetitiveTool() {
        let calls = Array(repeating: call("read_file", args: #"{"path":"a"}"#, ok: true), count: 6)
        guard case .repetitiveTool(let tool, let count)? =
            ToolCallLoopDetector.detectLoopPattern(in: calls)
        else { return XCTFail("the success arm must be unchanged") }
        XCTAssertEqual(tool, "read_file")
        XCTAssertEqual(count, 6)
    }

    /// Failures remain invisible to the success arm: a window of six failures reports the
    /// failure arm, never `.repetitiveTool`.
    func testFailures_areStillInvisibleToTheSuccessArm() {
        let calls = Array(repeating: call("edit_file", args: #"{"a":"1"}"#, ok: false), count: 6)
        if case .repetitiveTool? = ToolCallLoopDetector.detectLoopPattern(in: calls) {
            XCTFail("`.repetitiveTool`'s wasSuccessful semantics must not have changed")
        }
    }

    // MARK: - The advice

    /// The advice must not say "the state isn't changing" — no state was ever reached.
    /// RED: route `.repetitiveFailure` through the `.repetitiveTool` text → the model is
    /// told "the state isn't changing" about calls that never reached any state.
    func testAdvice_forInvalidArgs_pointsAtTheParameterList() {
        let message = LLMExecutionService.loopWarningMessage(
            loopDetection: .repetitiveFailure(
                tool: "edit_file", count: 3, errorCode: "INVALID_ARGS"),
            allowedToolNames: ["edit_file", "ask_supervisor"])

        XCTAssertTrue(message.contains("failed 3 times"), message)
        XCTAssertTrue(message.contains("INVALID_ARGS"), message)
        XCTAssertTrue(message.contains("arguments"), message)
        XCTAssertFalse(
            message.contains("state isn't changing"),
            "that is the SUCCESS arm's diagnosis and is false here: \(message)")
    }

    func testAdvice_forOtherCodes_saysRepeatingCannotSucceed() {
        let message = LLMExecutionService.loopWarningMessage(
            loopDetection: .repetitiveFailure(
                tool: "edit_file", count: 4, errorCode: "ANCHOR_NOT_FOUND"),
            allowedToolNames: ["edit_file"])
        XCTAssertTrue(message.contains("cannot succeed"), message)
        XCTAssertFalse(message.contains("ask_supervisor"), "role does not hold it: \(message)")
    }

    /// A change of error code is a change of CONDITION and may be said once more; a
    /// growing count is not.
    func testSignature_keysOnTheCodeButNotTheCount() {
        let a = LLMExecutionService.loopWarningSignature(
            .repetitiveFailure(tool: "edit_file", count: 3, errorCode: "INVALID_ARGS"), epoch: 0)
        let b = LLMExecutionService.loopWarningSignature(
            .repetitiveFailure(tool: "edit_file", count: 9, errorCode: "INVALID_ARGS"), epoch: 0)
        let c = LLMExecutionService.loopWarningSignature(
            .repetitiveFailure(tool: "edit_file", count: 3, errorCode: "ANCHOR_NOT_FOUND"),
            epoch: 0)
        let d = LLMExecutionService.loopWarningSignature(
            .repetitiveFailure(tool: "edit_file", count: 3, errorCode: "INVALID_ARGS"), epoch: 1)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }

    // MARK: - Same error, different arguments

    /// The shape `.repetitiveFailure` cannot see, taken verbatim from MeditationApp
    /// task 28: `edit_file` failing on one anchor while the model perturbs the
    /// indentation of `new_text` each time. Identity is `(tool, argumentsIdentity)`
    /// everywhere else, so each trailing run measured 1 and nothing fired.
    ///
    /// RED: drop the `detectPersistentToolError` call from `detectLoopPattern` → nil.
    func testSameErrorWithDifferingArguments_fires() {
        let anchorNotFound =
            #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","message":"old_text not found"}}"#
        let calls = [18, 19, 20].map { depth in
            call(
                "edit_file",
                args: #"{"old_text":"same","new_text":"\#(String(repeating: " ", count: depth))x"}"#,
                ok: false,
                result: anchorNotFound)
        }

        guard case .persistentToolError(let tool, let count, let code)? =
            ToolCallLoopDetector.detectLoopPattern(in: calls)
        else {
            return XCTFail("three same-error failures must be reported")
        }
        XCTAssertEqual(tool, "edit_file")
        XCTAssertEqual(count, 3)
        XCTAssertEqual(code, "ANCHOR_NOT_FOUND")
    }

    /// Identical arguments belong to the SIBLING arm, which says something more precise.
    /// The two must never both describe one tail.
    ///
    /// Pins the OUTCOME — which arm claims an identical-argument tail — and nothing about
    /// how that outcome is reached. Measured: neither dropping the guard below nor
    /// swapping the two arms' order in `detectLoopPattern` reds this test, because each
    /// defence alone is sufficient. The guard is the one that carries the weight; the
    /// test below pins it directly.
    func testIdenticalArguments_stayWithTheRepetitiveFailureArm() {
        let calls = Array(repeating: call("edit_file", args: #"{"a":"1"}"#, ok: false), count: 3)
        guard case .repetitiveFailure? = ToolCallLoopDetector.detectLoopPattern(in: calls) else {
            return XCTFail("identical arguments must stay with the precise arm")
        }
    }

    /// …and the SECOND place that disjointness lives: the arm refuses an identical-argument
    /// tail on its own, so it stays correct when called directly and would stay correct if
    /// the ordering above ever changed.
    ///
    /// Reached only by calling the detector directly — through `detectLoopPattern` the
    /// sibling returns first, which is why the ordering test above cannot cover this and
    /// a mutation of the guard went unnoticed until a RED sweep asked.
    ///
    /// RED: drop the `sawDifferingArguments` guard → fires.
    func testDetectPersistentToolError_directly_refusesIdenticalArguments() {
        let calls = Array(repeating: call("edit_file", args: #"{"a":"1"}"#, ok: false), count: 3)
        XCTAssertNil(ToolCallLoopDetector.detectPersistentToolError(in: calls))
    }

    /// Two different error codes are two different problems, not a loop.
    ///
    /// RED: compare only `toolName` → fires on any three consecutive failures.
    func testDifferentErrorCodes_areNotALoop() {
        let invalid = #"{"ok":false,"error":{"code":"INVALID_ARGS","message":"x"}}"#
        let missing = #"{"ok":false,"error":{"code":"FILE_NOT_FOUND","message":"y"}}"#
        let calls = [
            call("edit_file", args: "1", ok: false, result: invalid),
            call("edit_file", args: "2", ok: false, result: missing),
            call("edit_file", args: "3", ok: false, result: invalid),
        ]
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    /// A success breaks the run, exactly as it does for every other arm. This is the
    /// two `read_lines` calls the model interleaved in the real run: the reported run is
    /// the last three failures, never all four.
    ///
    /// RED: drop ALL THREE break guards (`wasSuccessful`, `toolName`, `errorCode`) from the
    /// walk → it runs straight through the interleaved `read_lines` and the count assertion
    /// reads 5 instead of 3.
    ///
    /// Compound deliberately, and the reason is the point: each guard alone bounds this
    /// tail, so no single mutation reds the test. `wasSuccessful` is additionally
    /// unreachable in production — `ToolCallTracker` sets it from `!isError` and
    /// `makeSuccessEnvelope` writes `error: nil`, so a successful call can never carry a
    /// matching code — and it is kept for symmetry with the sibling arm. What this test
    /// pins is the OUTCOME, that the run is bounded at three, not which guard bounds it.
    func testASuccessBreaksTheRun() {
        let anchorNotFound = #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","message":"z"}}"#
        let calls = [
            call("edit_file", args: "0", ok: false, result: anchorNotFound),
            call("read_lines", args: "r", ok: true),
            call("edit_file", args: "1", ok: false, result: anchorNotFound),
            call("edit_file", args: "2", ok: false, result: anchorNotFound),
            call("edit_file", args: "3", ok: false, result: anchorNotFound),
        ]
        guard case .persistentToolError(_, let count, _)? =
            ToolCallLoopDetector.detectLoopPattern(in: calls)
        else {
            return XCTFail("the trailing three must still fire")
        }
        XCTAssertEqual(count, 3, "the successful call must bound the run")
    }

    /// A failure carrying no typed code has nothing tying it to its neighbours. Uses
    /// DIFFERING arguments deliberately: with identical ones the sibling arm claims the
    /// tail on argument identity alone and this arm is never consulted, so the fixture
    /// would pass without exercising the rule it names.
    ///
    /// RED: make `errorCode` optional here → three unrelated untyped failures fire.
    func testFailuresWithoutACode_areNotALoop() {
        let calls = (1...3).map {
            call("bash", args: "cmd\($0)", ok: false, result: #"{"ok":false}"#)
        }
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    /// Information arriving that the model did not ask for bounds this arm too — the
    /// same rule its siblings obey.
    ///
    /// RED: drop the epoch guard → count reads 3 across the boundary.
    func testInformationEpoch_boundsTheRun() {
        let code = #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","message":"z"}}"#
        let calls = [
            call("edit_file", args: "1", ok: false, result: code, epoch: 0),
            call("edit_file", args: "2", ok: false, result: code, epoch: 1),
            call("edit_file", args: "3", ok: false, result: code, epoch: 1),
        ]
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    // MARK: - Advice

    /// The advice must INVERT the sibling's: "change the arguments" is what the model
    /// has already done N times, and repeating it sends it back into the loop.
    ///
    /// RED: reuse the `.repetitiveFailure` text → the message tells the model to change
    /// the arguments it has been changing.
    func testMessage_doesNotTellTheModelToChangeTheArgumentsAgain() {
        let message = LLMExecutionService.loopWarningMessage(
            loopDetection: .persistentToolError(
                tool: "edit_file", count: 3, errorCode: "ANCHOR_NOT_FOUND"),
            allowedToolNames: ["edit_file", "read_file"])

        XCTAssertTrue(message.contains("ANCHOR_NOT_FOUND"), message)
        XCTAssertTrue(message.contains("despite different arguments"), message)
        XCTAssertFalse(
            message.contains("change the arguments"),
            "that is the advice this arm exists to avoid: \(message)")
    }

    /// Tool-aware like every other branch: the measured escape route is named only when
    /// the role actually holds the tool it needs.
    ///
    /// RED: name `read_file` unconditionally → a role without it is steered into
    /// `tool_not_authorized`.
    func testMessage_namesReadFileOnlyWhenTheRoleHasIt() {
        let withRead = LLMExecutionService.loopWarningMessage(
            loopDetection: .persistentToolError(
                tool: "edit_file", count: 3, errorCode: "ANCHOR_NOT_FOUND"),
            allowedToolNames: ["edit_file", "read_file"])
        let withoutRead = LLMExecutionService.loopWarningMessage(
            loopDetection: .persistentToolError(
                tool: "edit_file", count: 3, errorCode: "ANCHOR_NOT_FOUND"),
            allowedToolNames: ["edit_file"])

        XCTAssertTrue(withRead.contains("read_file"), withRead)
        XCTAssertFalse(withoutRead.contains("read_file"), withoutRead)
        XCTAssertTrue(withoutRead.contains("different step"), withoutRead)
    }

    /// The tail both arms match, where the ORDER is therefore observable.
    ///
    /// `X(fail,E), Y(fail,E) x3` — one tool, one error code, X's arguments differing.
    /// The sibling breaks at X and reports a run of 3; this arm treats X's difference as a
    /// flag rather than a break and reports 4. Both fire, so they are NOT disjoint, and
    /// the sibling must be asked first because its description is the more precise one:
    /// the three tail calls really were byte-identical.
    ///
    /// A three-identical-call fixture cannot express this — `sawDifferingArguments` alone
    /// decides there, which is how an earlier RED sweep "confirmed" that the order was
    /// inert and the arms disjoint. Both claims were false.
    ///
    /// RED: swap the two calls in `detectLoopPattern` → `.persistentToolError`, count 4.
    func testOverlappingTail_theIdenticalArgumentsArmWins() {
        let code = #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","message":"z"}}"#
        let calls = [
            call("edit_file", args: "different", ok: false, result: code),
            call("edit_file", args: "same", ok: false, result: code),
            call("edit_file", args: "same", ok: false, result: code),
            call("edit_file", args: "same", ok: false, result: code),
        ]

        // Both arms match this tail — that is the premise, asserted so the test cannot
        // quietly stop being about an overlap.
        XCTAssertNotNil(ToolCallLoopDetector.detectPersistentToolError(in: calls))

        guard case .repetitiveFailure(_, let count, _)? =
            ToolCallLoopDetector.detectLoopPattern(in: calls)
        else {
            return XCTFail("the more precise arm must win an overlapping tail")
        }
        XCTAssertEqual(count, 3, "the identical run is three; X breaks it")
    }

    /// The warn-once gate must key on THIS arm's run too. `visibleCalls` cannot see
    /// failures, so a pure-failure tail answers 0 unless `epochOfTrailingRun` consults the
    /// failure arms — and because the two arms can never both be the reported one, listing
    /// only the sibling left the branch dead by construction for this one. A signature
    /// frozen at epoch 0 is the exact defect the epoch scoping exists to prevent.
    ///
    /// Mirrors `testEpochOfTrailingRun_tracksTheFailureRun`.
    ///
    /// RED: drop the `detectPersistentToolError` term from `epochOfTrailingRun` → it falls
    /// through to `visibleCalls`, which cannot see failures, so the epoch assertion reads 0
    /// instead of 4.
    func testEpochOfTrailingRun_tracksThePersistentErrorRun() {
        let code = #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","message":"z"}}"#
        let calls = (1...3).map {
            call("edit_file", args: "a\($0)", ok: false, result: code, epoch: 4)
        }
        XCTAssertNotNil(ToolCallLoopDetector.detectPersistentToolError(in: calls))
        XCTAssertEqual(ToolCallLoopDetector.epochOfTrailingRun(in: calls), 4)
    }

    /// The two arms are separate CONDITIONS, so a model that moves from holding its
    /// arguments to varying them earns a second warning rather than being suppressed by
    /// the first one's signature.
    func testSignature_differsFromTheIdenticalArgumentsArm() {
        let identical = LLMExecutionService.loopWarningSignature(
            .repetitiveFailure(tool: "edit_file", count: 3, errorCode: "ANCHOR_NOT_FOUND"),
            epoch: 0)
        let varied = LLMExecutionService.loopWarningSignature(
            .persistentToolError(tool: "edit_file", count: 3, errorCode: "ANCHOR_NOT_FOUND"),
            epoch: 0)
        XCTAssertNotEqual(identical, varied)
    }
}
