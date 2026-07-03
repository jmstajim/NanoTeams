import XCTest

@testable import NanoTeams

final class ToolCallLoopDetectorTests: XCTestCase {
    private typealias TN = ToolNames

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private func makeCall(_ toolName: String, args: String = "args", successful: Bool = true) -> ToolCallTracker.TrackedCall {
        ToolCallTracker.TrackedCall(
            toolName: toolName,
            argumentsSummary: args,
            resultSummary: "result",
            resultJSON: "{}",
            timestamp: MonotonicClock.shared.now(),
            wasSuccessful: successful
        )
    }

    // MARK: - Tests

    func testDetectLoopPattern_returnsNilWhenFewerThan6Calls() {
        let calls = (0..<5).map { _ in makeCall(TN.readFile) }
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    func testDetectLoopPattern_detectsReadOnlyLoop() {
        let calls = [
            makeCall(TN.readFile), makeCall(TN.listFiles), makeCall(TN.gitStatus),
            makeCall(TN.search), makeCall(TN.readFile), makeCall(TN.readLines),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)

        if case .readOnlyLoop(let message) = result {
            XCTAssertTrue(message.contains("read-only"))
        } else {
            XCTFail("Expected readOnlyLoop, got \(String(describing: result))")
        }
    }

    func testDetectLoopPattern_detectsRepetitiveTool() {
        let calls = [
            makeCall(TN.writeFile), makeCall(TN.writeFile),
            makeCall(TN.readFile), makeCall(TN.writeFile),
            makeCall(TN.writeFile), makeCall(TN.gitStatus),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)

        if case .repetitiveTool(let tool, let count, _) = result {
            XCTAssertEqual(tool, TN.writeFile)
            XCTAssertEqual(count, 4)
        } else {
            XCTFail("Expected repetitiveTool, got \(String(describing: result))")
        }
    }

    func testDetectLoopPattern_excludesScratchpadFromRepetition() {
        let calls = [
            makeCall(TN.updateScratchpad), makeCall(TN.updateScratchpad),
            makeCall(TN.updateScratchpad), makeCall(TN.updateScratchpad),
            makeCall(TN.readFile), makeCall(TN.writeFile),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)
        XCTAssertNil(result, "update_scratchpad should be excluded from repetitive tool detection")
    }

    // MARK: - Identity-based loop detection (regression EA190834)

    /// Regression: SWE made 7 `write_file` calls in a row, each writing a DIFFERENT path
    /// (package.json → vite.config.ts → tsconfig.json → public/index.html → src/main.tsx →
    /// src/evaluate.ts → src/components/Display.tsx). The previous detector counted only
    /// by tool name and falsely flagged this legitimate scaffolding as a loop. SWE saw
    /// the warning and gave up before completing the UI.
    func testDetectLoopPattern_doesNotFlagSameToolWithDifferentArguments() {
        let calls = [
            makeCall(TN.writeFile, args: "package.json"),
            makeCall(TN.writeFile, args: "vite.config.ts"),
            makeCall(TN.writeFile, args: "tsconfig.json"),
            makeCall(TN.writeFile, args: "public/index.html"),
            makeCall(TN.writeFile, args: "src/main.tsx"),
            makeCall(TN.writeFile, args: "src/evaluate.ts"),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)
        XCTAssertNil(
            result,
            "write_file across distinct paths is normal scaffolding, not a loop"
        )
    }

    /// Positive case for new identity check: same tool + same args 3+ times → real loop.
    func testDetectLoopPattern_flagsIdenticalCallsRepeated() {
        let calls = [
            makeCall(TN.writeFile, args: "src/App.tsx"),
            makeCall(TN.writeFile, args: "src/App.tsx"),
            makeCall(TN.writeFile, args: "src/App.tsx"),
            makeCall(TN.readFile, args: "elsewhere.swift"),
            makeCall(TN.gitStatus, args: "_"),
            makeCall(TN.search, args: "foo"),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)
        if case .repetitiveTool(let tool, let count, let message) = result {
            XCTAssertEqual(tool, TN.writeFile)
            XCTAssertEqual(count, 3)
            XCTAssertTrue(message.contains("identical arguments"))
        } else {
            XCTFail("Expected repetitiveTool for 3x identical write, got \(String(describing: result))")
        }
    }

    // MARK: - Computer-use identity + advice (regression: LinkedIn run 2026-07-02)

    /// Regression: 4 `ui_click` calls at DIFFERENT coordinates ((1257,55), (1257,90),
    /// (1257,60), (1408,126)) were flagged as "identical arguments 4 times" — the summarizer
    /// had no ui_click entry, every argumentsSummary was "", and all clicks collapsed onto
    /// one identity key. The model was then told to "try different arguments" while it
    /// already was. Distinct coordinates must not be a loop.
    func testDetectLoopPattern_uiClicksAtDifferentCoordinates_notALoop() {
        let coords = ["(1257, 55)", "(1257, 90)", "(1257, 60)", "(1408, 126)", "(587, 61)", "(834, 190)"]
        let calls = coords.map { makeCall(TN.uiClick, args: $0) }
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    func testDetectLoopPattern_identicalUIClicks_adviseRecapture_notDifferentArguments() {
        // For GUI tools the cure for a true identical-click loop is a fresh screenshot —
        // the model is probing a UI it can no longer see.
        let calls = [
            makeCall(TN.uiClick, args: "(100, 200)"),
            makeCall(TN.uiClick, args: "(100, 200)"),
            makeCall(TN.uiClick, args: "(100, 200)"),
            makeCall(TN.uiKey, args: "return"),
            makeCall(TN.uiType, args: "hello"),
            makeCall(TN.uiScroll, args: "(5, 5) d(0, -3)"),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)
        if case .repetitiveTool(let tool, _, let message) = result {
            XCTAssertEqual(tool, TN.uiClick)
            XCTAssertTrue(message.contains("screen_capture"), "GUI loop advice must be re-capture")
            XCTAssertFalse(message.contains("try different arguments"))
        } else {
            XCTFail("Expected repetitiveTool, got \(String(describing: result))")
        }
    }

    /// Regression: re-capturing the same target is the PRESCRIBED workflow (UI changes between
    /// calls). Counting screen_capture flagged the canonical capture→click→capture loop AND made
    /// the nudge advise the very action it flagged. It must be excluded like update_scratchpad.
    func testDetectLoopPattern_repeatedScreenCapture_notALoop() {
        let calls = [
            makeCall(TN.screenCapture, args: "Safari"),
            makeCall(TN.uiClick, args: "(10, 20)"),
            makeCall(TN.screenCapture, args: "Safari"),
            makeCall(TN.uiClick, args: "(30, 40)"),
            makeCall(TN.screenCapture, args: "Safari"),
            makeCall(TN.uiClick, args: "(50, 60)"),
        ]
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    func testDetectLoopPattern_nonGUITool_keepsDifferentArgumentsAdvice() {
        let calls = [
            makeCall(TN.writeFile, args: "src/App.tsx"),
            makeCall(TN.writeFile, args: "src/App.tsx"),
            makeCall(TN.writeFile, args: "src/App.tsx"),
            makeCall(TN.readFile, args: "a"), makeCall(TN.readFile, args: "b"),
            makeCall(TN.search, args: "foo"),
        ]
        guard case .repetitiveTool(_, _, let message)? = ToolCallLoopDetector.detectLoopPattern(in: calls) else {
            return XCTFail("Expected repetitiveTool")
        }
        XCTAssertTrue(message.contains("try different arguments"))
        XCTAssertFalse(message.contains("screen_capture"))
    }
}
