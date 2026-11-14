import Foundation
import SwiftUI
import XCTest
@testable import NanoTeams

@MainActor
final class ExternalAutovisorFeedTransparencyTests: XCTestCase {

    private let agentIdentity = AgentIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        label: "Claude Code"
    )

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    // MARK: - 1. Byte-for-Byte Wire Prompt Invariance (§11 / Ш22 Critical Invariant)

    func testWirePrompt_isByteIdentical_withAndWithoutExternalAgentOriginAndAuthorLabels() throws {
        let roleDef = TeamRoleDefinition(
            id: "coder",
            name: "Coder",
            icon: "hammer",
            prompt: "Write clean Swift code.",
            toolIDs: ["read_file", "write_file"],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let team = Team(
            id: "core-team",
            name: "Core Team",
            description: "Builds core features",
            roles: [roleDef],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )

        let msgTimestamp = date(100)
        let stepMsgID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let llmMsg1ID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let llmMsg2ID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let llmMsg3ID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

        let baseStepMessages = [
            StepMessage(
                id: stepMsgID,
                createdAt: msgTimestamp,
                role: .supervisor,
                content: "Supervisor instructions: Implement feature X."
            )
        ]

        let humanConversation: [LLMMessage] = [
            LLMMessage(
                id: llmMsg1ID,
                createdAt: date(110),
                role: .user,
                content: "Supervisor answer: Use actors.",
                sourceRole: .supervisor,
                sourceContext: .supervisorAnswer,
                authorLabel: nil
            ),
            LLMMessage(
                id: llmMsg2ID,
                createdAt: date(120),
                role: .user,
                content: "Supervisor message: Keep diff minimal.",
                sourceRole: .supervisor,
                sourceContext: .supervisorMessage,
                authorLabel: nil
            ),
            LLMMessage(
                id: llmMsg3ID,
                createdAt: date(130),
                role: .user,
                content: "[SUPERVISOR FEEDBACK — REVISION REQUESTED]\nAdd edge-case test.",
                sourceRole: .supervisor,
                sourceContext: .supervisorFeedback,
                authorLabel: nil
            )
        ]

        let agentConversation: [LLMMessage] = [
            LLMMessage(
                id: llmMsg1ID,
                createdAt: date(110),
                role: .user,
                content: "Supervisor answer: Use actors.",
                sourceRole: .supervisor,
                sourceContext: .supervisorAnswer,
                authorLabel: "Claude Code"
            ),
            LLMMessage(
                id: llmMsg2ID,
                createdAt: date(120),
                role: .user,
                content: "Supervisor message: Keep diff minimal.",
                sourceRole: .supervisor,
                sourceContext: .supervisorMessage,
                authorLabel: "Claude Code"
            ),
            LLMMessage(
                id: llmMsg3ID,
                createdAt: date(130),
                role: .user,
                content: "[SUPERVISOR FEEDBACK — REVISION REQUESTED]\nAdd edge-case test.",
                sourceRole: .supervisor,
                sourceContext: .supervisorFeedback,
                authorLabel: "Claude Code"
            )
        ]

        let humanStep = StepExecution(
            id: "coder",
            role: .custom(id: "coder"),
            title: "Coder",
            status: .running,
            updatedAt: date(140),
            messages: baseStepMessages,
            needsSupervisorInput: false,
            supervisorQuestion: "Should we use actors?",
            supervisorAnswer: "Use actors.",
            supervisorAnswerWasAuto: false,
            supervisorAnswerAuthor: nil,
            llmConversation: humanConversation,
            revisionComment: "Add edge-case test.",
            revisionCommentAuthor: nil
        )

        let agentStep = StepExecution(
            id: "coder",
            role: .custom(id: "coder"),
            title: "Coder",
            status: .running,
            updatedAt: date(140),
            messages: baseStepMessages,
            needsSupervisorInput: false,
            supervisorQuestion: "Should we use actors?",
            supervisorAnswer: "Use actors.",
            supervisorAnswerWasAuto: false,
            supervisorAnswerAuthor: "Claude Code",
            llmConversation: agentConversation,
            revisionComment: "Add edge-case test.",
            revisionCommentAuthor: "Claude Code"
        )

        let humanRun = Run(
            id: 1,
            createdAt: date(0),
            steps: [humanStep],
            supervisorEvents: []
        )
        let agentRun = Run(
            id: 1,
            createdAt: date(0),
            steps: [agentStep],
            supervisorEvents: [
                SupervisorTimelineEvent(
                    createdAt: date(135),
                    kind: .roleAccepted,
                    authorLabel: "Claude Code",
                    roleID: "coder"
                ),
                SupervisorTimelineEvent(
                    createdAt: date(139),
                    kind: .taskClosed,
                    authorLabel: "Claude Code"
                )
            ]
        )

        let humanTask = NTMSTask(
            id: 42,
            title: "Implement feature X",
            supervisorTask: "Implement feature X with unit tests.",
            status: .running,
            createdAt: date(0),
            updatedAt: date(140),
            runs: [humanRun],
            preferredTeamID: team.id,
            origin: nil
        )

        var agentTask = humanTask
        agentTask.origin = .externalAgent(agentIdentity)
        agentTask.runs = [agentRun]

        let humanPromptMessages = PromptBuilder.buildChatMessages(
            context: PromptBuilder.Context(
                task: humanTask,
                step: humanStep,
                stepIndex: 0,
                run: humanRun,
                workFolder: nil,
                artifactReader: { _ in nil },
                activeTeam: team,
                roleDefinition: roleDef
            ),
            tools: []
        )

        let agentPromptMessages = PromptBuilder.buildChatMessages(
            context: PromptBuilder.Context(
                task: agentTask,
                step: agentStep,
                stepIndex: 0,
                run: agentRun,
                workFolder: nil,
                artifactReader: { _ in nil },
                activeTeam: team,
                roleDefinition: roleDef
            ),
            tools: []
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let humanPromptBytes = try encoder.encode(humanPromptMessages)
        let agentPromptBytes = try encoder.encode(agentPromptMessages)
        XCTAssertEqual(
            humanPromptBytes,
            agentPromptBytes,
            "PromptBuilder wire messages must be byte-for-byte identical regardless of externalAgent origin or author labels"
        )

        let humanReplay = ConversationReplay.rebuildFromDisplayRecord(humanConversation)
        let agentReplay = ConversationReplay.rebuildFromDisplayRecord(agentConversation)
        let humanReplayBytes = try encoder.encode(humanReplay)
        let agentReplayBytes = try encoder.encode(agentReplay)
        XCTAssertEqual(
            humanReplayBytes,
            agentReplayBytes,
            "ConversationReplay wire messages must be byte-for-byte identical regardless of LLMMessage.authorLabel"
        )

        // Verify queued delivery wire prompt is also byte-for-byte identical
        let humanQueued = NTMSOrchestrator.composeQueuedDelivery([
            NTMSOrchestrator.QueuedDeliveryEntry(
                kind: .supervisorSpeech,
                body: "Check edge cases",
                isRedelivery: false,
                authorLabel: nil
            )
        ])
        let agentQueued = NTMSOrchestrator.composeQueuedDelivery([
            NTMSOrchestrator.QueuedDeliveryEntry(
                kind: .supervisorSpeech,
                body: "Check edge cases",
                isRedelivery: false,
                authorLabel: "Claude Code"
            )
        ])
        XCTAssertEqual(
            Data(humanQueued.wirePrompt.utf8),
            Data(agentQueued.wirePrompt.utf8),
            "Queued delivery wirePrompt must be byte-for-byte identical when authorLabel is set"
        )
        XCTAssertEqual(agentQueued.displayTurns.first?.authorLabel, "Claude Code")
    }

    // MARK: - 2. Sidebar Origin Badge / Pill

    func testSidebarViewLogic_populatesExternalAgentOriginLabel() {
        let externalTask = NTMSTask(
            id: 1,
            title: "External task",
            supervisorTask: "Do work",
            status: .running,
            createdAt: date(10),
            updatedAt: date(20),
            origin: .externalAgent(agentIdentity)
        )

        let humanTask = NTMSTask(
            id: 2,
            title: "Human task",
            supervisorTask: "Manual work",
            status: .running,
            createdAt: date(15),
            updatedAt: date(25),
            origin: nil
        )

        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [externalTask.toSummary(), humanTask.toSummary()],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:]
        )

        let extItem = items.first { $0.id == 1 }
        let humItem = items.first { $0.id == 2 }
        XCTAssertEqual(extItem?.externalAgentLabel, "Claude Code")
        XCTAssertNil(humItem?.externalAgentLabel)
    }

    // MARK: - 3. ActivityFeedBuilder & Transcript Transparency

    func testActivityFeedBuilder_andTranscriptRenderer_surfaceAllExternalAgentAuthorship() {
        let roleDef = TeamRoleDefinition(
            id: "coder",
            name: "Coder",
            icon: "hammer",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )

        let askCall = StepToolCall(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            createdAt: date(100),
            name: ToolNames.askSupervisor,
            argumentsJSON: #"{"question":"Which cache policy?"}"#,
            resultJSON: #"{"ok":true,"data":{"status":"answered"}}"#,
            isError: false
        )
        let answerMsg = LLMMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            createdAt: date(120),
            role: .user,
            content: "Supervisor answer: Use LRU cache.",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer,
            authorLabel: "Claude Code"
        )
        let directMsg = LLMMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            createdAt: date(140),
            role: .user,
            content: MessageSourceContext.supervisorMessagePrefix + "Please also add metrics.",
            sourceRole: .supervisor,
            sourceContext: .supervisorMessage,
            authorLabel: "Claude Code"
        )

        let step = StepExecution(
            id: "coder",
            role: .custom(id: "coder"),
            title: "Coder",
            status: .done,
            updatedAt: date(160),
            toolCalls: [askCall],
            needsSupervisorInput: false,
            supervisorQuestion: "Which cache policy?",
            supervisorAnswer: "Use LRU cache.",
            supervisorAnswerWasAuto: false,
            supervisorAnswerAuthor: "Claude Code",
            llmConversation: [answerMsg, directMsg],
            revisionComment: "Handle empty keys.",
            revisionCommentAuthor: "Claude Code"
        )

        let run = Run(
            id: 1,
            createdAt: date(0),
            steps: [step],
            supervisorEvents: [
                SupervisorTimelineEvent(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
                    createdAt: date(180),
                    kind: .roleAccepted,
                    authorLabel: "Claude Code",
                    roleID: "coder"
                ),
                SupervisorTimelineEvent(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                    createdAt: date(200),
                    kind: .taskClosed,
                    authorLabel: "Claude Code"
                )
            ]
        )

        let items = ActivityFeedBuilder.buildTimelineItems(
            steps: [step],
            run: run,
            teamRoles: [roleDef],
            activeTaskID: 7,
            supervisorBrief: "Build caching layer",
            supervisorBriefDate: date(10),
            supervisorTask: "Build caching layer",
            supervisorAuthorLabel: "Claude Code",
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )

        // 1) .supervisorTask carries authorLabel == "Claude Code"
        guard case let .supervisorTask(_, _, _, _, _, _, _, taskAuthor) = items.first?.item else {
            return XCTFail("Expected .supervisorTask first")
        }
        XCTAssertEqual(taskAuthor, "Claude Code")

        // 2) .supervisorInput carries answerAuthor == "Claude Code"
        let inputAuthors: [String?] = items.compactMap {
            if case let .notification(_, _, .supervisorInput(_, _, _, _, _, _, _, _, answerAuthor), _, _) = $0.item {
                return answerAuthor
            }
            return nil
        }
        XCTAssertEqual(inputAuthors, ["Claude Code"])

        // 3) message_task and pending revisionComment carry sourceContextDisplayLabel == "Claude Code"
        let supervisorBubbles: [(content: String, label: String?)] = items.compactMap {
            if case let .llmMessage(msg, _, _, _) = $0.item, msg.sourceContext?.rendersAsSupervisorUtterance == true {
                return (msg.displayContent, msg.sourceContextDisplayLabel)
            }
            return nil
        }
        XCTAssertEqual(supervisorBubbles.count, 2)
        XCTAssertEqual(supervisorBubbles[0].content, "Please also add metrics.")
        XCTAssertEqual(supervisorBubbles[0].label, "Claude Code")
        XCTAssertEqual(supervisorBubbles[1].content, "Handle empty keys.")
        XCTAssertEqual(supervisorBubbles[1].label, "Claude Code")

        // 4) System timeline events (.supervisorEvent) for accepted and closed
        let eventSummaries: [String] = items.compactMap {
            if case let .notification(_, _, .supervisorEvent(event, roleName), _, _) = $0.item {
                return event.summaryText(roleName: roleName)
            }
            return nil
        }
        XCTAssertEqual(eventSummaries, ["Claude Code accepted Coder", "Claude Code closed task"])

        // 5) ConversationTranscriptRenderer (conversation_log.md) includes all attributions
        let transcript = ConversationTranscriptRenderer.render(
            items: items,
            pending: [],
            teamRoles: [roleDef],
            isChatMode: false,
            generatedAt: date(250)
        )
        XCTAssertTrue(transcript.contains("Supervisor (Claude Code)"), "Transcript should attribute initial task to Supervisor (Claude Code)")
        XCTAssertTrue(transcript.contains("answer (by Claude Code): Use LRU cache."), "Transcript should attribute ask_supervisor answer to Claude Code")
        XCTAssertTrue(transcript.contains("✓ Claude Code accepted Coder"), "Transcript should include roleAccepted event")
        XCTAssertTrue(transcript.contains("✓ Claude Code closed task"), "Transcript should include taskClosed event")
    }

    // MARK: - 4. C8 Single-Writer & Clear-on-Re-Answer / Reset Discipline

    func testStepMessagingService_setsAndClearsSupervisorAnswerAuthor() {
        let askCall = StepToolCall(
            createdAt: date(100),
            name: ToolNames.askSupervisor,
            argumentsJSON: #"{"question":"Which cache policy?"}"#
        )
        let step = StepExecution(
            id: "coder",
            role: .custom(id: "coder"),
            title: "Coder",
            status: .needsSupervisorInput,
            toolCalls: [askCall],
            needsSupervisorInput: true,
            supervisorQuestion: "Which cache policy?"
        )
        var task = NTMSTask(
            id: 9,
            title: "Cache task",
            supervisorTask: "Build cache",
            runs: [Run(id: 1, steps: [step])]
        )

        let applied = StepMessagingService.answerSupervisorQuestion(
            stepID: "coder",
            answer: "Use LRU.",
            origin: .automated,
            author: "Claude Code",
            in: &task
        )
        XCTAssertTrue(applied)
        XCTAssertEqual(task.runs[0].steps[0].supervisorAnswerAuthor, "Claude Code")
        XCTAssertTrue(task.runs[0].steps[0].supervisorAnswerWasAuto)
        XCTAssertEqual(task.runs[0].steps[0].llmConversation.last?.authorLabel, "Claude Code")

        // Subsequent human answer clears supervisorAnswerAuthor
        task.runs[0].steps[0].needsSupervisorInput = true
        task.runs[0].steps[0].status = .needsSupervisorInput
        _ = StepMessagingService.answerSupervisorQuestion(
            stepID: "coder",
            answer: "Actually use ARC.",
            origin: .supervisor,
            author: nil,
            in: &task
        )
        XCTAssertNil(task.runs[0].steps[0].supervisorAnswerAuthor)
        XCTAssertFalse(task.runs[0].steps[0].supervisorAnswerWasAuto)
        XCTAssertNil(task.runs[0].steps[0].llmConversation.last?.authorLabel)

        // reset() also clears supervisorAnswerAuthor
        task.runs[0].steps[0].supervisorAnswerAuthor = "Claude Code"
        task.runs[0].steps[0].reset()
        XCTAssertNil(task.runs[0].steps[0].supervisorAnswerAuthor)
    }

    // MARK: - 5. One shape for every answer, one mark for the agent (design review 2026-11-07)

    /// The answer card's byline: the person's own answer has none; an agent's names the agent;
    /// the team's auto-answer says `auto`, the word the bubble header already uses.
    func testSupervisorInputCard_attributesAnAnswerOnlyWhenItWasNotThePersons() {
        func card(author: String?, auto: Bool) -> SupervisorInputCard {
            SupervisorInputCard(
                question: "Which cache?", answer: "LRU.", thinking: nil, thinkingID: UUID(),
                roleName: "Coder", isAutoAnswering: false, wasAutoAnswered: auto, answerAuthor: author)
        }
        XCTAssertNil(card(author: nil, auto: false).answerAttribution)
        XCTAssertNil(card(author: "   ", auto: false).answerAttribution, "a blank author is no author")
        XCTAssertEqual(card(author: "Claude Code", auto: false).answerAttribution, "answered by Claude Code")
        XCTAssertEqual(card(author: " Claude Code ", auto: true).answerAttribution, "answered by Claude Code",
                       "a signed turn names its signer, whatever the step's auto flag says")
        XCTAssertEqual(card(author: nil, auto: true).answerAttribution, "answered by \(LLMMessage.automatedSupervisorLabel)")
    }

    /// "<agent> closed task" is one log line, not a card: no block under it repeating it
    /// (2026-11-07) and no avatar square beside it (2026-11-08). Measured as height — a line of
    /// text is shorter than the 22 pt avatar box the card anatomy would put in the gutter.
    func testNotificationItemView_drawsASupervisorEventAsOneLogLine() throws {
        for event in [
            SupervisorTimelineEvent(kind: .taskClosed, authorLabel: "Claude Code"),
            SupervisorTimelineEvent(kind: .roleAccepted, authorLabel: "Claude Code", roleID: "coder"),
        ] {
            let row = NotificationItemView(
                stepID: "s", role: .supervisor,
                type: .supervisorEvent(event: event, roleName: "Coder"), isAutoAnswering: false)
            let height = try renderedHeight(of: row, width: 500)
            XCTAssertGreaterThan(height, 0, "the event drew nothing")
            XCTAssertLessThan(height, ActivityCardTokens.avatarSize,
                              "the \(event.kind) event is \(height) pt tall — taller than one line of text")
        }
    }

    /// The agent's name is the fact the row records (§11), so it is the part a narrow feed keeps:
    /// the row takes a second line — the action under the author — rather than cut it. Measured
    /// at the feed's narrowest content column (138 pt: `WindowLayout.teamBoardActivityMinWidth`
    /// less the feed's padding and the row's gutter) and a middling one (226 pt), on a 12-hour
    /// clock at its widest (`10:08 PM`), and for a label too long for any line. Until 2026-11-09
    /// the row stayed one line and the author was the first thing to shrink: at 226 pt it read
    /// `✓ accepted Software Engi… 10:08 PM`, no agent named. Height, against the same row on one
    /// line: two lines, never one and never three.
    func testSupervisorEventRow_takesASecondLineRatherThanCutTheAuthor() throws {
        let late = try XCTUnwrap(Calendar.current.date(bySettingHour: 22, minute: 8, second: 0, of: Date()))
        func height(_ event: SupervisorTimelineEvent, roleName: String? = nil, column: CGFloat) throws -> CGFloat {
            let row = SupervisorEventRow(event: event, roleName: roleName, glyphColor: Colors.success)
                .environment(\.locale, Locale(identifier: "en_US"))
            let gutter = ActivityCardTokens.avatarSize + ActivityCardTokens.cardPadding
            return try renderedHeight(of: row, width: gutter + column)
        }
        let closed = SupervisorTimelineEvent(createdAt: late, kind: .taskClosed, authorLabel: "Claude Code")
        let accepted = SupervisorTimelineEvent(createdAt: late, kind: .roleAccepted, authorLabel: "Claude Code")
        let longLabel = SupervisorTimelineEvent(
            createdAt: late, kind: .taskClosed,
            authorLabel: String(repeating: "A very long agent label ", count: 4))

        let oneLine = try height(closed, column: 466)
        XCTAssertLessThan(oneLine, ActivityCardTokens.avatarSize, "the wide row is not one line")
        let cases: [(String, SupervisorTimelineEvent, String?, CGFloat)] = [
            ("closed, narrowest", closed, nil, 138),
            ("accepted, narrowest", accepted, "Software Engineer", 138),
            ("accepted, middling", accepted, "Software Engineer", 226),
            ("a label no line holds", longLabel, nil, 466),
        ]
        for (name, event, roleName, column) in cases {
            let twoLines = try height(event, roleName: roleName, column: column)
            XCTAssertGreaterThan(twoLines, oneLine * 1.5,
                                 "\(name): \(twoLines) pt is one line — something in it was cut instead")
            XCTAssertLessThan(twoLines, oneLine * 2.5, "\(name): \(twoLines) pt is more than two lines")
        }
    }

    private func renderedHeight<V: View>(of view: V, width: CGFloat,
                                         file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat {
        let probe = HeightProbe()
        let render = PixelDiff.render(
            view.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { probe.height = $0 }
                .frame(maxHeight: .infinity, alignment: .top),
            width: width, height: 300, file: file, line: line)
        XCTAssertNotNil(render, "the row was drawn", file: file, line: line)
        return try XCTUnwrap(probe.height, file: file, line: line)
    }

    /// The row inks the author and the action apart; the transcript joins them. One source for
    /// both: the summary is the author, a space, and the action — whatever the role name is.
    func testSupervisorTimelineEvent_summaryIsAuthorThenAction() {
        let closed = SupervisorTimelineEvent(kind: .taskClosed, authorLabel: "Claude Code")
        XCTAssertEqual(closed.actionText(), "closed task")
        XCTAssertEqual(closed.actionText(roleName: "Coder"), "closed task", "closing names no role")

        let accepted = SupervisorTimelineEvent(kind: .roleAccepted, authorLabel: "Claude Code")
        XCTAssertEqual(accepted.actionText(roleName: "Coder"), "accepted Coder")
        XCTAssertEqual(accepted.actionText(roleName: ""), "accepted", "an empty role name is no role name")
        XCTAssertEqual(accepted.actionText(), "accepted")

        for (event, roleName) in [(closed, nil), (accepted, "Coder"), (accepted, ""), (accepted, nil)] as [(SupervisorTimelineEvent, String?)] {
            XCTAssertEqual(event.summaryText(roleName: roleName),
                           "Claude Code \(event.actionText(roleName: roleName))")
        }
    }

    /// The sidebar marks an agent's task with an icon, not its name: the row with the mark is
    /// no taller than the row without it, and the title keeps the line.
    func testSidebarTaskRow_marksAnAgentsTaskWithoutGrowingTheRow() throws {
        func height(origin: TaskOrigin?) throws -> CGFloat {
            let probe = HeightProbe()
            let row = SidebarTaskRow(
                task: SidebarTaskItem(id: 1, title: "linecount.py", status: .done, origin: origin),
                updatedAt: Date())
            let render = PixelDiff.render(
                row.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { probe.height = $0 }
                    .frame(maxHeight: .infinity, alignment: .top),
                width: 230, height: 200)
            XCTAssertNotNil(render, "the row was drawn")
            return try XCTUnwrap(probe.height)
        }
        let plain = try height(origin: nil)
        let marked = try height(origin: .externalAgent(agentIdentity))
        XCTAssertEqual(marked, plain, accuracy: 0.5, "the origin mark changed the row's height")
        XCTAssertEqual(SidebarTaskRow.externalAgentSymbol, SettingsView.SettingsTab.externalAgents.icon,
                       "the mark is the External Agents tab's own symbol")
    }
}

private final class HeightProbe {
    var height: CGFloat?
}
