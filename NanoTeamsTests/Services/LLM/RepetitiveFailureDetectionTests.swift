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

    /// Different arguments are different attempts, however similar the outcome.
    func testDifferentArgumentsFailing_isNotARun() {
        let calls = [
            call("edit_file", args: #"{"a":"1"}"#, ok: false),
            call("edit_file", args: #"{"a":"2"}"#, ok: false),
            call("edit_file", args: #"{"a":"3"}"#, ok: false),
        ]
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
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
}
