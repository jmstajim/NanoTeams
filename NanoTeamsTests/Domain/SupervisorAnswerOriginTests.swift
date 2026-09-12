import XCTest

@testable import NanoTeams

/// `SupervisorAnswerOrigin` — the one value every answer seam carries.
///
/// Three origins reach `StepMessagingService.answerSupervisorQuestion`, and each decides the
/// same four things about the turn it appends. The table is here rather than read off the
/// rendered feed because these are the properties a WRONG combination would express silently:
/// an app directive wearing the Supervisor's name, or a human answer wearing the auto badge.
final class SupervisorAnswerOriginTests: XCTestCase {

    // MARK: - The badge

    /// The badge means "an LLM answerer stood in for the human". The `[ Ask as form ]`
    /// directive is sent BY the human — they pressed the button — so it must not wear it.
    func testOnlyTheAutomatedOriginIsAutomated() {
        XCTAssertFalse(SupervisorAnswerOrigin.supervisor.isAutomated)
        XCTAssertTrue(SupervisorAnswerOrigin.automated.isAutomated)
        XCTAssertFalse(SupervisorAnswerOrigin.questionnaireRequest.isAutomated)
    }

    // MARK: - The appended turn

    func testHumanAndAutomatedAnswersSpeakAsTheSupervisor() {
        for origin in [SupervisorAnswerOrigin.supervisor, .automated] {
            XCTAssertEqual(origin.messageContext, .supervisorAnswer, "\(origin)")
            XCTAssertEqual(origin.messageSourceRole, .supervisor, "\(origin)")
            XCTAssertEqual(
                origin.messageContentPrefix, MessageSourceContext.supervisorAnswerPrefix,
                "\(origin)")
        }
    }

    /// RED: give the directive `.supervisorAnswer` → the feed draws it as the human
    /// checkmarking "The question was not answered" at the role that just asked, which is the
    /// whole defect this origin exists to undo.
    func testTheDirectiveSpeaksAsTheSystem() {
        let origin = SupervisorAnswerOrigin.questionnaireRequest

        XCTAssertEqual(origin.messageContext, .questionnaireRequest)
        XCTAssertNil(origin.messageSourceRole, "nil files the row under the ASKING role")
        XCTAssertEqual(origin.messageContentPrefix, "", "the wire gets it bare, in the envelope")
    }

    // MARK: - The invariant every origin owes

    /// Whatever the origin, the appended turn has to UNPARK the step — that is the whole
    /// contract of the seam. A context outside the resolving set would leave the composer
    /// chip, the Watchtower inbox and the sidebar indicator waiting forever.
    func testEveryOriginResolvesTheParkedAsk() {
        for origin in SupervisorAnswerOrigin.allCases {
            XCTAssertTrue(
                origin.messageContext.resolvesSupervisorAsk,
                "\(origin) appends a turn that does not resolve the park")
        }
    }
}
