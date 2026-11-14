import XCTest
@testable import NanoTeams

/// DEBTS D-M15: who wrote a Supervisor turn — the person or an automated path standing in for
/// them — is recorded on the turn itself, and every reader reads it there. Until 2026-11-07 only
/// the step knew, and only about its latest answer: the question cards and `task_log` judged every
/// answer of a step by that one flag, and the built-in Autovisor's messages, revisions and
/// corrections read as the person's words.
@MainActor
final class SupervisorTurnAuthorshipTests: XCTestCase {

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_799_971_200 + offset)
    }

    private func turn(
        _ context: MessageSourceContext, at offset: TimeInterval = 0,
        label: String? = nil, automated: Bool?
    ) -> LLMMessage {
        LLMMessage(
            createdAt: date(offset), role: .user, content: "said",
            sourceRole: .supervisor, sourceContext: context,
            authorLabel: label, isFromAutomatedSupervisor: automated)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The record on the turn

    /// A turn that records no author — every turn but the Supervisor's, and every turn persisted
    /// before the field — must keep its bytes: no key at all, not `null`.
    func testATurnWithoutARecordedAuthor_encodesNoKey() throws {
        let legacy = LLMMessage(role: .user, content: "hi", sourceRole: .supervisor, sourceContext: .supervisorAnswer)
        XCTAssertNil(try jsonObject(legacy)["isFromAutomatedSupervisor"])
    }

    func testATurnRoundTripsItsRecordedAuthor_eitherWay() throws {
        for automated in [true, false] {
            let original = turn(.supervisorMessage, automated: automated)
            let data = try JSONCoderFactory.makePersistenceEncoder().encode(original)
            let decoded = try JSONCoderFactory.makeDateDecoder().decode(LLMMessage.self, from: data)
            XCTAssertEqual(decoded.isFromAutomatedSupervisor, automated)
            XCTAssertEqual(decoded, original)
        }
    }

    func testATurnPersistedBeforeTheField_decodesWithNoRecord() throws {
        let json = #"{"id":"00000000-0000-0000-0000-0000000000AA","role":"user","content":"x","sourceContext":"supervisorAnswer"}"#
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(LLMMessage.self, from: Data(json.utf8))
        XCTAssertNil(decoded.isFromAutomatedSupervisor)
    }

    func testAStepMessageRoundTripsItsAuthor_andAnOldOneDecodesWithNone() throws {
        let signed = StepMessage(role: .supervisor, content: "Use SQLite",
                                 authorLabel: "Claude Code", isFromAutomatedSupervisor: true)
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(signed)
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(StepMessage.self, from: data)
        XCTAssertEqual(decoded.authorLabel, "Claude Code")
        XCTAssertEqual(decoded.isFromAutomatedSupervisor, true)

        let plain = StepMessage(role: .softwareEngineer, content: "working")
        let keys = try jsonObject(plain)
        XCTAssertNil(keys["authorLabel"], "a message that records no author keeps its bytes")
        XCTAssertNil(keys["isFromAutomatedSupervisor"])

        let old = #"{"id":"00000000-0000-0000-0000-0000000000AB","createdAt":"2026-01-01T00:00:00Z","role":"supervisor","content":"x"}"#
        let oldDecoded = try JSONCoderFactory.makeDateDecoder().decode(StepMessage.self, from: Data(old.utf8))
        XCTAssertNil(oldDecoded.authorLabel)
        XCTAssertNil(oldDecoded.isFromAutomatedSupervisor)
    }

    /// The step's revision author is a tri-state for the same reason: absent while nobody is
    /// recorded, so an old step keeps its bytes.
    func testTheRevisionsAuthor_isWrittenOnlyWhenRecorded() throws {
        var step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer")
        XCTAssertNil(try jsonObject(step)["revisionCommentIsFromAutomatedSupervisor"])

        step.revisionComment = "Use SQLite"
        step.revisionCommentIsFromAutomatedSupervisor = true
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(step)
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(StepExecution.self, from: data)
        XCTAssertEqual(decoded.revisionCommentIsFromAutomatedSupervisor, true)
    }

    // MARK: - The one reader

    /// A recorded turn is read as recorded, whatever the step's flag says — the flag describes
    /// only the latest answer.
    func testARecordedTurn_isReadAsRecorded_overTheStepsFlag() {
        var step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer")
        step.supervisorAnswerWasAuto = true
        XCTAssertFalse(step.supervisorTurnWasAutomated(turn(.supervisorAnswer, automated: false)),
                       "the person's earlier answer stays the person's after the model answers later")
        step.supervisorAnswerWasAuto = false
        XCTAssertTrue(step.supervisorTurnWasAutomated(turn(.supervisorAnswer, automated: true)),
                      "the model's earlier answer stays the model's after the person answers later")
    }

    /// A turn that recorded nothing reads the way every surface read it before: an answer by the
    /// step's flag, anything else as the person's — so an old run renders unchanged.
    func testAnUnrecordedTurn_readsAsBefore() {
        var step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer")
        step.supervisorAnswerWasAuto = true
        XCTAssertTrue(step.supervisorTurnWasAutomated(turn(.supervisorAnswer, automated: nil)))
        XCTAssertFalse(step.supervisorTurnWasAutomated(turn(.supervisorMessage, automated: nil)),
                       "the step's flag is about answers; an old message is the person's, as before")
        step.supervisorAnswerWasAuto = false
        XCTAssertFalse(step.supervisorTurnWasAutomated(turn(.supervisorAnswer, automated: nil)))
    }

    /// The feed and `conversation_log.md` sign an automated turn no agent signed `auto` — the
    /// word of the card's "auto-answered" badge — and leave the person's turns unsigned.
    func testTheDisplayLabel_signsAnUnsignedAutomatedTurnAuto() {
        for context in [MessageSourceContext.supervisorMessage, .supervisorFeedback] {
            XCTAssertEqual(turn(context, automated: true).sourceContextDisplayLabel,
                           LLMMessage.automatedSupervisorLabel, "\(context)")
            XCTAssertEqual(turn(context, label: "Claude Code", automated: true).sourceContextDisplayLabel,
                           "Claude Code", "an agent's own label wins: \(context)")
            XCTAssertNil(turn(context, automated: false).sourceContextDisplayLabel, "the person: \(context)")
            XCTAssertNil(turn(context, automated: nil).sourceContextDisplayLabel, "unrecorded: \(context)")
        }
        XCTAssertEqual(LLMMessage.automatedSupervisorLabel, "auto")
    }

    func testTheAnswerOrigin_namesTheTurnsAuthor() {
        XCTAssertEqual(SupervisorAnswerOrigin.supervisor.turnIsFromAutomatedSupervisor, false)
        XCTAssertEqual(SupervisorAnswerOrigin.automated.turnIsFromAutomatedSupervisor, true)
        XCTAssertNil(SupervisorAnswerOrigin.questionnaireRequest.turnIsFromAutomatedSupervisor,
                     "the directive is the app's words, not a Supervisor turn")
    }

    func testTheActorsLabel_isTheAgentsAndNoneForTheBuiltInManager() {
        XCTAssertNil(AutovisorActor.builtInManager.agentLabel)
        let agent = AgentIdentity(id: UUID(), label: "Claude Code")
        XCTAssertEqual(AutovisorActor.externalAgent(agent).agentLabel, "Claude Code")
    }

    // MARK: - Writers

    private func parkedTask() -> NTMSTask {
        let ask = StepToolCall(createdAt: date(1), name: ToolNames.askSupervisor,
                               argumentsJSON: #"{"question":"Which database?"}"#)
        let step = StepExecution(
            id: "r", role: .softwareEngineer, title: "Engineer", status: .needsSupervisorInput,
            toolCalls: [ask], needsSupervisorInput: true, supervisorQuestion: "Which database?")
        return NTMSTask(id: 3, title: "T", supervisorTask: "do it", runs: [Run(id: 0, steps: [step])])
    }

    /// Every answer records its answerer on its turn — including the unsigned automated ones (the
    /// built-in manager, a delegating parent), which until 2026-11-07 left only the step's flag.
    func testAnAnswer_recordsItsAnswererOnTheTurn() {
        let cases: [(SupervisorAnswerOrigin, Bool?)] = [
            (.supervisor, false), (.automated, true), (.questionnaireRequest, nil),
        ]
        for (origin, expected) in cases {
            var task = parkedTask()
            XCTAssertTrue(StepMessagingService.answerSupervisorQuestion(
                stepID: "r", answer: "SQLite", origin: origin, in: &task))
            let last = task.runs[0].steps[0].llmConversation.last
            XCTAssertEqual(last?.isFromAutomatedSupervisor, expected, "\(origin)")
            XCTAssertNil(last?.authorLabel, "no agent signed it: \(origin)")
        }
    }

    /// A restart comment is all that is left of the request after the reset, so the reset records
    /// who left it on the message that carries it.
    func testAReset_recordsWhoLeftTheRestartComment() {
        var step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .done)
        step.revisionComment = "old"
        step.revisionCommentAuthor = "Claude Code"
        step.revisionCommentIsFromAutomatedSupervisor = true
        step.reset(supervisorComment: "Supervisor Message: try again",
                   commentAuthorLabel: "Claude Code", commentIsFromAutomatedSupervisor: true)
        XCTAssertEqual(step.messages.first?.authorLabel, "Claude Code")
        XCTAssertEqual(step.messages.first?.isFromAutomatedSupervisor, true)
        XCTAssertNil(step.revisionCommentIsFromAutomatedSupervisor, "a reset clears the pending revision's author too")
        XCTAssertNil(step.revisionCommentAuthor)

        step.reset(supervisorComment: "Supervisor Message: again")
        XCTAssertNil(step.messages.first?.isFromAutomatedSupervisor, "a caller that does not know records nothing")
    }

    // MARK: - Queued Supervisor speech

    private func entry(_ body: String, label: String? = nil, automated: Bool = false,
                       redelivery: Bool = false) -> NTMSOrchestrator.QueuedDeliveryEntry {
        .init(kind: .supervisorSpeech, body: body, isRedelivery: redelivery,
              authorLabel: label, isFromAutomatedSupervisor: automated)
    }

    /// One drain can hold the person's message and the Autovisor's. The feed gets one turn per
    /// author — a merged turn has no one author to record, and until 2026-11-07 it dropped the
    /// label and read as the person's. The wire still gets the run as one section, byte for byte.
    func testAQueuedRunOfTwoAuthors_isOneTurnPerAuthor_andTheWireIsUnchanged() {
        let prefix = MessageSourceContext.supervisorMessagePrefix
        let delivery = NTMSOrchestrator.composeQueuedDelivery([
            entry("Use SQLite."),
            entry("Add a test.", automated: true),
            entry("And a benchmark.", automated: true),
            entry("Sign it.", label: "Claude Code", automated: true),
        ])

        XCTAssertEqual(delivery.wirePrompt, prefix + "Use SQLite.\nAdd a test.\nAnd a benchmark.\nSign it.")
        XCTAssertEqual(delivery.displayTurns.map(\.content), [
            prefix + "Use SQLite.",
            prefix + "Add a test.\nAnd a benchmark.",
            prefix + "Sign it.",
        ])
        XCTAssertEqual(delivery.displayTurns.map(\.isFromAutomatedSupervisor), [false, true, true])
        XCTAssertEqual(delivery.displayTurns.map(\.authorLabel), [nil, nil, "Claude Code"])
    }

    /// The common case — one author — stays one turn, now with its author recorded; a redelivery
    /// the person already saw still shows nothing.
    func testAQueuedRunOfOneAuthor_staysOneTurn() {
        let prefix = MessageSourceContext.supervisorMessagePrefix
        let delivery = NTMSOrchestrator.composeQueuedDelivery([
            entry("Seen before.", redelivery: true),
            entry("One."),
            entry("Two."),
        ])
        XCTAssertEqual(delivery.displayTurns.map(\.content), [prefix + "One.\nTwo."])
        XCTAssertEqual(delivery.displayTurns.first?.isFromAutomatedSupervisor, false)
    }

    /// The app's event notice is nobody's words: it records no Supervisor author.
    func testAnEventNotice_recordsNoSupervisorAuthor() {
        let delivery = NTMSOrchestrator.composeQueuedDelivery([
            .init(kind: .autovisorEventNotice, body: "Task #2 finished.", isRedelivery: false,
                  isFromAutomatedSupervisor: true),
        ])
        XCTAssertEqual(delivery.displayTurns.count, 1)
        XCTAssertNil(delivery.displayTurns.first?.isFromAutomatedSupervisor)
    }

    // MARK: - task_log's reader of step messages

    func testAStepMessagesRecordedAuthor_namesItInTaskLog() {
        let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer")
        let read = { (msg: StepMessage, pending: Bool) in
            AutovisorTaskTranscript.supervisorStepMessageAuthor(msg, in: step, isPendingRevision: pending)
        }
        XCTAssertEqual(read(StepMessage(role: .supervisor, content: "x", authorLabel: "Claude Code",
                                        isFromAutomatedSupervisor: true), false), "Claude Code")
        XCTAssertEqual(read(StepMessage(role: .supervisor, content: "x", isFromAutomatedSupervisor: true), false),
                       "autovisor")
        XCTAssertEqual(read(StepMessage(role: .supervisor, content: "x", isFromAutomatedSupervisor: false), true),
                       "supervisor", "a recorded person is not re-read from the pending revision")
        XCTAssertEqual(read(StepMessage(role: .supervisor, content: "x"), false), "supervisor")
    }

    /// A step message written before messages recorded their author names only the author of the
    /// pending revision it is — the step's fields, as `task_log` read them until then.
    func testAnOldStepMessage_borrowsThePendingRevisionsAuthor() {
        var step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer")
        step.revisionCommentIsFromAutomatedSupervisor = true
        let old = StepMessage(role: .supervisor, content: "x")
        XCTAssertEqual(AutovisorTaskTranscript.supervisorStepMessageAuthor(old, in: step, isPendingRevision: true), "autovisor")
        XCTAssertEqual(AutovisorTaskTranscript.supervisorStepMessageAuthor(old, in: step, isPendingRevision: false), "supervisor")
        step.revisionCommentAuthor = "Claude Code"
        XCTAssertEqual(AutovisorTaskTranscript.supervisorStepMessageAuthor(old, in: step, isPendingRevision: true), "Claude Code")
    }
}
