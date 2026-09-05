import XCTest

@testable import NanoTeams

/// Pins the escalation-answer durability contract in `ActivityFeedBuilder`:
/// a Supervisor answer to an escalation-style park (drift caps / the Autovisor
/// idle park — no `ask_supervisor` tool call) must stay visible in the feed
/// FOREVER, across re-parks.
///
/// Mechanism under test (`escalationCard(for:askIndex:isActive:)` + the pairing-aware
/// `.supervisorAnswer` suppression in `emitItems`):
/// - While `step.supervisorAnswer` is set (just answered), the synthesized
///   Q&A card owns the latest unpaired answer — its bubble is suppressed so
///   exactly ONE surface renders.
/// - When a RE-park clears `supervisorAnswer` (single-slot — see
///   `setNeedsSupervisorInput`), the card's gate fails and every unpaired
///   `.supervisorAnswer` message renders as a durable Supervisor bubble.
///   Pre-fix, the suppression was unconditional and the user's message
///   vanished from the UI entirely ("пропало сообщение после отправки
///   сообщения автовизору").
/// - Answers paired with real `ask_supervisor` tool calls (the first
///   `asks.count` — `StepFeedAux.askIndex.count` — `.supervisorAnswer` messages
///   in conversation order, the SAME index rule the answered-notification loop
///   uses) keep rendering inside their ask cards only: zero change to the
///   normal path.
final class ActivityFeedBuilderEscalationAnswerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Fixtures

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    private func makeMessage(
        role: LLMRole = .assistant,
        content: String,
        at timestamp: Date,
        sourceRole: Role? = nil,
        sourceContext: MessageSourceContext? = nil
    ) -> LLMMessage {
        LLMMessage(
            createdAt: timestamp,
            role: role,
            content: content,
            sourceRole: sourceRole,
            sourceContext: sourceContext
        )
    }

    private func makeAnswerMessage(_ text: String, at timestamp: Date) -> LLMMessage {
        // Mirrors StepMessagingService.answerSupervisorQuestion's append.
        makeMessage(
            role: .user,
            content: "\(MessageSourceContext.supervisorAnswerPrefix)\(text)",
            at: timestamp,
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer
        )
    }

    private func makeAskCall(question: String, at timestamp: Date) -> StepToolCall {
        StepToolCall(
            createdAt: timestamp,
            name: ToolNames.askSupervisor,
            argumentsJSON: #"{"question":"\#(question)"}"#
        )
    }

    private func makeStep(
        messages: [LLMMessage] = [],
        toolCalls: [StepToolCall] = [],
        status: StepStatus = .running,
        needsSupervisorInput: Bool = false,
        supervisorQuestion: String? = nil,
        supervisorAnswer: String? = nil
    ) -> StepExecution {
        StepExecution(
            id: Role.autovisor.baseID,
            role: .autovisor,
            title: "Autovisor Step",
            status: status,
            updatedAt: MonotonicClock.shared.now(),
            toolCalls: toolCalls,
            needsSupervisorInput: needsSupervisorInput,
            supervisorQuestion: supervisorQuestion,
            supervisorAnswer: supervisorAnswer,
            llmConversation: messages
        )
    }

    private func build(_ steps: [StepExecution]) -> [ActivityFeedBuilder.TaggedItem] {
        ActivityFeedBuilder.buildTimelineItems(
            steps: steps,
            run: nil,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
    }

    private func answerBubbles(in items: [ActivityFeedBuilder.TaggedItem]) -> [LLMMessage] {
        items.compactMap {
            if case let .llmMessage(message, _, _, _) = $0.item,
               message.sourceContext == .supervisorAnswer {
                return message
            }
            return nil
        }
    }

    private func supervisorNotifications(
        in items: [ActivityFeedBuilder.TaggedItem]
    ) -> [(question: String, answer: String?)] {
        items.compactMap {
            if case let .notification(_, _, .supervisorInput(question, answer, _, _, _, _, _), _, _) = $0.item {
                return (question, answer)
            }
            return nil
        }
    }

    // MARK: - The reported bug: answer vanishes on re-park

    func testEscalationAnswer_survivesRePark_asSupervisorBubble() {
        // Park → answer → manager works → RE-parks. `setNeedsSupervisorInput`
        // cleared `supervisorAnswer` (single-slot), so the Q&A card's gate fails.
        // The answer must survive as a durable Supervisor bubble — pre-fix it
        // vanished from the feed entirely.
        let answer = makeAnswerMessage("Проверь задачу №5 и закрой её.", at: date(100))
        let step = makeStep(
            messages: [answer],
            toolCalls: [],                       // idle park = no ask_supervisor call
            status: .needsSupervisorInput,
            needsSupervisorInput: true,          // re-parked
            supervisorQuestion: AutovisorConstants.idleParkQuestion,
            supervisorAnswer: nil                // cleared by the re-park
        )

        let items = build([step])

        let bubbles = answerBubbles(in: items)
        XCTAssertEqual(bubbles.count, 1,
                       "the answered message must render as a durable Supervisor bubble after re-park")
        XCTAssertEqual(bubbles.first?.id, answer.id)
        XCTAssertEqual(bubbles.first?.displayContent, "Проверь задачу №5 и закрой её.",
                       "bubble text comes via displayContent (prefix stripped)")
        XCTAssertTrue(supervisorNotifications(in: items).isEmpty,
                      "no Q&A card while re-parked (supervisorAnswer is nil — gate fails); "
                          + "the ACTIVE question is owned by the composer, not emitItems")
    }

    func testEscalationAnswer_multipleCycles_allBubblesChronological() {
        // Two park → answer cycles, then a third re-park. BOTH answers must
        // remain visible (per-answer durability), in chronological order.
        let first = makeAnswerMessage("Сначала посмотри логи.", at: date(100))
        let second = makeAnswerMessage("Теперь запусти задачу.", at: date(300))
        let step = makeStep(
            messages: [first, second],
            toolCalls: [],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: AutovisorConstants.idleParkQuestion,
            supervisorAnswer: nil
        )

        let items = build([step])

        let bubbles = answerBubbles(in: items)
        XCTAssertEqual(bubbles.map(\.id), [first.id, second.id],
                       "every past cycle's answer survives, sorted by createdAt")
    }

    // MARK: - Card/bubble handoff (no double render)

    func testEscalationAnswer_justAnswered_cardOwnsAnswer_noDoubleRender() {
        // The "just answered, not yet re-parked" window: `supervisorAnswer` is
        // still set, so the Q&A card renders — and the SAME answer must not
        // ALSO appear as a bubble (escalationCard is the shared gate).
        let answer = makeAnswerMessage("Займись рефакторингом.", at: date(100))
        let step = makeStep(
            messages: [answer],
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: AutovisorConstants.idleParkQuestion,
            supervisorAnswer: "Займись рефакторингом."
        )

        let items = build([step])

        let notifications = supervisorNotifications(in: items)
        XCTAssertEqual(notifications.count, 1, "the Q&A card renders while its gate holds")
        XCTAssertEqual(notifications.first?.answer, "Займись рефакторингом.")
        XCTAssertTrue(answerBubbles(in: items).isEmpty,
                      "the card-owned answer must NOT double-render as a bubble")
    }

    func testEscalationAnswer_earlierCycleBubble_coexistsWithCardForLatest() {
        // Cycle 1 answered (re-parked over), cycle 2 just answered: the card
        // owns ONLY the latest answer; the earlier one stays a bubble.
        let first = makeAnswerMessage("Первый ответ.", at: date(100))
        let second = makeAnswerMessage("Второй ответ.", at: date(300))
        let step = makeStep(
            messages: [first, second],
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: AutovisorConstants.idleParkQuestion,
            supervisorAnswer: "Второй ответ."
        )

        let items = build([step])

        XCTAssertEqual(answerBubbles(in: items).map(\.id), [first.id],
                       "only the card-owned (latest) answer is suppressed")
        XCTAssertEqual(supervisorNotifications(in: items).count, 1)
    }

    // MARK: - Normal ask_supervisor path: zero change

    func testAskPath_pairedAnswers_stillSuppressed() {
        let ask1 = makeAskCall(question: "Q1?", at: date(100))
        let answer1 = makeAnswerMessage("A1", at: date(150))
        let ask2 = makeAskCall(question: "Q2?", at: date(200))
        let answer2 = makeAnswerMessage("A2", at: date(250))
        let step = makeStep(
            messages: [answer1, answer2],
            toolCalls: [ask1, ask2],
            status: .running,
            needsSupervisorInput: false,
            supervisorAnswer: "A2"
        )

        let items = build([step])

        XCTAssertTrue(answerBubbles(in: items).isEmpty,
                      "answers paired with ask_supervisor calls render only inside their Q&A cards")
        XCTAssertEqual(supervisorNotifications(in: items).map(\.answer), ["A1", "A2"])
    }

    func testAskPath_thenEscalationAnswer_excessAnswerRendersAsBubble() {
        // Mixed step: one real ask call, then an escalation park answered later.
        // The first answer pairs with the ask call (card); the excess answer is
        // unpaired — pre-fix it was suppressed with NO rendering surface at all
        // (the escalation card requires askCalls.isEmpty).
        let ask = makeAskCall(question: "Q1?", at: date(100))
        let paired = makeAnswerMessage("A1", at: date(150))
        let escalation = makeAnswerMessage("Ответ на эскалацию", at: date(300))
        let step = makeStep(
            messages: [paired, escalation],
            toolCalls: [ask],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Escalated: please advise.",
            supervisorAnswer: nil               // re-park already cleared it
        )

        let items = build([step])

        XCTAssertEqual(answerBubbles(in: items).map(\.id), [escalation.id],
                       "the unpaired (escalation) answer renders as a bubble; the paired one stays in its card")
        XCTAssertEqual(supervisorNotifications(in: items).count, 1,
                       "exactly the ask-call Q&A card — the escalation card requires askCalls.isEmpty")
    }

    // MARK: - Legacy + degenerate corners

    func testLegacyEscalation_noAnswerMessage_cardStillRenders() {
        // task.json persisted before `answerSupervisorQuestion` started appending
        // the `.supervisorAnswer` message: card falls back to `step.supervisorAnswer`.
        let step = makeStep(
            messages: [],
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Legacy question?",
            supervisorAnswer: "Legacy answer"
        )

        let items = build([step])

        let notifications = supervisorNotifications(in: items)
        XCTAssertEqual(notifications.count, 1, "legacy data keeps the pre-append card behavior")
        XCTAssertEqual(notifications.first?.answer, "Legacy answer")
        XCTAssertTrue(answerBubbles(in: items).isEmpty)
    }

    func testEmptyAnswer_nothingRendered() {
        // An empty answer skips the message append AND normalizes
        // `supervisorAnswer` to nil — no card, no bubble.
        let step = makeStep(
            messages: [],
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Question?",
            supervisorAnswer: nil
        )

        let items = build([step])

        XCTAssertTrue(supervisorNotifications(in: items).isEmpty)
        XCTAssertTrue(answerBubbles(in: items).isEmpty)
    }

    func testDebugMode_rendersEveryAnswerMessage_unchangedContract() {
        // Debug mode bypasses ALL user-message suppression (pre-existing
        // contract) — paired and card-owned answers alike render raw.
        let ask = makeAskCall(question: "Q1?", at: date(100))
        let paired = makeAnswerMessage("A1", at: date(150))
        let step = makeStep(
            messages: [paired],
            toolCalls: [ask],
            status: .running,
            needsSupervisorInput: false,
            supervisorAnswer: "A1"
        )

        let items = ActivityFeedBuilder.buildTimelineItems(
            steps: [step],
            run: nil,
            stepArtifactContentCache: [:],
            debugModeEnabled: true,
            isStreaming: { _ in false }
        )

        XCTAssertEqual(answerBubbles(in: items).count, 1,
                       "debug mode renders the raw conversation, suppression off")
    }
}
