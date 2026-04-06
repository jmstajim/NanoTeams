import XCTest

@testable import NanoTeams

/// Extended tests for TeammateConsultationService covering message building,
/// artifact context construction, and consultation history edge cases.
final class TeammateConsultationExtendedTests: XCTestCase {

    // MARK: - generateResponse Error Path Tests

    func testGenerateResponse_ReturnsEmptyOnConnectionError() async throws {
        let context = makeConsultationContext()
        let client = NativeLMStudioClient()
        let config = LLMConfig(
            baseURLString: "http://invalid-host-that-does-not-exist.test:9999",
            modelName: "test-model"
        )

        do {
            _ = try await TeammateConsultationService.generateResponse(
                context: context,
                client: client,
                config: config
            )
            XCTFail("Should have thrown for unreachable server")
        } catch {
            // Expected error — connection failure propagates
        }
    }

    // MARK: - Consultation Limit Edge Cases

    func testHasReachedLimit_ZeroLimit_AlwaysTrue() {
        let consultations: [TeammateConsultation] = []
        let limits = TeamLimits(maxConsultationsPerStep: 0)

        let result = TeammateConsultationService.hasReachedLimit(
            consultations: consultations,
            limits: limits
        )

        XCTAssertTrue(result)
    }

    func testWouldExceedSameTeammateLimit_ZeroLimit_AlwaysTrue() {
        let consultations: [TeammateConsultation] = []
        let limits = TeamLimits(maxSameTeammateAsks: 0)

        let result = TeammateConsultationService.wouldExceedSameTeammateLimit(
            consultations: consultations,
            targetTeammate: .softwareEngineer,
            limits: limits
        )

        XCTAssertTrue(result)
    }

    // MARK: - isDuplicateQuestion Edge Cases

    func testIsDuplicateQuestion_EmptyQuestion_HandledCorrectly() {
        let consultations = [
            makeConsultation(consultedRole: .softwareEngineer, question: "")
        ]

        let result = TeammateConsultationService.isDuplicateQuestion(
            consultations: consultations,
            targetTeammate: .softwareEngineer,
            question: ""
        )

        XCTAssertTrue(result, "Empty questions should match as duplicates")
    }

    func testIsDuplicateQuestion_WhitespaceOnlyQuestion_Matches() {
        let consultations = [
            makeConsultation(consultedRole: .softwareEngineer, question: "   ")
        ]

        let result = TeammateConsultationService.isDuplicateQuestion(
            consultations: consultations,
            targetTeammate: .softwareEngineer,
            question: "\t\n  "
        )

        XCTAssertTrue(result, "Whitespace-only questions should normalize and match")
    }

    // MARK: - createConsultation Edge Cases

    func testCreateConsultation_WithEmptyQuestion() {
        let consultation = TeammateConsultationService.createConsultation(
            requestingRole: .productManager,
            consultedRole: .softwareEngineer,
            question: "",
            context: nil
        )

        XCTAssertEqual(consultation.question, "")
        XCTAssertEqual(consultation.status, .pending)
    }

    func testCreateConsultation_WithLongQuestion() {
        let longQuestion = String(repeating: "What? ", count: 1000)
        let consultation = TeammateConsultationService.createConsultation(
            requestingRole: .productManager,
            consultedRole: .softwareEngineer,
            question: longQuestion,
            context: nil
        )

        XCTAssertEqual(consultation.question, longQuestion)
    }

    func testCreateConsultation_AllRoleCombinations() {
        let roles: [Role] = [.productManager, .tpm, .uxDesigner, .softwareEngineer, .sre]

        for requesting in roles {
            for consulted in roles where requesting != consulted {
                let consultation = TeammateConsultationService.createConsultation(
                    requestingRole: requesting,
                    consultedRole: consulted,
                    question: "Test",
                    context: nil
                )

                XCTAssertEqual(consultation.requestingRole, requesting)
                XCTAssertEqual(consultation.consultedRole, consulted)
            }
        }
    }

