import XCTest
@testable import NanoTeams

/// Where a questionnaire reaches each surface — and where it deliberately does not.
///
/// Four surfaces show a supervisor question and only two of them can ANSWER a form: the docked
/// composer and the Quick Capture panel, which own the draft a half-filled form lives in. The
/// Watchtower points at the task instead, and the feed re-renders what was decided. Each of
/// those is one wiring decision, and each is checked here rather than trusted to a view body.
@MainActor
final class SupervisorInquirySurfacesTests: XCTestCase {

    private typealias TN = ToolNames

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Fixtures

    private var form: SupervisorInquiry {
        SupervisorInquiry(
            headline: "A few decisions first.",
            questions: [
                SupervisorInquiryQuestion(
                    id: "scheme", prompt: "Which scheme?", kind: .singleChoice,
                    options: [
                        SupervisorInquiryOption(id: "debug", label: "Debug"),
                        SupervisorInquiryOption(id: "release", label: "Release"),
                    ]),
                SupervisorInquiryQuestion(id: "notes", prompt: "Anything else?", kind: .freeText),
            ])
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: offset)
    }

    private func askCall(_ name: String, at offset: TimeInterval, question: String) -> StepToolCall {
        StepToolCall(
            createdAt: date(offset), name: name,
            argumentsJSON: name == TN.askSupervisorForm
                ? "{\"headline\":\"\(question)\"}"
                : "{\"question\":\"\(question)\"}")
    }

    private func answerMessage(_ text: String, at offset: TimeInterval) -> LLMMessage {
        LLMMessage(
            createdAt: date(offset),
            role: .user,
            content: "\(MessageSourceContext.supervisorAnswerPrefix)\(text)",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer)
    }

    private func makeStep(
        toolCalls: [StepToolCall],
        conversation: [LLMMessage] = [],
        needsSupervisorInput: Bool = false,
        question: String? = nil,
        answer: String? = nil,
        inquiry: SupervisorInquiry? = nil,
        inquiryAnswer: SupervisorInquiryAnswer? = nil
    ) -> StepExecution {
        var step = StepExecution(
            id: Role.softwareEngineer.baseID,
            role: .softwareEngineer,
            title: "Engineer",
            status: .done,
            updatedAt: date(100),
            toolCalls: toolCalls,
            needsSupervisorInput: needsSupervisorInput,
            supervisorQuestion: question,
            supervisorAnswer: answer,
            llmConversation: conversation)
        step.supervisorInquiry = inquiry
        step.supervisorInquiryAnswer = inquiryAnswer
        return step
    }

    private func makeTask(steps: [StepExecution], isChatMode: Bool = false) -> (NTMSTask, Run) {
        var run = Run(id: 0)
        run.steps = steps
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "do")
        task.runs = [run]
        task.setStoredChatMode(isChatMode)
        return (task, run)
    }

    // MARK: - Watchtower points at the task

    /// The banner cannot answer a form: it renders none of it, and a prose field beside a
    /// question whose options exist to replace prose is worse than no field.
    ///
    /// RED: hardcode `isInquiry: false` at the producer → the banner offers a text composer for
    /// a questionnaire, and whatever is typed there is read back by the label matcher.
    func testAFormQuestionMarksItsBannerAsAPointer() {
        let step = makeStep(
            toolCalls: [askCall(TN.askSupervisorForm, at: 10, question: "A few decisions first.")],
            needsSupervisorInput: true,
            question: "A few decisions first.",
            inquiry: form)
        let (task, run) = makeTask(steps: [step])

        let notifications = run.allWatchtowerNotifications(task: task, teamRoles: [])
        guard case .supervisorInput(_, _, _, _, let isInquiry) = notifications.first else {
            return XCTFail("expected a supervisor-input notification")
        }
        XCTAssertTrue(isInquiry)
    }

    /// …and a plain question keeps its inline composer, unchanged.
    func testAPlainQuestionKeepsItsInlineAnswerField() {
        let step = makeStep(
            toolCalls: [askCall(TN.askSupervisor, at: 10, question: "Which one?")],
            needsSupervisorInput: true,
            question: "Which one?")
        let (task, run) = makeTask(steps: [step])

        let notifications = run.allWatchtowerNotifications(task: task, teamRoles: [])
        guard case .supervisorInput(_, _, _, _, let isInquiry) = notifications.first else {
            return XCTFail("expected a supervisor-input notification")
        }
        XCTAssertFalse(isInquiry)
    }

    /// The banner's dismissal identity is unaffected by the new value — a dismissed question
    /// must stay dismissed across the change, and a form must not read as a second question.
    func testTheFormFlagDoesNotChangeTheDismissalIdentity() {
        let callID = UUID()
        let plain = WatchtowerNotificationType.supervisorInput(
            stepID: "s", question: "q", role: .softwareEngineer, toolCallID: callID,
            isInquiry: false)
        let asForm = WatchtowerNotificationType.supervisorInput(
            stepID: "s", question: "q", role: .softwareEngineer, toolCallID: callID,
            isInquiry: true)
        XCTAssertEqual(plain.dismissID, asForm.dismissID)
    }

    // MARK: - The feed re-renders the decisions

    /// The questionnaire belongs to the call that asked it.
    ///
    /// RED: attach `step.supervisorInquiry` to every ask card the way `wasAutoAnswered` is
    /// attached → the earlier plain question, answered in prose, is redrawn as a form with
    /// options nobody was offered.
    func testTheQuestionnaireLandsOnTheFormCardAndNotOnAnEarlierPlainOne() {
        let step = makeStep(
            toolCalls: [
                askCall(TN.askSupervisor, at: 10, question: "Ready to start?"),
                askCall(TN.askSupervisorForm, at: 30, question: "A few decisions first."),
            ],
            conversation: [answerMessage("yes", at: 20), answerMessage("Q1. …", at: 40)],
            answer: "Q1. Which scheme?\nA1. Debug",
            inquiry: form,
            inquiryAnswer: SupervisorInquiryAnswer(byQuestionID: [
                "scheme": .init(selectedOptionIDs: ["debug"])
            ]))

        let inquiries = supervisorInputInquiries(in: step)
        XCTAssertEqual(inquiries.count, 2, "one card per ask call")
        XCTAssertNil(inquiries[0], "the plain question was answered in prose and shows as prose")
        XCTAssertEqual(inquiries[1]?.inquiry, form)
        XCTAssertEqual(inquiries[1]?.answer?.byQuestionID["scheme"]?.selectedOptionIDs, ["debug"])
    }

    /// One park can be raised by SEVERAL calls in one batch: a plain `ask_supervisor` emitted
    /// beside a form is folded into the SAME questionnaire as a free-text question, so the
    /// TRAILING call is named `ask_supervisor` while the park it belongs to is a form.
    ///
    /// RED: discriminate on `call.name == ToolNames.askSupervisorForm` → the whole
    /// questionnaire disappears from the feed and from the audit log, and the card shows a
    /// headline with nothing under it.
    func testAMixedBatchStillShowsItsQuestionnaireOnTheTrailingCall() {
        let merged = SupervisorInquiry(
            headline: "A few decisions first.",
            questions: form.questions + [SupervisorInquiryQuestion(
                id: "ask_3", prompt: "Anything else?", kind: .freeText)])
        let step = makeStep(
            toolCalls: [
                askCall(TN.askSupervisorForm, at: 10, question: "A few decisions first."),
                askCall(TN.askSupervisor, at: 12, question: "Anything else?"),
            ],
            conversation: [answerMessage("Q1. …", at: 20)],
            answer: "Q1. Which scheme?\nA1. Debug",
            inquiry: merged,
            inquiryAnswer: SupervisorInquiryAnswer(byQuestionID: [
                "scheme": .init(selectedOptionIDs: ["debug"])
            ]))

        // Asserted over the whole set rather than positionally: the two cards are sorted by
        // ANSWER time, and the trailing call has none of its own, so it does not land last.
        let carried = supervisorInputInquiries(in: step).compactMap { $0 }
        XCTAssertEqual(carried.map(\.inquiry), [merged],
                       "the questionnaire belongs to the park, not to the last call's name")
    }

    /// A step whose last ask is a PLAIN question carries no questionnaire, because that park
    /// nils `supervisorInquiry` — which is what makes non-nil mean "this park".
    func testAPlainTrailingAskShowsNoQuestionnaire() {
        let step = makeStep(
            toolCalls: [
                askCall(TN.askSupervisorForm, at: 10, question: "A few decisions first."),
                askCall(TN.askSupervisor, at: 30, question: "And now?"),
            ],
            conversation: [answerMessage("done", at: 20), answerMessage("go on", at: 40)],
            answer: "go on")

        XCTAssertTrue(supervisorInputInquiries(in: step).allSatisfy { $0 == nil })
    }

    /// An unanswered form on a closed run still shows what was asked. Its card is emitted (the
    /// composer is not rendering it), and a headline with nothing under it reads as a question
    /// with no content.
    func testAnUnansweredFormStillRendersItsQuestions() {
        let step = makeStep(
            toolCalls: [askCall(TN.askSupervisorForm, at: 10, question: "A few decisions first.")],
            needsSupervisorInput: true,
            question: "A few decisions first.",
            inquiry: form)

        let inquiries = supervisorInputInquiries(in: step, questionsRenderedElsewhere: false)
        XCTAssertEqual(inquiries.count, 1)
        XCTAssertEqual(inquiries[0]?.inquiry, form)
        XCTAssertNil(inquiries[0]?.answer, "nothing was decided, and the card says so per row")
    }

    private func supervisorInputInquiries(
        in step: StepExecution, questionsRenderedElsewhere: Bool = true
    ) -> [AnsweredInquiry?] {
        ActivityFeedBuilder.buildTimelineItems(
            steps: [step],
            run: nil,
            supervisorBrief: nil,
            supervisorBriefDate: nil,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            activeQuestionsRenderedElsewhere: questionsRenderedElsewhere,
            isStreaming: { _ in false }
        ).compactMap { tagged -> AnsweredInquiry?? in
            guard case .notification(_, _, let type, _, _) = tagged.item,
                  case .supervisorInput(_, _, _, _, _, _, _, let inquiry) = type
            else { return nil }
            return .some(inquiry)
        }
    }

    // MARK: - The audit log keeps the decisions apart

    /// `conversation_log.md` is the human-readable half of the audit pair, and its answer line
    /// runs through `singleLine`, which flattens newlines AND truncates at 200 characters. A
    /// four-question form's decisions arrive there as three pairs and an ellipsis.
    ///
    /// RED: render the composed prose through `singleLine` for a questionnaire too → the last
    /// answers are cut off in the one file a person reads to check what was decided.
    func testTheAuditLogRendersOneLinePerQuestionRatherThanOneTruncatedParagraph() {
        let long = SupervisorInquiry(
            headline: "Decisions",
            questions: (1...4).map { index in
                SupervisorInquiryQuestion(
                    id: "q\(index)",
                    prompt: String(repeating: "question \(index) ", count: 8),
                    kind: .singleChoice,
                    options: [SupervisorInquiryOption(id: "a\(index)", label: "answer \(index)")])
            })
        let answered = SupervisorInquiryAnswer(byQuestionID: Dictionary(
            uniqueKeysWithValues: (1...4).map { ("q\($0)", SupervisorInquiryAnswer.QuestionAnswer(
                selectedOptionIDs: ["a\($0)"])) }))

        let markdown = ConversationTranscriptRenderer.render(
            items: [ActivityFeedBuilder.TaggedItem(
                item: .notification(
                    stepID: "eng", role: .softwareEngineer,
                    type: .supervisorInput(
                        question: long.headline, answer: "…", answerAttachmentPaths: [],
                        answerClippedTexts: [], toolCallID: UUID(), thinking: nil,
                        wasAutoAnswered: false,
                        inquiry: AnsweredInquiry(inquiry: long, answer: answered)),
                    createdAt: date(10), originTaskID: 0),
                showSectionHeader: true, boundary: nil)],
            pending: [], teamRoles: [], isChatMode: false,
            generatedAt: date(20))

        XCTAssertTrue(markdown.contains("A4. answer 4"),
                      "the fourth decision is in the log, not past a truncation ellipsis")
        XCTAssertTrue(markdown.contains("A1. answer 1"))
    }

    /// A plain question's line is untouched by any of this.
    func testTheAuditLogStillRendersAPlainAnswerOnOneLine() {
        let markdown = ConversationTranscriptRenderer.render(
            items: [ActivityFeedBuilder.TaggedItem(
                item: .notification(
                    stepID: "eng", role: .softwareEngineer,
                    type: .supervisorInput(
                        question: "Which one?", answer: "the second", answerAttachmentPaths: [],
                        answerClippedTexts: [], toolCallID: UUID(), thinking: nil,
                        wasAutoAnswered: false),
                    createdAt: date(10), originTaskID: 0),
                showSectionHeader: true, boundary: nil)],
            pending: [], teamRoles: [], isChatMode: false,
            generatedAt: date(20))

        XCTAssertTrue(markdown.contains("answer: the second"), markdown)
    }

    /// The composer shows the whole questionnaire while it waits. Printing the headline alone
    /// leaves the audit log unable to say what the role actually asked for.
    ///
    /// RED: drop the `q.inquiry` block from the pending loop → the log names a question and
    /// omits the four decisions it is waiting on.
    func testTheAuditLogsPendingSectionListsTheQuestionsBeingWaitedOn() {
        let pending = SupervisorQuestionInbox.PendingQuestion(
            key: TaskStepKey(taskID: 1, stepID: "eng"),
            role: .softwareEngineer,
            headline: form.headline,
            inquiry: form,
            paired: nil,
            askCallID: nil,
            askedAt: date(10))

        let markdown = ConversationTranscriptRenderer.render(
            items: [], pending: [pending], teamRoles: [], isChatMode: false,
            generatedAt: date(20))

        XCTAssertTrue(markdown.contains("Q1. Which scheme?"), markdown)
        XCTAssertTrue(markdown.contains("(not answered)"),
                      "and it says so, rather than leaving the row blank")
    }

    // MARK: - The panel rebuilds when the questionnaire changes

    private func payload(_ inquiry: SupervisorInquiry?) -> QuickCaptureMode {
        .supervisorAnswer(payload: SupervisorAnswerPayload(
            stepID: "s", taskID: 1, role: .softwareEngineer, roleDefinition: nil,
            question: "A few decisions first.", inquiry: inquiry,
            messageContent: nil, thinking: nil, isChatMode: false))
    }

    /// The panel rebuilds its hosting view only when `renderIdentity` moves, so a questionnaire
    /// the identity cannot see is a questionnaire the panel never redraws.
    ///
    /// RED: leave the inquiry out of `renderIdentity` → a role that replaces its form under the
    /// same headline leaves the previous form's options on screen, and the answer is filed
    /// against ids nothing in the new one resolves.
    func testTwoQuestionnairesUnderOneHeadlineAreDifferentPanels() {
        let other = SupervisorInquiry(
            headline: form.headline,
            questions: [
                SupervisorInquiryQuestion(
                    id: "scheme", prompt: "Which scheme?", kind: .singleChoice,
                    options: [
                        SupervisorInquiryOption(id: "debug", label: "Debug"),
                        SupervisorInquiryOption(id: "profile", label: "Profile"),
                    ]),
                SupervisorInquiryQuestion(id: "notes", prompt: "Anything else?", kind: .freeText),
            ])
        XCTAssertNotEqual(
            QuickCapturePresentationPolicy.renderIdentity(of: payload(form)),
            QuickCapturePresentationPolicy.renderIdentity(of: payload(other)))
    }

    func testTheSameQuestionnaireIsTheSamePanel() {
        XCTAssertEqual(
            QuickCapturePresentationPolicy.renderIdentity(of: payload(form)),
            QuickCapturePresentationPolicy.renderIdentity(of: payload(form)),
            "an identity that moved on its own would re-host the panel mid-fill")
    }

    func testAFormAndAPlainQuestionAreDifferentPanels() {
        XCTAssertNotEqual(
            QuickCapturePresentationPolicy.renderIdentity(of: payload(form)),
            QuickCapturePresentationPolicy.renderIdentity(of: payload(nil)))
    }

    // MARK: - The panel is handed the questionnaire at all

    /// RED: drop `inquiry:` from the coordinator's payload → the panel resolves an answer mode
    /// that renders the headline and no form, and the Supervisor answers a questionnaire in
    /// prose that the label matcher then has to guess at.
    func testResolvingAParkedFormCarriesItIntoThePayload() {
        let step = makeStep(
            toolCalls: [askCall(TN.askSupervisorForm, at: 10, question: "A few decisions first.")],
            needsSupervisorInput: true,
            question: "A few decisions first.",
            inquiry: form)
        let (task, _) = makeTask(steps: [step], isChatMode: true)

        let mode = DefaultQuickCaptureModeCoordinator().resolveMode(
            isTaskSelected: true, activeTask: task, engineState: .needsSupervisorInput,
            isInitializingRun: false, activeTeam: nil, forceNewTaskMode: false)

        guard case .supervisorAnswer(let resolvedSession) = mode else {
            return XCTFail("expected the panel to resolve to answer mode")
        }
        let resolved = resolvedSession.selected
        XCTAssertEqual(resolved.inquiry, form)
    }
}
