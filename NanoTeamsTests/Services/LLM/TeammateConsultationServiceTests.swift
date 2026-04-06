import XCTest
@testable import NanoTeams

final class TeammateConsultationServiceTests: XCTestCase {

    // MARK: - hasReachedLimit Tests

    func testHasReachedLimit_WithinLimit_ReturnsFalse() {
        let consultations = createConsultations(count: 3)
        let limits = TeamLimits(maxConsultationsPerStep: 5)

        let result = TeammateConsultationService.hasReachedLimit(
            consultations: consultations,
            limits: limits
        )

        XCTAssertFalse(result)
    }

    func testHasReachedLimit_AtLimit_ReturnsTrue() {
        let consultations = createConsultations(count: 5)
        let limits = TeamLimits(maxConsultationsPerStep: 5)

        let result = TeammateConsultationService.hasReachedLimit(
            consultations: consultations,
            limits: limits
        )

        XCTAssertTrue(result)
    }

    func testHasReachedLimit_OverLimit_ReturnsTrue() {
        let consultations = createConsultations(count: 7)
        let limits = TeamLimits(maxConsultationsPerStep: 5)

        let result = TeammateConsultationService.hasReachedLimit(
            consultations: consultations,
            limits: limits
        )

        XCTAssertTrue(result)
    }

    func testHasReachedLimit_EmptyConsultations_ReturnsFalse() {
        let consultations: [TeammateConsultation] = []
        let limits = TeamLimits(maxConsultationsPerStep: 5)

        let result = TeammateConsultationService.hasReachedLimit(
            consultations: consultations,
            limits: limits
        )

        XCTAssertFalse(result)
    }

    // MARK: - wouldExceedSameTeammateLimit Tests

    func testWouldExceedSameTeammateLimit_WithinLimit_ReturnsFalse() {
        let consultations = [
            createConsultation(consultedRole: .softwareEngineer)
        ]
        let limits = TeamLimits(maxSameTeammateAsks: 2)

        let result = TeammateConsultationService.wouldExceedSameTeammateLimit(
            consultations: consultations,
            targetTeammate: .softwareEngineer,
            limits: limits
        )

        XCTAssertFalse(result)
    }

    func testWouldExceedSameTeammateLimit_AtLimit_ReturnsTrue() {
        let consultations = [
            createConsultation(consultedRole: .softwareEngineer),
            createConsultation(consultedRole: .softwareEngineer)
        ]
        let limits = TeamLimits(maxSameTeammateAsks: 2)

        let result = TeammateConsultationService.wouldExceedSameTeammateLimit(
            consultations: consultations,
            targetTeammate: .softwareEngineer,
            limits: limits
        )

        XCTAssertTrue(result)
    }

    func testWouldExceedSameTeammateLimit_DifferentTeammate_ReturnsFalse() {
        let consultations = [
            createConsultation(consultedRole: .uxDesigner),
            createConsultation(consultedRole: .uxDesigner)
        ]
        let limits = TeamLimits(maxSameTeammateAsks: 2)

        let result = TeammateConsultationService.wouldExceedSameTeammateLimit(
            consultations: consultations,
            targetTeammate: .softwareEngineer,
            limits: limits
        )

        XCTAssertFalse(result)
    }

    func testWouldExceedSameTeammateLimit_MixedTeammates_CountsCorrectly() {
        let consultations = [
            createConsultation(consultedRole: .softwareEngineer),
            createConsultation(consultedRole: .uxDesigner),
            createConsultation(consultedRole: .softwareEngineer),
            createConsultation(consultedRole: .sre)
        ]
        let limits = TeamLimits(maxSameTeammateAsks: 2)

        let resultEngineer = TeammateConsultationService.wouldExceedSameTeammateLimit(
            consultations: consultations,
            targetTeammate: .softwareEngineer,
            limits: limits
        )
        let resultDesigner = TeammateConsultationService.wouldExceedSameTeammateLimit(
            consultations: consultations,
            targetTeammate: .uxDesigner,
            limits: limits
        )

        XCTAssertTrue(resultEngineer, "Engineer should be at limit")
        XCTAssertFalse(resultDesigner, "Designer should be within limit")
    }

