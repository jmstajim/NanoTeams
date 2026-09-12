import XCTest

@testable import NanoTeams

/// `TeamActivityActiveQuestion(pending:)` — the composer's whole production mapping.
///
/// The memberwise init carries defaults so routing and ordering tests can name three fields
/// and ignore the rest. That convenience is also the risk: a field added to `PendingQuestion`
/// and not forwarded here arrives at the composer as `nil` forever, and the only symptom is a
/// control that quietly stopped appearing. So the mapping exists as one initializer, and this
/// is the test that reads it.
@MainActor
final class TeamActivityComposerQuestionMappingTests: XCTestCase {

    private func pending(
        inquiry: SupervisorInquiry? = nil,
        askCallID: UUID? = UUID()
    ) -> SupervisorQuestionInbox.PendingQuestion {
        SupervisorQuestionInbox.PendingQuestion(
            key: TaskStepKey(taskID: 3, stepID: "engineer"),
            role: .softwareEngineer,
            headline: "Which way should the screen go?",
            inquiry: inquiry,
            paired: PairedAssistantMessage(id: UUID(), thinking: "Weighing both.", content: nil),
            askCallID: askCallID,
            askedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testEveryFieldTheComposerRendersComesFromThePendingQuestion() {
        let source = pending()

        let mapped = TeamActivityActiveQuestion(pending: source)

        XCTAssertEqual(mapped.stepID, source.stepID)
        XCTAssertEqual(mapped.role, source.role)
        XCTAssertEqual(mapped.question, source.headline)
        XCTAssertEqual(mapped.inquiry, source.inquiry)
        XCTAssertEqual(mapped.paired, source.paired)
        XCTAssertEqual(mapped.askCallID, source.askCallID)
    }

    /// The field `[ Ask as form ]` turns on.
    ///
    /// RED: drop it from the mapping → the button disappears from the composer for every
    /// question, and nothing else fails anywhere.
    func testTheAskCallSurvivesTheMapping_soTheButtonCanExist() {
        let asked = TeamActivityActiveQuestion(pending: pending())
        XCTAssertTrue(
            SupervisorQuestionnaireRequest.isAvailable(
                inquiry: asked.inquiry, askCallID: asked.askCallID))

        let escalated = TeamActivityActiveQuestion(pending: pending(askCallID: nil))
        XCTAssertFalse(
            SupervisorQuestionnaireRequest.isAvailable(
                inquiry: escalated.inquiry, askCallID: escalated.askCallID),
            "an app-raised park has no question to re-ask")
    }

    /// A questionnaire keeps the button away for the other reason — the options are already on
    /// screen — even though the role did ask.
    func testAFormLeavesNoRoomForTheButton() {
        let inquiry = SupervisorInquiry(
            headline: "A few decisions first.",
            questions: [
                SupervisorInquiryQuestion(
                    id: "layout", prompt: "Which layout?", kind: .singleChoice,
                    options: [
                        SupervisorInquiryOption(id: "list", label: "List"),
                        SupervisorInquiryOption(id: "grid", label: "Grid"),
                    ])
            ])

        let mapped = TeamActivityActiveQuestion(pending: pending(inquiry: inquiry))

        XCTAssertFalse(
            SupervisorQuestionnaireRequest.isAvailable(
                inquiry: mapped.inquiry, askCallID: mapped.askCallID))
    }
}
