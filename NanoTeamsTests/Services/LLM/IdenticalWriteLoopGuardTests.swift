import XCTest

@testable import NanoTeams

/// Guards the identical-write loop fix: a second `write_file` with the same `(path, content)`
/// in one step is rejected as a loop. Reproduces the Gemma-4-26b-a4b incident
/// (tasks/9/subtasks/10 — Software Engineer wrote `script.js` 14× with the exact same
/// 3945-byte content) at the per-step tracker level — `ToolCallTracker` records each
/// `write_file` fingerprint and the atomic `checkAndRecordWrite` short-circuits duplicates.
final class IdenticalWriteLoopGuardTests: XCTestCase {

    private typealias TN = ToolNames

    var sut: ToolCallTracker!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        sut = ToolCallTracker()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Identical write detection

    func testIsDuplicateIdenticalWrite_returnsFalse_forFirstCall() {
        let args = #"{"path":"script.js","content":"hello"}"#
        XCTAssertFalse(sut.isDuplicateIdenticalWrite(toolName: TN.writeFile, argumentsJSON: args))
    }

    func testIsDuplicateIdenticalWrite_returnsTrue_afterIdenticalRecord() {
        let args = #"{"path":"script.js","content":"hello"}"#
        sut.recordWriteFingerprint(toolName: TN.writeFile, argumentsJSON: args)
        XCTAssertTrue(sut.isDuplicateIdenticalWrite(toolName: TN.writeFile, argumentsJSON: args))
    }

    func testIsDuplicateIdenticalWrite_returnsFalse_forDifferentContentSamePath() {
        let first = #"{"path":"script.js","content":"hello"}"#
        let second = #"{"path":"script.js","content":"world"}"#
        sut.recordWriteFingerprint(toolName: TN.writeFile, argumentsJSON: first)
        XCTAssertFalse(sut.isDuplicateIdenticalWrite(toolName: TN.writeFile, argumentsJSON: second))
    }

    func testIsDuplicateIdenticalWrite_returnsFalse_forSameContentDifferentPath() {
        let first = #"{"path":"a.js","content":"hello"}"#
        let second = #"{"path":"b.js","content":"hello"}"#
        sut.recordWriteFingerprint(toolName: TN.writeFile, argumentsJSON: first)
        XCTAssertFalse(sut.isDuplicateIdenticalWrite(toolName: TN.writeFile, argumentsJSON: second))
    }

    func testIsDuplicateIdenticalWrite_isolatedToWriteFile() {
        // edit_file goes through a different code path (anchor-based replace) and isn't covered
        // by this guard — repeated edit_file calls have natural failure modes (anchor not found
        // after first edit). The guard intentionally fires only on `write_file`.
        let args = #"{"path":"script.js","old_text":"a","new_text":"b"}"#
        sut.recordWriteFingerprint(toolName: TN.editFile, argumentsJSON: args)
        XCTAssertFalse(sut.isDuplicateIdenticalWrite(toolName: TN.editFile, argumentsJSON: args))
    }

    func testRecordWriteFingerprint_handlesInvalidJSON_silently() {
        // Garbage input shouldn't crash or poison the fingerprint set.
        sut.recordWriteFingerprint(toolName: TN.writeFile, argumentsJSON: "not json")
        XCTAssertFalse(sut.isDuplicateIdenticalWrite(toolName: TN.writeFile, argumentsJSON: "not json"))
    }