    // MARK: - isDuplicateQuestion Tests

    func testIsDuplicateQuestion_ExactMatch_ReturnsTrue() {
        let consultations = [
            createConsultation(
                consultedRole: .softwareEngineer,
                question: "How should I structure the API?"
            )
        ]

        let result = TeammateConsultationService.isDuplicateQuestion(
            consultations: consultations,
            targetTeammate: .softwareEngineer,
            question: "How should I structure the API?"
        )

        XCTAssertTrue(result)
    }

    func testIsDuplicateQuestion_CaseInsensitive_ReturnsTrue() {
        let consultations = [
            createConsultation(
                consultedRole: .softwareEngineer,
                question: "How should I structure the API?"
            )
        ]

        let result = TeammateConsultationService.isDuplicateQuestion(
            consultations: consultations,
            targetTeammate: .softwareEngineer,
            question: "HOW SHOULD I STRUCTURE THE API?"
        )

        XCTAssertTrue(result)
    }

    func testIsDuplicateQuestion_WithWhitespace_ReturnsTrue() {
        let consultations = [
            createConsultation(
                consultedRole: .softwareEngineer,
                question: "How should I structure the API?"
            )
        ]

        let result = TeammateConsultationService.isDuplicateQuestion(
            consultations: consultations,
            targetTeammate: .softwareEngineer,
            question: "  How should I structure the API?  "
        )

        XCTAssertTrue(result)
    }

    func testIsDuplicateQuestion_DifferentQuestion_ReturnsFalse() {
        let consultations = [
            createConsultation(
                consultedRole: .softwareEngineer,
                question: "How should I structure the API?"
            )
        ]

        let result = TeammateConsultationService.isDuplicateQuestion(
            consultations: consultations,
            targetTeammate: .softwareEngineer,
            question: "What testing framework should we use?"
        )

        XCTAssertFalse(result)
    }

    func testIsDuplicateQuestion_DifferentTeammate_ReturnsFalse() {
        let consultations = [
            createConsultation(
                consultedRole: .softwareEngineer,
                question: "How should I structure the API?"
            )
        ]

        let result = TeammateConsultationService.isDuplicateQuestion(
            consultations: consultations,
            targetTeammate: .uxDesigner,
            question: "How should I structure the API?"
        )

        XCTAssertFalse(result)
    }

    func testIsDuplicateQuestion_EmptyConsultations_ReturnsFalse() {
        let consultations: [TeammateConsultation] = []

        let result = TeammateConsultationService.isDuplicateQuestion(
            consultations: consultations,
            targetTeammate: .softwareEngineer,
            question: "How should I structure the API?"
        )

        XCTAssertFalse(result)
    }

    // MARK: - createConsultation Tests

    func testCreateConsultation_CreatesWithCorrectValues() {
        let consultation = TeammateConsultationService.createConsultation(
            requestingRole: .productManager,
            consultedRole: .softwareEngineer,
            question: "What's the best approach?",
            context: "Working on requirements"
        )

        XCTAssertEqual(consultation.requestingRole, .productManager)
        XCTAssertEqual(consultation.consultedRole, .softwareEngineer)
        XCTAssertEqual(consultation.question, "What's the best approach?")
        XCTAssertEqual(consultation.context, "Working on requirements")
        XCTAssertEqual(consultation.status, .pending)
        XCTAssertNil(consultation.response)
    }

    func testCreateConsultation_WithoutContext_CreatesCorrectly() {
        let consultation = TeammateConsultationService.createConsultation(
            requestingRole: .uxDesigner,
            consultedRole: .sre,
            question: "How do you test this?",
            context: nil
        )

        XCTAssertEqual(consultation.requestingRole, .uxDesigner)
        XCTAssertEqual(consultation.consultedRole, .sre)
        XCTAssertEqual(consultation.question, "How do you test this?")
        XCTAssertNil(consultation.context)
        XCTAssertEqual(consultation.status, .pending)
    }

    // MARK: - TeammateConsultation Model Tests

