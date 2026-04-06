import XCTest

@testable import NanoTeams

final class ChangeRequestTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - StepAmendment Tests

    func testStepAmendment_initialization() {
        let amendment = StepAmendment(
            requestedByRoleID: "codeReviewer",
            reason: "Missing error handling",
            meetingDecision: "approved"
        )

        XCTAssertEqual(amendment.requestedByRoleID, "codeReviewer")
        XCTAssertEqual(amendment.reason, "Missing error handling")
        XCTAssertNil(amendment.meetingID)
        XCTAssertEqual(amendment.meetingDecision, "approved")
        XCTAssertTrue(amendment.previousArtifactSnapshots.isEmpty)
    }

    func testStepAmendment_initializationWithAllFields() {
        let meetingID = UUID()
        let snapshot = ArtifactSnapshot(artifactName: "Engineering Notes", relativePath: "artifacts/engineering_notes.md")

        let amendment = StepAmendment(
            requestedByRoleID: "sre",
            reason: "Performance concerns",
            meetingID: meetingID,
            meetingDecision: "escalated",
            previousArtifactSnapshots: [snapshot]
        )

        XCTAssertEqual(amendment.meetingID, meetingID)
        XCTAssertEqual(amendment.previousArtifactSnapshots.count, 1)
        XCTAssertEqual(amendment.previousArtifactSnapshots[0].artifactName, "Engineering Notes")
    }

    func testStepAmendment_codable() throws {
        let snapshot = ArtifactSnapshot(artifactName: "Code Review", relativePath: "artifacts/code_review.md")
        let original = StepAmendment(
            requestedByRoleID: "techLead",
            reason: "Architecture needs rework",
            meetingID: UUID(),
            meetingDecision: "approved",
            previousArtifactSnapshots: [snapshot]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StepAmendment.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.requestedByRoleID, original.requestedByRoleID)
        XCTAssertEqual(decoded.reason, original.reason)
        XCTAssertEqual(decoded.meetingID, original.meetingID)
        XCTAssertEqual(decoded.meetingDecision, original.meetingDecision)
        XCTAssertEqual(decoded.previousArtifactSnapshots.count, 1)
    }

    func testStepAmendment_hashable() {
        let id = UUID()
        let date = Date()
        let a1 = StepAmendment(
            id: id,
            createdAt: date,
            requestedByRoleID: "codeReviewer",
            reason: "test",
            meetingDecision: "approved"
        )
        let a2 = StepAmendment(
            id: id,
            createdAt: date,
            requestedByRoleID: "codeReviewer",
            reason: "test",
            meetingDecision: "approved"
        )

        XCTAssertEqual(a1, a2)
        XCTAssertEqual(a1.hashValue, a2.hashValue)
    }

    // MARK: - ArtifactSnapshot Tests

    func testArtifactSnapshot_initialization() {
        let snapshot = ArtifactSnapshot(artifactName: "Implementation Plan")

        XCTAssertEqual(snapshot.artifactName, "Implementation Plan")
        XCTAssertNil(snapshot.relativePath)
    }

    func testArtifactSnapshot_withRelativePath() {
        let snapshot = ArtifactSnapshot(
            artifactName: "Engineering Notes",
            relativePath: "artifacts/engineering_notes.md"
        )

        XCTAssertEqual(snapshot.relativePath, "artifacts/engineering_notes.md")
    }

    func testArtifactSnapshot_codable() throws {
        let original = ArtifactSnapshot(
            artifactName: "Design Spec",
            relativePath: "artifacts/design_spec.md"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ArtifactSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.artifactName, original.artifactName)
        XCTAssertEqual(decoded.relativePath, original.relativePath)
    }

    // MARK: - ChangeRequest Tests

    func testChangeRequest_initialization() {
        let cr = ChangeRequest(
            requestingRoleID: "codeReviewer",
            targetRoleID: "softwareEngineer",
            changes: "Fix null pointer dereference",
            reasoning: "Crash on empty input"
        )

        XCTAssertEqual(cr.requestingRoleID, "codeReviewer")
        XCTAssertEqual(cr.targetRoleID, "softwareEngineer")
        XCTAssertEqual(cr.changes, "Fix null pointer dereference")
        XCTAssertEqual(cr.reasoning, "Crash on empty input")
        XCTAssertNil(cr.meetingID)
        XCTAssertEqual(cr.status, .pending)
    }

    func testChangeRequest_codable() throws {
        let original = ChangeRequest(
            requestingRoleID: "sre",
            targetRoleID: "softwareEngineer",
            changes: "Add retry logic",
            reasoning: "Network calls can fail",
            meetingID: UUID(),
            status: .approved
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChangeRequest.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.requestingRoleID, original.requestingRoleID)
        XCTAssertEqual(decoded.targetRoleID, original.targetRoleID)
        XCTAssertEqual(decoded.changes, original.changes)
        XCTAssertEqual(decoded.reasoning, original.reasoning)
        XCTAssertEqual(decoded.meetingID, original.meetingID)
        XCTAssertEqual(decoded.status, .approved)
    }

    // MARK: - ChangeRequestStatus Tests

    func testChangeRequestStatus_rawValues() {
        XCTAssertEqual(ChangeRequestStatus.pending.rawValue, "pending")
        XCTAssertEqual(ChangeRequestStatus.approved.rawValue, "approved")
        XCTAssertEqual(ChangeRequestStatus.rejected.rawValue, "rejected")
        XCTAssertEqual(ChangeRequestStatus.escalated.rawValue, "escalated")
        XCTAssertEqual(ChangeRequestStatus.supervisorApproved.rawValue, "supervisorApproved")
        XCTAssertEqual(ChangeRequestStatus.supervisorRejected.rawValue, "supervisorRejected")
        XCTAssertEqual(ChangeRequestStatus.failed.rawValue, "failed")
    }

    func testChangeRequestStatus_codable() throws {
        let statuses: [ChangeRequestStatus] = [
            .pending, .approved, .rejected, .escalated, .supervisorApproved, .supervisorRejected, .failed,
        ]

        for status in statuses {
            let encoded = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(ChangeRequestStatus.self, from: encoded)
            XCTAssertEqual(decoded, status)
        }
    }

    // MARK: - MessageSourceContext Tests

    func testMessageSourceContext_changeRequest() throws {
        let context = MessageSourceContext.changeRequest
        XCTAssertEqual(context.rawValue, "changeRequest")

        let encoded = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(MessageSourceContext.self, from: encoded)
        XCTAssertEqual(decoded, .changeRequest)
    }

    // MARK: - StepExecution Migration (amendments field)

    func testStepExecution_amendments_defaultEmpty() throws {
        // Simulate legacy JSON without amendments field
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "title": "Test Step",
            "role": "softwareEngineer",
            "status": "done",
            "createdAt": 0,
            "updatedAt": 0,
            "messages": [],
            "artifacts": [],
            "expectedArtifacts": [],
            "toolCalls": [],
            "llmConversation": [],
            "consultations": []
        }
        """

        let data = json.data(using: .utf8)!
        let step = try JSONDecoder().decode(StepExecution.self, from: data)

        XCTAssertTrue(step.amendments.isEmpty)
    }

    func testStepExecution_amendments_roundTrip() throws {
        let amendment = StepAmendment(
            requestedByRoleID: "codeReviewer",
            reason: "Test",
            meetingDecision: "approved"
        )

        var step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Test",
            expectedArtifacts: ["Engineering Notes"]
        )
        step.amendments = [amendment]

        let encoded = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(StepExecution.self, from: encoded)

        XCTAssertEqual(decoded.amendments.count, 1)
        XCTAssertEqual(decoded.amendments[0].requestedByRoleID, "codeReviewer")
        XCTAssertEqual(decoded.amendments[0].reason, "Test")
    }

    // MARK: - Run Migration (changeRequests field)

    func testRun_changeRequests_defaultEmpty() throws {
        let json = """
        {
            "id": 0,
            "mode": "manual"
        }
        """

        let data = json.data(using: .utf8)!
        let run = try JSONDecoder().decode(Run.self, from: data)

        XCTAssertTrue(run.changeRequests.isEmpty)
    }

    func testRun_changeRequests_roundTrip() throws {
        let cr = ChangeRequest(
            requestingRoleID: "codeReviewer",
            targetRoleID: "softwareEngineer",
            changes: "Fix bug",
            reasoning: "Crash",
            status: .approved
        )

        var run = Run(id: 0)
        run.changeRequests = [cr]

        let encoded = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(Run.self, from: encoded)

        XCTAssertEqual(decoded.changeRequests.count, 1)
        XCTAssertEqual(decoded.changeRequests[0].status, .approved)
    }

    // MARK: - TeamLimits Migration

    func testTeamLimits_changeRequestDefaults() throws {
        let json = """
        {
            "maxConsultationsPerStep": 5,
            "maxConsultationResponseTokens": 1024,
            "maxMeetingsPerRun": 3,
            "maxMeetingTurns": 10,
            "maxMeetingToolIterationsPerTurn": 3
        }
        """

        let data = json.data(using: .utf8)!
        let limits = try JSONDecoder().decode(TeamLimits.self, from: data)

        XCTAssertEqual(limits.maxChangeRequestsPerRun, 3)
        XCTAssertEqual(limits.maxAmendmentsPerStep, 2)
    }

    func testTeamLimits_changeRequestCustomValues() throws {
        let limits = TeamLimits(
            maxChangeRequestsPerRun: 5,
            maxAmendmentsPerStep: 3
        )

        let encoded = try JSONEncoder().encode(limits)
        let decoded = try JSONDecoder().decode(TeamLimits.self, from: encoded)

        XCTAssertEqual(decoded.maxChangeRequestsPerRun, 5)
        XCTAssertEqual(decoded.maxAmendmentsPerStep, 3)
    }

    func testTeamLimits_discussionClubDisabled() {
        let limits = TeamLimits.discussionClub
        XCTAssertEqual(limits.maxChangeRequestsPerRun, 0)
        XCTAssertEqual(limits.maxAmendmentsPerStep, 0)
    }
}
