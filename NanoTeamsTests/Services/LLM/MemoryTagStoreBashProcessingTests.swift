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
            bashResult(command: "ls", output: #"{"ok":true,"data":{"stdout":"a"}}"#), iteration: 1)
        if case .tagged = r { /* ok */ } else { XCTFail("expected .tagged, got \(r)") }
    }

    func testRepeatIdenticalOutput_reference() {
        let result = bashResult(command: "ls", output: #"{"ok":true,"data":{"stdout":"a"}}"#)
        _ = store.processToolResult(result, iteration: 1)
        let second = store.processToolResult(result, iteration: 2)
        if case .reference = second { /* ok */ } else { XCTFail("expected .reference, got \(second)") }
    }

    func testChangedOutput_newTag() {
        _ = store.processToolResult(
            bashResult(command: "ls", output: #"{"ok":true,"data":{"stdout":"a"}}"#), iteration: 1)
        let changed = store.processToolResult(
            bashResult(command: "ls", output: #"{"ok":true,"data":{"stdout":"a b"}}"#), iteration: 2)
        if case .tagged = changed { /* ok */ } else { XCTFail("expected .tagged for changed output, got \(changed)") }
    }

    func testError_passthrough() {
        let r = store.processToolResult(
            bashResult(command: "rm -rf /", output: #"{"ok":false}"#, isError: true), iteration: 1)
        if case .passthrough = r { /* ok */ } else { XCTFail("expected .passthrough for error") }
    }

    func testDistinctCommands_independentTags() {
        let a = store.processToolResult(
            bashResult(command: "ls", output: #"{"ok":true,"data":{"stdout":"x"}}"#), iteration: 1)
        let b = store.processToolResult(
            bashResult(command: "pwd", output: #"{"ok":true,"data":{"stdout":"x"}}"#), iteration: 2)
        // Same output bytes but different commands → both tagged (not deduped).
        if case .tagged = a {} else { XCTFail("first should be tagged") }
        if case .tagged = b {} else { XCTFail("distinct command should be tagged even with identical output") }
    }

    private func bashResultInDir(command: String, dir: String, output: String) -> ToolExecutionResult {
        ToolExecutionResult(
            toolName: ToolNames.bash,
            argumentsJSON: #"{"command":"\#(command)","working_directory":"\#(dir)"}"#,
            outputJSON: output, isError: false)
    }

    func testSameCommandDifferentWorkingDirectory_independentTags() {
        let same = #"{"ok":true,"data":{"stdout":"x"}}"#
        let a = store.processToolResult(bashResultInDir(command: "ls", dir: "src", output: same), iteration: 1)
        let b = store.processToolResult(bashResultInDir(command: "ls", dir: "tests", output: same), iteration: 2)
        if case .tagged = a {} else { XCTFail("first dir should be tagged") }
        // Identical output bytes but a DIFFERENT directory must NOT collapse to a
        // stale reference — the key folds in working_directory.
        if case .tagged = b {} else { XCTFail("same command in a different dir must stay independently tagged") }
    }

    func testSameCommandSameWorkingDirectory_reference() {
        let same = #"{"ok":true,"data":{"stdout":"x"}}"#
        _ = store.processToolResult(bashResultInDir(command: "ls", dir: "src", output: same), iteration: 1)
        let second = store.processToolResult(bashResultInDir(command: "ls", dir: "src", output: same), iteration: 2)
        if case .reference = second {} else { XCTFail("identical re-run in the same dir should reference") }
    }

    // MARK: - Key injectivity (length-prefixed cwd)

    func testCommandKey_isInjectiveAcrossDirCommandBoundary() {
        // (cwd "a", cmd "bc") vs (cwd "ab", cmd "c") concatenate to the same "abc"
        // under a naive separator-free join — the length prefix keeps them distinct.
        let k1 = MemoryTagStore.bashCommandKey(from: #"{"command":"bc","working_directory":"a"}"#)
        let k2 = MemoryTagStore.bashCommandKey(from: #"{"command":"c","working_directory":"ab"}"#)
        XCTAssertNotEqual(k1, k2)
    }

    func testCommandKey_stableAndDirSensitive() {
        let a = MemoryTagStore.bashCommandKey(from: #"{"command":"ls","working_directory":"src"}"#)
        let b = MemoryTagStore.bashCommandKey(from: #"{"command":"ls","working_directory":"src"}"#)
        XCTAssertEqual(a, b)
        // No working_directory is a distinct key from any non-empty dir.
        XCTAssertNotEqual(a, MemoryTagStore.bashCommandKey(from: #"{"command":"ls"}"#))
    }
}
