import XCTest

@testable import NanoTeams

/// Tests for `ConversationTranscriptRenderer` — the displayed-side audit transcript
/// (`conversation_log.md`) that's diffed against `network_log.json`.
///
/// Fidelity contract = **default-collapsed view only**: message content + one-line tool
/// summaries, NO thinking, NO raw tool args/result JSON, artifacts header-only. Plus the
/// `Supervisor:\n` prefix is stripped and pending supervisor questions are surfaced.
final class ConversationTranscriptRendererTests: XCTestCase {

    private func tag(_ item: TeamActivityTimelineItem) -> ActivityFeedBuilder.TaggedItem {
        ActivityFeedBuilder.TaggedItem(item: item, showSectionHeader: true, boundary: nil)
    }

    private func render(
        _ items: [TeamActivityTimelineItem],
        pending: [ActivityFeedBuilder.ActiveSupervisorQuestion] = [],
        isChatMode: Bool = false
    ) -> String {
        ConversationTranscriptRenderer.render(
            items: items.map(tag),
            pending: pending,
            teamRoles: [],
            isChatMode: isChatMode,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Empty

    func testEmpty_rendersHeaderAndNoActivity() {
        let md = render([])
        XCTAssertTrue(md.contains("# Conversation Log"))
        XCTAssertTrue(md.contains("No activity recorded"))
    }

    // MARK: - Supervisor:\n prefix is stripped (matches displayContent)

    func testSupervisorMessage_prefixStripped() {
        let msg = LLMMessage(
            role: .user,
            content: "\(MessageSourceContext.supervisorMessagePrefix)PLEASE_FIX_THE_BUG",
            sourceRole: .supervisor,
            sourceContext: .supervisorMessage
        )
        let md = render([.llmMessage(message: msg, role: .supervisor, stepID: "eng", originTaskID: 0)])

        XCTAssertTrue(md.contains("PLEASE_FIX_THE_BUG"))
        // The raw attribution prefix must NOT appear in the body (only the role label conveys it).
        XCTAssertFalse(md.contains("\(MessageSourceContext.supervisorMessagePrefix)PLEASE_FIX_THE_BUG"))
    }

    // MARK: - Thinking is NOT rendered (collapsed view)

    func testAssistantMessage_thinkingExcluded_contentIncluded() {
        let msg = LLMMessage(
            role: .assistant,
            content: "VISIBLE_CONTENT",
            thinking: "SECRET_THINKING"
        )
        let md = render([.llmMessage(message: msg, role: .softwareEngineer, stepID: "eng", originTaskID: 0)])

        XCTAssertTrue(md.contains("VISIBLE_CONTENT"))
        XCTAssertFalse(md.contains("SECRET_THINKING"), "Thinking is collapsed by default — must not appear.")
    }

    // MARK: - Tool call: one-line summary + status, NOT raw result JSON

    func testToolCall_summaryAndStatus_noRawResultJSON() {
        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\":\"src/main.swift\"}",
            resultJSON: "{\"ok\":true,\"secret_field\":\"DO_NOT_DUMP\"}",
            isError: false
        )
        let md = render([.toolCall(call: call, role: .softwareEngineer, stepID: "eng", originTaskID: 0)])

        XCTAssertTrue(md.contains("read_file"))
        XCTAssertTrue(md.contains("✓"), "Successful tool call shows the success status.")
        XCTAssertTrue(md.contains("src/main.swift"), "One-line arg summary should surface the path.")
        XCTAssertFalse(md.contains("DO_NOT_DUMP"), "Raw result JSON is window-only — must not be dumped.")
    }

    func testToolCall_error_showsErrorStatus() {
        let call = StepToolCall(name: "write_file", argumentsJSON: "{}", resultJSON: "{\"ok\":false}", isError: true)
        let md = render([.toolCall(call: call, role: .softwareEngineer, stepID: "eng", originTaskID: 0)])
        XCTAssertTrue(md.contains("write_file"))
        XCTAssertTrue(md.contains("✗"))
    }

    // MARK: - Artifact: header only (name + mimeType), NO content

    func testArtifact_headerOnly() {
        let artifact = Artifact(name: "Engineering Notes", mimeType: "text/markdown", relativePath: "tasks/0/runs/0/roles/eng/artifact_engineering_notes.md")
        let md = render([.artifact(artifact: artifact, role: .softwareEngineer, stepID: "eng", originTaskID: 0)])
        XCTAssertTrue(md.contains("Engineering Notes"))
        XCTAssertTrue(md.contains("text/markdown"))
    }

    // MARK: - Supervisor task brief

    func testSupervisorTask_rendersBrief() {
        let item = TeamActivityTimelineItem.supervisorTask(
            brief: "BUILD_A_CALCULATOR",
            taskCreatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            supervisorTask: "BUILD_A_CALCULATOR",
            clippedTexts: ["CLIP_ONE"],
            attachmentPaths: ["docs/spec.pdf"],
            workFolderURL: nil,
            originTaskID: 0
        )
        let md = render([item])
        XCTAssertTrue(md.contains("BUILD_A_CALCULATOR"))
        XCTAssertTrue(md.contains("CLIP_ONE"))
        XCTAssertTrue(md.contains("docs/spec.pdf"))
    }

    // MARK: - Resolved supervisor Q&A notification

    func testResolvedSupervisorInput_questionAndAnswer_noThinking() {
        let type = ActivityNotificationType.supervisorInput(
            question: "NEED_DECISION",
            answer: "DO_IT",
            answerAttachmentPaths: [],
            answerClippedTexts: [],
            toolCallID: UUID(),
            thinking: "NOTIF_SECRET_THINKING",
            wasAutoAnswered: false
        )
        let item = TeamActivityTimelineItem.notification(
            stepID: "eng", role: .softwareEngineer, type: type,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), originTaskID: 0
        )
        let md = render([item])
        XCTAssertTrue(md.contains("NEED_DECISION"))
        XCTAssertTrue(md.contains("DO_IT"))
        XCTAssertFalse(md.contains("NOTIF_SECRET_THINKING"), "Notification thinking is collapsed — must not appear.")
    }