    // MARK: - TeammateConsultation Model Additional Tests

    func testConsultation_CompleteOverwritesPreviousResponse() {
        var consultation = makeConsultation(
            consultedRole: .softwareEngineer,
            question: "First?"
        )

        consultation.complete(with: "First response", responseTimeMs: 100)
        XCTAssertEqual(consultation.response, "First response")

        consultation.complete(with: "Second response", responseTimeMs: 200)
        XCTAssertEqual(consultation.response, "Second response")
        XCTAssertEqual(consultation.responseTimeMs, 200)
    }

    func testConsultation_FailAfterComplete_ChangesStatus() {
        var consultation = makeConsultation(
            consultedRole: .softwareEngineer,
            question: "Test?"
        )

        consultation.complete(with: "Response", responseTimeMs: 100)
        XCTAssertEqual(consultation.status, .completed)

        consultation.fail()
        XCTAssertEqual(consultation.status, .failed)
    }

    func testConsultation_CancelAfterComplete_ChangesStatus() {
        var consultation = makeConsultation(
            consultedRole: .softwareEngineer,
            question: "Test?"
        )

        consultation.complete(with: "Response", responseTimeMs: 100)
        consultation.cancel()
        XCTAssertEqual(consultation.status, .cancelled)
    }

    // MARK: - hasReachedLimit with Large Counts

    func testHasReachedLimit_LargeCount() {
        let consultations = (0..<100).map { i in
            TeammateConsultation(
                requestingRole: .productManager,
                consultedRole: .softwareEngineer,
                question: "Q\(i)",
                status: .completed
            )
        }
        let limits = TeamLimits(maxConsultationsPerStep: 50)

        let result = TeammateConsultationService.hasReachedLimit(
            consultations: consultations,
            limits: limits
        )

        XCTAssertTrue(result)
    }

    // MARK: - Custom Role Consultations

    func testCreateConsultation_WithCustomRole() {
        let customRole = Role.custom(id: "techLead")
        let consultation = TeammateConsultationService.createConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: customRole,
            question: "How should we architect this?",
            context: "Working on microservices"
        )

        XCTAssertEqual(consultation.consultedRole, customRole)
        XCTAssertEqual(consultation.context, "Working on microservices")
    }

    func testIsDuplicateQuestion_WithCustomRole() {
        let customRole = Role.custom(id: "techLead")
        let consultations = [
            TeammateConsultation(
                requestingRole: .softwareEngineer,
                consultedRole: customRole,
                question: "Architecture advice?",
                status: .pending
            )
        ]

        let result = TeammateConsultationService.isDuplicateQuestion(
            consultations: consultations,
            targetTeammate: customRole,
            question: "architecture advice?"
        )

        XCTAssertTrue(result)
    }

    // MARK: - Helpers

    private func makeConsultationContext(
        consultedRole: Role = .softwareEngineer,
        requestingRole: Role = .productManager,
        question: String = "How should we approach this?",
        artifacts: [Artifact] = [],
        consultationHistory: [TeammateConsultation] = []
    ) -> TeammateConsultationService.ConsultationContext {
        let task = NTMSTask(id: 0, title: "Test Task",
            supervisorTask: "Build feature",
            runs: [Run(id: 0)]
        )

        return TeammateConsultationService.ConsultationContext(
            consultedRole: consultedRole,
            requestingRole: requestingRole,
            question: question,
            additionalContext: nil,
            task: task,
            availableArtifacts: artifacts,
            artifactReader: { _ in nil },
            consultationHistory: consultationHistory,
            team: Team.default
        )
    }

    private func makeConsultation(
        consultedRole: Role,
        question: String = "Default question"
    ) -> TeammateConsultation {
        TeammateConsultation(
            requestingRole: .productManager,
            consultedRole: consultedRole,
            question: question,
            status: .pending
        )
    }
}
