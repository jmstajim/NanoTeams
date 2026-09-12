import XCTest
@testable import NanoTeams

/// `ToolErrorNotePolicy` — what the runtime says to the model after a FAILED tool call.
///
/// The type returns a DIRECTION and never a FACT, so this suite is split the same way:
/// an assertion about what HAPPENED (scope, region count, path, blocker, handler message)
/// is pinned on the ENVELOPE, and only an assertion about what to DO NEXT is pinned on the
/// direction. Before the split every arm opened with the envelope's `message` verbatim and
/// these tests read it back out of the direction — which pinned the duplication itself, and
/// is why three arms that added nothing at all survived so long.
///
/// Renamed from `ToolErrorGuidanceTests` when the decision moved off `LLMExecutionService`
/// into a pure `nonisolated` policy beside `ScratchpadNotePolicy`.
@MainActor
final class ToolErrorNotePolicyTests: XCTestCase {

    // MARK: - tool_not_authorized

    /// The screenshot case: a Code Reviewer emits `list_files /` but the tool is not in its
    /// toolset. Generic "retry with correct arguments" tells the model the args are wrong —
    /// they aren't; the tool itself is unavailable.
    ///
    /// The scope ("for this role") is pinned on the envelope, which is where it is composed
    /// and where the model reads it one turn earlier.
    ///
    /// RED: restore the envelope-message intro at either the policy or the call site → the
    /// non-duplication pin below fires.
    func testToolNotAuthorized_directsAwayFromTheTool_withoutRestatingTheEnvelope() throws {
        let call = StepToolCall(name: "list_files", argumentsJSON: #"{"path":"/"}"#)
        let envelope = LLMExecutionService.makeToolNotAuthorizedResult(
            call: call, canonicalName: "list_files", scope: "for this role")

        XCTAssertTrue(
            envelope.outputJSON.contains("for this role"),
            "the scope is the ENVELOPE's job: \(envelope.outputJSON)")

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertTrue(
            direction.contains("Do not retry 'list_files'"),
            "the anti-loop instruction is the one thing the envelope does not say, got: \(direction)")
        XCTAssertFalse(
            direction.contains("with the correct arguments"),
            "generic 'retry with correct arguments' is misleading for an unauthorized tool, got: \(direction)")
        XCTAssertFalse(
            direction.contains("is not available"),
            "the envelope already said the tool is unavailable, got: \(direction)")
    }

    /// `MeetingToolExecutor` composes the same envelope with `scope: "in this meeting"`, and
    /// the message is the only carrier of that distinction — which is why the arm used to
    /// copy the whole sentence.
    ///
    /// It never had to: the meeting executor feeds its rejections into its own turn
    /// conversation and never reaches this policy (the one production caller,
    /// `processRegularToolResult`, hard-codes `scope: "for this role"`). So the scope is
    /// pinned where it lives, and the direction is pinned to be scope-INDEPENDENT — which is
    /// exactly what makes copying unnecessary.
    ///
    /// RED: reintroduce the envelope-message intro → the direction stops being identical
    /// across the two scopes and the last assertion fails.
    func testMeetingScope_livesInTheEnvelope_andTheDirectionIsScopeIndependent() throws {
        let call = StepToolCall(name: "write_file", argumentsJSON: #"{"path":"x.swift"}"#)
        let meeting = LLMExecutionService.makeToolNotAuthorizedResult(
            call: call, canonicalName: "write_file", scope: "in this meeting")
        let role = LLMExecutionService.makeToolNotAuthorizedResult(
            call: call, canonicalName: "write_file", scope: "for this role")

        XCTAssertTrue(meeting.outputJSON.contains("in this meeting"), meeting.outputJSON)
        XCTAssertFalse(meeting.outputJSON.contains("for this role"), meeting.outputJSON)

        let meetingDirection = try XCTUnwrap(ToolErrorNotePolicy.direction(for: meeting, allowedToolNames: []))
        let roleDirection = try XCTUnwrap(ToolErrorNotePolicy.direction(for: role, allowedToolNames: []))

        XCTAssertTrue(
            meetingDirection.contains("Do not retry 'write_file'"),
            "got: \(meetingDirection)")
        XCTAssertEqual(
            meetingDirection, roleDirection,
            "the direction must not depend on a scope it no longer quotes — that independence "
                + "is what makes copying the envelope's sentence unnecessary")
    }

    /// Defensive: a `tool_not_authorized` envelope with no `message` at all. The direction
    /// still has to name the tool, or the anti-loop instruction attaches to nothing.
    func testToolNotAuthorized_envelopeWithoutMessage_stillNamesTheTool() throws {
        let envelope = ToolExecutionResult(
            toolName: "delete_file",
            argumentsJSON: "{}",
            outputJSON: #"{"error":"tool_not_authorized","tool":"delete_file"}"#,
            isError: true)

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertTrue(direction.contains("Do not retry 'delete_file'"), "got: \(direction)")
    }

    // MARK: - plan_required

    /// The one rejection that is temporal rather than structural — and the envelope already
    /// states both halves of the remedy ("call `update_scratchpad` … then call 'X' again").
    /// The retired direction paraphrased exactly that in different words, which reads as a
    /// second, different instruction.
    ///
    /// RED: return any non-nil direction for this arm → this fails.
    func testPlanRequired_addsNothing_becauseTheEnvelopeAlreadyStatesTheRemedy() {
        let call = StepToolCall(name: "edit_file", argumentsJSON: #"{"path":"a.swift"}"#)
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call, canonicalName: "edit_file", scope: "for this role",
            reason: .withheldUntilPlanRecorded)

        XCTAssertTrue(envelope.outputJSON.contains("update_scratchpad"), envelope.outputJSON)
        XCTAssertTrue(envelope.outputJSON.contains("again"), envelope.outputJSON)

        XCTAssertNil(
            ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []),
            "the envelope names the tool, the remedy and the retry — there is nothing left to add")
    }

    // MARK: - questionnaire_required

    /// The envelope carries both halves — what was refused and the form to send instead — so
    /// the policy adds nothing. The default arm would say "choose a different approach",
    /// which for an ask-only role means prose.
    func testQuestionnaireRequired_addsNothing_theEnvelopeNamesTheForm() {
        let result = ToolExecutionResult(
            toolName: ToolNames.askSupervisor, argumentsJSON: "{}",
            outputJSON: makeErrorEnvelope(
                code: .questionnaireRequired, message: "Several questions in a plain ask.",
                next: NextHint(suggested_cmd: ToolNames.askSupervisorForm, reason: "Send them as a form.")),
            isError: true)

        XCTAssertNil(
            ToolErrorNotePolicy.direction(
                for: result, allowedToolNames: [ToolNames.askSupervisor, ToolNames.askSupervisorForm]),
            "the envelope names the form and the entry per question — there is nothing left to add")
    }

    // MARK: - precondition_failed

    /// The envelope names the missing prerequisite; what it does not say is that retrying
    /// cannot help, which is the whole recovery.
    func testPreconditionFailed_saysWhyRetryingIsPointless_withoutRestatingTheBlocker() throws {
        let call = StepToolCall(name: "git_add", argumentsJSON: #"{"paths":["a"]}"#)
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call, canonicalName: "git_add", scope: "for this role", reason: .gitRepoMissing)

        XCTAssertTrue(
            envelope.outputJSON.contains(".git"),
            "the blocker is named by the ENVELOPE: \(envelope.outputJSON)")

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertTrue(direction.contains("Do not retry 'git_add'"), "got: \(direction)")
        // It says retrying is pointless and names NO blocker: six reasons share this code and
        // their blockers differ, so the sentence that used to claim the work folder set every
        // one of them was a false diagnosis for `.computerUseDisabled` / `.bashDisabled`
        // (R1.8.5, DEBTS D-B10). The blocker stays the ENVELOPE's to name.
        XCTAssertTrue(
            direction.contains("the blocker is not your arguments, and no rewording reaches it"),
            "got: \(direction)")
        XCTAssertFalse(
            direction.localizedCaseInsensitiveContains("work folder"),
            "the direction is chosen by CODE and may not diagnose on six reasons' behalf: "
                + "\(direction)")
        XCTAssertFalse(
            direction.contains("requires a git repository"),
            "the envelope already said which precondition is missing, got: \(direction)")
    }

    // MARK: - identical_write_loop

    /// A second `write_file` with identical `(path, content)` is rejected as a loop. Generic
    /// guidance says "retry with correct arguments" — but the args are EXACTLY what was just
    /// rejected. The remedy (verify state) is the addition; the path and the fact are the
    /// envelope's.
    func testIdenticalWriteLoop_directsToVerifyState_andLeavesTheFactToTheEnvelope() throws {
        let call = StepToolCall(
            name: "write_file",
            argumentsJSON: #"{"path":"src/foo.swift","content":"let x = 1\n"}"#)
        let envelope = LLMExecutionService.makeIdenticalWriteLoopResult(call: call)

        XCTAssertTrue(envelope.outputJSON.contains("Identical write"), envelope.outputJSON)
        XCTAssertTrue(envelope.outputJSON.contains("src/foo.swift"), envelope.outputJSON)

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertTrue(direction.contains("do not re-issue"), "got: \(direction)")
        XCTAssertTrue(direction.contains("Read the file's current state"), "got: \(direction)")
        XCTAssertFalse(
            direction.contains("Identical write"),
            "the envelope already stated the fact, got: \(direction)")
        XCTAssertFalse(
            direction.contains("with the correct arguments"),
            "got: \(direction)")
    }

    /// The `"?"` sentinel is the STRUCTURED field's placeholder for a `write_file` whose args
    /// carry no parseable `path`. It must not reach the message: the model reads `'?'` there
    /// as a literal path.
    ///
    /// This moved onto the producer when the direction stopped restating the sentence — the
    /// direction used to collapse the sentinel on its way past, which meant the envelope
    /// could carry it and nobody noticed.
    ///
    /// RED: revert `makeIdenticalWriteLoopResult` to interpolating `path` into `msg` → the
    /// message assertion fails.
    func testIdenticalWriteLoop_envelopeWithNoPath_saysTheFile_notTheSentinel() {
        let call = StepToolCall(name: "write_file", argumentsJSON: "{}")
        let envelope = LLMExecutionService.makeIdenticalWriteLoopResult(call: call)

        XCTAssertTrue(
            envelope.outputJSON.contains("Identical write to the file already executed"),
            "the message must not render the sentinel as a path: \(envelope.outputJSON)")
        XCTAssertFalse(
            envelope.outputJSON.contains("to '?'"),
            "the sentinel must not reach the model as a path: \(envelope.outputJSON)")
        XCTAssertTrue(
            envelope.outputJSON.contains(#""path":"?""#),
            "the structured field keeps the sentinel — its shape is what downstream reads")
    }

    // MARK: - anchor_not_found

    /// ANCHOR_NOT_FOUND with an untyped, message-only envelope: the direction still carries
    /// what the envelope does not — slash direction and the re-read remedy.
    func testAnchorNotFound_addsSlashDirectionAndReRead_whichTheEnvelopeLacks() throws {
        let envelope = ToolExecutionResult(
            toolName: "edit_file",
            argumentsJSON: #"{"path":"src/foo.swift","old_text":"foo","new_text":"bar"}"#,
            outputJSON: #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","message":"old_text not found in file."}}"#,
            isError: true)

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertTrue(direction.contains("src/foo.swift"), "got: \(direction)")
        XCTAssertTrue(direction.lowercased().contains("exactly"), "got: \(direction)")
        XCTAssertTrue(direction.contains("re-read the region"), "got: \(direction)")
        XCTAssertFalse(
            direction.lowercased().contains("content changed"),
            "must not falsely claim the file changed, got: \(direction)")
        XCTAssertFalse(
            direction.contains("Retry the tool call with the correct arguments"),
            "got: \(direction)")
    }

    /// Defensive: no `path` in args → "the file" placeholder, never empty quotes.
    func testAnchorNotFound_missingPath_usesGenericPlaceholder() throws {
        let envelope = ToolExecutionResult(
            toolName: "edit_file",
            argumentsJSON: "{}",
            outputJSON: #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","message":"old_text not found"}}"#,
            isError: true)

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertTrue(direction.contains("the file"), "got: \(direction)")
        XCTAssertFalse(direction.contains("''"), "got: \(direction)")
    }

    /// A TYPED diagnosis means the handler located the window (or proved the text absent) and
    /// wrote the whole answer into the message. The generic sentence would CONTRADICT it —
    /// telling a model to match "character for character, including whitespace" is actively
    /// wrong for an anchor naming code that does not exist, the majority case in the field.
    ///
    /// So the envelope stands alone. Driven through the real handler, because the point is
    /// the wire shape the handler emits, not a fixture's idea of it.
    ///
    /// RED: return the envelope's message again instead of `nil` → the non-duplication pin
    /// below fires.
    func testAnchorNotFound_typedDiagnosis_addsNothing() async throws {
        let result = try await runEdit(
            fileContents: "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\nlet e = 5\n",
            oldText: "struct NeverExisted {\n    let x: Int\n}")

        XCTAssertTrue(result.outputJSON.contains("none of its lines appear"), result.outputJSON)

        XCTAssertNil(
            ToolErrorNotePolicy.direction(for: result, allowedToolNames: []),
            "a typed diagnosis is the whole answer — restating it was the defect")
    }

    /// The interior-whitespace diagnosis (tier 3.5) is typed like its siblings, so the
    /// same suppression applies. Pinned explicitly because in the sweep below this row
    /// only ever exercises the anti-vacuity arms — `direction` returns nil for it, so
    /// the non-duplication assertion never runs on it and would stay green if the
    /// suppression broke the OTHER way (a direction appearing).
    ///
    /// RED: give `interiorWhitespaceMismatch` `key: nil` → the legacy character-level
    /// steering reappears and this assertion fails.
    func testAnchorNotFound_interiorDiagnosis_addsNothing() async throws {
        let result = try await runEdit(
            fileContents: "let s = a  + b;\nlet s = a   + b;\n",
            oldText: "let s = a + b;")

        XCTAssertTrue(result.outputJSON.contains("interior_whitespace_mismatch"), result.outputJSON)

        XCTAssertNil(
            ToolErrorNotePolicy.direction(for: result, allowedToolNames: []),
            "the typed interior diagnosis is the whole answer, like its three siblings")
    }

    /// Inverted 2026-09-06, with the state it pins. An anchor with more lines than the
    /// file used to compose its message as `anchorNotFoundMessage + " " + hint`, and the
    /// generic half told the model to "make sure it matches exactly including whitespace
    /// and indentation" — advice that cannot help when the anchor simply does not fit, and
    /// which this file's sibling calls "actively WRONG" for the states it does not apply
    /// to. Both former legacy states now write their own complete message, so the whole
    /// six-state family is answered by the envelope alone.
    ///
    /// Driven through the real handler on purpose: a hand-built fixture that separates
    /// message from hint is not a shape production emits.
    ///
    /// RED: restore the composed `anchorNotFoundMessage + hint` message → the envelope
    /// carries the contradictory sentence again and the second assertion fails.
    func testAnchorNotFound_shapeDiagnosis_isTheWholeAnswer() async throws {
        let result = try await runEdit(fileContents: "a\nb\n", oldText: "a\nb\nc\nd")

        XCTAssertTrue(
            result.outputJSON.contains("cannot match anywhere"),
            "the envelope states the shape problem: \(result.outputJSON)")
        XCTAssertFalse(
            result.outputJSON.contains("whitespace and indentation"),
            "…and must not also advise a whitespace fix that cannot help: \(result.outputJSON)")

        XCTAssertNil(
            ToolErrorNotePolicy.direction(for: result, allowedToolNames: []),
            "like its four siblings, the typed diagnosis leaves nothing to add")
    }

    /// The other former legacy state, and the one whose composed message CONTRADICTED
    /// itself: "matches exactly including whitespace" immediately followed by "old_text is
    /// whitespace-only — anchor on adjacent non-blank lines instead".
    func testAnchorNotFound_whitespaceOnlyAnchor_doesNotAdviseMatchingWhitespace() async throws {
        let result = try await runEdit(fileContents: "a\n\nb\n", oldText: "   ")

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("whitespace-only"), result.outputJSON)
        XCTAssertFalse(
            result.outputJSON.contains("matches exactly including whitespace"),
            "the advice that produced the failure must not be the advice given: \(result.outputJSON)")
        XCTAssertNil(ToolErrorNotePolicy.direction(for: result, allowedToolNames: []))
    }

    /// The hint IS appended when no envelope message carried it — a malformed envelope is the
    /// only shape where this branch is the model's sole channel for the diagnosis.
    func testAnchorNotFound_hintWithNoEnvelopeMessage_isAppendedLast() throws {
        let envelope = ToolExecutionResult(
            toolName: "edit_file",
            argumentsJSON: #"{"path":"src/foo.swift"}"#,
            outputJSON: #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","details":{"hint":"Lines match ignoring indentation near line 3 — check leading whitespace (tabs vs spaces)."}}}"#,
            isError: true)

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertTrue(direction.contains("near line 3"), "got: \(direction)")
        XCTAssertTrue(
            direction.hasSuffix("(tabs vs spaces)."),
            "the hint must come last so the generic steering does not bury it, got: \(direction)")
        XCTAssertTrue(direction.contains("src/foo.swift"), "got: \(direction)")
    }

    /// Defensive: an empty hint must not leave a dangling space.
    func testAnchorNotFound_emptyHint_notAppended() throws {
        let envelope = ToolExecutionResult(
            toolName: "edit_file",
            argumentsJSON: "{}",
            outputJSON: #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","details":{"hint":""}}}"#,
            isError: true)

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertFalse(direction.hasSuffix(" "), "got: '\(direction)'")
    }

    // MARK: - anchor_ambiguous

    /// The envelope carries BOTH the region count and the remedy ("include more surrounding
    /// lines"), so there is nothing to add. This arm used to return that message verbatim.
    ///
    /// RED: return the envelope's message again → the non-duplication pin below fires.
    func testAnchorAmbiguous_addsNothing_whenTheEnvelopeCarriesTheMessage() async throws {
        let result = try await runEdit(
            fileContents: "m  \nn\nz\nm\t\nn\n", oldText: "m\nn", fileName: "amb.txt")

        XCTAssertTrue(result.outputJSON.contains("ANCHOR_AMBIGUOUS"), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("matches 2 "), result.outputJSON)

        XCTAssertNil(
            ToolErrorNotePolicy.direction(for: result, allowedToolNames: []),
            "the envelope names the count AND the remedy — restating it was the defect")
    }

    /// Only a malformed envelope with no message needs the remedy synthesized here.
    func testAnchorAmbiguous_envelopeWithoutMessage_synthesizesTheRemedy() throws {
        let envelope = ToolExecutionResult(
            toolName: "edit_file",
            argumentsJSON: "{}",
            outputJSON: #"{"ok":false,"error":{"code":"ANCHOR_AMBIGUOUS"}}"#,
            isError: true)

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertTrue(direction.contains("more surrounding lines"), "got: \(direction)")
        XCTAssertFalse(
            direction.contains("not found"),
            "must not claim the anchor was absent, got: \(direction)")
    }

    // MARK: - default branch

    /// Args ARE the cause for `INVALID_ARGS`, so fix-the-arguments is the right direction.
    /// The handler's message stays the envelope's.
    func testDefault_invalidArgs_directsToFixArgs_withoutEchoingTheMessage() throws {
        let envelope = ToolExecutionResult(
            toolName: "edit_file",
            argumentsJSON: "{}",
            outputJSON: #"{"error":{"code":"INVALID_ARGS","message":"missing required field 'path'"}}"#,
            isError: true)

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertTrue(direction.contains("[INVALID_ARGS]"), "got: \(direction)")
        XCTAssertTrue(direction.contains("Fix the arguments and retry"), "got: \(direction)")
        XCTAssertTrue(
            direction.contains("`edit_file` requires:"),
            "the whole contract is the addition, got: \(direction)")
        XCTAssertFalse(
            direction.contains("missing required field 'path'"),
            "the handler's message is the envelope's, got: \(direction)")
    }

    /// An `INVALID_ARGS` envelope that already carries a `next`, with every required argument
    /// present, gets no note at all: `next.reason` is the instruction, written for that one
    /// failure, and "Fix the arguments and retry." is the same sentence with the specifics
    /// taken out. It would land AFTER the envelope — on Ollama merged into the same user
    /// message — so the LAST thing the model reads before its retry would be the vaguer of
    /// the two (playbook R1.4.2). Measured: MeditationApp task 67 run 1, where the form was
    /// one `}` short and the model's next reasoning was "my JSON string contains a Russian
    /// character".
    ///
    /// RED: drop the `dict?["next"]` guard → the note comes back and the recency slot holds
    /// a content-free restatement again.
    func testInvalidArgs_withANextAndEveryArgumentPresent_saysNothing() throws {
        let envelope = ToolExecutionResult(
            toolName: ToolNames.askSupervisorForm,
            argumentsJSON: #"{"headline":"H","form":"{"}"#,
            outputJSON: #"""
            {"error":{"code":"INVALID_ARGS","message":"Invalid form: the form ends."},"next":{"suggested_cmd":"ask_supervisor_form","reason":"Repair the `form` argument and call again."},"ok":false}
            """#,
            isError: true)
        XCTAssertNil(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))
    }

    /// The contract list is a fact the envelope cannot know — it comes from the SCHEMA — so a
    /// `next` does not silence it.
    func testInvalidArgs_withANextButAMissingArgument_stillNamesTheContract() throws {
        let envelope = ToolExecutionResult(
            toolName: ToolNames.askSupervisorForm,
            argumentsJSON: #"{"headline":"H"}"#,
            outputJSON: #"""
            {"error":{"code":"INVALID_ARGS","message":"Missing required argument: form"},"next":{"suggested_cmd":"ask_supervisor_form","reason":"Repair the `form` argument and call again."},"ok":false}
            """#,
            isError: true)
        let direction = try XCTUnwrap(
            ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))
        XCTAssertTrue(direction.contains("requires:"), direction)
    }

    /// A path shape the sandbox refuses reaches the model as `INVALID_ARGS` since 2026-09-07,
    /// so the direction is the fix-and-retry one. As `PERMISSION_DENIED` it fell into the
    /// `_DENIED` arm and told the model NOT to retry a call whose own message said how to.
    func testSandboxPathRejection_directsToFixTheArguments_neverDoNotRetry() async throws {
        let result = await ToolErrorHandler.execute(toolName: ToolNames.readFile, args: ["path": "../x"]) {
            throw SandboxPathError.parentTraversalNotAllowed("../x")
        }
        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: result, allowedToolNames: [ToolNames.readFile]))

        XCTAssertTrue(direction.contains("Fix the arguments and retry"), "got: \(direction)")
        XCTAssertFalse(direction.contains("Do not retry"), "got: \(direction)")
    }

    /// The typed code is a DISCRIMINATOR the direction is chosen by, not a restatement — it
    /// stays, so the model can tell don't-retry from maybe-retry-later from fix-args.
    func testDefault_keepsTheTypedCode_asTheRecoveryDiscriminator() throws {
        let envelope = ToolExecutionResult(
            toolName: "delegate_to_team",
            argumentsJSON: "{}",
            outputJSON: #"{"error":{"code":"DELEGATION_DENIED","message":"role is not a top-level delegator"}}"#,
            isError: true)

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertTrue(direction.contains("DELEGATION_DENIED"), "got: \(direction)")
        XCTAssertTrue(direction.contains("Do not retry"), "got: \(direction)")
        XCTAssertFalse(
            direction.contains("role is not a top-level delegator"),
            "got: \(direction)")
    }

    /// Legacy shape `{"error":{"message":…}}` with no `code` must still produce a coherent
    /// direction — no `[]` artifact.
    func testDefault_nestedErrorWithoutCode_rendersNoEmptyBracket() throws {
        let envelope = ToolExecutionResult(
            toolName: "edit_file",
            argumentsJSON: "{}",
            outputJSON: #"{"error":{"message":"legacy shape, no code"}}"#,
            isError: true)

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertFalse(direction.contains("[]"), "got: \(direction)")
        XCTAssertFalse(direction.contains("legacy shape, no code"), "got: \(direction)")
    }

    /// A malformed envelope with neither `error` nor `message`: the direction hedges rather
    /// than blaming arguments, and still names the tool so it attaches to something.
    func testDefault_unknownShape_hedgesAndNamesTheTool() throws {
        let envelope = ToolExecutionResult(
            toolName: "write_file", argumentsJSON: "{}", outputJSON: "{}", isError: true)

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertTrue(direction.contains("'write_file'"), "got: \(direction)")
        XCTAssertTrue(direction.contains("otherwise choose a different approach"), "got: \(direction)")
    }

    /// A timeout is not an argument problem — the pre-fix fixed suffix actively misled
    /// weaker models.
    func testDefault_timedOutCode_directsTransientRetry_notArgs() throws {
        let envelope = ToolExecutionResult(
            toolName: "delegate_to_team",
            argumentsJSON: "{}",
            outputJSON: #"{"error":{"code":"DELEGATION_TIMED_OUT","message":"timed out after 30 minutes"}}"#,
            isError: true)

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertTrue(direction.contains("transient"), "got: \(direction)")
        XCTAssertFalse(direction.contains("correct arguments"), "got: \(direction)")
    }

    // MARK: - bash_denied

    func testBashDenied_saysTheBlockIsPolicy_withoutRestatingTheReason() throws {
        let envelope = ToolExecutionResult(
            toolName: "bash",
            argumentsJSON: #"{"command":"rm -rf /"}"#,
            outputJSON: #"{"ok":false,"error":{"code":"bash_denied","message":"Denied by rule 'rm'."}}"#,
            isError: true)

        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: []))

        XCTAssertTrue(direction.contains("Do NOT retry this command"), "got: \(direction)")
        XCTAssertTrue(
            direction.contains("the block is set by policy, not by your arguments"),
            "got: \(direction)")
        XCTAssertFalse(direction.contains("Denied by rule 'rm'."), "got: \(direction)")
    }

    // MARK: - R3.8.6: the escalation names the channel the role holds, or nothing

    private static let bashDenied = ToolExecutionResult(
        toolName: "bash", argumentsJSON: #"{"command":"rm -rf /"}"#,
        outputJSON: #"{"ok":false,"error":{"code":"bash_denied","message":"Denied by rule 'rm'."}}"#,
        isError: true)

    private static let gitMissing = LLMExecutionService.makeUnavailableToolResult(
        call: StepToolCall(name: "git_add", argumentsJSON: #"{"paths":["a"]}"#),
        canonicalName: "git_add", scope: "for this role", reason: .gitRepoMissing)

    /// "…or ask the Supervisor" went to every role, including the Autovisor — which holds no
    /// `ask_supervisor` — and a bash role that may not either: an instruction to write prose
    /// the runtime does not detect. The clause now names the tool the role holds
    /// (`wait_for_events` identifies the manager, then `ask_supervisor`) or is dropped.
    func testBashDenied_namesTheEscalationChannelTheRoleHolds_orNone() throws {
        let held = try XCTUnwrap(ToolErrorNotePolicy.direction(
            for: Self.bashDenied, allowedToolNames: [ToolNames.bash, ToolNames.askSupervisor]))
        XCTAssertTrue(held.hasSuffix("already-approved command, or call ask_supervisor."), held)

        let manager = try XCTUnwrap(ToolErrorNotePolicy.direction(
            for: Self.bashDenied,
            allowedToolNames: [ToolNames.bash, ToolNames.waitForEvents, ToolNames.askSupervisor]))
        XCTAssertTrue(manager.hasSuffix(", or call wait_for_events."),
                      "wait_for_events identifies the manager and wins: \(manager)")

        let neither = try XCTUnwrap(ToolErrorNotePolicy.direction(
            for: Self.bashDenied, allowedToolNames: [ToolNames.bash]))
        XCTAssertTrue(neither.hasSuffix("already-approved command."), neither)
        XCTAssertFalse(neither.lowercased().contains("supervisor"),
                       "a role with no channel is told nothing about escalating: \(neither)")
    }

    // MARK: - approval_unavailable (A15, 2026-09-07): no channel, from either envelope shape

    private static let gateApprovalUnavailable = ToolExecutionResult(
        toolName: "bash", argumentsJSON: #"{"command":"python3 test.py"}"#,
        outputJSON: makeErrorEnvelope(
            code: .approvalUnavailable,
            message: "This command needs human approval (Command is not pre-approved and is not read-only — requires review.), and this run has no human to give it. Read-only commands run without approval; nothing inside the run can approve the rest — take a different step."),
        isError: true)

    private static let executorApprovalUnavailable = LLMExecutionService.makeUnavailableToolResult(
        call: StepToolCall(name: "bash", argumentsJSON: #"{"command":"python3 test.py"}"#),
        canonicalName: "bash", scope: "for this role", reason: .approverUnavailable)

    /// The 2026-09-07 audit's ring: the gate refused for want of a human, the note said "or call
    /// ask_supervisor", the autonomous Supervisor "approved", the gate refused again. The arm
    /// for this code names NO channel, whichever tool the role holds — the channel reaches the
    /// answerer that cannot approve — and says the block is not the arguments.
    func testApprovalUnavailable_namesNoChannel_whateverTheRoleHolds() throws {
        for envelope in [Self.gateApprovalUnavailable, Self.executorApprovalUnavailable] {
            for held: Set<String> in [[ToolNames.bash], [ToolNames.bash, ToolNames.askSupervisor],
                                      [ToolNames.bash, ToolNames.waitForEvents, ToolNames.askSupervisor]] {
                let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope, allowedToolNames: held))
                XCTAssertTrue(direction.contains("Do NOT retry"), direction)
                XCTAssertFalse(direction.contains("ask_supervisor"), "no channel: \(direction)")
                XCTAssertFalse(direction.contains("wait_for_events"), "no channel: \(direction)")
                XCTAssertFalse(direction.lowercased().contains("supervisor"), direction)
                XCTAssertTrue(direction.contains("no one in this run can approve"), direction)
            }
        }
    }

    /// The gate's UPPERCASE `ToolErrorCode` and the executor's lowercase literal are one arm.
    func testApprovalUnavailable_bothSpellingsReachTheSameArm() throws {
        let fromGate = try XCTUnwrap(ToolErrorNotePolicy.direction(
            for: Self.gateApprovalUnavailable, allowedToolNames: [ToolNames.askSupervisor]))
        let fromExecutor = try XCTUnwrap(ToolErrorNotePolicy.direction(
            for: Self.executorApprovalUnavailable, allowedToolNames: [ToolNames.askSupervisor]))
        XCTAssertEqual(fromGate, fromExecutor)
    }

    /// The precondition envelopes used to carry their own "ask the supervisor whether to
    /// initialize one" — a builder that cannot know the schema. The fact stays in the
    /// envelope; the channel is this policy's to add, and only when held.
    func testPreconditionFailed_namesTheEscalationChannelTheRoleHolds_orNone() throws {
        XCTAssertFalse(Self.gitMissing.outputJSON.lowercased().contains("supervisor"),
                       "the envelope states the fact, never the channel: \(Self.gitMissing.outputJSON)")

        let held = try XCTUnwrap(ToolErrorNotePolicy.direction(
            for: Self.gitMissing, allowedToolNames: [ToolNames.askSupervisor]))
        XCTAssertTrue(held.hasSuffix("If the step cannot proceed without it, call ask_supervisor."), held)

        let neither = try XCTUnwrap(ToolErrorNotePolicy.direction(
            for: Self.gitMissing, allowedToolNames: [ToolNames.readFile]))
        // "proceed without this step" is the permission withdrawn on 2026-09-11; it survived
        // in this arm until 2026-09-13, arriving one turn AFTER `.xcodeSchemeNotSelected` had
        // said "rather than assuming one".
        XCTAssertTrue(neither.hasSuffix("rather than assuming a result."), neither)
        XCTAssertFalse(neither.contains("proceed without this step"), neither)
        XCTAssertFalse(neither.lowercased().contains("supervisor"), neither)
    }

    // MARK: - The structural pin

    /// Every representative envelope, in the shape production emits it, paired with the
    /// message the model reads one turn earlier.
    private func nonDuplicationTable() async throws -> [(label: String, envelope: ToolExecutionResult)] {
        let write = StepToolCall(
            name: "write_file", argumentsJSON: #"{"path":"a.swift","content":"x"}"#)
        var rows: [(String, ToolExecutionResult)] = await [
            ("identical_write_loop",
             LLMExecutionService.makeIdenticalWriteLoopResult(call: write)),
            ("INVALID_ARGS", ToolExecutionResult(
                toolName: "edit_file", argumentsJSON: "{}",
                outputJSON: #"{"ok":false,"error":{"code":"INVALID_ARGS","message":"Missing required argument: path"}}"#,
                isError: true)),
            ("bash_denied", ToolExecutionResult(
                toolName: "bash", argumentsJSON: #"{"command":"rm -rf /"}"#,
                outputJSON: #"{"ok":false,"error":{"code":"bash_denied","message":"Denied by rule 'rm'."}}"#,
                isError: true)),
            ("DELEGATION_TIMED_OUT", ToolExecutionResult(
                toolName: "delegate_to_team", argumentsJSON: "{}",
                outputJSON: #"{"ok":false,"error":{"code":"DELEGATION_TIMED_OUT","message":"timed out after 30 minutes"}}"#,
                isError: true)),
            ("ANCHOR_NOT_FOUND (typed)",
             try runEdit(fileContents: "let a = 1\nlet b = 2\nlet c = 3\n",
                         oldText: "struct NeverExisted {}")),
            // Two lines equal only once interior runs collapse; the drifted anchor is
            // located but ambiguous → the interior_whitespace_mismatch diagnosis.
            ("ANCHOR_NOT_FOUND (interior)",
             try runEdit(fileContents: "let s = a  + b;\nlet s = a   + b;\n",
                         oldText: "let s = a + b;")),
            ("ANCHOR_NOT_FOUND (legacy)",
             try runEdit(fileContents: "a\nb\n", oldText: "a\nb\nc\nd")),
            ("ANCHOR_AMBIGUOUS",
             try runEdit(fileContents: "m  \nn\nz\nm\t\nn\n", oldText: "m\nn", fileName: "amb.txt")),
        ]
        rows.append(("APPROVAL_UNAVAILABLE (gate)", Self.gateApprovalUnavailable))
        // Every executor rejection, through the real emitter rather than a literal.
        for reason in LLMExecutionService.ToolUnavailabilityReason.allCases {
            let call = StepToolCall(name: "git_add", argumentsJSON: #"{"paths":["a"]}"#)
            rows.append((
                "ToolUnavailabilityReason.\(reason)",
                LLMExecutionService.makeUnavailableToolResult(
                    call: call, canonicalName: "git_add", scope: "for this role", reason: reason)))
        }
        return rows.map { (label: $0.0, envelope: $0.1) }
    }

    /// The envelope's `message`, exactly as `StepToolCall.errorMessage` reads it.
    private func envelopeMessage(_ result: ToolExecutionResult) -> String? {
        StepToolCall(
            name: result.toolName, argumentsJSON: result.argumentsJSON,
            resultJSON: result.outputJSON, isError: true
        ).errorMessage
    }

    /// **No direction may restate its own envelope's message.**
    ///
    /// The rule this type exists for, pinned mechanically rather than per-arm: every arm
    /// used to open with the message verbatim, and three added nothing else at all. A
    /// per-arm assertion catches the arm it was written for; this catches the tenth.
    ///
    /// It catches VERBATIM duplication only. Paraphrase (`plan_required` restating the
    /// remedy in different words) is closed by that arm returning `nil`, not by wording —
    /// which is why the per-arm nil tests above are not redundant with this one.
    ///
    /// RED: restore any arm's `"\(intro) …"` composition → this fires and names the arm.
    func testNoDirectionRestatesItsEnvelopesMessage() async throws {
        var directionsEmitted = 0
        let table = try await nonDuplicationTable()

        for row in table {
            let message = try XCTUnwrap(
                envelopeMessage(row.envelope),
                "anti-vacuity: \(row.label) must carry a message, or this row proves nothing")
            XCTAssertFalse(
                message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "anti-vacuity: \(row.label)'s message is blank")

            guard let direction = ToolErrorNotePolicy.direction(for: row.envelope, allowedToolNames: []) else { continue }
            directionsEmitted += 1
            XCTAssertFalse(
                direction.contains(message),
                "\(row.label): the direction restates the envelope's message, which the model "
                    + "read one turn earlier.\nmessage:   \(message)\ndirection: \(direction)")
        }

        XCTAssertGreaterThanOrEqual(
            directionsEmitted, 5,
            "anti-vacuity: only \(directionsEmitted) of \(table.count) rows produced a direction "
                + "— a policy that always returns nil would pass the loop above without checking "
                + "anything")
    }

    /// The four arms that add nothing must KEEP adding nothing. Named separately from the
    /// pin above because that one is satisfied by silence, and silence is exactly what a
    /// regression here would reintroduce noise into.
    ///
    /// `cancelled` joined the three for a DIFFERENT reason and is asserted here anyway: the
    /// other three are silent because the direction would restate the envelope, while this one
    /// is silent because no direction is true — the run stopped, and on resume the step
    /// re-issues, so both "fix the arguments" (the default arm it used to fall into) and "do
    /// not retry" are wrong.
    func testTheFourSilentArms_staySilent() async throws {
        let planRequired = LLMExecutionService.makeUnavailableToolResult(
            call: StepToolCall(name: "edit_file", argumentsJSON: "{}"),
            canonicalName: "edit_file", scope: "for this role",
            reason: .withheldUntilPlanRecorded)
        // Hoisted out of the assertion: `XCTAssertNil` takes an autoclosure, which is not an
        // async context, so `await` cannot appear inside the parentheses.
        let anchorNotFound = try await runEdit(
            fileContents: "let a = 1\nlet b = 2\nlet c = 3\n",
            oldText: "struct NeverExisted {}")
        let anchorAmbiguous = try await runEdit(
            fileContents: "m  \nn\nz\nm\t\nn\n", oldText: "m\nn", fileName: "amb.txt")

        let cancelled = makeCancelledResult(toolName: ToolNames.bash, argumentsJSON: "{}")

        XCTAssertNil(ToolErrorNotePolicy.direction(for: planRequired, allowedToolNames: []), "plan_required")
        XCTAssertNil(ToolErrorNotePolicy.direction(for: anchorNotFound, allowedToolNames: []), "ANCHOR_NOT_FOUND (typed)")
        XCTAssertNil(ToolErrorNotePolicy.direction(for: anchorAmbiguous, allowedToolNames: []), "ANCHOR_AMBIGUOUS")
        XCTAssertNil(ToolErrorNotePolicy.direction(for: cancelled, allowedToolNames: []), "CANCELLED")
    }

    /// Both producers of a `CANCELLED` envelope reach the same silent arm: `ToolRuntime` /
    /// `ToolErrorHandler` build theirs from a tool name, the approval gates from the held
    /// `StepToolCall`. The two spellings must not drift into two behaviours.
    func testCancelled_bothEnvelopeSpellings_areSilent() {
        let fromRuntime = makeCancelledResult(toolName: ToolNames.bash, argumentsJSON: "{}")
        let fromGate = makeCancelledResult(
            for: StepToolCall(providerID: "tc_0", name: ToolNames.bash,
                              argumentsJSON: #"{"command":"make install"}"#))

        XCTAssertEqual(fromRuntime.outputJSON, fromGate.outputJSON,
                       "one condition must have one wire shape")
        XCTAssertNil(ToolErrorNotePolicy.direction(for: fromGate, allowedToolNames: []))
        XCTAssertEqual(fromGate.providerID, "tc_0",
                       "the gate's synthetic must carry the call's providerID or the wire orphans")
    }

    // MARK: - Helpers

    /// Runs a real `edit_file` against a throwaway work folder and returns its envelope.
    ///
    /// Real handler rather than a literal: the shapes under test (typed diagnosis, legacy
    /// hint composition) are decided inside `FileWriteHandlers`, and a hand-rolled fixture
    /// that separates message from hint is not a shape production emits — pinning against
    /// one is how the hint duplication stayed invisible.
    @discardableResult
    private func runEdit(
        fileContents: String, oldText: String, fileName: String = "m.swift"
    ) async throws -> ToolExecutionResult {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: tempDir) }
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fm.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)
        try fileContents.write(
            to: tempDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)

        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0))
        let context = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role")
        let args: [String: Any] = ["path": fileName, "old_text": oldText, "new_text": "z"]
        let argsJSON = String(
            data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let result = await runtime.executeAll(
            context: context, toolCalls: [StepToolCall(name: "edit_file", argumentsJSON: argsJSON)])[0]
        XCTAssertTrue(result.isError, "precondition: the edit must fail — \(result.outputJSON)")
        return result
    }
}