    func testResolvedSupervisorInput_autoAnswered_showsAutoBadge() {
        let type = ActivityNotificationType.supervisorInput(
            question: "Q", answer: "AUTO_ANSWER", answerAttachmentPaths: [], answerClippedTexts: [],
            toolCallID: UUID(), thinking: nil, wasAutoAnswered: true
        )
        let item = TeamActivityTimelineItem.notification(
            stepID: "eng", role: .softwareEngineer, type: type, createdAt: Date(), originTaskID: 0
        )
        let md = render([item])
        XCTAssertTrue(md.contains("AUTO_ANSWER"))
        XCTAssertTrue(md.lowercased().contains("auto"))
    }

    func testResolvedSupervisorInput_chatMode_vs_nonChat_headerCopy() {
        // `title(for:isChatMode:)` only branches on isChatMode for an UNANSWERED notification.
        let type = ActivityNotificationType.supervisorInput(
            question: "Q", answer: nil, answerAttachmentPaths: [], answerClippedTexts: [],
            toolCallID: UUID(), thinking: nil, wasAutoAnswered: false
        )
        let item = TeamActivityTimelineItem.notification(
            stepID: "eng", role: .softwareEngineer, type: type, createdAt: Date(), originTaskID: 0
        )
        XCTAssertTrue(render([item], isChatMode: true).contains("replied"))
        XCTAssertTrue(render([item], isChatMode: false).contains("needs your input"))
    }

    // MARK: - Failed notification

    func testFailedNotification_rendersError() {
        let item = TeamActivityTimelineItem.notification(
            stepID: "eng", role: .softwareEngineer,
            type: .failed(errorMessage: "BUILD_BLEW_UP"),
            createdAt: Date(), originTaskID: 0
        )
        let md = render([item])
        XCTAssertTrue(md.lowercased().contains("error"))
        XCTAssertTrue(md.contains("BUILD_BLEW_UP"))
    }

    // MARK: - Meeting message

