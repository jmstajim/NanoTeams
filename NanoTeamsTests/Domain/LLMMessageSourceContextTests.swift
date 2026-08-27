import XCTest
@testable import NanoTeams

/// Tests for LLMMessage.sourceContext and sourceRole Codable round-trips
/// and StepExecution nested arrays (consultations, meetingIDs, llmConversation).
final class LLMMessageSourceContextTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - MessageSourceContext Codable

    func testMessageSourceContext_Consultation_CodableRoundTrip() throws {
        let original: MessageSourceContext = .consultation
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MessageSourceContext.self, from: encoded)
        XCTAssertEqual(decoded, .consultation)
    }

    func testMessageSourceContext_Meeting_CodableRoundTrip() throws {
        let original: MessageSourceContext = .meeting
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MessageSourceContext.self, from: encoded)
        XCTAssertEqual(decoded, .meeting)
    }

    func testMessageSourceContext_RawValues() {
        XCTAssertEqual(MessageSourceContext.consultation.rawValue, "consultation")
        XCTAssertEqual(MessageSourceContext.meeting.rawValue, "meeting")
        XCTAssertEqual(MessageSourceContext.supervisorMessage.rawValue, "supervisorMessage")
    }

    func testMessageSourceContext_SupervisorMessage_CodableRoundTrip() throws {
        let original: MessageSourceContext = .supervisorMessage
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MessageSourceContext.self, from: encoded)
        XCTAssertEqual(decoded, .supervisorMessage)
    }

    func testMessageSourceContext_SupervisorMessage_DisplayLabel() {
        // The label is surfaced next to the role name in message bubbles.
        XCTAssertEqual(MessageSourceContext.supervisorMessage.displayLabel, "message")
    }

    // MARK: - autovisorEvent

    func testMessageSourceContext_AutovisorEvent_CodableRoundTrip() throws {
        // Persisted in `step.llmConversation`, so the raw value is a storage contract:
        // renaming it re-renders every archived notice as an unattributed `.user` turn,
        // which the feed's no-source filter then hides outside Debug mode.
        XCTAssertEqual(MessageSourceContext.autovisorEvent.rawValue, "autovisorEvent")
        let encoded = try JSONEncoder().encode(MessageSourceContext.autovisorEvent)
        let decoded = try JSONDecoder().decode(MessageSourceContext.self, from: encoded)
        XCTAssertEqual(decoded, .autovisorEvent)
    }

    func testMessageSourceContext_AutovisorEvent_DisplayLabel() {
        // Must equal `SystemNoticePresentation`'s label for this kind — the two are
        // drift-guarded against each other there.
        XCTAssertEqual(MessageSourceContext.autovisorEvent.displayLabel, "event")
    }

    /// Unlike `.supervisorMessage`, whose label is suppressed because the crowned bubble
    /// already said who spoke, this one keeps its label: the collapsed feed row suppresses it
    /// locally (`MessageBubbleView.headerSourceLabel`), but `conversation_log.md` renders the
    /// same helper with no row to lean on, and there the label is the only attribution.
    ///
    /// RED: add `.autovisorEvent` to `sourceContextDisplayLabel`'s nil early-returns → the
    /// transcript stops naming these turns at all.
    func testSourceContextDisplayLabel_autovisorEvent_isNotSuppressed() {
        let msg = LLMMessage(
            role: .user,
            content: MessageSourceContext.autovisorEventNoticeHeader + "\n- Task #1 failed.",
            sourceContext: .autovisorEvent
        )
        XCTAssertEqual(msg.sourceContextDisplayLabel, "event")
    }

    func testAutovisorEventNoticeHeader_constantValue() {
        // Shared by the composer (`composeAutovisorEventNotice`) and the preview skip
        // (`SystemNoticePresentation.previewSkippedHeaders`). It also ships on the wire: the
        // notice is unmarked, so this line is what identifies it once the provider flattens
        // consecutive user turns.
        XCTAssertEqual(
            MessageSourceContext.autovisorEventNoticeHeader,
            "Event update while you are reviewing — new since this pass started:"
        )
    }

    /// The notice is sent UNMARKED, so there is nothing to strip and `displayContent` must
    /// leave it exactly as persisted — including its header, which `ConversationReplay`
    /// replays verbatim because this notice really was sent.
    ///
    /// RED: give `.autovisorEvent` a strip arm in `displayContent` → this fails, and the
    /// replayed wire silently diverges from the live one.
    func testDisplayContent_autovisorEvent_isUntouched() {
        let raw = MessageSourceContext.autovisorEventNoticeHeader
            + "\n- Task #35 \"M15\" is waiting for a supervisor answer (answer_task_question)."
        let msg = LLMMessage(role: .user, content: raw, sourceContext: .autovisorEvent)
        XCTAssertEqual(msg.displayContent, raw)
    }

    /// Corner: a notice whose body happens to open with the Supervisor marker must NOT have
    /// it stripped — the strip is keyed on `.supervisorMessage`, and an event notice wearing
    /// that text is content, not attribution.
    func testDisplayContent_autovisorEvent_keepsASupervisorLookalikePrefix() {
        let raw = MessageSourceContext.supervisorMessagePrefix + "- Task #1 failed."
        let msg = LLMMessage(role: .user, content: raw, sourceContext: .autovisorEvent)
        XCTAssertEqual(msg.displayContent, raw)
    }

    // MARK: - sourceContextDisplayLabel (bubble label contract)

    func testSourceContextDisplayLabel_changeRequest() {
        // Revision-continuation feedback messages carry `.changeRequest` so the
        // bubble renders "(change request)" — pinned because the appendLLMMessage
        // parameter defaults to nil, and dropping it compiles silently.
        let msg = LLMMessage(
            role: .user,
            content: "Supervisor Feedback: fix it",
            sourceRole: .supervisor,
            sourceContext: .changeRequest
        )
        XCTAssertEqual(msg.sourceContextDisplayLabel, "change request")
    }

    func testSourceContextDisplayLabel_sourceRoleWithoutContext_fallsBackToConsultation() {
        // The trap branch: ANY message with a sourceRole but no sourceContext renders
        // "(consultation)". This is why revision feedback must set `.changeRequest` —
        // the original mislabel bug was exactly this fallback firing.
        let msg = LLMMessage(
            role: .user,
            content: "Supervisor Feedback: fix it",
            sourceRole: .supervisor,
            sourceContext: nil
        )
        XCTAssertEqual(msg.sourceContextDisplayLabel, "consultation")
    }

    func testSourceContextDisplayLabel_plainUserMessage_isInput() {
        let msg = LLMMessage(role: .user, content: "Hello")
        XCTAssertEqual(msg.sourceContextDisplayLabel, "input")
    }

    func testSourceContextDisplayLabel_supervisorMessage_isNil() {
        // `.supervisorMessage` bubbles already show the role name — no secondary label.
        let msg = LLMMessage(
            role: .user,
            content: "Supervisor:\nhi",
            sourceRole: .supervisor,
            sourceContext: .supervisorMessage
        )
        XCTAssertNil(msg.sourceContextDisplayLabel)
    }

    func testSupervisorFeedbackPrefix_constantValue() {
        // The wire/persistence contract: write sites (requestRevision, correctRole)
        // and the send site (StepLifecycle revision continuation) share this constant.
        XCTAssertEqual(MessageSourceContext.supervisorFeedbackPrefix, "Supervisor Feedback: ")
    }

    // MARK: - rawFeedback normalization corners

    func testRawFeedback_plainText_trimsOnly() {
        XCTAssertEqual(MessageSourceContext.rawFeedback("  fix the bug  \n"), "fix the bug")
    }

    func testRawFeedback_stripsLeadingPrefix() {
        XCTAssertEqual(
            MessageSourceContext.rawFeedback("Supervisor Feedback: fix the bug"),
            "fix the bug")
    }

    func testRawFeedback_isIdempotent() {
        let once = MessageSourceContext.rawFeedback("Supervisor Feedback: fix the bug")
        XCTAssertEqual(MessageSourceContext.rawFeedback(once), once,
                       "Every prefix-attaching site applies it unconditionally — must not double-strip")
    }

    func testRawFeedback_stripsOnlyONELeadingPrefix() {
        // A doubled legacy value loses one layer per pass; the send site applies
        // rawFeedback once, so a pre-fix "Supervisor Feedback: Supervisor Feedback: x"
        // resolves to a single prefix on the wire — not zero.
        XCTAssertEqual(
            MessageSourceContext.rawFeedback("Supervisor Feedback: Supervisor Feedback: x"),
            "Supervisor Feedback: x")
    }

    func testRawFeedback_prefixMidTextIsNotStripped() {
        let text = "Please change the line that says 'Supervisor Feedback: ' in the template"
        XCTAssertEqual(MessageSourceContext.rawFeedback(text), text,
                       "Only a LEADING prefix is attribution — mid-text occurrences are user content")
    }

    func testRawFeedback_prefixWithLeadingWhitespace_isStillStripped() {
        // Trim happens before the prefix check, so "  Supervisor Feedback: x" normalizes.
        XCTAssertEqual(MessageSourceContext.rawFeedback("  Supervisor Feedback: x"), "x")
    }

    func testRawFeedback_prefixOnly_normalizesToEmpty() {
        // "Supervisor Feedback: " alone carries no feedback — entry guards
        // (requestRevision / correctRole) reject the empty result loudly.
        XCTAssertEqual(MessageSourceContext.rawFeedback("Supervisor Feedback: "), "")
        XCTAssertEqual(MessageSourceContext.rawFeedback("Supervisor Feedback:    \n"), "")
    }

    func testRawFeedback_caseSensitive_lowercaseNotStripped() {
        // Exact-match contract: only the canonical constant is attribution.
        let text = "supervisor feedback: lowercase is user content"
        XCTAssertEqual(MessageSourceContext.rawFeedback(text), text)
    }

    func testRawFeedback_multilinePreserved() {
        let multiline = "Supervisor Feedback: line 1\nline 2\n- bullet"
        XCTAssertEqual(MessageSourceContext.rawFeedback(multiline), "line 1\nline 2\n- bullet")
    }

    // MARK: - displayContent strip for .supervisorMessage

    func testDisplayContent_stripsMultilineSupervisorHeader() {
        let msg = LLMMessage(
            role: .user,
            content: "Supervisor:\nостановись",
            sourceRole: .supervisor,
            sourceContext: .supervisorMessage
        )
        XCTAssertEqual(msg.displayContent, "остановись")
    }

    func testDisplayContent_stripsMultiMessageBatch() {
        let msg = LLMMessage(
            role: .user,
            content: "Supervisor:\nmsg 1\nmsg 2\nmsg 3",
            sourceRole: .supervisor,
            sourceContext: .supervisorMessage
        )
        XCTAssertEqual(msg.displayContent, "msg 1\nmsg 2\nmsg 3")
    }

    func testDisplayContent_stripsLegacyInlinePrefix() {
        // Backward compat: turns persisted by earlier builds used the inline
        // "Supervisor: " form. Those must still strip cleanly after upgrade.
        let msg = LLMMessage(
            role: .user,
            content: "Supervisor: old-style",
            sourceRole: .supervisor,
            sourceContext: .supervisorMessage
        )
        XCTAssertEqual(msg.displayContent, "old-style")
    }

    func testDisplayContent_nonSupervisorMessage_returnsRawContent() {
        // The strip ONLY applies to `.supervisorMessage`. A regular user turn
        // whose content happens to start with "Supervisor:" must NOT be stripped.
        let msg = LLMMessage(
            role: .user,
            content: "Supervisor:\nshould not strip",
            sourceRole: nil,
            sourceContext: nil
        )
        XCTAssertEqual(msg.displayContent, "Supervisor:\nshould not strip")
    }

    func testDisplayContent_supervisorMessage_withoutPrefix_returnsContentUnchanged() {
        // Defensive: if somehow a .supervisorMessage landed without the header,
        // don't mangle its content.
        let msg = LLMMessage(
            role: .user,
            content: "no header here",
            sourceRole: .supervisor,
            sourceContext: .supervisorMessage
        )
        XCTAssertEqual(msg.displayContent, "no header here")
    }

    // MARK: - displayContent strip for .supervisorAnswer

    func testSupervisorAnswerPrefix_constantValue() {
        // The wire/persistence contract: write sides (StepMessagingService,
        // the auto-answer append, PromptBuilder's stateless rebuild) and read
        // sides (displayContent, ActivityFeedBuilder's answer extraction)
        // share this constant.
        XCTAssertEqual(MessageSourceContext.supervisorAnswerPrefix, "Supervisor answer: ")
    }

    func testDisplayContent_supervisorAnswer_stripsPrefix() {
        // Unpaired escalation/idle-park answers render as Supervisor bubbles —
        // the header already attributes the speaker, so the LLM-facing marker
        // must not show inline.
        let msg = LLMMessage(
            role: .user,
            content: "Supervisor answer: проверь задачу №5",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer
        )
        XCTAssertEqual(msg.displayContent, "проверь задачу №5")
    }

    func testDisplayContent_supervisorAnswer_withoutPrefix_returnsContentUnchanged() {
        // Defensive: an answer message that somehow lacks the marker renders raw.
        let msg = LLMMessage(
            role: .user,
            content: "no marker here",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer
        )
        XCTAssertEqual(msg.displayContent, "no marker here")
    }

    func testDisplayContent_nonAnswerMessage_keepsAnswerLookalikePrefix() {
        // The strip applies ONLY to `.supervisorAnswer` — a regular user turn
        // whose content happens to start with the marker is user content.
        let msg = LLMMessage(role: .user, content: "Supervisor answer: looks like one")
        XCTAssertEqual(msg.displayContent, "Supervisor answer: looks like one")
    }

    // MARK: - displayContent strip for .loopCorrection

    private var loopOpen: String { MessageSourceContext.loopCorrectionBlockOpen }
    private var loopClose: String { MessageSourceContext.loopCorrectionBlockClose }

    private func loopCorrection(_ content: String) -> LLMMessage {
        LLMMessage(role: .user, content: content, sourceContext: .loopCorrection)
    }

    /// The delimiters exist so both providers stop flattening the correction into the
    /// preceding `[Tool Result]` block — they are addressed to the wire, not to the reader.
    /// The feed row is already labelled `system: loop correction`, so leaving them in made the
    /// row's one-line preview read `--- LOOP CORRECTION ---`: a duplicate of its own label.
    func testDisplayContent_loopCorrection_stripsBothDelimiters() {
        let msg = loopCorrection("\(loopOpen)\nThe turn immediately before this note…\n\(loopClose)")
        XCTAssertEqual(msg.displayContent, "The turn immediately before this note…")
    }

    /// Each half is stripped on its own merit — a body that somehow carries only one marker
    /// must lose that one rather than neither. Two mechanisms, two pins (CLAUDE.md #60).
    func testDisplayContent_loopCorrection_stripsTheOpenMarkerAlone() {
        XCTAssertEqual(loopCorrection("\(loopOpen)\nbody").displayContent, "body")
    }

    func testDisplayContent_loopCorrection_stripsTheCloseMarkerAlone() {
        XCTAssertEqual(loopCorrection("body\n\(loopClose)").displayContent, "body")
    }

    func testDisplayContent_loopCorrection_isIdempotent() {
        let once = loopCorrection("\(loopOpen)\nbody\n\(loopClose)").displayContent
        XCTAssertEqual(loopCorrection(once).displayContent, once,
                       "an already-stripped body must not lose its first and last lines")
    }

    /// Corrections persisted before the delimited block was introduced carry no markers.
    func testDisplayContent_loopCorrection_withoutDelimiters_returnsContentUnchanged() {
        XCTAssertEqual(loopCorrection("bare legacy correction").displayContent,
                       "bare legacy correction")
    }

    /// A body of nothing but delimiters collapses to empty — NOT to a delimiter. This is the
    /// shape `SystemNoticePresentation.previewLine` reduces to the feed row.
    func testDisplayContent_loopCorrection_delimitersOnly_isEmpty() {
        let stripped = loopCorrection("\(loopOpen)\n\(loopClose)").displayContent
        XCTAssertFalse(stripped.contains(loopOpen))
        XCTAssertFalse(stripped.contains(loopClose))
    }

    /// The strip is gated on the CONTEXT, exactly like the two supervisor prefixes above.
    /// A retry nudge (or a model turn) whose text happens to open with the same line is
    /// content, not framing.
    func testDisplayContent_nonLoopCorrection_keepsDelimiterLookalikes() {
        let raw = "\(loopOpen)\nbody\n\(loopClose)"
        XCTAssertEqual(
            LLMMessage(role: .user, content: raw, sourceContext: .retryNudge).displayContent, raw)
        XCTAssertEqual(LLMMessage(role: .assistant, content: raw).displayContent, raw)
    }

    /// `displayContent` is a projection: the stored `content` — what
    /// `ConversationReplay.rebuildFromDisplayRecord` replays onto the wire — keeps the markers.
    func testDisplayContent_loopCorrection_doesNotMutateStoredContent() {
        let raw = "\(loopOpen)\nbody\n\(loopClose)"
        let msg = loopCorrection(raw)
        _ = msg.displayContent
        XCTAssertEqual(msg.content, raw)
    }

    func testLLMMessage_WithSupervisorMessageContext_CodableRoundTrip() throws {
        // Regression guard for the queued-message injection path: saved tasks must
        // round-trip LLMMessages carrying `.supervisorMessage` without loss so the
        // activity feed renders them correctly after app restart.
        let original = LLMMessage(
            role: .user,
            content: "Supervisor: доложи статус",
            sourceRole: .supervisor,
            sourceContext: .supervisorMessage
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)

        XCTAssertEqual(decoded.role, .user)
        XCTAssertEqual(decoded.sourceRole, .supervisor)
        XCTAssertEqual(decoded.sourceContext, .supervisorMessage)
        XCTAssertEqual(decoded.content, "Supervisor: доложи статус")
    }

    // MARK: - LLMMessage with sourceContext + sourceRole

    func testLLMMessage_WithSourceContext_CodableRoundTrip() throws {
        let original = LLMMessage(
            role: .user,
            content: "Here is my review of the plan.",
            sourceRole: .uxDesigner,
            sourceContext: .consultation
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, .user)
        XCTAssertEqual(decoded.content, "Here is my review of the plan.")
        XCTAssertEqual(decoded.sourceRole, .uxDesigner)
        XCTAssertEqual(decoded.sourceContext, .consultation)
    }

    func testLLMMessage_WithMeetingContext_CodableRoundTrip() throws {
        let original = LLMMessage(
            role: .user,
            content: "Meeting discussion point",
            sourceRole: .tpm,
            sourceContext: .meeting
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)

        XCTAssertEqual(decoded.sourceRole, .tpm)
        XCTAssertEqual(decoded.sourceContext, .meeting)
    }

    func testLLMMessage_WithoutSourceContext_DecodesAsNil() throws {
        // Backward compatibility: old JSON without sourceContext/sourceRole
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440001",
            "role": "assistant",
            "content": "Hello from the assistant"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LLMMessage.self, from: json)

        XCTAssertNil(decoded.sourceRole)
        XCTAssertNil(decoded.sourceContext)
        XCTAssertEqual(decoded.role, .assistant)
        XCTAssertEqual(decoded.content, "Hello from the assistant")
    }

    func testLLMMessage_WithThinking_CodableRoundTrip() throws {
        let original = LLMMessage(
            role: .assistant,
            content: "Final answer",
            thinking: "Let me reason through this..."
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)

        XCTAssertEqual(decoded.thinking, "Let me reason through this...")
        XCTAssertNil(decoded.sourceRole)
        XCTAssertNil(decoded.sourceContext)
    }

    func testLLMMessage_WithCustomRole_CodableRoundTrip() throws {
        let original = LLMMessage(
            role: .user,
            content: "Custom role response",
            sourceRole: .custom(id: "dataScientist"),
            sourceContext: .consultation
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)

        XCTAssertEqual(decoded.sourceRole, .custom(id: "dataScientist"))
    }

    // MARK: - StepExecution with Nested Arrays

    func testStepExecution_WithConsultations_CodableRoundTrip() throws {
        let consultation = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "How should the UI look?",
            response: "Use glassmorphism.",
            status: .completed
        )
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Engineer Step",
            consultations: [consultation]
        )

        let encoded = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(StepExecution.self, from: encoded)

        XCTAssertEqual(decoded.consultations.count, 1)
        XCTAssertEqual(decoded.consultations.first?.consultedRole, .uxDesigner)
        XCTAssertEqual(decoded.consultations.first?.response, "Use glassmorphism.")
        XCTAssertEqual(decoded.consultations.first?.status, .completed)
    }

    func testStepExecution_WithMeetingIDs_CodableRoundTrip() throws {
        let meetingID1 = UUID()
        let meetingID2 = UUID()
        let step = StepExecution(
            id: "test_step",
            role: .tpm,
            title: "PM Step",
            meetingIDs: [meetingID1, meetingID2]
        )

        let encoded = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(StepExecution.self, from: encoded)

        XCTAssertEqual(decoded.meetingIDs.count, 2)
        XCTAssertTrue(decoded.meetingIDs.contains(meetingID1))
        XCTAssertTrue(decoded.meetingIDs.contains(meetingID2))
    }

    func testStepExecution_WithLLMConversation_CodableRoundTrip() throws {
        let messages = [
            LLMMessage(role: .system, content: "You are a PM."),
            LLMMessage(role: .user, content: "Here is the task."),
            LLMMessage(role: .assistant, content: "I will create a plan."),
            LLMMessage(
                role: .user,
                content: "Designer perspective on UI",
                sourceRole: .uxDesigner,
                sourceContext: .consultation
            )
        ]
        let step = StepExecution(
            id: "test_step",
            role: .tpm,
            title: "PM Step",
            llmConversation: messages
        )

        let encoded = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(StepExecution.self, from: encoded)

        XCTAssertEqual(decoded.llmConversation.count, 4)

        // Verify the consultation message preserved sourceRole/sourceContext
        let consultationMsg = decoded.llmConversation[3]
        XCTAssertEqual(consultationMsg.sourceRole, .uxDesigner)
        XCTAssertEqual(consultationMsg.sourceContext, .consultation)
    }

    func testStepExecution_BackwardCompatibility_NoOptionalFields() throws {
        let json = """
        {
            "id": "legacy_step",
            "role": "softwareEngineer",
            "title": "Legacy Step",
            "status": "done"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(StepExecution.self, from: json)

        XCTAssertTrue(decoded.consultations.isEmpty)
        XCTAssertTrue(decoded.meetingIDs.isEmpty)
        XCTAssertTrue(decoded.llmConversation.isEmpty)
        XCTAssertNil(decoded.scratchpad)
        XCTAssertFalse(decoded.needsSupervisorInput)
    }

    // MARK: - Run.teamID Preservation

    func testRun_TeamID_CodableRoundTrip() throws {
        let teamID: NTMSID = "test_team"
        let run = Run(id: 0, teamID: teamID)

        let encoded = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(Run.self, from: encoded)

        XCTAssertEqual(decoded.teamID, teamID)
    }

    func testRun_TeamID_BackwardCompatibility() throws {
        let json = """
        {
            "id": 0,
            "mode": "manual"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Run.self, from: json)

        XCTAssertNil(decoded.teamID)
    }

    // MARK: - .serverError context (red retry-status bubble)

    func testMessageSourceContext_ServerError_RawValueIsStable() {
        // The rawValue is the persisted/wire form — pinned so it can't silently
        // drift and orphan messages saved by earlier builds.
        XCTAssertEqual(MessageSourceContext.serverError.rawValue, "serverError")
    }

    func testMessageSourceContext_ServerError_CodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(MessageSourceContext.serverError)
        let decoded = try JSONDecoder().decode(MessageSourceContext.self, from: encoded)
        XCTAssertEqual(decoded, .serverError)
    }

    func testSourceContextDisplayLabel_serverError_isNil() {
        // The red bubble + self-describing text convey "server error" — no label.
        let msg = LLMMessage(role: .assistant, content: "LLM server error (attempt 3)…",
                             sourceContext: .serverError)
        XCTAssertNil(msg.sourceContextDisplayLabel)
    }

    func testServerError_displayLabel_fallsBackToRawValue() {
        // `.serverError` is intentionally NOT in displayLabelMap (the nil bubble
        // label comes from the sourceContextDisplayLabel early-return, not the map).
        XCTAssertEqual(MessageSourceContext.serverError.displayLabel, "serverError")
    }

    func testLLMMessage_WithServerErrorContext_CodableRoundTrip() throws {
        let original = LLMMessage(role: .assistant, content: "LLM server error (attempt 1)…",
                                  sourceContext: .serverError)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)
        XCTAssertEqual(decoded.sourceContext, .serverError)
        XCTAssertEqual(decoded.content, "LLM server error (attempt 1)…")
    }

    func testLLMMessage_unknownSourceContextRawValue_decodesAsNil() throws {
        // Forward-compat: a context case added by a NEWER build, read after a
        // downgrade, must degrade to nil — not throw and fail the whole message
        // (and its step / task) to decode. Mirrors the tolerant `role` decode.
        let json = """
        {"id":"550e8400-e29b-41d4-a716-446655440099","role":"assistant","content":"x","sourceContext":"futureUnknownCase"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: json)
        XCTAssertNil(decoded.sourceContext, "Unknown sourceContext raw must decode to nil, not throw")
        XCTAssertEqual(decoded.content, "x")
    }

    // MARK: - carriesUnsolicitedInformation (loop-detector information boundary)

    /// The unsolicited set is exactly what arrives through the QUEUED-MESSAGE pipeline:
    /// `.supervisorMessage` — a queued Supervisor turn (human steering, `message_task`) or a
    /// parent's `forward_to_team` injected into a child — and `.autovisorEvent`, the app's
    /// mid-review notice that folder state moved. Nobody in the conversation asked for either.
    ///
    /// This test read `supervisorMessage_isTheOnlyBoundary` until `.autovisorEvent` was split
    /// out of `.supervisorMessage` (it had been the notice's context, which is why the feed
    /// drew it as a crowned Supervisor bubble). The pin was re-aimed at the property that
    /// survives the split rather than weakened or deleted (CLAUDE.md #104): "only one" was
    /// never the invariant — "unsolicited means it came off the queue" is.
    ///
    /// RED: drop either case from the `true` arm → this fails naming it, and in production the
    /// manager re-checking a task it was just told changed is scored as a loop.
    func testCarriesUnsolicitedInformation_theQueuedContexts_areTheBoundaries() {
        XCTAssertTrue(MessageSourceContext.supervisorMessage.carriesUnsolicitedInformation)
        XCTAssertTrue(MessageSourceContext.autovisorEvent.carriesUnsolicitedInformation)
    }

    /// `.autovisorEvent` is SYSTEM-authored yet a boundary, which no other system-authored
    /// context is — so state why here rather than leaving it to look like an oversight.
    ///
    /// The self-immunizing hazard that keeps `.toolAcknowledgement` / `.runtimeWarning` /
    /// `.retryNudge` on the `false` side does not apply: those are each stamped strictly after
    /// a call the model made, so a model spinning on that call would refresh its own cutoff.
    /// The event notice is composed by the app from FOLDER state, on a cadence the manager
    /// does not control — no amount of spinning manufactures one.
    ///
    /// RED: flip `.autovisorEvent` to `false` → this fails, and `AutovisorStuckEvaluator` plus
    /// `LoopScanner.scanCommitted` stop seeing the arrival they exist to respect.
    func testAutovisorEvent_isABoundary_despiteBeingSystemAuthored() {
        XCTAssertTrue(MessageSourceContext.autovisorEvent.carriesUnsolicitedInformation)
        XCTAssertNotNil(
            SystemNoticePresentation.resolve(context: .autovisorEvent, content: "body"),
            "system-authored (it collapses to a notice row) AND a boundary — that pairing is "
                + "unique to this context and is the point of this test"
        )
    }

    /// The self-immunizing set. Each of these is appended as the ANSWER to a tool call the
    /// model made, stamped strictly after that call in the same step's conversation
    /// (`commitCollaborationOutcome`, `recordAutoSupervisorAnswer`). If any of them opened a
    /// boundary, a model spinning on that very tool would refresh its own cutoff with every
    /// repeat, the committed scan would drop everything before the newest call, and the
    /// trailing run would be pinned at 1 — the detector could never fire again for
    /// `ask_teammate`, `request_team_meeting`, `request_changes`, or an auto-answered
    /// `ask_supervisor`.
    ///
    /// RED: flip any one of these to `true` → this fails naming it, and in production that
    /// tool becomes permanently un-detectable.
    func testSolicitedAnswers_areNotABoundary() {
        for context: MessageSourceContext in [
            .consultation, .meeting, .changeRequest, .supervisorAnswer,
        ] {
            XCTAssertFalse(
                context.carriesUnsolicitedInformation,
                "\(context.rawValue) is the answer to the model's OWN tool call and is stamped "
                    + "after it — counting it would let a spin on that tool immunize itself"
            )
        }
    }

    /// Stamped into the PARENT's conversation by a delegated CHILD, at a cadence the parent
    /// does not control. Counting them would let a child's chatter mask a parent looping on
    /// `delegate_to_team`.
    func testDelegationQuestions_areNotABoundary() {
        XCTAssertFalse(MessageSourceContext.delegatedQuestion.carriesUnsolicitedInformation)
        XCTAssertFalse(MessageSourceContext.delegationEscalation.carriesUnsolicitedInformation)
    }

    /// `.retryNudge` is load-bearing rather than merely correct: `checkAndInjectLoopWarning`
    /// persists its warning with exactly this context, so treating it as unsolicited
    /// information would make the detector cancel itself with its own output — it would fire
    /// once per step and then stay silent for as long as the model kept looping, which is
    /// worse than the false positive this whole mechanism was built to remove.
    ///
    /// RED: flip `.retryNudge` to `true` → this fails, and the repetition warning starts
    /// resetting the count it was emitted about.
    func testAppAuthoredTurns_areNotABoundary() {
        for context: MessageSourceContext in [
            .serverError, .loopCorrection, .retryNudge,
            .toolAcknowledgement, .runtimeWarning, .screenDescription,
        ] {
            XCTAssertFalse(
                context.carriesUnsolicitedInformation,
                "\(context.rawValue) is the app talking to the model — nothing arrived"
            )
        }
    }

    /// Why the tables above are hand-written lists and not a sweep over `allCases`.
    ///
    /// A sweep asserts that a new case falls on some default side, and here there IS no safe
    /// default: a missed boundary blames the model for reacting to news, and a spurious one
    /// on a context the model itself produces disables the detector for that tool forever.
    /// So exhaustiveness is enforced by the COMPILER instead — twice. Once in production
    /// (`carriesUnsolicitedInformation` is a `switch` with no `default`), and once here: this
    /// helper must bucket every case, so a context added later cannot compile without its
    /// author reading this file and deciding which table it belongs in.
    ///
    /// RED: add a `default:` arm here → a new case stops breaking this file, and the tables
    /// silently stop covering the enum.
    private enum Bucket { case boundary, solicitedAnswer, delegationChatter, appAuthored }

    private func bucket(_ context: MessageSourceContext) -> Bucket {
        switch context {
        case .supervisorMessage, .autovisorEvent: return .boundary
        case .consultation, .meeting, .changeRequest, .supervisorAnswer: return .solicitedAnswer
        case .delegatedQuestion, .delegationEscalation: return .delegationChatter
        case .serverError, .loopCorrection, .retryNudge,
             .toolAcknowledgement, .runtimeWarning, .screenDescription: return .appAuthored
        }
    }

    /// The buckets and the predicate must agree: exactly `.boundary` is a boundary.
    ///
    /// Sweeps `allCases` — unlike the tables above, this one asserts nothing about which side a
    /// new case belongs on, only that `bucket` and the predicate answer alike. The compiler
    /// already forces the author of a new case through `bucket`, so a literal list here would
    /// add a second place to forget and no coverage.
    func testBucketing_agreesWithThePredicate() {
        XCTAssertGreaterThanOrEqual(MessageSourceContext.allCases.count, 14,
                                    "anti-vacuity: a short allCases would check almost nothing")
        for context in MessageSourceContext.allCases {
            XCTAssertEqual(
                context.carriesUnsolicitedInformation,
                bucket(context) == .boundary,
                "\(context.rawValue): the truth table and the predicate disagree"
            )
        }
    }
}
