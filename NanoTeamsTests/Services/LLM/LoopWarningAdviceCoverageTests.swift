import XCTest

@testable import NanoTeams

/// What the app SAYS to a model that is stuck, and whether it says it more than once.
///
/// Every case here failed against the tree that predates its fix (most against the
/// pre-wave-20 tree). The through-line is that the loop warning was assembled in two places:
/// `ToolCallLoopDetector` composed advice with no idea which tools the role holds, and
/// `loopWarningMessage` — the layer whose whole doc comment is about naming only tools in
/// the schema — pasted that advice in verbatim and appended a generic tail to it.
final class LoopWarningAdviceCoverageTests: XCTestCase {

    private typealias Svc = LLMExecutionService
    private typealias TN = ToolNames

    // MARK: - The read-only role

    /// The shipped Code Reviewer — read tools plus `create_artifact` — does six reads in
    /// a row as its NORMAL review behaviour, which is why there is no "all reads"
    /// detection case any more: the removed `.readOnlyLoop` was a tool-CATEGORY predicate,
    /// blind to arguments, so the reviewer doing its job, a role's first orientation in a
    /// fresh folder, and the planning-phase brief's prescribed exploration were all
    /// flagged as loops — with a message ("do not re-read the same files") that was false
    /// for every one of them.
    ///
    /// RED: restore the all-reads category branch as `detectLoopPattern`'s first arm →
    /// this fires.
    func testReviewerReadingSixDistinctFiles_isNotFlaggedAtAll() {
        let calls = [
            Self.call(TN.gitDiff, args: "{}"),
            Self.call(TN.readFile, args: #"{"path":"Sources/A.swift"}"#),
            Self.call(TN.readFile, args: #"{"path":"Sources/B.swift"}"#),
            Self.call(TN.gitLog, args: "{}"),
            Self.call(TN.readFile, args: #"{"path":"Tests/ATests.swift"}"#),
            Self.call(TN.search, args: #"{"query":"TODO"}"#),
        ]
        XCTAssertNil(
            ToolCallLoopDetector.detectLoopPattern(in: calls),
            "six distinct reads are a review, not a loop")
    }

    /// The narrowest role of all — pure read tools, not even a deliverable (the
    /// `fallbackCustomRoleToolIDs` shape). A GENUINE read loop (the same file three times
    /// over) is the identity arm's job now, and its message keeps the tool-aware contract:
    /// it names nothing the role lacks.
    ///
    /// RED: append an unconditional "submit with create_artifact" tail → this fires.
    func testReadLoop_readOnlyRole_namesNoToolItLacks() {
        let schema: Set<String> = [TN.readFile, TN.listFiles, TN.search]
        let msg = Svc.loopWarningMessage(
            loopDetection: .repetitiveTool(tool: TN.readFile, count: 3),
            allowedToolNames: schema)

        for absent in [TN.editFile, TN.writeFile, TN.createArtifact, TN.gitCommit, TN.askSupervisor] {
            XCTAssertFalse(msg.contains(absent), "named \(absent), which is absent: \(msg)")
        }
        XCTAssertTrue(msg.contains("identical arguments"), msg)
    }

    // MARK: - The self-contradicting GUI message

    /// RED: append the old generic tail ("Do one of: change the arguments, …") to every
    /// branch → this fires.
    ///
    /// The detector deliberately substitutes re-capture advice for GUI tools, with a comment
    /// saying "try different arguments" is the WRONG cure — and the caller then appended
    /// exactly that, one sentence later. The model received both instructions in the same
    /// turn.
    func testComputerUseLoop_doesNotContradictItsOwnAdvice() {
        let msg = Svc.loopWarningMessage(
            loopDetection: .repetitiveTool(tool: TN.uiClick, count: 3),
            allowedToolNames: [TN.uiClick, TN.screenCapture])

        XCTAssertTrue(msg.contains(TN.screenCapture), msg)
        XCTAssertFalse(msg.lowercased().contains("change the arguments"), msg)
    }

    /// `screen_capture` is a SIBLING tool, and per-role toolsets differ: a role may hold
    /// `ui_click` without it. Naming it there teaches a vocabulary the runtime rejects.
    func testComputerUseLoop_withoutScreenCapture_doesNotNameIt() {
        let msg = Svc.loopWarningMessage(
            loopDetection: .repetitiveTool(tool: TN.uiClick, count: 3),
            allowedToolNames: [TN.uiClick])
        XCTAssertFalse(msg.contains(TN.screenCapture), msg)
        XCTAssertTrue(msg.lowercased().contains("different element"), msg)
    }

    // MARK: - The plan spin

    /// RED: delete the `.repetitivePlanning` arm from `detectLoopPattern` → nil, and the
    /// tool-aware ladder in `loopWarningMessage` goes back to being unreachable.
    ///
    /// `.repetitiveTool(tool: update_scratchpad)` was impossible to construct — the
    /// repetition counter filters `update_scratchpad` out one line before it counts — so a
    /// role re-planning forever hit neither branch and got no warning, while the ladder
    /// written for it sat dead and a test file asserted it was "a production path".
    func testScratchpadSpin_isDetected() {
        let calls = (1...6).map { i in
            Self.call(TN.updateScratchpad, args: "{\"content\":\"plan v\(i)\"}")
        }
        guard case .repetitivePlanning(let count)? =
            ToolCallLoopDetector.detectLoopPattern(in: calls)
        else {
            return XCTFail("six consecutive scratchpad writes are a plan spin")
        }
        XCTAssertEqual(count, 6)

        let msg = Svc.loopWarningMessage(
            loopDetection: .repetitivePlanning(count: count),
            allowedToolNames: [TN.updateScratchpad, TN.editFile])
        XCTAssertTrue(msg.contains("Plan already recorded"), msg)
        XCTAssertTrue(msg.contains(TN.editFile), msg)
    }

    /// The narrow arm stays narrow: a window that MIXES planning with real work is not a
    /// spin, or every role that records a plan and then acts would be warned.
    func testScratchpadPlusWork_isNotAPlanSpin() {
        let calls = [
            Self.call(TN.updateScratchpad, args: "{\"content\":\"plan\"}"),
            Self.call(TN.updateScratchpad, args: "{\"content\":\"plan 2\"}"),
            Self.call(TN.updateScratchpad, args: "{\"content\":\"plan 3\"}"),
            Self.call(TN.updateScratchpad, args: "{\"content\":\"plan 4\"}"),
            Self.call(TN.updateScratchpad, args: "{\"content\":\"plan 5\"}"),
            Self.call(TN.writeFile, args: "{\"path\":\"a.swift\",\"content\":\"x\"}"),
        ]
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    // MARK: - Identity: the display summarizer is not an identity

    /// RED: key the detector's grouping on `argumentsSummary` again → this fires.
    ///
    /// `ToolCallSummarizer` has no entry for any of the ten Autovisor tools, so every one of
    /// their summaries is `""`. Three `task_status` calls about three DIFFERENT tasks — the
    /// manager's most ordinary review pass — collapsed onto one identity and were reported
    /// as "identical arguments 3 times".
    func testDistinctArguments_onATooWithNoSummarizer_areNotALoop() {
        let calls = [
            Self.call(TN.listTasks, args: "{}"),
            Self.call(TN.messageTask, args: "{\"task_id\":1,\"message\":\"hi\"}"),
            Self.call(TN.controlTask, args: "{\"task_id\":2,\"verb\":\"pause\"}"),
            Self.call(TN.taskStatus, args: "{\"task_id\":1}"),
            Self.call(TN.taskStatus, args: "{\"task_id\":2}"),
            Self.call(TN.taskStatus, args: "{\"task_id\":3}"),
        ]
        XCTAssertNil(
            ToolCallLoopDetector.detectLoopPattern(in: calls),
            "three different tasks are three different calls")
    }

    /// The positive half: the same call three times IN A ROW is a loop, summarizer or
    /// not — a manager polling one task back-to-back instead of calling wait_for_events.
    /// Without this the fix above could be "never detect anything" and still pass.
    /// (Run at the tail — the window state production fires on.)
    func testIdenticalArguments_onATooWithNoSummarizer_isALoop() {
        let calls = [
            Self.call(TN.listTasks, args: "{}"),
            Self.call(TN.messageTask, args: "{\"task_id\":1,\"message\":\"hi\"}"),
            Self.call(TN.controlTask, args: "{\"task_id\":2,\"verb\":\"pause\"}"),
            Self.call(TN.taskStatus, args: "{\"task_id\":7}"),
            Self.call(TN.taskStatus, args: "{\"task_id\":7}"),
            Self.call(TN.taskStatus, args: "{\"task_id\":7}"),
        ]
        guard case .repetitiveTool(let tool, let count)? =
            ToolCallLoopDetector.detectLoopPattern(in: calls)
        else { return XCTFail("three identical task_status calls in a row are a loop") }
        XCTAssertEqual(tool, TN.taskStatus)
        XCTAssertEqual(count, 3)
    }

    /// Key ORDER is not identity — the same call re-serialized differently by the model
    /// must still count as the same call.
    func testKeyOrder_doesNotChangeIdentity() {
        XCTAssertEqual(
            ToolCallTracker.argumentsIdentity(forJSON: "{\"a\":1,\"b\":2}"),
            ToolCallTracker.argumentsIdentity(forJSON: "{\"b\":2,\"a\":1}"))
    }

    /// Quoted numbers fold, because `ToolArgumentHelpers` accepts them wherever it accepts
    /// the bare number — the two calls DO the same thing.
    func testQuotedNumber_foldsWithItsBareSpelling() {
        XCTAssertEqual(
            ToolCallTracker.argumentsIdentity(forJSON: "{\"start_line\":501}"),
            ToolCallTracker.argumentsIdentity(forJSON: "{\"start_line\":\"501\"}"))
    }

    /// …but only on an exact round-trip. `"0501"` is not a spelling of `501`, and merging
    /// values that merely look alike is how a false "you are looping" gets manufactured.
    func testNonCanonicalNumericString_staysDistinct() {
        XCTAssertNotEqual(
            ToolCallTracker.argumentsIdentity(forJSON: "{\"start_line\":501}"),
            ToolCallTracker.argumentsIdentity(forJSON: "{\"start_line\":\"0501\"}"))
    }

    /// Unparseable payloads still have an identity — their own bytes — so a model repeating
    /// one malformed call verbatim is still caught.
    func testMalformedArguments_areIdenticalToThemselves_andNotToOthers() {
        XCTAssertEqual(
            ToolCallTracker.argumentsIdentity(forJSON: "{not json"),
            ToolCallTracker.argumentsIdentity(forJSON: "  {not json  "))
        XCTAssertNotEqual(
            ToolCallTracker.argumentsIdentity(forJSON: "{not json"),
            ToolCallTracker.argumentsIdentity(forJSON: "{also not json"))
    }

    // MARK: - Helpers

    private static func call(
        _ tool: String, args: String, successful: Bool = true, epoch: Int = 0
    ) -> ToolCallTracker.TrackedCall {
        ToolCallTracker.TrackedCall(
            toolName: tool,
            argumentsSummary: "",
            argumentsIdentity: ToolCallTracker.argumentsIdentity(forJSON: args),
            resultSummary: "",
            resultJSON: "{}",
            wasSuccessful: successful,
            informationEpoch: epoch)
    }
}
