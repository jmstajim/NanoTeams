import XCTest
@testable import NanoTeams

/// `AutovisorTaskTranscript` — the one reading of a run that `task_log` pages and
/// `task_result.recent_messages` tails (wave W3 of the MCP contract, 2026-11-09).
///
/// Until then the two were built separately and disagreed: `recent_messages` listed every step
/// message under the step's role in STEP order (a Supervisor's revision read as the role's own
/// words, and an early role's last note outranked a later one's), and neither read the run's
/// timeline, so an Accept, a Close, a Pause or a Resume reached the agent only as an event.
@MainActor
final class AutovisorTaskTranscriptTests: XCTestCase {

    private typealias Kind = AutovisorTaskTranscript.Kind

    private func at(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_799_971_200 + offset)
    }

    private func step(
        _ id: String,
        messages: [StepMessage] = [],
        toolCalls: [StepToolCall] = [],
        conversation: [LLMMessage] = []
    ) -> StepExecution {
        StepExecution(
            id: id, role: .custom(id: id), title: id, status: .running,
            createdAt: at(0), updatedAt: at(0),
            messages: messages, toolCalls: toolCalls, llmConversation: conversation)
    }

    private func task(
        _ steps: [StepExecution],
        events: [SupervisorTimelineEvent] = [],
        meetings: [TeamMeeting] = [],
        changeRequests: [ChangeRequest] = [],
        consultations: [String: RoleConsultationChat] = [:],
        earlierRuns: [Run] = []
    ) -> NTMSTask {
        let run = Run(
            id: earlierRuns.count, createdAt: at(0), updatedAt: at(0),
            steps: steps, meetings: meetings, changeRequests: changeRequests,
            consultationChats: consultations, supervisorEvents: events)
        return NTMSTask(
            id: 7, title: "Calculator", supervisorTask: "Build it",
            createdAt: at(0), updatedAt: at(0), runs: earlierRuns + [run])
    }

    private func said(_ text: String, at offset: TimeInterval) -> StepMessage {
        StepMessage(createdAt: at(offset), role: .assistant, content: text)
    }

    private func call(
        _ name: String, _ arguments: String, result: String? = nil,
        isError: Bool? = nil, at offset: TimeInterval
    ) -> StepToolCall {
        StepToolCall(createdAt: at(offset), name: name, argumentsJSON: arguments,
                     resultJSON: result, isError: isError)
    }

    private func turn(
        _ context: MessageSourceContext, _ content: String, at offset: TimeInterval,
        label: String? = nil, automated: Bool? = nil
    ) -> LLMMessage {
        LLMMessage(
            createdAt: at(offset), role: .user, content: content,
            sourceRole: .supervisor, sourceContext: context,
            authorLabel: label, isFromAutomatedSupervisor: automated)
    }

    private func entries(_ task: NTMSTask, role: String? = nil) -> [AutovisorTaskTranscript.Entry] {
        AutovisorTaskTranscript.entries(of: task, role: role)
    }

    // MARK: - The vocabulary

    /// The kinds are wire values: `task_log` rows carry them and its description lists them.
    func testTheKinds_areTheWireVocabulary() {
        XCTAssertEqual(Kind.allCases.map(\.rawValue), [
            "message", "question", "answer", "supervisor_message", "supervisor_feedback",
            "tool_call", "meeting", "meeting_decision", "consultation", "change_request",
            "accepted", "closed", "paused", "resumed",
        ])
    }

    /// `recent_messages` is the conversation between a role and whoever supervises it; the work
    /// around it — calls, meetings, votes and the Supervisor's control actions — stays in
    /// `task_log`.
    func testTheConversationalKinds_areTheTurnsBetweenARoleAndItsSupervisor() {
        XCTAssertEqual(
            Set(Kind.allCases.filter(\.isConversational)),
            [.message, .question, .answer, .supervisorMessage, .supervisorFeedback])
    }

    // MARK: - Which run, which order

    func testATaskWithNoRun_hasNoEntries() {
        let empty = NTMSTask(id: 1, title: "t", supervisorTask: "b")
        XCTAssertTrue(entries(empty).isEmpty)
    }

    /// `task_status` describes the latest run, and so does every row here: an earlier run's turns
    /// would read as the current work.
    func testOnlyTheLatestRunIsRead() {
        let earlier = Run(id: 0, createdAt: at(0), steps: [step("swe", messages: [said("old run", at: 1)])])
        let current = task([step("swe", messages: [said("new run", at: 2)])], earlierRuns: [earlier])
        XCTAssertEqual(entries(current).map(\.text), ["new run"])
    }

    /// By when it was said, not by which step said it: step order put an early role's last note
    /// after everything a later role said.
    func testEntries_runInTimeOrderAcrossSteps() {
        let t = task([
            step("pm", messages: [said("pm first", at: 10), said("pm last", at: 30)]),
            step("swe", messages: [said("swe between", at: 20)]),
        ])
        XCTAssertEqual(entries(t).map(\.text), ["pm first", "swe between", "pm last"])
        XCTAssertEqual(entries(t).map(\.from), ["pm", "swe", "pm"])
    }

    func testEntriesOfOneMoment_keepTheOrderTheyWereRecorded() {
        let t = task([step("swe", messages: [said("one", at: 5), said("two", at: 5), said("three", at: 5)])])
        XCTAssertEqual(entries(t).map(\.text), ["one", "two", "three"])
    }

    // MARK: - What a step says

    func testARolesOwnMessage_isAMessageFromThatRole() {
        let entry = entries(task([step("swe", messages: [said("Done.", at: 1)])])).first
        XCTAssertEqual(entry, AutovisorTaskTranscript.Entry(at: at(1), from: "swe", kind: .message, text: "Done."))
    }

    /// A `.supervisor` step message is what the Supervisor side told the role — not the role's
    /// words — and it names whoever wrote it.
    func testASupervisorStepMessage_isFeedbackFromItsRecordedAuthor() {
        let t = task([step("swe", messages: [
            StepMessage(createdAt: at(1), role: .supervisor,
                        content: "\(MessageSourceContext.supervisorFeedbackPrefix)Use SQLite",
                        authorLabel: "Claude Code", isFromAutomatedSupervisor: true),
            StepMessage(createdAt: at(2), role: .supervisor, content: "Mind the tests",
                        isFromAutomatedSupervisor: true),
            StepMessage(createdAt: at(3), role: .supervisor, content: "Ship it",
                        isFromAutomatedSupervisor: false),
        ])])
        let rows = entries(t)
        XCTAssertEqual(rows.map(\.kind), [.supervisorFeedback, .supervisorFeedback, .supervisorFeedback])
        XCTAssertEqual(rows.map(\.from), ["Claude Code", "autovisor", "supervisor"])
        XCTAssertEqual(rows.first?.text, "Use SQLite", "the relay marker is not part of what was said")
    }

    /// Revision feedback gets a display turn of its own when the step re-enters; listed from the
    /// step message too, every delivered revision read twice.
    func testFeedbackDeliveredAsATurn_isListedOnce_asTheTurn() {
        let feedback = "\(MessageSourceContext.supervisorFeedbackPrefix)Fix the divide-by-zero"
        let t = task([step(
            "swe",
            messages: [StepMessage(createdAt: at(1), role: .supervisor, content: feedback)],
            conversation: [turn(.supervisorFeedback, feedback, at: 2, label: "Claude Code", automated: true)])])
        let rows = entries(t).filter { $0.kind == .supervisorFeedback }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.from, "Claude Code")
        XCTAssertEqual(rows.first?.at, at(2), "at the moment the role was told")
    }

    func testAnAsk_isAQuestionCarryingItsText() {
        let t = task([step("swe", toolCalls: [
            call(ToolNames.askSupervisor, #"{"question":"Which operator set?"}"#, result: #"{"ok":true}"#, at: 1),
        ])])
        XCTAssertEqual(entries(t).first?.kind, .question)
        XCTAssertEqual(entries(t).first?.text, "Which operator set?")
    }

    /// A refused ask asked nobody anything: it is a call that failed, and says why.
    func testARefusedAsk_isAFailedToolCall() {
        let refusal = #"{"ok":false,"error":{"code":"QUESTIONNAIRE_REQUIRED","message":"Use the form."}}"#
        let t = task([step("swe", toolCalls: [
            call(ToolNames.askSupervisor, #"{"question":"1) a 2) b"}"#, result: refusal, isError: true, at: 1),
        ])])
        let entry = entries(t).first
        XCTAssertEqual(entry?.kind, .toolCall)
        XCTAssertEqual(entry?.text, "ask_supervisor 1) a 2) b → error QUESTIONNAIRE_REQUIRED: Use the form.")
    }

    // MARK: - One line per tool call

    func testAToolCallLine_namesTheToolAndWhatItsArgumentsSay() {
        let line = AutovisorTaskTranscript.toolCallLine(
            call(ToolNames.readFile, #"{"path":"Sources/Calc.swift"}"#, result: #"{"ok":true,"data":{}}"#, at: 1))
        XCTAssertEqual(line, "read_file Sources/Calc.swift")
    }

    /// The activity feed draws an artifact as a card of its own, so the card summary leaves the
    /// name out — and a line with no name says only that something was submitted.
    func testACreateArtifactLine_namesTheArtifact() {
        let line = AutovisorTaskTranscript.toolCallLine(
            call(ToolNames.createArtifact, #"{"name":"Engineering Notes","content":"…"}"#, result: #"{"ok":true}"#, at: 1))
        XCTAssertEqual(line, "create_artifact Engineering Notes")
    }

    /// A command's own failure arrives in a SUCCESS envelope — the tool ran, the command did not
    /// pass — and until 2026-11-09 the row read exactly like a pass.
    func testAFailingCommand_saysItsExitCodeAndTheLastLineItPrinted() {
        let result = #"{"ok":true,"data":{"exit_code":1,"stdout":"Compiling\n","stderr":"error: x\nFAILED: 2 of 9 tests\n\n","timed_out":false,"sandboxed":true}}"#
        let line = AutovisorTaskTranscript.toolCallLine(
            call(ToolNames.bash, #"{"command":"swift test"}"#, result: result, at: 1))
        XCTAssertEqual(line, "bash swift test → failed: exit 1: FAILED: 2 of 9 tests")
    }

    func testAPassingCommand_saysExit0() {
        let result = #"{"ok":true,"data":{"exit_code":0,"stdout":"ok\n","stderr":"","timed_out":false,"sandboxed":true}}"#
        let line = AutovisorTaskTranscript.toolCallLine(
            call(ToolNames.bash, #"{"command":"swift build"}"#, result: result, at: 1))
        XCTAssertEqual(line, "bash swift build → exit 0")
    }

    func testATestRun_saysWhatFailed() {
        let result = #"{"ok":true,"data":{"success":false,"exit_code":65,"passed":7,"failed":2,"log":"…"}}"#
        let line = AutovisorTaskTranscript.toolCallLine(call(ToolNames.runXcodetests, "{}", result: result, at: 1))
        XCTAssertEqual(line, "run_xcodetests → failed: 2 failed, 7 passed")
    }

    /// A call the runtime refused carries no outcome of its own — only why it was refused, once.
    func testAnErroredCall_saysWhyAndNothingElse() {
        let refusal = #"{"ok":false,"error":{"code":"APPROVAL_UNAVAILABLE","message":"Nobody can approve it."}}"#
        let line = AutovisorTaskTranscript.toolCallLine(
            call(ToolNames.bash, #"{"command":"rm -rf build"}"#, result: refusal, isError: true, at: 1))
        XCTAssertEqual(line, "bash rm -rf build → error APPROVAL_UNAVAILABLE: Nobody can approve it.")
    }

    func testAnErroredCallWithNoReason_saysError() {
        let line = AutovisorTaskTranscript.toolCallLine(
            call(ToolNames.readFile, #"{"path":"a"}"#, result: #"{"ok":false}"#, isError: true, at: 1))
        XCTAssertEqual(line, "read_file a → error")
    }

    // MARK: - What the Supervisor said, and who

    func testSupervisorTurns_carryTheirKindAndAuthor() {
        let t = task([step("swe", conversation: [
            turn(.supervisorAnswer, "\(MessageSourceContext.supervisorAnswerPrefix)Yes", at: 1, automated: true),
            turn(.supervisorMessage, "Also add a clear key", at: 2, label: "Codex", automated: true),
            turn(.supervisorFeedback, "\(MessageSourceContext.supervisorFeedbackPrefix)Rename it", at: 3, automated: false),
        ])])
        let rows = entries(t)
        XCTAssertEqual(rows.map(\.kind), [.answer, .supervisorMessage, .supervisorFeedback])
        XCTAssertEqual(rows.map(\.from), ["autovisor", "Codex", "supervisor"])
        XCTAssertEqual(rows.first?.text, "Yes", "listed as said, without the relay prefix")
    }

    /// The rest of a role's conversation — a teammate's reply, a retry notice, the model's own
    /// turns — is not the Supervisor's, and the step messages already carry the role's words.
    func testOtherTurns_areNotListed() {
        let t = task([step("swe", conversation: [
            LLMMessage(createdAt: at(1), role: .assistant, content: "thinking aloud"),
            LLMMessage(createdAt: at(2), role: .assistant, content: "LLM server error (attempt 2)", sourceContext: .serverError),
            LLMMessage(createdAt: at(3), role: .user, content: "teammate says hi", sourceContext: .consultation),
        ])])
        XCTAssertTrue(entries(t).isEmpty)
    }

    /// Accept, Close, Pause and Resume are on the run's timeline with who did them — a person, the
    /// built-in manager, an external agent; an event recorded before its actor names its label.
    func testTimelineEvents_areListedWithWhoActed() {
        let agent = AgentIdentity(id: UUID(), label: "Claude Code")
        let t = task([], events: [
            SupervisorTimelineEvent(createdAt: at(1), kind: .roleAccepted, by: .person, roleID: "swe"),
            SupervisorTimelineEvent(createdAt: at(2), kind: .runPaused, by: .builtInAutovisor),
            SupervisorTimelineEvent(createdAt: at(3), kind: .runResumed, by: .externalAgent(agent)),
            SupervisorTimelineEvent(createdAt: at(4), kind: .taskClosed, authorLabel: "Codex"),
        ])
        let rows = entries(t)
        XCTAssertEqual(rows.map(\.kind), [.accepted, .paused, .resumed, .closed])
        XCTAssertEqual(rows.map(\.from), ["supervisor", "autovisor", "Claude Code", "Codex"])
        XCTAssertEqual(rows.map(\.text), ["accepted swe", "paused task", "resumed task", "closed task"])
    }

    // MARK: - What a run says outside its steps

    func testMeetingsConsultationsAndChangeRequests_areListedWithTheirStatus() {
        let meeting = TeamMeeting(
            createdAt: at(1), updatedAt: at(1), topic: "API",
            initiatedBy: .softwareEngineer, participants: [.softwareEngineer, .techLead],
            messages: [TeamMessage(createdAt: at(2), role: .techLead, content: "Use REST", messageType: .discussion)],
            decisions: [TeamDecision(createdAt: at(3), summary: "REST it is", proposedBy: .techLead, agreedBy: [.softwareEngineer])],
            status: .completed)
        let chat = RoleConsultationChat(
            id: "reviewer",
            messages: [
                LLMMessage(createdAt: at(4), role: .system, content: "You are consulted."),
                LLMMessage(createdAt: at(5), role: .assistant, content: "Looks fine"),
            ],
            createdAt: at(4), updatedAt: at(5))
        let vote = ChangeRequest(
            createdAt: at(6), requestingRoleID: "reviewer", targetRoleID: "swe",
            changes: "Add an index", reasoning: "Slow")
        let rows = entries(task([], meetings: [meeting], changeRequests: [vote], consultations: ["reviewer": chat]))
        XCTAssertEqual(rows.map(\.kind), [.meeting, .meetingDecision, .consultation, .changeRequest])
        XCTAssertEqual(rows.map(\.from), [Role.techLead.baseID, Role.techLead.baseID, "reviewer", "reviewer"])
        XCTAssertEqual(rows.last?.text, "swe [\(vote.status.rawValue)]: Add an index",
                       "a vote's status tells a team that corrects itself from one deadlocked on it")
        XCTAssertFalse(rows.contains { $0.text == "You are consulted." }, "a consultation's system prompt is not a turn")
    }

    // MARK: - One role

    /// `role` keeps that role's own entries and an Accept of it — and none of another role's, nor
    /// the run-wide ones (a meeting, a Close, a Pause).
    func testARoleFilter_keepsTheRolesEntriesAndItsAccept() {
        let meeting = TeamMeeting(
            createdAt: at(1), updatedAt: at(1), topic: "API",
            initiatedBy: .softwareEngineer, participants: [.softwareEngineer],
            messages: [TeamMessage(createdAt: at(2), role: .softwareEngineer, content: "Hi", messageType: .discussion)],
            decisions: [], status: .completed)
        let t = task(
            [step("swe", messages: [said("mine", at: 3)]), step("tl", messages: [said("theirs", at: 4)])],
            events: [
                SupervisorTimelineEvent(createdAt: at(5), kind: .roleAccepted, by: .person, roleID: "swe"),
                SupervisorTimelineEvent(createdAt: at(6), kind: .roleAccepted, by: .person, roleID: "tl"),
                SupervisorTimelineEvent(createdAt: at(7), kind: .runPaused, by: .person),
                SupervisorTimelineEvent(createdAt: at(8), kind: .taskClosed, by: .person),
            ],
            meetings: [meeting])
        let rows = entries(t, role: "swe")
        XCTAssertEqual(rows.map(\.text), ["mine", "accepted swe"])
    }

    func testABlankRoleFilter_isNoFilter() {
        let t = task([step("swe", messages: [said("a", at: 1)]), step("tl", messages: [said("b", at: 2)])])
        XCTAssertEqual(entries(t, role: ""), entries(t))
    }

    func testARoleWithNoEntries_hasNone() {
        let t = task([step("swe", messages: [said("a", at: 1)])])
        XCTAssertTrue(entries(t, role: "nobody").isEmpty)
    }

    // MARK: - The text itself

    /// What a role wrote is data for the agent to read, never markup to act on: invisible
    /// controls are stripped from every entry, whoever wrote it.
    func testEveryEntry_isCleanedOfInvisibleControls() {
        let t = task(
            [step("swe", messages: [said("safe\u{202E}txt", at: 1)],
                  conversation: [turn(.supervisorMessage, "go\u{2066}on", at: 2, automated: false)])])
        XCTAssertEqual(entries(t).map(\.text), ["safetxt", "goon"])
    }

    // MARK: - Outcome separation and cursor re-delivery (§5.3)

    /// When a tool call is executed asynchronously, its invocation line is stamped at `createdAt`.
    /// When `recordResult` completes later (`resultRecordedAt > createdAt`), the transcript
    /// emits a distinct outcome line at `resultRecordedAt` containing the exit code, result summary,
    /// or error status. Subsequent cursor queries with `after: createdAt` re-deliver this outcome.
    func testTranscriptOutcome_cursorRedelivery_toolCalls() {
        // 1. Initial pending/in-flight bash command
        var toolCall = StepToolCall(
            createdAt: at(10),
            name: ToolNames.bash,
            argumentsJSON: #"{"command":"swift test"}"#
        )
        let taskInFlight = task([step("swe", toolCalls: [toolCall])])
        let inFlightEntries = entries(taskInFlight)
        XCTAssertEqual(inFlightEntries.count, 1)
        XCTAssertEqual(inFlightEntries[0].at, at(10))
        XCTAssertEqual(inFlightEntries[0].kind, .toolCall)
        XCTAssertEqual(inFlightEntries[0].from, "swe")
        XCTAssertEqual(inFlightEntries[0].text, "bash swift test")
        let invocationCursor = inFlightEntries[0].cursor
        XCTAssertEqual(invocationCursor, Int(at(10).timeIntervalSince1970 * 1000))

        // Querying with cursor `after: invocationCursor` yields nothing while in-flight
        let inFlightPage = NTMSOrchestrator.TaskLogPage(anchor: .after(invocationCursor), limit: 50)
        let inFlightSlice = inFlightPage.slice(of: inFlightEntries.map(\.cursor))
        XCTAssertTrue(inFlightEntries[inFlightSlice.range].isEmpty)

        // 2. Result recorded with success (exit 0) at at(15)
        let passResult = #"{"ok":true,"data":{"exit_code":0,"stdout":"Executed 42 tests, with 0 failures\n","stderr":"","timed_out":false,"sandboxed":true}}"#
        toolCall.recordResult(passResult, isError: false, at: at(15))
        XCTAssertEqual(toolCall.resultRecordedAt, at(15))

        let taskCompleted = task([step("swe", toolCalls: [toolCall])])
        let completedEntries = entries(taskCompleted)
        XCTAssertEqual(completedEntries.count, 2)
        XCTAssertEqual(completedEntries[0].at, at(10))
        XCTAssertEqual(completedEntries[0].text, "bash swift test")
        XCTAssertEqual(completedEntries[0].cursor, invocationCursor)

        XCTAssertEqual(completedEntries[1].at, at(15))
        XCTAssertEqual(completedEntries[1].kind, .toolCall)
        XCTAssertEqual(completedEntries[1].from, "swe")
        XCTAssertEqual(completedEntries[1].text, "bash swift test → exit 0")
        let outcomeCursor = completedEntries[1].cursor
        XCTAssertGreaterThan(outcomeCursor, invocationCursor)

        // Querying with cursor `after: invocationCursor` re-delivers the distinct outcome line
        let completedPage = NTMSOrchestrator.TaskLogPage(anchor: .after(invocationCursor), limit: 50)
        let completedSlice = completedPage.slice(of: completedEntries.map(\.cursor))
        let delivered = Array(completedEntries[completedSlice.range])
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].text, "bash swift test → exit 0")
        XCTAssertEqual(delivered[0].at, at(15))

        // Querying after the outcome returns no further entries
        let finalPage = NTMSOrchestrator.TaskLogPage(anchor: .after(outcomeCursor), limit: 50)
        let finalSlice = finalPage.slice(of: completedEntries.map(\.cursor))
        XCTAssertTrue(completedEntries[finalSlice.range].isEmpty)

        // 3. Command failure with non-zero exit code recorded later
        var failingCall = StepToolCall(
            createdAt: at(20),
            name: ToolNames.bash,
            argumentsJSON: #"{"command":"swift test"}"#
        )
        let failResult = #"{"ok":true,"data":{"exit_code":1,"stdout":"","stderr":"error: 2 failed\n","timed_out":false,"sandboxed":true}}"#
        failingCall.recordResult(failResult, isError: false, at: at(25))
        let failEntries = entries(task([step("swe", toolCalls: [failingCall])]))
        XCTAssertEqual(failEntries.count, 2)
        XCTAssertEqual(failEntries[0].text, "bash swift test")
        XCTAssertEqual(failEntries[1].text, "bash swift test → failed: exit 1: error: 2 failed")
        let failingCursor = failEntries[0].cursor
        let failDelivered = failEntries.filter { $0.cursor > failingCursor }
        XCTAssertEqual(failDelivered.count, 1)
        XCTAssertEqual(failDelivered[0].text, "bash swift test → failed: exit 1: error: 2 failed")

        // 4. Errored non-bash call (e.g. read_file refused with runtime error)
        var errorCall = StepToolCall(
            createdAt: at(30),
            name: ToolNames.readFile,
            argumentsJSON: #"{"path":"restricted.key"}"#
        )
        let refusalResult = #"{"ok":false,"error":{"code":"PERMISSION_DENIED","message":"Sandbox denied read."}}"#
        errorCall.recordResult(refusalResult, isError: true, at: at(35))
        let errorEntries = entries(task([step("swe", toolCalls: [errorCall])]))
        XCTAssertEqual(errorEntries.count, 2)
        XCTAssertEqual(errorEntries[0].text, "read_file restricted.key")
        XCTAssertEqual(errorEntries[1].text, "read_file restricted.key → error PERMISSION_DENIED: Sandbox denied read.")
        let errorInvocationCursor = errorEntries[0].cursor
        let errorDelivered = errorEntries.filter { $0.cursor > errorInvocationCursor }
        XCTAssertEqual(errorDelivered.count, 1)
        XCTAssertEqual(errorDelivered[0].text, "read_file restricted.key → error PERMISSION_DENIED: Sandbox denied read.")

        // 5. Successful tool call without outcome summary (e.g. read_file with ok: true)
        // Does not produce separate outcome line because read_file has no wire outcome summary
        var readSuccessCall = StepToolCall(
            createdAt: at(40),
            name: ToolNames.readFile,
            argumentsJSON: #"{"path":"main.swift"}"#
        )
        readSuccessCall.recordResult(#"{"ok":true,"data":{"content":"print(1)"}}"#, isError: false, at: at(45))
        let readSuccessEntries = entries(task([step("swe", toolCalls: [readSuccessCall])]))
        XCTAssertEqual(readSuccessEntries.count, 1)
        XCTAssertEqual(readSuccessEntries[0].at, at(40))
        XCTAssertEqual(readSuccessEntries[0].text, "read_file main.swift")
    }

    /// When a change request is created, it is emitted with `[pending]` status at `createdAt`.
    /// When it is resolved (`resolvedAt > createdAt`), querying with a cursor `after: createdAt`
    /// yields the resolved change request outcome line with the final status (`[approved]`, `[rejected]`, etc.).
    func testTranscriptOutcome_cursorRedelivery_changeRequests() {
        // 1. Pending change request initially
        var cr = ChangeRequest(
            createdAt: at(10),
            requestingRoleID: "reviewer",
            targetRoleID: "swe",
            changes: "Extract helper function",
            reasoning: "Improve modularity",
            status: .pending
        )
        let taskPending = task([], changeRequests: [cr])
        let pendingEntries = entries(taskPending)
        XCTAssertEqual(pendingEntries.count, 1)
        XCTAssertEqual(pendingEntries[0].at, at(10))
        XCTAssertEqual(pendingEntries[0].kind, .changeRequest)
        XCTAssertEqual(pendingEntries[0].from, "reviewer")
        XCTAssertEqual(pendingEntries[0].text, "swe [pending]: Extract helper function")
        let pendingCursor = pendingEntries[0].cursor

        // Querying with cursor `after: pendingCursor` returns no entries while still pending
        let pendingPage = NTMSOrchestrator.TaskLogPage(anchor: .after(pendingCursor), limit: 50)
        let pendingSlice = pendingPage.slice(of: pendingEntries.map(\.cursor))
        XCTAssertTrue(pendingEntries[pendingSlice.range].isEmpty)

        // 2. Change request resolved as approved at at(20)
        cr.status = .approved
        cr.resolvedAt = at(20)
        let taskApproved = task([], changeRequests: [cr])
        let approvedEntries = entries(taskApproved)
        XCTAssertEqual(approvedEntries.count, 2)
        XCTAssertEqual(approvedEntries[0].at, at(10))
        XCTAssertEqual(approvedEntries[0].text, "swe [pending]: Extract helper function")
        XCTAssertEqual(approvedEntries[0].cursor, pendingCursor)

        XCTAssertEqual(approvedEntries[1].at, at(20))
        XCTAssertEqual(approvedEntries[1].kind, .changeRequest)
        XCTAssertEqual(approvedEntries[1].from, "reviewer")
        XCTAssertEqual(approvedEntries[1].text, "swe [approved]: Extract helper function")
        let approvedCursor = approvedEntries[1].cursor
        XCTAssertGreaterThan(approvedCursor, pendingCursor)

        // Querying with cursor `after: pendingCursor` delivers only the resolved outcome
        let approvedPage = NTMSOrchestrator.TaskLogPage(anchor: .after(pendingCursor), limit: 50)
        let approvedSlice = approvedPage.slice(of: approvedEntries.map(\.cursor))
        let redeliveredApproved = Array(approvedEntries[approvedSlice.range])
        XCTAssertEqual(redeliveredApproved.count, 1)
        XCTAssertEqual(redeliveredApproved[0].text, "swe [approved]: Extract helper function")
        XCTAssertEqual(redeliveredApproved[0].at, at(20))
        XCTAssertEqual(redeliveredApproved[0].kind, .changeRequest)

        // 3. Change request resolved as rejected at at(30)
        let crRejected = ChangeRequest(
            createdAt: at(25),
            requestingRoleID: "techLead",
            targetRoleID: "swe",
            changes: "Remove cache",
            reasoning: "Not needed",
            status: .rejected,
            resolvedAt: at(30)
        )
        let taskRejected = task([], changeRequests: [crRejected])
        let rejectedEntries = entries(taskRejected)
        XCTAssertEqual(rejectedEntries.count, 2)
        XCTAssertEqual(rejectedEntries[0].text, "swe [pending]: Remove cache")
        XCTAssertEqual(rejectedEntries[1].text, "swe [rejected]: Remove cache")
        let rejPendingCursor = rejectedEntries[0].cursor
        let redeliveredRejection = rejectedEntries.filter { $0.cursor > rejPendingCursor }
        XCTAssertEqual(redeliveredRejection.count, 1)
        XCTAssertEqual(redeliveredRejection[0].text, "swe [rejected]: Remove cache")
        XCTAssertEqual(redeliveredRejection[0].at, at(30))
    }

    /// When `resultRecordedAt` or `resolvedAt` is nil or equal to `createdAt` (historical tasks
    /// or instantaneous recording), a single entry is emitted at `createdAt`.
    func testTranscriptOutcome_sameTimestampOrNilRecordedAt_emitsSingleLine() {
        // Tool call with resultRecordedAt == createdAt
        var toolCallSame = StepToolCall(
            createdAt: at(10),
            name: ToolNames.bash,
            argumentsJSON: #"{"command":"ls"}"#
        )
        toolCallSame.recordResult(
            #"{"ok":true,"data":{"exit_code":0,"stdout":"file.txt\n","stderr":"","timed_out":false,"sandboxed":true}}"#,
            isError: false,
            at: at(10)
        )
        let sameEntries = entries(task([step("swe", toolCalls: [toolCallSame])]))
        XCTAssertEqual(sameEntries.count, 1)
        XCTAssertEqual(sameEntries[0].at, at(10))
        XCTAssertEqual(sameEntries[0].text, "bash ls → exit 0")

        // Change request with resolvedAt == createdAt
        let crSame = ChangeRequest(
            createdAt: at(20),
            requestingRoleID: "reviewer",
            targetRoleID: "swe",
            changes: "Fix typo",
            reasoning: "Spelling error",
            status: .approved,
            resolvedAt: at(20)
        )
        let crSameEntries = entries(task([], changeRequests: [crSame]))
        XCTAssertEqual(crSameEntries.count, 1)
        XCTAssertEqual(crSameEntries[0].at, at(20))
        XCTAssertEqual(crSameEntries[0].text, "swe [approved]: Fix typo")

        // Change request with resolvedAt == nil
        let crNil = ChangeRequest(
            createdAt: at(30),
            requestingRoleID: "reviewer",
            targetRoleID: "swe",
            changes: "Update docs",
            reasoning: "Clarity",
            status: .approved,
            resolvedAt: nil
        )
        let crNilEntries = entries(task([], changeRequests: [crNil]))
        XCTAssertEqual(crNilEntries.count, 1)
        XCTAssertEqual(crNilEntries[0].at, at(30))
        XCTAssertEqual(crNilEntries[0].text, "swe [approved]: Update docs")
    }

    // MARK: - Wave Final Coverage Hardening (M6.1)

    /// Hits line 180 in AutovisorTaskTranscript.swift: toolCallInvocationLine and toolCallOutcomeLine with createArtifact
    func testToolCallInvocationLine_createArtifact_formatsArtifactName() {
        let call = StepToolCall(
            createdAt: at(10),
            name: ToolNames.createArtifact,
            argumentsJSON: "{\"name\":\"FinalArchitectureReport.md\"}"
        )
        let invocation = AutovisorTaskTranscript.toolCallInvocationLine(call)
        XCTAssertEqual(invocation, "create_artifact FinalArchitectureReport.md")

        var errCall = StepToolCall(
            createdAt: at(10),
            name: ToolNames.createArtifact,
            argumentsJSON: "{\"name\":\"FinalArchitectureReport.md\"}"
        )
        let refusalResult = #"{"ok":false,"error":{"code":"DISK_FULL","message":"No space left"}}"#
        errCall.recordResult(refusalResult, isError: true, at: at(15))
        let outcome = AutovisorTaskTranscript.toolCallOutcomeLine(errCall)
        XCTAssertEqual(outcome, "create_artifact FinalArchitectureReport.md → error DISK_FULL: No space left")
    }

    func testAppendStep_supervisorAskWithoutParsedQuestion_fallsBackToArgumentsJSON() {
        let askCall = StepToolCall(
            createdAt: at(10),
            name: "ask_supervisor",
            argumentsJSON: "{\"raw\":\"unstructured\"}"
        )
        let st = step("swe", toolCalls: [askCall])
        let list = entries(task([st]))
        XCTAssertTrue(list.contains(where: { $0.text.contains("{\"raw\":\"unstructured\"}") }))
    }

    func testAutovisorCommandExecutor_unavailableWhenServiceNil() async {
        let executor = AutovisorCommandExecutor(executionService: nil)
        let res = await executor.execute(.listTasks)
        XCTAssertTrue(res.contains("COMMAND_FAILED"))
        XCTAssertTrue(res.contains(LLMExecutionService.autovisorUnavailableMessage))
    }
}