    func testTeammateConsultation_Complete_SetsValues() {
        var consultation = createConsultation(consultedRole: .softwareEngineer)

        consultation.complete(with: "Here's my advice...", responseTimeMs: 1500)

        XCTAssertEqual(consultation.status, .completed)
        XCTAssertEqual(consultation.response, "Here's my advice...")
        XCTAssertEqual(consultation.responseTimeMs, 1500)
    }

    func testTeammateConsultation_Fail_SetsStatus() {
        var consultation = createConsultation(consultedRole: .softwareEngineer)

        consultation.fail()

        XCTAssertEqual(consultation.status, .failed)
        XCTAssertNil(consultation.response)
    }

    func testTeammateConsultation_Cancel_SetsStatus() {
        var consultation = createConsultation(consultedRole: .softwareEngineer)

        consultation.cancel()

        XCTAssertEqual(consultation.status, .cancelled)
    }

    func testTeammateConsultation_IsDuplicateOf_SameQuestionAndTeammate_ReturnsTrue() {
        let consultation1 = createConsultation(
            consultedRole: .softwareEngineer,
            question: "How do I do this?"
        )
        let consultation2 = createConsultation(
            consultedRole: .softwareEngineer,
            question: "How do I do this?"
        )

        XCTAssertTrue(consultation1.isDuplicateOf(consultation2))
    }

    func testTeammateConsultation_IsDuplicateOf_DifferentQuestion_ReturnsFalse() {
        let consultation1 = createConsultation(
            consultedRole: .softwareEngineer,
            question: "How do I do this?"
        )
        let consultation2 = createConsultation(
            consultedRole: .softwareEngineer,
            question: "What's the best approach?"
        )

        XCTAssertFalse(consultation1.isDuplicateOf(consultation2))
    }

    // MARK: - ConsultationStatus Tests

    func testConsultationStatus_DisplayName() {
        XCTAssertEqual(ConsultationStatus.pending.displayName, "Pending")
        XCTAssertEqual(ConsultationStatus.completed.displayName, "Completed")
        XCTAssertEqual(ConsultationStatus.failed.displayName, "Failed")
        XCTAssertEqual(ConsultationStatus.cancelled.displayName, "Cancelled")
    }

    func testConsultationStatus_Icon() {
        XCTAssertEqual(ConsultationStatus.pending.icon, "clock")
        XCTAssertEqual(ConsultationStatus.completed.icon, "checkmark.circle")
        XCTAssertEqual(ConsultationStatus.failed.icon, "xmark.circle")
        XCTAssertEqual(ConsultationStatus.cancelled.icon, "slash.circle")
    }

    // MARK: - Codable Tests

    func testTeammateConsultation_Codable_RoundTrip() throws {
        let original = TeammateConsultation(
            requestingRole: .productManager,
            consultedRole: .softwareEngineer,
            question: "Test question?",
            context: "Test context",
            response: "Test response",
            status: .completed,
            responseTimeMs: 1234
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TeammateConsultation.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.requestingRole, original.requestingRole)
        XCTAssertEqual(decoded.consultedRole, original.consultedRole)
        XCTAssertEqual(decoded.question, original.question)
        XCTAssertEqual(decoded.context, original.context)
        XCTAssertEqual(decoded.response, original.response)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.responseTimeMs, original.responseTimeMs)
    }

    func testTeammateConsultation_Codable_WithMissingOptionals() throws {
        // Simulate JSON without optional fields
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "requestingRole": "productManager",
            "consultedRole": "softwareEngineer",
            "question": "Test question?"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TeammateConsultation.self, from: json)

        XCTAssertEqual(decoded.requestingRole, .productManager)
        XCTAssertEqual(decoded.consultedRole, .softwareEngineer)
        XCTAssertEqual(decoded.question, "Test question?")
        XCTAssertNil(decoded.context)
        XCTAssertNil(decoded.response)
        XCTAssertEqual(decoded.status, .pending)
        XCTAssertNil(decoded.responseTimeMs)
    }

    // MARK: - Helpers

    private func createConsultations(count: Int) -> [TeammateConsultation] {
        (0..<count).map { i in
            TeammateConsultation(
                requestingRole: .productManager,
                consultedRole: .softwareEngineer,
                question: "Question \(i)",
                status: .pending
            )
        }
    }

    private func createConsultation(
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
