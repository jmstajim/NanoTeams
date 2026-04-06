import XCTest

@testable import NanoTeams

final class HarmonyToolCallParserFailureTests: XCTestCase {

    // Failure 1 & similar: to=tool with space in JSON or logic
    func testParsesChannelCallWithConstraints() {
        let input =
            "<|channel|>commentary to=repo_browser.read_file <|constrain|>json<|message|>{\"path\":\"runs/artifact_requirements.md\",\"line_start\":1,\"line_end\":400}"
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "repo_browser.read_file")
        // Note: argumentsJSON order might vary but normalization handles it
        XCTAssertTrue(calls[0].argumentsJSON.contains("run"))
    }

    // Failure 2 & 3: "to=tool code<|message|>"
    func testParsesChannelCallWithCodeKeyword() {
        let input =
            "<|channel|>commentary to=repo_browser.read_file code<|message|>{\"path\":\"runs/artifact.md\"}"
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "repo_browser.read_file")
    }

    // Failure with space after to= (hypothetical fix robustness)
    func testParsesChannelCallWithSpaceAfterTo() {
        let input = "<|channel|>commentary to= read_file <|message|>{\"path\":\"file.txt\"}"
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read_file")
    }

    // Fallback strategy: No message marker
    func testParsesChannelCallWithoutMessageMarker() {
        let input = "<|channel|>commentary to=read_file { \"path\": \"file.txt\" }"
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read_file")
        XCTAssertTrue(calls[0].argumentsJSON.contains("file.txt"))
    }

    // Failure 7: JSON with spaces
    func testParsesChannelCallWithSpacesInJSON() {
        let input =
            "<|channel|>commentary to=repo_browser.print_tree <|constrain|>json<|message|>{\"path\": \"\", \"depth\": 2}"
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "repo_browser.print_tree")
    }
}
