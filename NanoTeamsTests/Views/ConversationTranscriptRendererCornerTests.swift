import XCTest

@testable import NanoTeams

/// Corner-case coverage for `ConversationTranscriptRenderer`: empty/nil/whitespace bodies,
/// multi-line + markdown-special content, every tool-status branch, truncation/newline
/// collapsing, no-step anchors, custom team-role name resolution, and degenerate
/// notification / pending inputs.
final class ConversationTranscriptRendererCornerTests: XCTestCase {

    private func tag(_ item: TeamActivityTimelineItem) -> ActivityFeedBuilder.TaggedItem {
        ActivityFeedBuilder.TaggedItem(item: item, showSectionHeader: true, boundary: nil)
    }

    private func render(
        _ items: [TeamActivityTimelineItem],
        pending: [ActivityFeedBuilder.ActiveSupervisorQuestion] = [],
        isChatMode: Bool = false,
        teamRoles: [TeamRoleDefinition] = []
    ) -> String {
        ConversationTranscriptRenderer.render(
            items: items.map(tag),
            pending: pending,
            teamRoles: teamRoles,
            isChatMode: isChatMode,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func msgItem(_ msg: LLMMessage, role: Role = .softwareEngineer, stepID: String = "eng") -> TeamActivityTimelineItem {
        .llmMessage(message: msg, role: role, stepID: stepID, originTaskID: 0)
    }

    private func customRole(id: String, name: String) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: name, prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
    }

    // MARK: - Body formatting (quote / multi-line / markdown)

    func testMultiLineContent_eachLineBlockquoted() {
        let md = render([msgItem(LLMMessage(role: .assistant, content: "LINE_ONE\nLINE_TWO"))])
        XCTAssertTrue(md.contains("> LINE_ONE"))
        XCTAssertTrue(md.contains("> LINE_TWO"))
    }

    func testMarkdownSpecialChars_preservedNotInterpreted() {
        // A leading "#"/backtick in the body must stay inside the blockquote, not become a real heading.
        let md = render([msgItem(LLMMessage(role: .assistant, content: "# Not A Heading `code`"))])
        XCTAssertTrue(md.contains("> # Not A Heading `code`"))
    }

    func testWhitespaceOnlyMeetingContent_rendersEmptyMarker() {
        let item = TeamActivityTimelineItem.meetingMessage(
            message: TeamMessage(role: .softwareEngineer, content: "   "),
            meetingTopic: "T", originTaskID: 0
        )
        XCTAssertTrue(render([item]).contains("_(empty)_"))
    }

    // MARK: - singleLine: newline collapsing + truncation

    func testAnswer_newlinesCollapsedToSingleLine() {
        let type = ActivityNotificationType.supervisorInput(
            question: "Q", answer: "a\nb\nc", answerAttachmentPaths: [], answerClippedTexts: [],
            toolCallID: UUID(), thinking: nil, wasAutoAnswered: false
        )
        let md = render([.notification(stepID: "eng", role: .softwareEngineer, type: type, createdAt: Date(), originTaskID: 0)])
        XCTAssertTrue(md.contains("answer: a b c"))
        XCTAssertFalse(md.contains("answer: a\nb"))
    }

    func testAnswer_truncatedAtBoundary() {
        let long = String(repeating: "Y", count: 250)
        let type = ActivityNotificationType.supervisorInput(
            question: "Q", answer: long, answerAttachmentPaths: [], answerClippedTexts: [],
            toolCallID: UUID(), thinking: nil, wasAutoAnswered: false
        )
        let md = render([.notification(stepID: "eng", role: .softwareEngineer, type: type, createdAt: Date(), originTaskID: 0)])
        XCTAssertTrue(md.contains("…"), "Over-200-char answer is truncated with an ellipsis.")
        XCTAssertTrue(md.contains(String(repeating: "Y", count: 200)))
        XCTAssertFalse(md.contains(String(repeating: "Y", count: 250)))
    }

    func testClip_newlinesCollapsed() {
        let item = TeamActivityTimelineItem.supervisorTask(
            brief: "B", taskCreatedAt: Date(), supervisorTask: "B",
            clippedTexts: ["x\ny\nz"], attachmentPaths: [], workFolderURL: nil, originTaskID: 0
        )
        XCTAssertTrue(render([item]).contains("clip: x y z"))
    }

    // MARK: - Tool-call status branches

    func testToolCall_pending_nilResult_ellipsis() {
        let call = StepToolCall(name: "read_file", argumentsJSON: "{}", resultJSON: nil)
        XCTAssertTrue(render([.toolCall(call: call, role: .softwareEngineer, stepID: "eng", originTaskID: 0)]).contains("…"))
    }

    func testToolCall_analyzing_ellipsis() {
        let call = StepToolCall(
            name: ToolNames.analyzeImage, argumentsJSON: "{}",
            resultJSON: "{\"status\":\"analyzing\"}", isError: nil
        )
        XCTAssertTrue(render([.toolCall(call: call, role: .softwareEngineer, stepID: "eng", originTaskID: 0)]).contains("…"))
    }

    func testToolCall_generatingTeam_ellipsis() {
        let call = StepToolCall(
            name: ToolNames.createTeam, argumentsJSON: "{}",
            resultJSON: "{\"status\":\"generating\"}", isError: nil
        )
        XCTAssertTrue(render([.toolCall(call: call, role: .supervisor, stepID: "sup", originTaskID: 0)]).contains("…"))
    }

    func testToolCall_unknownTool_noCrash_nameShown() {
        let call = StepToolCall(name: "totally_made_up_tool", argumentsJSON: "{}", resultJSON: "{\"ok\":true}", isError: false)
        let md = render([.toolCall(call: call, role: .softwareEngineer, stepID: "eng", originTaskID: 0)])
        XCTAssertTrue(md.contains("totally_made_up_tool"))
        XCTAssertTrue(md.contains("✓"))
    }

    func testToolCall_malformedArgsJSON_noCrash() {
        let call = StepToolCall(name: "read_file", argumentsJSON: "{not valid json", resultJSON: "{\"ok\":true}", isError: false)
        let md = render([.toolCall(call: call, role: .softwareEngineer, stepID: "eng", originTaskID: 0)])
        XCTAssertTrue(md.contains("read_file"))
    }

    // MARK: - Notification degenerate inputs

    func testSupervisorInput_emptyAnswer_noAnswerLine() {
        let type = ActivityNotificationType.supervisorInput(
            question: "QUESTION_X", answer: "", answerAttachmentPaths: ["f.pdf"], answerClippedTexts: ["c"],
            toolCallID: UUID(), thinking: nil, wasAutoAnswered: false
        )
        let md = render([.notification(stepID: "eng", role: .softwareEngineer, type: type, createdAt: Date(), originTaskID: 0)])
        XCTAssertTrue(md.contains("QUESTION_X"))
        XCTAssertFalse(md.contains("answer:"), "Empty answer must not produce an answer line…")
        XCTAssertFalse(md.contains("f.pdf"), "…nor its attachments (gated on a non-empty answer).")
    }

    func testSupervisorInput_answerWithAttachmentsAndClips() {
        let type = ActivityNotificationType.supervisorInput(
            question: "Q", answer: "DONE", answerAttachmentPaths: ["spec.pdf"], answerClippedTexts: ["CLIP_Y"],
            toolCallID: UUID(), thinking: nil, wasAutoAnswered: false
        )
        let md = render([.notification(stepID: "eng", role: .softwareEngineer, type: type, createdAt: Date(), originTaskID: 0)])
        XCTAssertTrue(md.contains("spec.pdf"))
        XCTAssertTrue(md.contains("CLIP_Y"))
    }

    func testFailedNotification_nilError_noBody() {
        let item = TeamActivityTimelineItem.notification(
            stepID: "eng", role: .softwareEngineer, type: .failed(errorMessage: nil),
            createdAt: Date(), originTaskID: 0
        )
        let md = render([item])
        XCTAssertTrue(md.lowercased().contains("error"))
        XCTAssertFalse(md.contains("> "), "Nil error message means no quoted body line.")
    }

    // MARK: - Change request status passthrough

    func testChangeRequest_approvedStatus() {
        let request = ChangeRequest(requestingRoleID: "cr", targetRoleID: "eng", changes: "C", reasoning: "R", status: .approved)
        let md = render([.changeRequest(request: request, targetRoleName: "Engineer", originTaskID: 0)])
        XCTAssertTrue(md.contains("[approved]"))
    }

    // MARK: - Supervisor task fallback + no-step anchor

    func testSupervisorTask_emptySupervisorTask_fallsBackToBrief() {
        let item = TeamActivityTimelineItem.supervisorTask(
            brief: "FALLBACK_BRIEF", taskCreatedAt: Date(), supervisorTask: "",
            clippedTexts: [], attachmentPaths: [], workFolderURL: nil, originTaskID: 0
        )
        XCTAssertTrue(render([item]).contains("FALLBACK_BRIEF"))
    }

    func testSupervisorTask_anchorHasNoStepSegment() {
        let item = TeamActivityTimelineItem.supervisorTask(
            brief: "B", taskCreatedAt: Date(), supervisorTask: "B",
            clippedTexts: [], attachmentPaths: [], workFolderURL: nil, originTaskID: 0
        )
        // Supervisor task carries no stepID → anchor is `time · Supervisor`, never `· step`.
        XCTAssertFalse(render([item]).contains("Supervisor · step"))
    }

    // MARK: - Anchor timestamp format

    func testAnchor_containsISOTimestamp() {
        // 1_700_000_000 = 2023-11-14T22:13:20Z (ISO8601DateFormatter defaults to UTC).
        let md = render([msgItem(LLMMessage(role: .assistant, content: "x"))])
        XCTAssertTrue(md.contains("2023-11-14T"), "Anchor must carry an ISO-8601 timestamp for network_log correlation.")
    }

    // MARK: - Role-name resolution

    func testToolCall_resolvesCustomTeamRoleName() {
        let roles = [customRole(id: "eng_step", name: "Custom Engineer")]
        let call = StepToolCall(name: "read_file", argumentsJSON: "{}", resultJSON: "{\"ok\":true}", isError: false)
        let md = render(
            [.toolCall(call: call, role: .softwareEngineer, stepID: "eng_step", originTaskID: 0)],
            teamRoles: roles
        )
        XCTAssertTrue(md.contains("Custom Engineer"), "Step-scoped items resolve the team's custom role name by stepID.")
    }

    func testConsultation_prefersSourceRoleName_overTeamRolesByStep() {
        // Consultation bubble: displayed actor is the sourceRole, NOT the step's role —
        // even when teamRoles has a custom name for the step id.
        let roles = [customRole(id: "eng", name: "Custom Engineer")]
        let msg = LLMMessage(role: .user, content: "C", sourceRole: .codeReviewer, sourceContext: .consultation)
        let md = render([msgItem(msg, role: .codeReviewer, stepID: "eng")], teamRoles: roles)
        XCTAssertTrue(md.contains("Code Reviewer"))
        XCTAssertFalse(md.contains("Custom Engineer"), "preferRole forces the sourceRole's name, not the step's.")
    }

    // MARK: - Pending corner cases

    func testMultiplePendingQuestions_allRendered_oneHeader() {
        let q1 = ActivityFeedBuilder.ActiveSupervisorQuestion(
            stepID: "eng", role: .softwareEngineer, question: "PENDING_A", paired: nil, toolCallID: UUID(), askedAt: Date()
        )
        let q2 = ActivityFeedBuilder.ActiveSupervisorQuestion(
            stepID: "tl", role: .techLead, question: "PENDING_B", paired: nil, toolCallID: UUID(), askedAt: Date()
        )
        let md = render([], pending: [q1, q2])
        XCTAssertTrue(md.contains("PENDING_A"))
        XCTAssertTrue(md.contains("PENDING_B"))
        // Single section header for the whole pending block.
        let headerCount = md.components(separatedBy: "Pending supervisor input").count - 1
        XCTAssertEqual(headerCount, 1)
    }

    func testPendingQuestion_emptyText_rendersEmptyMarker() {
        let q = ActivityFeedBuilder.ActiveSupervisorQuestion(
            stepID: "eng", role: .softwareEngineer, question: "   ", paired: nil, toolCallID: UUID(), askedAt: Date()
        )
        XCTAssertTrue(render([], pending: [q]).contains("_(empty)_"))
    }

    // MARK: - Flat render: showSectionHeader is intentionally IGNORED (per-entry anchors)

    func testFlatRender_ignoresShowSectionHeader_anchorPerEntry() {
        // The transcript is flat: every entry carries its own `time · role · step` anchor for
        // network_log correlation — consecutive same-role items are NOT grouped under one header,
        // regardless of `TaggedItem.showSectionHeader`.
        let a = ActivityFeedBuilder.TaggedItem(
            item: msgItem(LLMMessage(role: .assistant, content: "FIRST")),
            showSectionHeader: true, boundary: nil
        )
        let b = ActivityFeedBuilder.TaggedItem(
            item: msgItem(LLMMessage(role: .assistant, content: "SECOND")),
            showSectionHeader: false, boundary: nil
        )
        let md = ConversationTranscriptRenderer.render(
            items: [a, b], pending: [], teamRoles: [], isChatMode: false,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(md.contains("FIRST") && md.contains("SECOND"))
        // A full `· step eng` anchor appears once per entry even with showSectionHeader=false
        // (the renderer never groups consecutive same-role items).
        XCTAssertEqual(md.components(separatedBy: "step eng").count - 1, 2)
    }

    // MARK: - Degenerate item bodies

    func testSupervisorTask_bothBriefAndTaskEmpty_emptyMarker() {
        let item = TeamActivityTimelineItem.supervisorTask(
            brief: "", taskCreatedAt: Date(), supervisorTask: "",
            clippedTexts: [], attachmentPaths: [], workFolderURL: nil, originTaskID: 0
        )
        XCTAssertTrue(render([item]).contains("_(empty)_"))
    }

    func testChangeRequest_emptyChanges_emptyMarker() {
        let request = ChangeRequest(requestingRoleID: "cr", targetRoleID: "eng", changes: "   ", reasoning: "R", status: .pending)
        let md = render([.changeRequest(request: request, targetRoleName: "Engineer", originTaskID: 0)])
        XCTAssertTrue(md.contains("Engineer"))
        XCTAssertTrue(md.contains("_(empty)_"))
    }

    // MARK: - singleLine truncation boundary

    func testSingleLine_at200Chars_notTruncated() {
        let exactly200 = String(repeating: "Z", count: 200)
        let type = ActivityNotificationType.supervisorInput(
            question: "Q", answer: exactly200, answerAttachmentPaths: [], answerClippedTexts: [],
            toolCallID: UUID(), thinking: nil, wasAutoAnswered: false
        )
        let md = render([.notification(stepID: "eng", role: .softwareEngineer, type: type, createdAt: Date(), originTaskID: 0)])
        XCTAssertTrue(md.contains(exactly200))
        XCTAssertFalse(md.contains("…"), "Exactly 200 chars is the boundary — not truncated.")
    }

    func testSingleLine_at201Chars_truncated() {
        let type = ActivityNotificationType.supervisorInput(
            question: "Q", answer: String(repeating: "W", count: 201), answerAttachmentPaths: [], answerClippedTexts: [],
            toolCallID: UUID(), thinking: nil, wasAutoAnswered: false
        )
        let md = render([.notification(stepID: "eng", role: .softwareEngineer, type: type, createdAt: Date(), originTaskID: 0)])
        XCTAssertTrue(md.contains("…"))
        XCTAssertFalse(md.contains(String(repeating: "W", count: 201)))
    }
}
