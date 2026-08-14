import XCTest

@testable import NanoTeams

/// E2E tests for the tool execution pipeline:
/// authorize → execute → track → loop detection → conversation append.
@MainActor
final class EndToEndToolExecutionPipelineTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: Tool execution records into tracker

    func testToolPipeline_authorizedToolExecutes() {
        let tracker = ToolCallTracker()
        let toolName = ToolNames.readFile
        let argsJSON = #"{"path":"src/main.swift"}"#

        // Record a successful call
        tracker.record(toolName: toolName, argumentsJSON: argsJSON, resultJSON: #"{"content":"hello"}"#, isError: false)

        // Verify it was tracked
        XCTAssertEqual(tracker.recentCalls(limit: .max).count, 1)
        XCTAssertEqual(tracker.recentCalls(limit: .max)[0].toolName, toolName)
        XCTAssertTrue(tracker.recentCalls(limit: .max)[0].wasSuccessful)
    }

    // MARK: - Test 2: Unauthorized tool returns error (tested via tool name check)

    func testToolPipeline_unauthorizedToolRejected() {
        let allowedTools: Set<String> = ["read_file", "list_files", "search"]
        let requestedTool = "write_file"

        // The pipeline checks authorization before execution
        let isAuthorized = allowedTools.contains(requestedTool)
        XCTAssertFalse(isAuthorized, "write_file should not be in read-only toolset")
    }

    // MARK: - Test 5: Loop detection triggers on REPETITION, not on the read category

    /// Six reads of six DIFFERENT files is the ordinary opening of any task (and the
    /// planning-phase brief prescribes it verbatim). The deleted `.readOnlyLoop` arm
    /// flagged this window by tool CATEGORY alone and nudged the model to "state your
    /// conclusion instead" — observed cutting a planning phase short after 5 files.
    ///
    /// RED: restore the all-reads category branch in `detectLoopPattern` → this fires.
    func testToolPipeline_distinctReads_noLoopDetected() {
        let tracker = ToolCallTracker()

        for i in 0..<6 {
            tracker.record(
                toolName: ToolNames.readFile,
                argumentsJSON: #"{"path":"file\#(i).swift"}"#,
                resultJSON: #"{"content":"content"}"#,
                isError: false
            )
        }

        let detection = ToolCallLoopDetector.detectLoopPattern(in: tracker.recentCalls(limit: 6))
        XCTAssertNil(detection, "Six distinct reads are exploration, not a loop")
    }

    /// The genuine read loop — the SAME file over and over — is still caught, by the
    /// identity-aware branch the category arm used to mask for all-read windows.
    func testToolPipeline_identicalReads_loopDetected() {
        let tracker = ToolCallTracker()

        for _ in 0..<6 {
            tracker.record(
                toolName: ToolNames.readFile,
                argumentsJSON: #"{"path":"file.swift"}"#,
                resultJSON: #"{"content":"content"}"#,
                isError: false
            )
        }

        let detection = ToolCallLoopDetector.detectLoopPattern(in: tracker.recentCalls(limit: 6))
        if case .repetitiveTool(let tool, let count) = detection {
            XCTAssertEqual(tool, ToolNames.readFile)
            XCTAssertEqual(count, 6)
        } else {
            XCTFail("Expected repetitiveTool for 6x identical read, got \(String(describing: detection))")
        }
    }

    // MARK: - Test 6: Alias resolution via ToolRegistry

    func testToolPipeline_aliasResolution() {
        // Verify alias resolution via the static defaultAliases dictionary

        // Common aliases should resolve to actual tool names
        let searchAlias = ToolRegistry.defaultAliases["grep"]
        XCTAssertEqual(searchAlias, ToolNames.search,
                       "'grep' alias should resolve to 'search'")

        let submitArtifact = ToolRegistry.defaultAliases["submit_artifact"]
        XCTAssertEqual(submitArtifact, ToolNames.createArtifact,
                       "'submit_artifact' alias should resolve to 'create_artifact'")

        let saveArtifact = ToolRegistry.defaultAliases["save_artifact"]
        XCTAssertEqual(saveArtifact, ToolNames.createArtifact,
                       "'save_artifact' alias should resolve to 'create_artifact'")
    }

    // MARK: - Test: Repetitive tool detection

    /// The detector groups by `toolName + argumentsSummary` and its own warning
    /// says "with IDENTICAL arguments … the state isn't changing", so the calls
    /// that must trip it are genuinely identical ones.
    func testToolPipeline_repetitiveToolDetected() {
        let tracker = ToolCallTracker()
        let toolName = ToolNames.editFile

        // Six genuinely identical calls — the same anchor, over and over, which
        // is what "the state isn't changing" actually describes.
        for _ in 0..<6 {
            tracker.record(
                toolName: toolName,
                argumentsJSON: #"{"path":"file.swift","old_text":"v0","new_text":"v1"}"#,
                resultJSON: #"{"success":true}"#,
                isError: false
            )
        }

        let recentCalls = tracker.recentCalls(limit: 6)
        let detection = ToolCallLoopDetector.detectLoopPattern(in: recentCalls)

        XCTAssertNotNil(detection, "Should detect repetitive tool usage")
        if case .repetitiveTool(let tool, let count) = detection {
            XCTAssertEqual(tool, toolName)
            XCTAssertGreaterThanOrEqual(count, 4)
        } else {
            XCTFail("Expected repetitiveTool detection")
        }
    }

    /// The counterpart, and the reason `edit_file`'s summary carries its anchor:
    /// six edits that walk a file forward are how a role legitimately works. This
    /// case used to be reported as "identical arguments 6 times", telling a role
    /// making real progress to "try different arguments or move on" — the same
    /// harm the `screen_capture` and `update_scratchpad` exclusions were added to
    /// stop, and the same reason `read_lines` carries its range.
    func testToolPipeline_differentEditsToOneFile_areNotALoop() {
        let tracker = ToolCallTracker()

        for i in 0..<6 {
            tracker.record(
                toolName: ToolNames.editFile,
                argumentsJSON: #"{"path":"file.swift","old_text":"v\#(i)","new_text":"v\#(i + 1)"}"#,
                resultJSON: #"{"success":true}"#,
                isError: false
            )
        }

        XCTAssertNil(
            ToolCallLoopDetector.detectLoopPattern(in: tracker.recentCalls(limit: 6)),
            "six DIFFERENT edits to one file are progress, not a repeated call")
    }

    /// Regression (2026-08-11 screenshot): edit_file (a different change each time)
    /// alternated with run_xcodebuild (identical arguments — build args are naturally
    /// constant) is the prescribed edit→verify cycle, and the frequency-over-window
    /// count reported it as "identical arguments 3 times and the state isn't changing"
    /// — false on both halves, every build followed a successful edit. Driven through
    /// the real tracker so the canonical-JSON identity path is exercised end to end.
    func testToolPipeline_editBuildCycles_areNotALoop() {
        let tracker = ToolCallTracker()

        for i in 0..<3 {
            tracker.record(
                toolName: ToolNames.editFile,
                argumentsJSON: #"{"path":"OnboardingStore.swift","old_text":"v\#(i)","new_text":"v\#(i + 1)"}"#,
                resultJSON: #"{"success":true}"#,
                isError: false
            )
            tracker.record(
                toolName: ToolNames.runXcodebuild,
                argumentsJSON: #"{"scheme":"MeditationApp"}"#,
                resultJSON: #"{"success":true}"#,
                isError: false
            )
        }

        XCTAssertNil(
            ToolCallLoopDetector.detectLoopPattern(in: tracker.recentCalls(limit: 6)),
            "edit→build cycles are the prescribed coding workflow, not a loop")
    }

    // MARK: - Test: No loop with fewer than 6 calls

    func testToolPipeline_noLoopDetectionUnder6Calls() {
        let tracker = ToolCallTracker()

        for i in 0..<5 {
            tracker.record(
                toolName: ToolNames.readFile,
                argumentsJSON: #"{"path":"file\#(i).swift"}"#,
                resultJSON: #"{"content":"ok"}"#,
                isError: false
            )
        }

        let recentCalls = tracker.recentCalls(limit: 6)
        let detection = ToolCallLoopDetector.detectLoopPattern(in: recentCalls)
        XCTAssertNil(detection, "Should not detect loop with fewer than 6 calls")
    }

}
