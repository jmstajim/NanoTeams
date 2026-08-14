import XCTest

@testable import NanoTeams

final class MemoryTagStoreBashProcessingTests: XCTestCase {

    var store: MemoryTagStore!

    override func setUp() {
        super.setUp()
        store = MemoryTagStore()
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func bashResult(command: String, output: String, isError: Bool = false) -> ToolExecutionResult {
        ToolExecutionResult(
            toolName: ToolNames.bash,
            argumentsJSON: "{\"command\":\"\(command)\"}",
            outputJSON: output,
            isError: isError)
    }

    func testNewCommand_tagged() {
        let r = store.processToolResult(
            bashResult(command: "ls", output: #"{"ok":true,"data":{"stdout":"a"}}"#))
        guard case .tagged(let content, let tag) = r else {
            return XCTFail("expected .tagged, got \(r)")
        }
        XCTAssertEqual(tag, "<§S1§>")
        XCTAssertTrue(content.contains("\"stdout\":\"a\"") || content.contains("stdout"),
                      "the full output rides the envelope: \(content)")
    }

    /// The anti-dedup pin for bash: an identical re-run gets a FRESH tag and the
    /// FULL output again — there is no unchanged-reference collapse any more.
    ///
    /// RED: reintroduce a same-command/same-output reference branch → this fails.
    func testRepeatIdenticalOutput_getsFreshTagAndFullOutput() {
        let result = bashResult(command: "ls", output: #"{"ok":true,"data":{"stdout":"a"}}"#)
        _ = store.processToolResult(result)
        let second = store.processToolResult(result)

        guard case .tagged(let content, let tag) = second else {
            return XCTFail("expected .tagged, got \(second)")
        }
        XCTAssertEqual(tag, "<§S2§>", "every action mints its own tag")
        XCTAssertTrue(content.contains("stdout"), "the full output ships every time")
    }

    func testError_passthrough() {
        let r = store.processToolResult(
            bashResult(command: "rm -rf /", output: #"{"ok":false}"#, isError: true))
        if case .passthrough = r { /* ok */ } else { XCTFail("expected .passthrough for error") }
    }

    func testDistinctCommands_independentTags() {
        let a = store.processToolResult(
            bashResult(command: "ls", output: #"{"ok":true,"data":{"stdout":"x"}}"#))
        let b = store.processToolResult(
            bashResult(command: "pwd", output: #"{"ok":true,"data":{"stdout":"x"}}"#))
        guard case .tagged(_, let tagA) = a, case .tagged(_, let tagB) = b else {
            return XCTFail("both commands should be tagged")
        }
        XCTAssertNotEqual(tagA, tagB)
    }
}