    func testMeetingMessage_rendersTopicContentAndType() {
        let msg = TeamMessage(role: .softwareEngineer, content: "MEETING_BODY", messageType: .proposal)
        let item = TeamActivityTimelineItem.meetingMessage(
            message: msg, meetingTopic: "MEETING_TOPIC", originTaskID: 0
        )
        let md = render([item])
        XCTAssertTrue(md.contains("MEETING_TOPIC"))
        XCTAssertTrue(md.contains("MEETING_BODY"))
        XCTAssertTrue(md.contains("proposal"))
    }

    func testMeetingMessage_thinkingExcluded() {
        let msg = TeamMessage(
            role: .softwareEngineer, content: "VISIBLE", messageType: .discussion,
            thinking: "MEETING_SECRET_THINKING"
        )
        let item = TeamActivityTimelineItem.meetingMessage(message: msg, meetingTopic: "T", originTaskID: 0)
        let md = render([item])
        XCTAssertTrue(md.contains("VISIBLE"))
        XCTAssertFalse(md.contains("MEETING_SECRET_THINKING"))
    }

    // MARK: - Change request

    func testChangeRequest_rendersTargetStatusAndChanges() {
        let request = ChangeRequest(
            requestingRoleID: "cr", targetRoleID: "eng",
            changes: "RENAME_THE_FUNCTION", reasoning: "clarity", status: .pending
        )
        let item = TeamActivityTimelineItem.changeRequest(
            request: request, targetRoleName: "Engineer", originTaskID: 0
        )
        let md = render([item])
        XCTAssertTrue(md.contains("Engineer"))
        XCTAssertTrue(md.contains("pending"))
        XCTAssertTrue(md.contains("RENAME_THE_FUNCTION"))
    }

    // MARK: - Consultation bubble (sourceRole + label)

    func testConsultationMessage_rendersConsultedRoleAndLabel() {
        let msg = LLMMessage(
            role: .user, content: "CONSULT_ANSWER",
            sourceRole: .codeReviewer, sourceContext: .consultation
        )
        let md = render([.llmMessage(message: msg, role: .codeReviewer, stepID: "eng", originTaskID: 0)])
        XCTAssertTrue(md.contains("Code Reviewer"), "Consulted role name (sourceRole) should show.")
        XCTAssertTrue(md.contains("(consultation)"))
        XCTAssertTrue(md.contains("CONSULT_ANSWER"))
    }

    // MARK: - Supervisor message: embedded attachment/clip markers extracted

    func testSupervisorMessage_extractsEmbeddedAttachments() {
        let content = "\(MessageSourceContext.supervisorMessagePrefix)DO_THE_THING\n\n## Attached Files\n- docs/spec.pdf"
        let msg = LLMMessage(
            role: .user, content: content,
            sourceRole: .supervisor, sourceContext: .supervisorMessage
        )
        let md = render([.llmMessage(message: msg, role: .supervisor, stepID: "eng", originTaskID: 0)])
        XCTAssertTrue(md.contains("DO_THE_THING"))
        XCTAssertTrue(md.contains("docs/spec.pdf"))
        // The marker section must be stripped from the visible body (matches MessageBubbleView).
        XCTAssertFalse(md.contains("## Attached Files"))
    }

    /// The transcript and the feed must answer "can this turn embed attachment markers?"
    /// identically. They did not: the feed covered `.supervisorAnswer`, this file covered
    /// only `.supervisorMessage`, so an answer carrying markers rendered as thumbnail cards
    /// on screen and as raw marker text on disk. Both now read
    /// `MessageSourceContext.mayEmbedAttachmentMarkers`.
    ///
    /// RED: narrow the predicate back to `== .supervisorMessage` → this fails.
    func testSupervisorAnswer_extractsEmbeddedAttachments_matchingTheFeed() {
        let content = "\(MessageSourceContext.supervisorAnswerPrefix)USE_THIS\n\n## Attached Files\n- docs/api.pdf"
        let msg = LLMMessage(
            role: .user, content: content,
            sourceRole: .supervisor, sourceContext: .supervisorAnswer
        )
        let md = render([.llmMessage(message: msg, role: .supervisor, stepID: "eng", originTaskID: 0)])
        XCTAssertTrue(md.contains("USE_THIS"))
        XCTAssertTrue(md.contains("docs/api.pdf"))
        XCTAssertFalse(md.contains("## Attached Files"))
    }

