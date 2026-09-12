import XCTest

@testable import NanoTeams

/// What the feed shows after `[ Ask as form ]`.
///
/// The directive resolves a park the way an answer does — it rides the same field, because the
/// tool result of the role's own `ask_supervisor` is the only channel a parked step has — but
/// it is the app speaking, not the Supervisor. So the Q&A card that would render it as a
/// checkmarked human reply is not drawn at all, and the turn renders as its own
/// `# system: form request` row instead (`SystemNoticePresentation` collapses it; here we
/// assert the builder EMITS it rather than folding it into a card).
final class ActivityFeedBuilderFormRequestTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Fixtures

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    private func askCall(_ question: String, at timestamp: Date) -> StepToolCall {
        StepToolCall(
            createdAt: timestamp,
            name: ToolNames.askSupervisor,
            argumentsJSON: #"{"question":"\#(question)"}"#
        )
    }

    /// Mirrors `StepMessagingService.answerSupervisorQuestion` with `origin: .supervisor`.
    private func answer(_ text: String, at timestamp: Date) -> LLMMessage {
        LLMMessage(
            createdAt: timestamp,
            role: .user,
            content: "\(MessageSourceContext.supervisorAnswerPrefix)\(text)",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer)
    }

    /// …and with `origin: .questionnaireRequest`: no marker, no source role.
    private func formRequest(at timestamp: Date) -> LLMMessage {
        LLMMessage(
            createdAt: timestamp,
            role: .user,
            content: SupervisorQuestionnaireRequest.directive,
            sourceRole: nil,
            sourceContext: .questionnaireRequest)
    }

    private func step(
        toolCalls: [StepToolCall],
        messages: [LLMMessage],
        supervisorQuestion: String? = nil,
        supervisorAnswer: String? = nil
    ) -> StepExecution {
        StepExecution(
            id: "engineer",
            role: .softwareEngineer,
            title: "Engineer",
            status: .running,
            updatedAt: MonotonicClock.shared.now(),
            toolCalls: toolCalls,
            needsSupervisorInput: false,
            supervisorQuestion: supervisorQuestion,
            supervisorAnswer: supervisorAnswer,
            llmConversation: messages)
    }

    private func build(_ steps: [StepExecution]) -> [ActivityFeedBuilder.TaggedItem] {
        ActivityFeedBuilder.buildTimelineItems(
            steps: steps,
            run: nil,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false })
    }

    private func questionCards(
        in items: [ActivityFeedBuilder.TaggedItem]
    ) -> [(question: String, answer: String?)] {
        items.compactMap {
            if case let .notification(_, _, .supervisorInput(question, answer, _, _, _, _, _, _), _, _)
                = $0.item
            {
                return (question, answer)
            }
            return nil
        }
    }

    private func rows(
        withContext context: MessageSourceContext, in items: [ActivityFeedBuilder.TaggedItem]
    ) -> [LLMMessage] {
        items.compactMap {
            if case let .llmMessage(message, _, _, _) = $0.item,
               message.sourceContext == context
            {
                return message
            }
            return nil
        }
    }

    // MARK: - The directive gets a row, not a card

    /// RED both ways: without the skip the feed draws an "asked (answered)" card whose answer
    /// is the directive, i.e. the human telling the role its question went unanswered; and if
    /// the bubble suppression were widened to every resolving context, the row would vanish
    /// too and the click would leave no trace at all.
    func testFormRequestedPark_drawsNoCardAndKeepsItsOwnRow() {
        let question = "Which way should the screen go?"
        let step = step(
            toolCalls: [askCall(question, at: date(10))],
            messages: [formRequest(at: date(20))],
            supervisorQuestion: question,
            supervisorAnswer: SupervisorQuestionnaireRequest.directive)

        let items = build([step])

        XCTAssertTrue(questionCards(in: items).isEmpty, "the ask card yields to the row")
        XCTAssertEqual(rows(withContext: .questionnaireRequest, in: items).count, 1)
    }

    /// The `$ ask_supervisor` row is always drawn, so the pair the Supervisor reads is the
    /// call and the directive under it — in that order, which `MonotonicClock` guarantees.
    func testTheDirectiveRowFollowsTheAskItAnswers() {
        let question = "Which way should the screen go?"
        let step = step(
            toolCalls: [askCall(question, at: date(10))],
            messages: [formRequest(at: date(20))],
            supervisorQuestion: question,
            supervisorAnswer: SupervisorQuestionnaireRequest.directive)

        let items = build([step])

        let askIndex = items.firstIndex {
            if case let .toolCall(call, _, _, _) = $0.item {
                return call.name == ToolNames.askSupervisor
            }
            return false
        }
        let rowIndex = items.firstIndex {
            if case let .llmMessage(message, _, _, _) = $0.item {
                return message.sourceContext == .questionnaireRequest
            }
            return false
        }
        XCTAssertNotNil(askIndex)
        XCTAssertNotNil(rowIndex)
        if let askIndex, let rowIndex { XCTAssertLessThan(askIndex, rowIndex) }
    }

    // MARK: - Pairing stays aligned

    /// Park 1 answered by a person, park 2 sent back as a form, park 3 answered again.
    ///
    /// RED: count only `.supervisorAnswer` into the pairing → the LAST answer slides onto
    /// park 2's card — the feed then shows a question the Supervisor never answered wearing
    /// the answer they gave to a different one.
    func testAnswersKeepTheirOwnCards_whenAFormRequestSitsBetweenThem() {
        let step = step(
            toolCalls: [
                askCall("First?", at: date(10)),
                askCall("Second?", at: date(30)),
                askCall("Third?", at: date(50)),
            ],
            messages: [
                answer("Use the list.", at: date(20)),
                formRequest(at: date(40)),
                answer("Ship it.", at: date(60)),
            ],
            supervisorQuestion: "Third?",
            supervisorAnswer: "Ship it.")

        let cards = questionCards(in: build([step]))

        XCTAssertEqual(cards.count, 2, "the form-requested park draws none")
        XCTAssertEqual(cards.first?.question, "First?")
        XCTAssertEqual(cards.first?.answer, "Use the list.")
        XCTAssertEqual(cards.last?.question, "Third?")
        XCTAssertEqual(cards.last?.answer, "Ship it.")
    }

    /// The Supervisor's own answers keep being absorbed by their cards — the directive is the
    /// only resolving turn that renders as a row of its own.
    func testAnswerBubblesAreStillSuppressedIntoTheirCards() {
        let step = step(
            toolCalls: [askCall("First?", at: date(10))],
            messages: [answer("Use the list.", at: date(20))],
            supervisorQuestion: "First?",
            supervisorAnswer: "Use the list.")

        let items = build([step])

        XCTAssertTrue(rows(withContext: .supervisorAnswer, in: items).isEmpty)
        XCTAssertEqual(questionCards(in: items).count, 1)
    }
}
