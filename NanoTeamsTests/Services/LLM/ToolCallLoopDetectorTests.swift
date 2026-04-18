import XCTest

@testable import NanoTeams

final class ToolCallLoopDetectorTests: XCTestCase {
    private typealias TN = ToolNames

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private func makeCall(_ toolName: String, args: String = "args", successful: Bool = true) -> ToolCallCache.TrackedCall {
        ToolCallCache.TrackedCall(
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
}
