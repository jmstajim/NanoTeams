import XCTest

@testable import NanoTeams

final class ToolCallLoopDetectorTests: XCTestCase {
    private typealias TN = ToolNames

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private func makeCall(_ toolName: String, successful: Bool = true) -> ToolCallCache.TrackedCall {
        ToolCallCache.TrackedCall(
            toolName: toolName,
            argumentsSummary: "args",
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
}