    func testRecordWriteFingerprint_ignoresMissingFields() {
        // Missing `content` → no fingerprint recorded.
        sut.recordWriteFingerprint(toolName: TN.writeFile, argumentsJSON: #"{"path":"foo.js"}"#)
        XCTAssertFalse(sut.isDuplicateIdenticalWrite(
            toolName: TN.writeFile,
            argumentsJSON: #"{"path":"foo.js","content":"x"}"#
        ))
    }

    /// The 14× identical-content scenario from the Gemma incident: one record, then 13 duplicate
    /// detections all hit. Establishes the loop is detected from call #2 onward.
    func testIsDuplicateIdenticalWrite_repeatedDetections_afterFirstRecord() {
        let content = String(repeating: "x", count: 3945)
        let args = "{\"path\":\"script.js\",\"content\":\"\(content)\"}"
        sut.recordWriteFingerprint(toolName: TN.writeFile, argumentsJSON: args)

        for callIndex in 2...14 {
            XCTAssertTrue(
                sut.isDuplicateIdenticalWrite(toolName: TN.writeFile, argumentsJSON: args),
                "Call #\(callIndex) should be flagged as identical-write loop"
            )
        }
    }

    // MARK: - Atomic check-and-record (write-guard ordering invariant)

    /// `checkAndRecordWrite` fuses `isDuplicateIdenticalWrite` + `recordWriteFingerprint`
    /// into one method so the ordering invariant lives in the type, not in a caller
    /// comment. First call returns `false` (not yet a duplicate) AND records the
    /// fingerprint as a side effect; subsequent identical calls return `true`.
    func testCheckAndRecordWrite_firstCall_returnsFalseAndRecordsFingerprint() {
        let args = #"{"path":"script.js","content":"hello"}"#

        XCTAssertFalse(sut.checkAndRecordWrite(toolName: TN.writeFile, argumentsJSON: args),
                       "First write_file must not be flagged as duplicate")
        // Side effect: fingerprint recorded — observable via the legacy split API.
        XCTAssertTrue(sut.isDuplicateIdenticalWrite(toolName: TN.writeFile, argumentsJSON: args),
                      "checkAndRecordWrite must record the fingerprint atomically")
    }

    func testCheckAndRecordWrite_secondIdenticalCall_returnsTrue() {
        let args = #"{"path":"script.js","content":"hello"}"#
        _ = sut.checkAndRecordWrite(toolName: TN.writeFile, argumentsJSON: args)
        XCTAssertTrue(sut.checkAndRecordWrite(toolName: TN.writeFile, argumentsJSON: args),
                      "Second identical checkAndRecordWrite must return true")
    }

    func testCheckAndRecordWrite_differentContentSamePath_returnsFalse() {
        let first = #"{"path":"script.js","content":"hello"}"#
        let second = #"{"path":"script.js","content":"world"}"#
        _ = sut.checkAndRecordWrite(toolName: TN.writeFile, argumentsJSON: first)
        XCTAssertFalse(sut.checkAndRecordWrite(toolName: TN.writeFile, argumentsJSON: second))
    }

    /// `edit_file` and other non-`write_file` tools go through their own collision modes;
    /// the fingerprint guard intentionally fires only on `write_file`. The atomic helper
    /// must preserve that: every non-write_file call returns `false`, regardless of repetition.
    func testCheckAndRecordWrite_isolatedToWriteFile() {
        let args = #"{"path":"script.js","old_text":"a","new_text":"b"}"#
        XCTAssertFalse(sut.checkAndRecordWrite(toolName: TN.editFile, argumentsJSON: args))
        XCTAssertFalse(sut.checkAndRecordWrite(toolName: TN.editFile, argumentsJSON: args))
    }

    // MARK: - Per-step isolation

    func testFingerprintsResetWhenNewTrackerCreated() {
        // ToolCallTracker is per-step; a fresh instance must not see fingerprints from a prior step.
        let args = #"{"path":"script.js","content":"hello"}"#
        sut.recordWriteFingerprint(toolName: TN.writeFile, argumentsJSON: args)
        XCTAssertTrue(sut.isDuplicateIdenticalWrite(toolName: TN.writeFile, argumentsJSON: args))

        let nextStep = ToolCallTracker()
        XCTAssertFalse(nextStep.isDuplicateIdenticalWrite(toolName: TN.writeFile, argumentsJSON: args))
    }

    // MARK: - Reject envelope shape

    func testMakeIdenticalWriteLoopResult_envelopeShape() {
        let call = StepToolCall(
            providerID: "tool-call-1",
            name: TN.writeFile,
            argumentsJSON: #"{"path":"script.js","content":"hello"}"#
        )
        let result = LLMExecutionService.makeIdenticalWriteLoopResult(call: call)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains(#""error":"identical_write_loop""#))
        XCTAssertTrue(result.outputJSON.contains(#""path":"script.js""#))
        XCTAssertEqual(result.providerID, "tool-call-1")
    }
}