    /// The other side of the same predicate, and the reason it is not simply "every
    /// Supervisor turn": `stripAttachedFiles` TRUNCATES at the first line-anchored marker.
    /// Revision feedback can legitimately quote one — the Autovisor's `manage_role(comment:)`
    /// draws its text from the task brief, which composes that exact heading — and there is
    /// no attachment list behind it, so extracting would silently delete the tail.
    ///
    /// RED: add `.supervisorFeedback` to `mayEmbedAttachmentMarkers` → the tail vanishes and
    /// this fails.
    func testSupervisorFeedback_quotingAMarker_keepsItsTail() {
        let content = "\(MessageSourceContext.supervisorFeedbackPrefix)FIX_LINE_NUMBERS\n\n## Attached Files\n- TAIL_MUST_SURVIVE.md"
        let msg = LLMMessage(
            role: .user, content: content,
            sourceRole: .supervisor, sourceContext: .supervisorFeedback
        )
        let md = render([.llmMessage(message: msg, role: .supervisor, stepID: "eng", originTaskID: 0)])
        XCTAssertTrue(md.contains("FIX_LINE_NUMBERS"))
        XCTAssertTrue(md.contains("TAIL_MUST_SURVIVE.md"),
                      "the body is quoted whole — nothing was treated as an attachment list")
        XCTAssertFalse(md.contains("(supervisor feedback)"),
                       "and it carries no secondary label, matching the bubble")
    }

    // MARK: - Flat-feed ordering (items in order, pending block last)

    func testMultipleItems_preserveOrder_pendingBlockLast() {
        let task = TeamActivityTimelineItem.supervisorTask(
            brief: "AAA_TASK", taskCreatedAt: Date(), supervisorTask: "AAA_TASK",
            clippedTexts: [], attachmentPaths: [], workFolderURL: nil, originTaskID: 0
        )
        let msg = TeamActivityTimelineItem.llmMessage(
            message: LLMMessage(role: .assistant, content: "BBB_MSG"),
            role: .softwareEngineer, stepID: "eng", originTaskID: 0
        )
        let call = TeamActivityTimelineItem.toolCall(
            call: StepToolCall(name: "read_file", argumentsJSON: "{}", resultJSON: "{\"ok\":true}", isError: false),
            role: .softwareEngineer, stepID: "eng", originTaskID: 0
        )
        let pending = ActivityFeedBuilder.ActiveSupervisorQuestion(
            stepID: "eng", role: .softwareEngineer, question: "ZZZ_PENDING",
            paired: nil, toolCallID: UUID(), askedAt: Date()
        )
        let md = render([task, msg, call], pending: [pending])

        guard let aPos = md.range(of: "AAA_TASK")?.lowerBound,
              let bPos = md.range(of: "BBB_MSG")?.lowerBound,
              let cPos = md.range(of: "read_file")?.lowerBound,
              let zPos = md.range(of: "ZZZ_PENDING")?.lowerBound else {
            return XCTFail("All markers should be present")
        }
        XCTAssertTrue(aPos < bPos && bPos < cPos, "Items render in input order.")
        XCTAssertTrue(cPos < zPos, "Pending block renders after all timeline items.")
    }

    // MARK: - Pending (unanswered) supervisor question (composer-owned)

    func testPendingSupervisorQuestion_surfaced() {
        let pending = ActivityFeedBuilder.ActiveSupervisorQuestion(
            stepID: "eng",
            role: .softwareEngineer,
            question: "SHOULD_I_ADD_A_TEST",
            paired: nil,
            toolCallID: UUID(),
            askedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let md = render([], pending: [pending])
        XCTAssertTrue(md.contains("Pending supervisor input"))
        XCTAssertTrue(md.contains("SHOULD_I_ADD_A_TEST"))
    }

    // MARK: - Correlation anchor (step id present for alignment with network_log.json)

    func testEntry_carriesStepAnchor() {
        let msg = LLMMessage(role: .assistant, content: "hi")
        let md = render([.llmMessage(message: msg, role: .softwareEngineer, stepID: "eng_step_42", originTaskID: 0)])
        XCTAssertTrue(md.contains("step eng_step_42"), "Each entry must carry its stepID for network_log correlation.")
    }
}
