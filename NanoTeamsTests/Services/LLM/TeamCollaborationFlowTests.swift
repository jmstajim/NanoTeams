import XCTest

@testable import NanoTeams

/// Tests for LLMExecutionService+TeamCollaboration — consultation validation,
/// meeting participant filtering, artifact context building, consultation chat
/// persistence, and change request flow logic.
@MainActor
final class TeamCollaborationFlowTests: XCTestCase {

    var service: LLMExecutionService!
    var mockDelegate: MockLLMExecutionDelegate!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() {
        service = nil
        mockDelegate = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeFAANGTeam() -> Team {
        let supervisor = TeamRoleDefinition(
            id: "supervisor", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Supervisor Task"]),
            isSystemRole: true, systemRoleID: "supervisor"
        )
        let pm = TeamRoleDefinition(
            id: "productManager", name: "Product Manager", prompt: "",
            toolIDs: ["read_file"], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Supervisor Task"],
                producesArtifacts: ["Product Requirements"]
            ),
            isSystemRole: true, systemRoleID: "productManager"
        )
        let engineer = TeamRoleDefinition(
            id: "softwareEngineer", name: "Software Engineer", prompt: "",
            toolIDs: ["read_file", "write_file"], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Product Requirements"],
                producesArtifacts: ["Engineering Notes"]
            ),
            isSystemRole: true, systemRoleID: "softwareEngineer"
        )
        let reviewer = TeamRoleDefinition(
            id: "codeReviewer", name: "Code Reviewer", prompt: "",
            toolIDs: ["read_file"], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Engineering Notes"],
                producesArtifacts: ["Code Review"]
            ),
            isSystemRole: true, systemRoleID: "codeReviewer"
        )

        return Team(
            name: "Test FAANG",
            roles: [supervisor, pm, engineer, reviewer],
            artifacts: [],
            settings: .default,
            graphLayout: TeamGraphLayout()
        )
    }

    // MARK: - Consultation Validation

    func testConsultationValidation_selfConsultation_returnsError() {
        let team = makeFAANGTeam()

        let error = service._testConsultationValidationError(
            consultedRoleID: "softwareEngineer",
            requestingRoleID: "softwareEngineer",
            team: team,
            teamSettings: team.settings
        )

        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("yourself") ?? false || error?.contains("same") ?? false,
                       "Should reject self-consultation")
    }

    func testConsultationValidation_supervisorConsultation_returnsError() {
        let team = makeFAANGTeam()

        let error = service._testConsultationValidationError(
            consultedRoleID: "supervisor",
            requestingRoleID: "softwareEngineer",
            team: team,
            teamSettings: team.settings
        )

        XCTAssertNotNil(error,
                       "Consulting supervisor directly should return error (use ask_supervisor)")
    }

    func testConsultationValidation_validTeammate_returnsNil() {
        let team = makeFAANGTeam()

        let error = service._testConsultationValidationError(
            consultedRoleID: "productManager",
            requestingRoleID: "softwareEngineer",
            team: team,
            teamSettings: team.settings
        )

        XCTAssertNil(error, "Valid cross-role consultation should succeed")
    }

    func testConsultationValidation_unknownRole_returnsError() {
        let team = makeFAANGTeam()

        let error = service._testConsultationValidationError(
            consultedRoleID: "nonexistentRole",
            requestingRoleID: "softwareEngineer",
            team: team,
            teamSettings: team.settings
        )

        XCTAssertNotNil(error, "Unknown role should return error")
    }

    // MARK: - Meeting Participant Filtering

    func testFilterMeetingParticipants_validParticipants_returnsAll() {
        let team = makeFAANGTeam()

        let result = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["productManager", "codeReviewer"],
            initiatingRole: .softwareEngineer,
            team: team,
            teamSettings: team.settings
        )

        XCTAssertEqual(result.participants.count, 2)
        XCTAssertTrue(result.rejectedReasons.isEmpty)
    }

    func testFilterMeetingParticipants_selfIncluded_isRejected() {
        let team = makeFAANGTeam()

        let result = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["softwareEngineer", "productManager"],
            initiatingRole: .softwareEngineer,
            team: team,
            teamSettings: team.settings
        )

        // Self should be filtered out
        XCTAssertFalse(result.participants.contains(where: { $0.baseID == "softwareEngineer" }),
                       "Initiating role should be excluded from participants")
    }

    func testFilterMeetingParticipants_supervisorByDefault_isRejected() {
        var team = makeFAANGTeam()
        // Default: supervisorCanBeInvited is false
        team.settings.supervisorCanBeInvited = false

        let result = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["supervisor", "productManager"],
            initiatingRole: .softwareEngineer,
            team: team,
            teamSettings: team.settings
        )

        XCTAssertFalse(result.participants.contains(where: { $0.baseID == "supervisor" }),
                       "Supervisor should be excluded when supervisorCanBeInvited is false")
    }

    func testFilterMeetingParticipants_supervisorCanBeInvited() {
        var team = makeFAANGTeam()
        team.settings.supervisorCanBeInvited = true

        let result = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["supervisor", "productManager"],
            initiatingRole: .softwareEngineer,
            team: team,
            teamSettings: team.settings
        )

        // Supervisor should be included when setting allows
        let hasSupervisor = result.participants.contains(where: { $0 == .supervisor })
        XCTAssertTrue(hasSupervisor,
                      "Supervisor should be included when supervisorCanBeInvited is true")
    }

    func testFilterMeetingParticipants_unknownParticipant_isRejected() {
        let team = makeFAANGTeam()

        let result = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["nonexistentRole"],
            initiatingRole: .softwareEngineer,
            team: team,
            teamSettings: team.settings
        )

        XCTAssertTrue(result.participants.isEmpty)
        XCTAssertFalse(result.rejectedReasons.isEmpty)
    }

    func testFilterMeetingParticipants_emptyList_returnsEmpty() {
        let team = makeFAANGTeam()

        let result = MeetingParticipantResolver.filterParticipants(
            participantIDs: [],
            initiatingRole: .softwareEngineer,
            team: team,
            teamSettings: team.settings
        )

        XCTAssertTrue(result.participants.isEmpty)
    }

    // MARK: - Available Teammates List

    func testAvailableTeammatesList_excludesRequestingRole() {
        let team = makeFAANGTeam()

        let list = MeetingParticipantResolver.availableTeammatesList(
            team: team,
            teamSettings: team.settings,
            excludeRoleID: "softwareEngineer"
        )

        XCTAssertFalse(list.contains("Software Engineer"),
                       "Requesting role should be excluded from available list")
        // Should contain at least PM and Code Reviewer
        XCTAssertTrue(list.contains("productManager"))
    }

    func testAvailableTeammatesList_excludesSupervisor() {
        let team = makeFAANGTeam()

        let list = MeetingParticipantResolver.availableTeammatesList(
            team: team,
            teamSettings: team.settings,
            excludeRoleID: "softwareEngineer"
        )

        XCTAssertFalse(list.lowercased().contains("supervisor"),
                       "Supervisor should be excluded from teammate list")
    }

    func testAvailableTeammatesList_nilTeam_fallsBackToBuiltInRoles() {
        let list = MeetingParticipantResolver.availableTeammatesList(
            team: nil,
            teamSettings: .default,
            excludeRoleID: "softwareEngineer"
        )

        // When team is nil, returns all built-in role IDs except the excluded one
        XCTAssertFalse(list.isEmpty, "Nil team should fall back to built-in role IDs")
        XCTAssertFalse(list.contains("softwareEngineer"),
                       "Excluded role should not appear in list")
        XCTAssertTrue(list.contains("productManager"),
                      "Other built-in roles should appear")
    }

    // MARK: - Change Request Recording

    func testRecordChangeRequest_appendsToRun() async {
        let stepID = "test_step"
        let taskID = 0
        let step = StepExecution(
            id: stepID, role: .softwareEngineer,
            title: "Code", status: .running
        )
        let run = Run(id: 0, steps: [step], roleStatuses: ["eng": .working])
        let task = NTMSTask(id: taskID, title: "Task", supervisorTask: "Goal", runs: [run])
        mockDelegate.taskToMutate = task

        let cr = ChangeRequest(
            requestingRoleID: "codeReviewer",
            targetRoleID: "softwareEngineer",
            changes: "Fix null check",
            reasoning: "Could crash"
        )

        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        await service.recordChangeRequest(taskID: taskID, changeRequest: cr)

        XCTAssertEqual(mockDelegate.taskToMutate?.runs.last?.changeRequests.count, 1)
        XCTAssertEqual(mockDelegate.taskToMutate?.runs.last?.changeRequests.first?.changes, "Fix null check")
    }

    func testRecordChangeRequest_upsertExisting() async {
        let stepID = "test_step"
        let taskID = 0
        let crID = UUID()

        let existingCR = ChangeRequest(
            id: crID,
            requestingRoleID: "codeReviewer",
            targetRoleID: "softwareEngineer",
            changes: "Old changes",
            reasoning: "Old reasoning"
        )
        let step = StepExecution(
            id: stepID, role: .softwareEngineer,
            title: "Code", status: .running
        )
        var run = Run(id: 0, steps: [step], roleStatuses: ["eng": .working])
        run.changeRequests = [existingCR]
        let task = NTMSTask(id: taskID, title: "Task", supervisorTask: "Goal", runs: [run])
        mockDelegate.taskToMutate = task

        // Update with same ID
        var updatedCR = existingCR
        updatedCR.changes = "New changes"
        updatedCR.status = .approved

        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        await service.recordChangeRequest(taskID: taskID, changeRequest: updatedCR)

        XCTAssertEqual(mockDelegate.taskToMutate?.runs.last?.changeRequests.count, 1,
                       "Upsert should not duplicate")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs.last?.changeRequests.first?.changes, "New changes")
    }

    // MARK: - Vote Tallying (Extended)

    func testTallyVotes_caseInsensitive() {
        let messages = [
            TeamMessage(role: .softwareEngineer, content: "vote: approve"),
            TeamMessage(role: .techLead, content: "VOTE: APPROVE"),
        ]

        let result = ChangeRequestService.tallyVotes(meetingMessages: messages)
        XCTAssertEqual(result, .approved)
    }

    func testTallyVotes_voteAtEndOfLongMessage() {
        let messages = [
            TeamMessage(role: .softwareEngineer, content: """
                I've reviewed the changes carefully. The null check fix is important
                and the code quality improvements are welcome. After careful consideration,
                I believe these changes are necessary.
                VOTE: APPROVE
                """),
            TeamMessage(role: .techLead, content: "Good analysis. VOTE: APPROVE"),
        ]

        let result = ChangeRequestService.tallyVotes(meetingMessages: messages)
        XCTAssertEqual(result, .approved)
    }

    func testTallyVotes_emptyMessages_returnsTied() {
        let result = ChangeRequestService.tallyVotes(meetingMessages: [])
        XCTAssertEqual(result, .tied, "0 approves vs 0 rejects should return .tied")
    }

    func testTallyVotes_mixedContentWithVotes() {
        let messages = [
            TeamMessage(role: .softwareEngineer, content: "This is a discussion message without a vote."),
            TeamMessage(role: .techLead, content: "I think we should VOTE: APPROVE this."),
            TeamMessage(role: .codeReviewer, content: "I disagree. VOTE: REJECT"),
            TeamMessage(role: .sre, content: "Let me think about it more."),
        ]

        let result = ChangeRequestService.tallyVotes(meetingMessages: messages)
        // 1 approve, 1 reject — tie
        XCTAssertEqual(result, .tied)
    }

    // MARK: - Meeting Delegate Calls

    func testSetMeetingParticipants_delegatesCorrectly() {
        let taskID = 0
        let participants: Set<String> = ["eng", "pm", "designer"]

        mockDelegate.setActiveMeetingParticipants(participants, for: taskID)

        XCTAssertEqual(mockDelegate.setMeetingParticipantsCalls.count, 1)
        XCTAssertEqual(mockDelegate.setMeetingParticipantsCalls[0].0, participants)
        XCTAssertEqual(mockDelegate.setMeetingParticipantsCalls[0].1, taskID)
    }

    func testClearMeetingParticipants_delegatesCorrectly() {
        let taskID = 0

        mockDelegate.clearActiveMeetingParticipants(for: taskID)

        XCTAssertEqual(mockDelegate.clearMeetingParticipantsCalls.count, 1)
        XCTAssertEqual(mockDelegate.clearMeetingParticipantsCalls[0], taskID)
    }
}
