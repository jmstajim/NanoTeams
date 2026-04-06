import XCTest

@testable import NanoTeams

final class StepToolCallTests: XCTestCase {

    // MARK: - isAnalyzing

    func testIsAnalyzing_trueWhenInterimVisionResult() {
        let call = StepToolCall(
            name: ToolNames.analyzeImage,
            argumentsJSON: "{}",
            resultJSON: "{\"ok\":true,\"data\":{\"status\":\"analyzing\",\"path\":\"img.png\"}}",
            isError: false
        )
        XCTAssertTrue(call.isAnalyzing)
    }

    func testIsAnalyzing_falseForOtherToolName() {
        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{}",
            resultJSON: "{\"status\":\"analyzing\"}",
            isError: false
        )
        XCTAssertFalse(call.isAnalyzing)
    }

    func testIsAnalyzing_falseWhenFinalResult() {
        let call = StepToolCall(
            name: ToolNames.analyzeImage,
            argumentsJSON: "{}",
            resultJSON: "{\"ok\":true,\"data\":{\"analysis\":\"A screenshot of code\"}}",
            isError: false
        )
        XCTAssertFalse(call.isAnalyzing)
    }

    func testIsAnalyzing_falseWhenResultContainsWordAnalyzing() {
        // Guard against false positive: real result containing the word "analyzing"
        let call = StepToolCall(
            name: ToolNames.analyzeImage,
            argumentsJSON: "{}",
            resultJSON: "{\"ok\":true,\"data\":{\"analysis\":\"The image shows someone analyzing data\"}}",
            isError: false
        )
        XCTAssertFalse(call.isAnalyzing)
    }

    func testIsAnalyzing_falseWhenError() {
        let call = StepToolCall(
            name: ToolNames.analyzeImage,
            argumentsJSON: "{}",
            resultJSON: "{\"status\":\"analyzing\"}",
            isError: true
        )
        XCTAssertFalse(call.isAnalyzing)
    }

    func testIsAnalyzing_falseWhenResultNil() {
        let call = StepToolCall(
            name: ToolNames.analyzeImage,
            argumentsJSON: "{}",
            resultJSON: nil,
            isError: nil
        )
        XCTAssertFalse(call.isAnalyzing)
    }

    func testIsAnalyzing_trueWhenIsErrorNil() {
        // isError nil treated as non-error via != true
        let call = StepToolCall(
            name: ToolNames.analyzeImage,
            argumentsJSON: "{}",
            resultJSON: "{\"status\":\"analyzing\"}",
            isError: nil
        )
        XCTAssertTrue(call.isAnalyzing)
    }
}
