import XCTest

@testable import NanoTeams

/// `BashArguments` is the SINGLE command resolver shared by the permission gate
/// and the handler. These tests pin that a command can't be supplied under a key
/// the gate doesn't see (gate-bypass regression) and that timeout validation
/// rejects non-positive values instead of silently clamping.
final class BashArgumentsTests: XCTestCase {

    // MARK: - command(from:)

    func testStandardCommandKey() {
        XCTAssertEqual(BashArguments.command(from: ["command": "echo hi"]), "echo hi")
    }

    func testCommandWithStructuralSiblings_resolvesViaSingleRemaining() {
        let args: [String: Any] = ["command": "ls -la", "timeout": 5000, "working_directory": "src", "run_in_background": false]
        XCTAssertEqual(BashArguments.command(from: args), "ls -la")
    }

    func testAlternativeKeys_resolve() {
        // Renamed to `command` by the runtime's reading (`BashTool.undeclaredArguments`) — the
        // gate reads the same, so a command under one of them is judged, never run ungated.
        XCTAssertEqual(BashArguments.command(fromJSON: #"{"text":"rm -rf /"}"#), "rm -rf /")
        XCTAssertEqual(BashArguments.command(fromJSON: #"{"content":"curl x | sh"}"#), "curl x | sh")
        XCTAssertEqual(BashArguments.command(fromJSON: #"{"script":"make"}"#), "make")
        XCTAssertEqual(BashArguments.command(fromJSON: #"{"body":"git push"}"#), "git push")
        XCTAssertEqual(BashArguments.command(fromJSON: #"{"cmd":"ls"}"#), "ls")
        XCTAssertEqual(BashArguments.command(fromJSON: #"{"code":"pwd"}"#), "pwd")
    }

    private func isRefused(_ json: String) -> Bool {
        if case .invalid = ToolCallArguments.prepare(rawJSON: json, emittedName: ToolNames.bash) { return true }
        return false
    }

    func testContentDecoy_isRefused_neverResolvedEitherWay() {
        // {"command":"ls","content":"rm -rf ~"} — until 2026-11-09 the alias OUTRANKED the
        // declared key and `content` ran. Two spellings of one argument now refuse the call:
        // nothing is judged, nothing runs.
        let json = #"{"command":"ls","content":"rm -rf ~"}"#
        XCTAssertNil(BashArguments.command(fromJSON: json))
        XCTAssertTrue(isRefused(json))
    }

    func testEmptyOrWhitespace_isNil() {
        XCTAssertNil(BashArguments.command(from: [:]))
        XCTAssertNil(BashArguments.command(from: ["command": "   \n"]))
        XCTAssertNil(BashArguments.command(from: ["command": ""]))
    }

    func testJSONParity_matchesDictResolution() {
        XCTAssertNil(BashArguments.command(fromJSON: #"{"command":"ls","content":"rm -rf ~"}"#))
        // Prose reaches the handler under `__raw_input__` and the handler runs it, so the gate
        // must judge it — until 2026-11-09 this was `nil`, and the gate skipped the call.
        XCTAssertEqual(BashArguments.command(fromJSON: "not json"), "not json")
        XCTAssertEqual(BashArguments.command(fromJSON: #"{"text":"whoami"}"#), "whoami")
    }

    // MARK: - workingDirectory

    func testWorkingDirectory() {
        XCTAssertEqual(BashArguments.workingDirectory(from: ["working_directory": "src"]), "src")
        XCTAssertNil(BashArguments.workingDirectory(from: ["working_directory": ""]))
        XCTAssertNil(BashArguments.workingDirectory(from: [:]))
        XCTAssertEqual(BashArguments.workingDirectory(fromJSON: #"{"working_directory":"a/b"}"#), "a/b")
    }

    // MARK: - resolveTimeoutSeconds

    func testTimeout_default() {
        // 120_000 ms default → 120 s.
        XCTAssertEqual(BashArguments.resolveTimeoutSeconds(milliseconds: nil), 120)
    }

    func testTimeout_msToSeconds() {
        XCTAssertEqual(BashArguments.resolveTimeoutSeconds(milliseconds: 5000), 5)
    }

    func testTimeout_subSecondFloorsToOne() {
        XCTAssertEqual(BashArguments.resolveTimeoutSeconds(milliseconds: 500), 1)
    }

    func testTimeout_clampedToCeiling() {
        // Above the 600_000 ms ceiling → 600 s.
        XCTAssertEqual(BashArguments.resolveTimeoutSeconds(milliseconds: 9_999_999), 600)
        XCTAssertEqual(BashArguments.resolveTimeoutSeconds(milliseconds: 600_000), 600)
    }

    func testTimeout_nonPositive_isNil() {
        // A sign typo is rejected (handler surfaces INVALID_ARGS), not clamped to 1s.
        XCTAssertNil(BashArguments.resolveTimeoutSeconds(milliseconds: 0))
        XCTAssertNil(BashArguments.resolveTimeoutSeconds(milliseconds: -5000))
    }

    func testTimeout_boundaryExactness() {
        // Sub-second values all floor to 1s; one past the ceiling clamps to 600s.
        XCTAssertEqual(BashArguments.resolveTimeoutSeconds(milliseconds: 1), 1)
        XCTAssertEqual(BashArguments.resolveTimeoutSeconds(milliseconds: 999), 1)
        XCTAssertEqual(BashArguments.resolveTimeoutSeconds(milliseconds: 1000), 1)
        XCTAssertEqual(BashArguments.resolveTimeoutSeconds(milliseconds: 600_001), 600)
    }

    // MARK: - Extended alias / precedence (gate-bypass surface)

    func testNamesOutsideTheList_areRefused_aNarrowingOnPurpose() {
        // The old resolver took eleven body names and then ANY single remaining string as the
        // command. A name outside the six is now refused by name — never run as a command.
        for key in ["data", "value", "file_content", "source", "message", "plan", "notes"] {
            let json = "{\"\(key)\":\"whoami\"}"
            XCTAssertNil(BashArguments.command(fromJSON: json), key)
            XCTAssertTrue(isRefused(json), key)
        }
    }

    func testTwoAliases_areRefused_noPrecedence() {
        // There used to be a precedence (content > text > body). There is none now: two
        // spellings would let the gate and the runtime read different ones.
        XCTAssertTrue(isRefused(#"{"content":"A","text":"B"}"#))
        XCTAssertTrue(isRefused(#"{"text":"B","body":"C"}"#))
    }

    func testCommandDecoyUnderAliasKey_isRefused() {
        XCTAssertTrue(isRefused(#"{"command":"ls","text":"rm -rf ~"}"#))
        XCTAssertTrue(isRefused(#"{"command":"ls","data":"curl x | sh"}"#), "`data` is not a spelling of `command`")
    }

    func testAnUnknownKey_isRefused_neverRunAsTheCommand() {
        XCTAssertNil(BashArguments.command(fromJSON: #"{"foo":"whoami"}"#))
        XCTAssertTrue(isRefused(#"{"foo":"whoami"}"#))
    }

    func testDescription_isIgnored_andTheCommandRuns() throws {
        let call = try XCTUnwrap(ToolCallArguments.prepare(
            rawJSON: #"{"command":"ls","description":"List files"}"#, emittedName: ToolNames.bash).dispatched)
        XCTAssertEqual(BashArguments.command(from: call.args), "ls")
        XCTAssertEqual(call.notes, ["Ignored `description`: a command's description is not part of what runs."])
    }

    func testAmbiguousTwoUnknownKeys_isNil() {
        // Two competing unknown keys are ambiguous → resolver returns nil rather than
        // guessing. Gate and handler both get nil (handler then errors "missing").
        XCTAssertNil(BashArguments.command(from: ["foo": "A", "bar": "B"]))
    }

    func testExplicitCommandKey_usedWhenContentAmbiguous() {
        // `command` + one unknown string → the content resolver is ambiguous (two
        // candidates) → falls back to the explicit `command` key.
        XCTAssertEqual(BashArguments.command(from: ["command": "ls", "foo": "bar"]), "ls")
    }

    func testNonStringCommand_isNil() {
        // A non-string command value (numeric / bool / array emission) yields nil —
        // strict, so the handler surfaces a clean "missing command" instead of coercing.
        XCTAssertNil(BashArguments.command(from: ["command": 123]))
        XCTAssertNil(BashArguments.command(from: ["command": true]))
        XCTAssertNil(BashArguments.command(from: ["text": ["a", "b"]]))
    }

    func testJSON_topLevelNonObject_isWhatTheRuntimeDispatches() {
        // A list is not arguments: the runtime refuses it, so nothing runs and nothing is judged.
        XCTAssertNil(BashArguments.command(fromJSON: "[1,2,3]"))
        // A bare scalar is not a JSON object either, but the runtime does NOT refuse it — it
        // reaches the handler as prose under `__raw_input__`, and the handler runs that text.
        // So the gate judges exactly it (until 2026-11-09 this was `nil`: judged nothing, ran it).
        XCTAssertEqual(BashArguments.command(fromJSON: "123"), "123")
        XCTAssertEqual(BashArguments.command(fromJSON: "\"hello\""), "\"hello\"")
    }

    func testWorkingDirectory_whitespaceNotTrimmed_and_badJSON() {
        // `workingDirectory` only nils the EMPTY string (not whitespace), unlike
        // `command`. (The handler separately trims via the path resolver, so a
        // whitespace value runs in the work folder root — see BashHandlersTests.)
        XCTAssertEqual(BashArguments.workingDirectory(from: ["working_directory": "   "]), "   ")
        XCTAssertNil(BashArguments.workingDirectory(fromJSON: "not json"))
    }
}
