import XCTest
@testable import NanoTeams

/// Pins the LLM-facing `.user` follow-up message that `LLMExecutionService` appends
/// after every `isError: true` tool result. Two executor-emitted error codes
/// (`tool_not_authorized`, `identical_write_loop`) require bespoke guidance because
/// the generic "Retry the tool call with the correct arguments" suffix actively
/// misleads the model into looping — args are not the cause in either case.
///
/// Handler-emitted error codes (INVALID_ARGS, FILE_NOT_FOUND, etc.) intentionally
/// keep the generic suffix; the bad arguments ARE the cause.
@MainActor
final class ToolErrorGuidanceTests: XCTestCase {

    var sut: LLMExecutionService!

    override func setUp() {
        super.setUp()
        sut = LLMExecutionService(repository: NTMSRepository())
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - tool_not_authorized

    /// Reproduces the screenshot case: Code Reviewer emits `list_files /` but the
    /// tool is not in its toolset. Generic "retry with correct arguments" tells
    /// the model the args are wrong — they aren't; the tool itself is unavailable.
    func testGuidance_toolNotAuthorized_directsToPickDifferentTool() {
        let call = StepToolCall(name: "list_files", argumentsJSON: #"{"path":"/"}"#)
        let envelope = LLMExecutionService.makeToolNotAuthorizedResult(
            call: call,
            canonicalName: "list_files",
            scope: "for this role"
        )

        let guidance = sut.buildToolErrorGuidance(result: envelope)

        XCTAssertTrue(
            guidance.contains("for this role"),
            "expected the executor's scope ('for this role') from envelope.message, got: \(guidance)"
        )
        XCTAssertTrue(
            guidance.contains("do not retry 'list_files'"),
            "expected explicit anti-loop instruction, got: \(guidance)"
        )
        XCTAssertFalse(
            guidance.contains("with the correct arguments"),
            "generic 'retry with correct arguments' is misleading for unauthorized tools, got: \(guidance)"
        )
    }

    /// `MeetingToolExecutor` emits the same envelope shape with `scope: "in this
    /// meeting"` — the message field is the only carrier of that distinction.
    /// Pre-fix the guidance synthesized "is not in your toolset" verbatim and
    /// dropped the envelope's message entirely, so a meeting-rejected tool was
    /// reported as a role-level rejection. The model would then re-attempt the
    /// tool outside the meeting (where it might be authorized), creating a loop.
    func testGuidance_toolNotAuthorized_meetingScope_surfacesEnvelopeMessage() {
        let call = StepToolCall(name: "write_file", argumentsJSON: #"{"path":"x.swift"}"#)
        let envelope = LLMExecutionService.makeToolNotAuthorizedResult(
            call: call,
            canonicalName: "write_file",
            scope: "in this meeting"
        )

        let guidance = sut.buildToolErrorGuidance(result: envelope)

        XCTAssertTrue(
            guidance.contains("in this meeting"),
            "Meeting-scope envelope.message must surface — pre-fix it was discarded for synthesized 'for this role' text. Got: \(guidance)"
        )
        XCTAssertFalse(
            guidance.contains("for this role"),
            "Synthesized role-scope text must NOT override envelope's meeting scope. Got: \(guidance)"
        )
        XCTAssertTrue(
            guidance.contains("do not retry 'write_file'"),
            "Anti-loop suffix must be appended to the envelope message. Got: \(guidance)"
        )
    }

    /// Defensive: malformed `tool_not_authorized` envelope without `message`
    /// (or with empty message) — guidance falls back to a generic intro using
    /// the tool name. Symmetric to `testGuidance_identicalWriteLoop_missingPath_*`.
    func testGuidance_toolNotAuthorized_missingMessage_usesGenericIntro() {
        let envelope = ToolExecutionResult(
            toolName: "delete_file",
            argumentsJSON: "{}",
            outputJSON: #"{"error":"tool_not_authorized","tool":"delete_file"}"#,
            isError: true
        )

        let guidance = sut.buildToolErrorGuidance(result: envelope)

        XCTAssertTrue(
            guidance.contains("'delete_file'"),
            "Generic intro must name the tool, got: \(guidance)"
        )
        XCTAssertTrue(
            guidance.contains("do not retry 'delete_file'"),
            "Anti-loop suffix must still fire on missing message, got: \(guidance)"
        )
    }

    // MARK: - identical_write_loop

    /// A second `write_file` with identical (path, content) is rejected as a loop.
    /// Generic guidance tells the model to "retry with correct arguments" — but
    /// the args are EXACTLY what was just rejected as duplicate. The model needs
    /// to verify state, not retry blindly.
    func testGuidance_identicalWriteLoop_directsToReadAndNotRewrite() {
        let call = StepToolCall(
            name: "write_file",
            argumentsJSON: #"{"path":"src/foo.swift","content":"let x = 1\n"}"#
        )
        let envelope = LLMExecutionService.makeIdenticalWriteLoopResult(call: call)

        let guidance = sut.buildToolErrorGuidance(result: envelope)

        XCTAssertTrue(
            guidance.contains("Identical write"),
            "expected 'Identical write' framing in guidance, got: \(guidance)"
        )
        XCTAssertTrue(
            guidance.contains("src/foo.swift"),
            "expected the offending path embedded in guidance, got: \(guidance)"
        )
        XCTAssertTrue(
            guidance.contains("do not re-issue"),
            "expected explicit anti-loop instruction, got: \(guidance)"
        )
        XCTAssertFalse(
            guidance.contains("with the correct arguments"),
            "generic 'retry with correct arguments' is misleading after a write-loop rejection, got: \(guidance)"
        )
    }

    /// Defensive: production always emits `path` in the envelope, but parser
    /// must not crash or interpolate `''` when a malformed envelope omits it.
    func testGuidance_identicalWriteLoop_missingPath_usesGenericPlaceholder() {
        let envelope = ToolExecutionResult(
            toolName: "write_file",
            argumentsJSON: "{}",
            outputJSON: #"{"error":"identical_write_loop","message":"Identical write to '?' already executed in this step."}"#,
            isError: true
        )

        let guidance = sut.buildToolErrorGuidance(result: envelope)

        XCTAssertTrue(
            guidance.contains("the file"),
            "expected 'the file' placeholder when path field is missing, got: \(guidance)"
        )
        XCTAssertFalse(
            guidance.contains("''"),
            "guidance must not interpolate empty quotes when path is missing, got: \(guidance)"
        )
    }

    /// `makeIdenticalWriteLoopResult` uses `"?"` as the literal sentinel when
    /// args lack a parseable `path` (e.g. a malformed `write_file` call). The
    /// pre-fix filter only collapsed empty strings, so the guidance rendered
    /// `to '?'` — confusing prose that the LLM might interpret as a literal
    /// path. Treating `"?"` as nil routes through the same `"the file"`
    /// fallback the missing-field test covers.
    func testGuidance_identicalWriteLoop_questionMarkPath_usesGenericPlaceholder() {
        let envelope = ToolExecutionResult(
            toolName: "write_file",
            argumentsJSON: "{}",
            outputJSON: #"{"error":"identical_write_loop","path":"?","message":"Identical write to '?' already executed in this step."}"#,
            isError: true
        )

        let guidance = sut.buildToolErrorGuidance(result: envelope)

        XCTAssertTrue(
            guidance.contains("the file"),
            "?-sentinel must collapse to 'the file' placeholder, got: \(guidance)"
        )
        XCTAssertFalse(
            guidance.contains("'?'"),
            "?-sentinel must not appear as a literal path, got: \(guidance)"
        )
    }

    // MARK: - anchor_not_found

    /// `edit_file` returns ANCHOR_NOT_FOUND when `old_text` no longer matches —
    /// the file changed since the last read. Generic "retry with correct
    /// arguments" tells the model to fuzz `old_text` blindly instead of
    /// re-reading. The bespoke branch names the path and prescribes "re-read".
    /// Pin both the path embedding and the re-read direction.
    func testGuidance_anchorNotFound_directsToReread() {
        let envelope = ToolExecutionResult(
            toolName: "edit_file",
            argumentsJSON: #"{"path":"src/foo.swift","old_text":"foo","new_text":"bar"}"#,
            outputJSON: #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","message":"old_text not found in file."}}"#,
            isError: true
        )

        let guidance = sut.buildToolErrorGuidance(result: envelope)

        XCTAssertTrue(
            guidance.contains("src/foo.swift"),
            "Expected path embedded in guidance, got: \(guidance)"
        )
        XCTAssertTrue(
            guidance.lowercased().contains("re-read"),
            "Expected explicit 're-read' direction, got: \(guidance)"
        )
        XCTAssertFalse(
            guidance.contains("Retry the tool call with the correct arguments"),
            "Generic retry-with-args suffix misleads after ANCHOR_NOT_FOUND, got: \(guidance)"
        )
    }

    /// Defensive: ANCHOR_NOT_FOUND envelope where `argumentsJSON` lacks `path`
    /// — should collapse to "the file" placeholder, not interpolate empty quotes.
    func testGuidance_anchorNotFound_missingPath_usesGenericPlaceholder() {
        let envelope = ToolExecutionResult(
            toolName: "edit_file",
            argumentsJSON: "{}",
            outputJSON: #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","message":"old_text not found"}}"#,
            isError: true
        )

        let guidance = sut.buildToolErrorGuidance(result: envelope)

        XCTAssertTrue(
            guidance.contains("the file"),
            "Missing path must fall back to 'the file' placeholder, got: \(guidance)"
        )
        XCTAssertFalse(
            guidance.contains("''"),
            "Missing path must not render empty quotes, got: \(guidance)"
        )
    }

    // MARK: - default branch (regression pins)

    /// Handler-shape envelope (`{"error":{"code":"...","message":"..."}}`) is
    /// what every `ToolErrorHandler.execute` body emits. Args ARE the cause for
    /// `INVALID_ARGS`, so "retry with correct arguments" is correct guidance.
    func testGuidance_genericInvalidArgs_keepsRetryWording() {
        let envelope = ToolExecutionResult(
            toolName: "edit_file",
            argumentsJSON: "{}",
            outputJSON: #"{"error":{"code":"INVALID_ARGS","message":"missing required field 'path'"}}"#,
            isError: true
        )

        let guidance = sut.buildToolErrorGuidance(result: envelope)

        XCTAssertTrue(
            guidance.contains("Retry the tool call with the correct arguments"),
            "default branch must preserve generic retry wording for handler-shape errors, got: \(guidance)"
        )
        XCTAssertTrue(
            guidance.contains("missing required field 'path'"),
            "default branch must echo the handler's error message, got: \(guidance)"
        )
    }

    /// Default-branch envelopes carry a typed `code` (`DELEGATION_DENIED`,
    /// `DELEGATION_TIMED_OUT`, `INVALID_ARGS`, etc.) — the LLM needs to see it
    /// to disambiguate recovery (don't-retry vs maybe-retry vs fix-args).
    /// Pre-fix only the message text was surfaced, dropping the structural
    /// signal that distinguishes these cases.
    func testGuidance_genericInvalidArgs_includesCodeInDetail() {
        let envelope = ToolExecutionResult(
            toolName: "delegate_to_team",
            argumentsJSON: "{}",
            outputJSON: #"{"error":{"code":"DELEGATION_DENIED","message":"role is not a top-level delegator"}}"#,
            isError: true
        )

        let guidance = sut.buildToolErrorGuidance(result: envelope)

        XCTAssertTrue(
            guidance.contains("DELEGATION_DENIED"),
            "Default branch must surface the typed code so LLM can disambiguate recovery, got: \(guidance)"
        )
        XCTAssertTrue(
            guidance.contains("role is not a top-level delegator"),
            "Default branch must keep echoing the message, got: \(guidance)"
        )
    }

    /// Legacy envelope shape `{"error":{"message":"..."}}` (no `code`) must
    /// still produce a coherent guidance string — no `[]` artifact, no crash.
    /// Pinned because the silent-failure-hunter audit flagged this as an
    /// unpinned defensive path.
    func testGuidance_nestedErrorObject_withoutCode_works() {
        let envelope = ToolExecutionResult(
            toolName: "edit_file",
            argumentsJSON: "{}",
            outputJSON: #"{"error":{"message":"legacy shape, no code"}}"#,
            isError: true
        )

        let guidance = sut.buildToolErrorGuidance(result: envelope)

        XCTAssertTrue(
            guidance.contains("legacy shape, no code"),
            "Nested-error message must surface even without code, got: \(guidance)"
        )
        XCTAssertFalse(
            guidance.contains("[]"),
            "Missing code must not render an empty bracket, got: \(guidance)"
        )
    }

    /// Malformed envelope with neither `error` nor `message` — falls back to
    /// "unknown error" + generic retry. Preserves the existing fallback so a
    /// truly unknown failure shape doesn't crash the tool loop.
    func testGuidance_unknownShape_fallsBackToUnknownError() {
        let envelope = ToolExecutionResult(
            toolName: "write_file",
            argumentsJSON: "{}",
            outputJSON: "{}",
            isError: true
        )

        let guidance = sut.buildToolErrorGuidance(result: envelope)

        XCTAssertTrue(
            guidance.hasSuffix("unknown error. Retry the tool call with the correct arguments."),
            "fallback for malformed envelope should end with 'unknown error. Retry...', got: \(guidance)"
        )
    }
}
