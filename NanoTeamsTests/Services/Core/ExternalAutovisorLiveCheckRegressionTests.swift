import XCTest
@testable import NanoTeams

/// Defects found on 2026-11-07 by the first live run of a REAL Claude Code client (2.1.319)
/// against the Hosted MCP server, driving a Startup task on qwen3.6-35b-a3b-splash. Each test
/// names what the agent saw.
@MainActor
final class ExternalAutovisorLiveCheckRegressionTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agent = AgentIdentity(
        id: UUID(uuidString: "cccccccc-1111-2222-3333-444444444443")!,
        label: "Claude Code"
    )

    private func openReadyExternalFolder() async throws -> String {
        await sut.openWorkFolder(tempDir)
        if let nonChat = sut.snapshot?.workFolder.teams.first(where: { !$0.isChatMode && !$0.isHiddenFromPickers }) {
            await sut.mutateWorkFolder { $0.setActiveTeam(nonChat.id) }
        }
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        return try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
    }

    private func call(_ tool: String, _ args: [String: Any]) async throws -> (isError: Bool, envelope: [String: Any]) {
        let result = await sut.executeExternalAutovisorTool(name: tool, args: args, agent: agent)
        let data = try XCTUnwrap(result.outputJSON.data(using: .utf8))
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (result.isError, envelope)
    }

    /// Active, so `mutateTask` can seed its run — a task created with `makeActive: false` is not
    /// loaded into memory and the seeding mutation would not reach it.
    private func createAgentTask() async throws -> Int {
        let id = await sut.createTask(
            title: "wordcount.py",
            supervisorTask: "Write wordcount.py",
            makeActive: true,
            origin: .externalAgent(agent)
        )
        return try XCTUnwrap(id)
    }

    // MARK: - wait_for_events task_ids

    /// The agent's first task in a fresh folder is #0, and `task_ids: [0]` was refused as
    /// "task IDs must be positive integers" — the filter could never name that task.
    func testWaitForEvents_acceptsTheFirstTaskOfAFolder_whoseIDIsZero() async throws {
        _ = try await openReadyExternalFolder()
        let taskID = try await createAgentTask()
        XCTAssertEqual(taskID, 0, "precondition: a fresh folder numbers its first task 0")

        let wait = try await call(ExternalAutovisorToolNames.waitForEvents,
                                  ["task_ids": [taskID], "timeout_seconds": 0])

        XCTAssertFalse(wait.isError, "\(wait.envelope)")
    }

    func testWaitForEvents_rejectsNegativeTaskIDs() async throws {
        _ = try await openReadyExternalFolder()

        let wait = try await call(ExternalAutovisorToolNames.waitForEvents,
                                  ["task_ids": [-1], "timeout_seconds": 0])

        XCTAssertTrue(wait.isError)
        let message = (wait.envelope["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("non-negative"), message)
    }

    // MARK: - task_log

    /// Lays out what the live task had: the role asked, the agent answered, the role wrote the
    /// file in the answer's format, then tried a tool that does not exist. The step's last write
    /// (create_artifact) is much later than the answer.
    private func seedAnsweredStep(taskID: Int) async throws {
        let base = Date(timeIntervalSince1970: 1_799_971_200)
        let seeded = await sut.mutateTask(taskID: taskID) { task in
            let ask = StepToolCall(
                createdAt: base.addingTimeInterval(1),
                name: ToolNames.askSupervisor,
                argumentsJSON: #"{"question":"Space-separated or labelled lines?"}"#,
                resultJSON: #"{"ok":true,"data":{"response":"Use labelled lines."}}"#,
                isError: false
            )
            let write = StepToolCall(
                createdAt: base.addingTimeInterval(5),
                name: ToolNames.writeFile,
                argumentsJSON: #"{"path":"wordcount.py","content":"print(1)"}"#,
                resultJSON: #"{"ok":true,"data":{"path":"wordcount.py"}}"#,
                isError: false
            )
            let unknown = StepToolCall(
                createdAt: base.addingTimeInterval(6),
                name: "shell",
                argumentsJSON: #"{"command":"python3 wordcount.py"}"#,
                resultJSON: #"{"ok":false,"error":{"code":"UNKNOWN_TOOL","message":"Tool 'shell' is not available."}}"#,
                isError: true
            )
            let answer = LLMMessage(
                createdAt: base.addingTimeInterval(2),
                role: .user,
                content: "\(MessageSourceContext.supervisorAnswerPrefix)Use labelled lines.",
                sourceRole: .supervisor,
                sourceContext: .supervisorAnswer,
                authorLabel: "Claude Code"
            )
            let followUp = LLMMessage(
                createdAt: base.addingTimeInterval(7),
                role: .user,
                content: "Also print a usage line on bad arguments.",
                sourceRole: .supervisor,
                sourceContext: .supervisorMessage,
                authorLabel: "Claude Code"
            )
            let step = StepExecution(
                id: "engineer",
                role: .softwareEngineer,
                title: "Engineer",
                status: .done,
                updatedAt: base.addingTimeInterval(30),
                messages: [StepMessage(createdAt: base.addingTimeInterval(4), role: .softwareEngineer,
                                       content: "Writing it with labelled lines.")],
                toolCalls: [ask, write, unknown],
                supervisorAnswer: "Use labelled lines.",
                supervisorAnswerWasAuto: true,
                supervisorAnswerAuthor: "Claude Code",
                supervisorAnswerPendingDelivery: false,
                llmConversation: [answer, followUp]
            )
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["engineer": .done])]
        }
        XCTAssertTrue(seeded, "the seed must reach the task")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.steps.first?.llmConversation.count, 2)
    }

    private func taskLog(folderID: String, taskID: Int) async throws -> [[String: Any]] {
        let log = try await call(ExternalAutovisorToolNames.taskLog,
                                 ["folder_id": folderID, "task_id": taskID, "limit": 50])
        XCTAssertFalse(log.isError, "\(log.envelope)")
        let data = try XCTUnwrap(log.envelope["data"] as? [String: Any])
        return try XCTUnwrap(data["messages"] as? [[String: Any]])
    }

    /// The answer was stamped with the STEP's last write (`step.updatedAt`), so the log put it
    /// after the file the role had already written in the answer's format.
    func testTaskLog_timesAnAnswerByItsOwnTurn_notTheStepsLastWrite() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask()
        try await seedAnsweredStep(taskID: taskID)

        let entries = try await taskLog(folderID: folderID, taskID: taskID)
        let kinds = entries.compactMap { $0["kind"] as? String }
        let answers = entries.filter { $0["kind"] as? String == "answer" }

        XCTAssertEqual(answers.count, 1, "one answer, not one from the slot and one from the turn: \(kinds)")
        let answer = try XCTUnwrap(answers.first)
        XCTAssertEqual(answer["from"] as? String, "Claude Code")
        XCTAssertEqual(answer["text"] as? String, "Use labelled lines.", "the wire marker is not part of what was said")
        let answerIndex = try XCTUnwrap(kinds.firstIndex(of: "answer"))
        let writeIndex = try XCTUnwrap(entries.firstIndex { ($0["text"] as? String)?.hasPrefix(ToolNames.writeFile) == true })
        XCTAssertLessThan(answerIndex, writeIndex, "the answer came before the write it shaped: \(kinds)")
    }

    /// `message_task` and revision feedback reach the role as turns of their own; the log left
    /// them out, so the agent could not see its own instructions in the task's history.
    func testTaskLog_includesTheSupervisorsUnpromptedTurns() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask()
        try await seedAnsweredStep(taskID: taskID)

        let entries = try await taskLog(folderID: folderID, taskID: taskID)
        let followUp = try XCTUnwrap(entries.first { $0["kind"] as? String == "supervisor_message" })

        XCTAssertEqual(followUp["from"] as? String, "Claude Code")
        XCTAssertEqual(followUp["text"] as? String, "Also print a usage line on bad arguments.")
    }

    // MARK: - task_log attribution (review of 2026-11-07)

    /// One step whose history the test chooses: the role's own reply first, then the given
    /// Supervisor-side step messages and conversation turns.
    private func seedStep(
        taskID: Int,
        stepMessages: [StepMessage] = [],
        turns: [LLMMessage] = [],
        answerWasAuto: Bool = false,
        revisionComment: String? = nil,
        revisionCommentAuthor: String? = nil
    ) async throws {
        let base = Date(timeIntervalSince1970: 1_799_971_200)
        let seeded = await sut.mutateTask(taskID: taskID) { task in
            var step = StepExecution(
                id: "engineer",
                role: .softwareEngineer,
                title: "Engineer",
                status: .done,
                updatedAt: base.addingTimeInterval(30),
                messages: [StepMessage(createdAt: base, role: .softwareEngineer, content: "Starting the script.")]
                    + stepMessages,
                supervisorAnswerWasAuto: answerWasAuto,
                supervisorAnswerPendingDelivery: false,
                llmConversation: turns
            )
            step.revisionComment = revisionComment
            step.revisionCommentAuthor = revisionCommentAuthor
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["engineer": .done])]
        }
        XCTAssertTrue(seeded, "the seed must reach the task")
    }

    private func unlabelledAnswerTurn() -> LLMMessage {
        LLMMessage(
            createdAt: Date(timeIntervalSince1970: 1_799_971_202),
            role: .user,
            content: "\(MessageSourceContext.supervisorAnswerPrefix)Use labelled lines.",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer
        )
    }

    /// An answer an LLM wrote in the person's place — the built-in manager's
    /// `answer_task_question`, or the team's auto-answer under `.autonomous` — carries no author
    /// label. RED before 2026-11-07: the log read the label alone and credited it to
    /// "supervisor", the person; fb58ac28 read the step's auto flag and said "autovisor", as the
    /// question card's "Auto-answered" badge does.
    func testTaskLog_creditsAnUnlabelledAutomatedAnswerToTheAutovisor() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask()
        try await seedStep(taskID: taskID, turns: [unlabelledAnswerTurn()], answerWasAuto: true)

        let entries = try await taskLog(folderID: folderID, taskID: taskID)
        let answer = try XCTUnwrap(entries.first { $0["kind"] as? String == "answer" })

        XCTAssertEqual(answer["from"] as? String, "autovisor")
    }

    /// The person's own answer stays theirs.
    func testTaskLog_creditsThePersonsAnswerToTheSupervisor() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask()
        try await seedStep(taskID: taskID, turns: [unlabelledAnswerTurn()], answerWasAuto: false)

        let entries = try await taskLog(folderID: folderID, taskID: taskID)
        let answer = try XCTUnwrap(entries.first { $0["kind"] as? String == "answer" })

        XCTAssertEqual(answer["from"] as? String, "supervisor")
    }

    // MARK: - task_log authorship on the turn (DEBTS D-M15)

    private func answerTurn(_ text: String, at offset: TimeInterval, automated: Bool) -> LLMMessage {
        LLMMessage(
            createdAt: Date(timeIntervalSince1970: 1_799_971_200 + offset),
            role: .user,
            content: "\(MessageSourceContext.supervisorAnswerPrefix)\(text)",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer,
            authorLabel: nil,
            isFromAutomatedSupervisor: automated
        )
    }

    /// RED before 2026-11-07: every answer of a step was credited to whoever answered LAST —
    /// the step's flag — so the person's earlier answer read as the Autovisor's.
    func testTaskLog_creditsEachAnswerToItsOwnAnswerer() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask()
        try await seedStep(
            taskID: taskID,
            turns: [answerTurn("SQLite", at: 2, automated: false), answerTurn("Yes", at: 3, automated: true)],
            answerWasAuto: true)

        let entries = try await taskLog(folderID: folderID, taskID: taskID)
        let answerers = entries.filter { $0["kind"] as? String == "answer" }.compactMap { $0["from"] as? String }

        XCTAssertEqual(answerers, ["supervisor", "autovisor"])
    }

    /// The built-in manager's `message_task` reaches the role as a turn no agent signed. RED
    /// before 2026-11-07: the log credited it to "supervisor", the person.
    func testTaskLog_creditsAnUnsignedAutomatedMessageToTheAutovisor() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask()
        try await seedStep(taskID: taskID, turns: [LLMMessage(
            createdAt: Date(timeIntervalSince1970: 1_799_971_204),
            role: .user,
            content: MessageSourceContext.supervisorMessagePrefix + "Add a benchmark.",
            sourceRole: .supervisor,
            sourceContext: .supervisorMessage,
            authorLabel: nil,
            isFromAutomatedSupervisor: true
        )])

        let entries = try await taskLog(folderID: folderID, taskID: taskID)
        let message = try XCTUnwrap(entries.first { $0["kind"] as? String == "supervisor_message" })

        XCTAssertEqual(message["from"] as? String, "autovisor")
    }

    /// A restart comment records who left it. RED before 2026-11-07: every restart comment was
    /// listed as the person's, the agent's own guidance included.
    func testTaskLog_creditsARestartCommentToWhoeverLeftIt() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask()
        try await seedStep(taskID: taskID, stepMessages: [StepMessage(
            createdAt: Date(timeIntervalSince1970: 1_799_971_210),
            role: .supervisor,
            content: MessageSourceContext.supervisorMessagePrefix + "retry with SQLite",
            authorLabel: "Claude Code",
            isFromAutomatedSupervisor: true
        )])

        let entries = try await taskLog(folderID: folderID, taskID: taskID)
        let comment = try XCTUnwrap(entries.first { ($0["text"] as? String)?.contains("retry with SQLite") == true })

        XCTAssertEqual(comment["from"] as? String, "Claude Code")
    }

    /// A revision comment is stored twice: as a `.supervisor` step message the wire relays, and
    /// as the `.supervisorFeedback` turn the step's re-entry appends. RED before 2026-11-07: the
    /// log listed both, the first as the ROLE's own message.
    func testTaskLog_listsADeliveredRevisionCommentOnce_asItsAuthors() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask()
        let feedback = MessageSourceContext.supervisorFeedbackPrefix + "Use SQLite"
        try await seedStep(
            taskID: taskID,
            stepMessages: [StepMessage(createdAt: Date(timeIntervalSince1970: 1_799_971_210), role: .supervisor, content: feedback)],
            turns: [LLMMessage(
                createdAt: Date(timeIntervalSince1970: 1_799_971_211),
                role: .user,
                content: feedback,
                sourceRole: .supervisor,
                sourceContext: .supervisorFeedback,
                authorLabel: "Claude Code"
            )]
        )

        let entries = try await taskLog(folderID: folderID, taskID: taskID)
        let mentions = entries.filter { ($0["text"] as? String)?.contains("Use SQLite") == true }

        XCTAssertEqual(mentions.count, 1, "\(mentions)")
        XCTAssertEqual(mentions.first?["kind"] as? String, "supervisor_feedback")
        XCTAssertEqual(mentions.first?["from"] as? String, "Claude Code")
        XCTAssertEqual(mentions.first?["text"] as? String, "Use SQLite")
        let reply = try XCTUnwrap(entries.first { $0["kind"] as? String == "message" })
        XCTAssertEqual(reply["from"] as? String, "engineer", "the role's own reply is still the role's")
        XCTAssertEqual(reply["text"] as? String, "Starting the script.")
    }

    /// A comment the step has not re-entered with yet exists only as the step message, so the
    /// log lists it from there — once, as the Supervisor-side utterance it is, under the author
    /// of the pending revision it is.
    func testTaskLog_listsAnUndeliveredRevisionComment_asItsAuthors() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask()
        try await seedStep(
            taskID: taskID,
            stepMessages: [StepMessage(
                createdAt: Date(timeIntervalSince1970: 1_799_971_210),
                role: .supervisor,
                content: MessageSourceContext.supervisorFeedbackPrefix + "Use SQLite"
            )],
            revisionComment: "Use SQLite",
            revisionCommentAuthor: "Claude Code"
        )

        let entries = try await taskLog(folderID: folderID, taskID: taskID)
        let mentions = entries.filter { ($0["text"] as? String)?.contains("Use SQLite") == true }

        XCTAssertEqual(mentions.count, 1, "\(mentions)")
        XCTAssertEqual(mentions.first?["kind"] as? String, "supervisor_feedback")
        XCTAssertEqual(mentions.first?["from"] as? String, "Claude Code")
    }

    /// The comment the person left for the next role when accepting the previous one
    /// (`supervisorCommentForNext`) never gets a display turn; it is the Supervisor's, not the
    /// role's.
    func testTaskLog_listsASupervisorCommentForTheNextRole_asTheSupervisors() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask()
        try await seedStep(
            taskID: taskID,
            stepMessages: [StepMessage(
                createdAt: Date(timeIntervalSince1970: 1_799_971_210),
                role: .supervisor,
                content: "Supervisor Comment: Keep it short"
            )]
        )

        let entries = try await taskLog(folderID: folderID, taskID: taskID)
        let comment = try XCTUnwrap(entries.first { ($0["text"] as? String)?.contains("Keep it short") == true })

        XCTAssertEqual(comment["kind"] as? String, "supervisor_feedback")
        XCTAssertEqual(comment["from"] as? String, "supervisor")
    }

    /// The log listed `shell` with no outcome, so the agent could not tell a refused call from a
    /// successful one.
    /// Only the Supervisor side's own turns get a `task_log` kind. A role's conversation also
    /// carries the app's retry nudges, runtime warnings, tool acknowledgements, compaction seeds
    /// and the like — real turns the log must not list as anyone's words.
    func testTaskLogKind_namesOnlyTheSupervisorSidesOwnTurns() {
        let named: [MessageSourceContext: String] = [
            .supervisorAnswer: "answer",
            .supervisorMessage: "supervisor_message",
            .supervisorFeedback: "supervisor_feedback",
        ]
        for context in MessageSourceContext.allCases {
            XCTAssertEqual(AutovisorTaskTranscript.kind(forSupervisorTurn: context)?.rawValue, named[context], "\(context)")
        }
    }

    func testTaskLog_saysWhyAFailedToolCallFailed() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask()
        try await seedAnsweredStep(taskID: taskID)

        let entries = try await taskLog(folderID: folderID, taskID: taskID)
        let shell = try XCTUnwrap(entries.first { ($0["text"] as? String)?.hasPrefix("shell") == true })
        let text = try XCTUnwrap(shell["text"] as? String)

        XCTAssertTrue(text.contains("UNKNOWN_TOOL"), text)
        XCTAssertTrue(text.contains("not available"), text)
        let write = try XCTUnwrap(entries.first { ($0["text"] as? String)?.hasPrefix(ToolNames.writeFile) == true })
        XCTAssertFalse((write["text"] as? String ?? "").contains("error"), "a successful call carries no outcome suffix")
    }

    // MARK: - folder_status llm.reachable

    /// Plan §8.1 promised `llm {provider, model, reachable}`; only the first two shipped, so an
    /// agent could not tell a dead LLM server from a slow team.
    func testFolderStatus_reportsWhetherTheLLMServerAnswered() async throws {
        _ = try await openReadyExternalFolder()
        sut.llmReachability = { LLMReachabilityStatus(reachable: false, checkedAt: Date()) }

        let status = try await call(ExternalAutovisorToolNames.folderStatus, [:])
        let llm = try XCTUnwrap((status.envelope["data"] as? [String: Any])?["llm"] as? [String: Any])

        XCTAssertEqual(llm["reachable"] as? Bool, false)
    }

    func testFolderStatus_omitsReachabilityBeforeTheFirstProbe() async throws {
        _ = try await openReadyExternalFolder()
        sut.llmReachability = { LLMReachabilityStatus(reachable: nil, checkedAt: nil) }

        let status = try await call(ExternalAutovisorToolNames.folderStatus, [:])
        let llm = try XCTUnwrap((status.envelope["data"] as? [String: Any])?["llm"] as? [String: Any])

        XCTAssertNil(llm["reachable"], "unknown is not false: \(llm)")
        XCTAssertNotNil(llm["model"])
    }
}
