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
}
