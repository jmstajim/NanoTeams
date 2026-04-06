import XCTest

@testable import NanoTeams

final class TeammateConsultationTests: XCTestCase {

    // MARK: - Initialization Tests

    func testTeammateConsultation_initialization() {
        let consultation = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "What color scheme should we use?"
        )

        XCTAssertEqual(consultation.requestingRole, .softwareEngineer)
        XCTAssertEqual(consultation.consultedRole, .uxDesigner)
        XCTAssertEqual(consultation.question, "What color scheme should we use?")
        XCTAssertNil(consultation.context)
        XCTAssertNil(consultation.response)
        XCTAssertEqual(consultation.status, .pending)
        XCTAssertNil(consultation.responseTimeMs)
    }

    func testTeammateConsultation_initializationWithAllFields() {
        let id = UUID()
        let createdAt = Date()

        let consultation = TeammateConsultation(
            id: id,
            createdAt: createdAt,
            requestingRole: .tpm,
            consultedRole: .sre,
            question: "Can we proceed with testing?",
            context: "Build completed successfully",
            response: "Yes, all prerequisites are met",
            status: .completed,
            responseTimeMs: 1500
        )

        XCTAssertEqual(consultation.id, id)
        XCTAssertEqual(consultation.createdAt, createdAt)
        XCTAssertEqual(consultation.requestingRole, .tpm)
        XCTAssertEqual(consultation.consultedRole, .sre)
        XCTAssertEqual(consultation.question, "Can we proceed with testing?")
        XCTAssertEqual(consultation.context, "Build completed successfully")
        XCTAssertEqual(consultation.response, "Yes, all prerequisites are met")
        XCTAssertEqual(consultation.status, .completed)
        XCTAssertEqual(consultation.responseTimeMs, 1500)
    }

    // MARK: - Codable Tests

    func testTeammateConsultation_codable() throws {
        let original = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "Test question",
            context: "Test context",
            response: "Test response",
            status: .completed,
            responseTimeMs: 500
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TeammateConsultation.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.requestingRole, original.requestingRole)
        XCTAssertEqual(decoded.consultedRole, original.consultedRole)
        XCTAssertEqual(decoded.question, original.question)
        XCTAssertEqual(decoded.context, original.context)
        XCTAssertEqual(decoded.response, original.response)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.responseTimeMs, original.responseTimeMs)
    }

    func testTeammateConsultation_codable_backwardsCompatibility() throws {
        // Test decoding with missing optional fields
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "requestingRole": "softwareEngineer",
            "consultedRole": "uxDesigner",
            "question": "Test?"
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TeammateConsultation.self, from: data)

        XCTAssertEqual(decoded.status, .pending)  // Default
        XCTAssertNil(decoded.context)
        XCTAssertNil(decoded.response)
        XCTAssertNil(decoded.responseTimeMs)
    }

    // MARK: - complete() Tests

    func testComplete_setsResponseAndStatus() {
        var consultation = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "What colors?"
        )

        consultation.complete(with: "Use blue and green", responseTimeMs: 1200)

        XCTAssertEqual(consultation.response, "Use blue and green")
        XCTAssertEqual(consultation.status, .completed)
        XCTAssertEqual(consultation.responseTimeMs, 1200)
    }

    func testComplete_withoutResponseTime() {
        var consultation = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "What colors?"
        )

        consultation.complete(with: "Use blue")

        XCTAssertEqual(consultation.response, "Use blue")
        XCTAssertEqual(consultation.status, .completed)
        XCTAssertNil(consultation.responseTimeMs)
    }

    // MARK: - fail() Tests

    func testFail_setsStatusToFailed() {
        var consultation = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "What colors?"
        )

        consultation.fail()

        XCTAssertEqual(consultation.status, .failed)
        XCTAssertNil(consultation.response)
    }

    // MARK: - cancel() Tests

    func testCancel_setsStatusToCancelled() {
        var consultation = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "What colors?"
        )

        consultation.cancel()

        XCTAssertEqual(consultation.status, .cancelled)
    }

    // MARK: - isDuplicateOf() Tests

    func testIsDuplicateOf_sameTeammateAndQuestion() {
        let consultation1 = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "What colors should we use?"
        )

        let consultation2 = TeammateConsultation(
            requestingRole: .tpm,
            consultedRole: .uxDesigner,
            question: "What colors should we use?"
        )

        XCTAssertTrue(consultation1.isDuplicateOf(consultation2))
    }

    func testIsDuplicateOf_caseInsensitive() {
        let consultation1 = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "WHAT COLORS?"
        )

        let consultation2 = TeammateConsultation(
            requestingRole: .tpm,
            consultedRole: .uxDesigner,
            question: "what colors?"
        )

        XCTAssertTrue(consultation1.isDuplicateOf(consultation2))
    }

    func testIsDuplicateOf_trimmedComparison() {
        let consultation1 = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "   What colors?   "
        )

        let consultation2 = TeammateConsultation(
            requestingRole: .tpm,
            consultedRole: .uxDesigner,
            question: "What colors?"
        )

        XCTAssertTrue(consultation1.isDuplicateOf(consultation2))
    }

    func testIsDuplicateOf_differentTeammate() {
        let consultation1 = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "What colors?"
        )

        let consultation2 = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .sre,
            question: "What colors?"
        )

        XCTAssertFalse(consultation1.isDuplicateOf(consultation2))
    }

    func testIsDuplicateOf_differentQuestion() {
        let consultation1 = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "What colors?"
        )

        let consultation2 = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "What fonts?"
        )

        XCTAssertFalse(consultation1.isDuplicateOf(consultation2))
    }

    // MARK: - ConsultationStatus Tests

    func testConsultationStatus_displayName() {
        XCTAssertEqual(ConsultationStatus.pending.displayName, "Pending")
        XCTAssertEqual(ConsultationStatus.completed.displayName, "Completed")
        XCTAssertEqual(ConsultationStatus.failed.displayName, "Failed")
        XCTAssertEqual(ConsultationStatus.cancelled.displayName, "Cancelled")
    }

    func testConsultationStatus_icon() {
        XCTAssertEqual(ConsultationStatus.pending.icon, "clock")
        XCTAssertEqual(ConsultationStatus.completed.icon, "checkmark.circle")
        XCTAssertEqual(ConsultationStatus.failed.icon, "xmark.circle")
        XCTAssertEqual(ConsultationStatus.cancelled.icon, "slash.circle")
    }

    func testConsultationStatus_codable() throws {
        let statuses: [ConsultationStatus] = [.pending, .completed, .failed, .cancelled]

        for status in statuses {
            let encoder = JSONEncoder()
            let data = try encoder.encode(status)

            let decoder = JSONDecoder()
            let decoded = try decoder.decode(ConsultationStatus.self, from: data)

            XCTAssertEqual(decoded, status)
        }
    }

    // MARK: - Hashable Tests

    func testTeammateConsultation_hashable() {
        let consultation1 = TeammateConsultation(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "Test?"
        )

        let consultation2 = TeammateConsultation(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "Test?"
        )

        XCTAssertEqual(consultation1.hashValue, consultation2.hashValue)

        var set = Set<TeammateConsultation>()
        set.insert(consultation1)
        XCTAssertTrue(set.contains(consultation2))
    }

    // MARK: - Identifiable Tests

    func testTeammateConsultation_identifiable() {
        let consultation = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "Test?"
        )

        XCTAssertNotNil(consultation.id)
        XCTAssertEqual(consultation.id, consultation.id)  // ID is stable
    }
}
