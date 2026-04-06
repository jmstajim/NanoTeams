import XCTest

@testable import NanoTeams

/// E2E tests for team meeting lifecycle:
/// creation → tool filtering → limits → excluded tools → source context.
@MainActor
final class EndToEndMeetingLifecycleTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: Meeting creation with valid participants

    func testMeeting_createWithValidParticipants() {
        let meeting = TeamMeeting(
            topic: "Architecture Review",
            initiatedBy: .softwareEngineer,
            participants: [.softwareEngineer, .techLead, .codeReviewer]
        )

        XCTAssertEqual(meeting.topic, "Architecture Review")
        XCTAssertEqual(meeting.participants.count, 3)
        XCTAssertTrue(meeting.messages.isEmpty, "New meeting should have no messages")
        XCTAssertEqual(meeting.turnCount, 0)
    }

    // MARK: - Test 2: Excluded tools in meeting context

    func testMeeting_excludedToolsNotAvailable() {
        let schema = JSONSchema(type: "object")
        let allTools = [
            ToolSchema(name: "read_file", description: "Read", parameters: schema),
            ToolSchema(name: "write_file", description: "Write", parameters: schema),
            ToolSchema(name: "ask_supervisor", description: "Ask", parameters: schema),
            ToolSchema(name: "create_artifact", description: "Create", parameters: schema),
            ToolSchema(name: "ask_teammate", description: "Consult", parameters: schema),
            ToolSchema(name: "request_team_meeting", description: "Request", parameters: schema),
            ToolSchema(name: "conclude_meeting", description: "Conclude", parameters: schema),
            ToolSchema(name: "request_changes", description: "Changes", parameters: schema),
            ToolSchema(name: "analyze_image", description: "Vision", parameters: schema),
        ]

        let filtered = MeetingCoordinator.filterMeetingTools(allTools)
        let filteredNames = Set(filtered.map(\.name))

        // File tools should be available
        XCTAssertTrue(filteredNames.contains("read_file"))
        XCTAssertTrue(filteredNames.contains("write_file"))

        // Collaborative tools should be excluded
        XCTAssertFalse(filteredNames.contains("ask_supervisor"))
        XCTAssertFalse(filteredNames.contains("create_artifact"))
        XCTAssertFalse(filteredNames.contains("ask_teammate"))
        XCTAssertFalse(filteredNames.contains("request_team_meeting"))
        XCTAssertFalse(filteredNames.contains("conclude_meeting"))
        XCTAssertFalse(filteredNames.contains("request_changes"))
        XCTAssertFalse(filteredNames.contains("analyze_image"))
    }

    // MARK: - Test 3: Meeting limits enforcement

    func testMeeting_limitsEnforced() {
        let limits = TeamLimits()
        let maxMeetings = limits.maxMeetingsPerRun

        // Create meetings up to the limit
        var meetings: [TeamMeeting] = []
        for _ in 0..<maxMeetings {
            meetings.append(TeamMeeting(
                topic: "Meeting",
                initiatedBy: .softwareEngineer,
                participants: [.softwareEngineer, .productManager]
            ))
        }

        let hasReachedLimit = TeamMeetingService.hasReachedMeetingLimit(
            meetings: meetings,
            limits: limits
        )
        XCTAssertTrue(hasReachedLimit, "Should reach meeting limit at \(maxMeetings)")

        // Under the limit
        let underLimit = TeamMeetingService.hasReachedMeetingLimit(
            meetings: Array(meetings.dropLast()),
            limits: limits
        )
        XCTAssertFalse(underLimit, "Should not reach limit with \(maxMeetings - 1) meetings")
    }

    // MARK: - Test 4: Meeting message with source context

    func testMeeting_messageWithSourceContext() {
        let meetingResult = LLMMessage(
            role: .user,
            content: "Meeting concluded with decision to use REST API.",
            sourceRole: .techLead,
            sourceContext: .meeting
        )

        XCTAssertEqual(meetingResult.sourceContext, .meeting)
        XCTAssertEqual(meetingResult.sourceRole, .techLead)
        XCTAssertTrue(meetingResult.content.contains("REST API"))
    }

    // MARK: - Test 5: Participant filtering via MeetingParticipantResolver

    func testMeeting_participantFiltering() {
        let team = makeTeamWithRoles()

        // Use filterParticipants to filter out self and supervisor
        let result = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["pm-role", "tl-role", "supervisor", "swe-role"],
            initiatingRole: .softwareEngineer,
            team: team,
            teamSettings: team.settings
        )

        // Supervisor should be filtered by default (supervisorCanBeInvited is false by default)
        let hasSupervisor = result.participants.contains { $0 == .supervisor }
        XCTAssertFalse(hasSupervisor, "Supervisor should be filtered when not invitable")

        // Should have some resolved participants
        XCTAssertGreaterThan(result.participants.count, 0, "Should resolve some participants")
    }

    // MARK: - Test 6: Meeting excluded tools set is complete

    func testMeeting_excludedToolsSetComplete() {
        let excluded = MeetingCoordinator.meetingExcludedTools

        // All collaborative/control tools should be excluded
        XCTAssertTrue(excluded.contains(ToolNames.askTeammate))
        XCTAssertTrue(excluded.contains(ToolNames.requestTeamMeeting))
        XCTAssertTrue(excluded.contains(ToolNames.concludeMeeting))
        XCTAssertTrue(excluded.contains(ToolNames.askSupervisor))
        XCTAssertTrue(excluded.contains(ToolNames.requestChanges))
        XCTAssertTrue(excluded.contains(ToolNames.createArtifact))
        XCTAssertTrue(excluded.contains(ToolNames.analyzeImage))

        // File tools should NOT be excluded
        XCTAssertFalse(excluded.contains(ToolNames.readFile))
        XCTAssertFalse(excluded.contains(ToolNames.writeFile))
    }

    // MARK: - Helpers

    private func makeTeamWithRoles() -> Team {
        Team(
            name: "Test Team",
            roles: [
                TeamRoleDefinition(
                    id: "supervisor", name: "Supervisor", prompt: "", toolIDs: [],
                    usePlanningPhase: false,
                    dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Supervisor Task"]),
                    isSystemRole: true, systemRoleID: "supervisor"
                ),
                TeamRoleDefinition(
                    id: "pm-role", name: "Product Manager", prompt: "", toolIDs: ["read_file"],
                    usePlanningPhase: false,
                    dependencies: RoleDependencies(requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Requirements"])
                ),
                TeamRoleDefinition(
                    id: "tl-role", name: "Tech Lead", prompt: "", toolIDs: ["read_file"],
                    usePlanningPhase: false,
                    dependencies: RoleDependencies(requiredArtifacts: ["Requirements"], producesArtifacts: ["Plan"])
                ),
                TeamRoleDefinition(
                    id: "swe-role", name: "Software Engineer", prompt: "", toolIDs: ["read_file", "write_file"],
                    usePlanningPhase: false,
                    dependencies: RoleDependencies(requiredArtifacts: ["Plan"], producesArtifacts: ["Code"])
                ),
            ],
            artifacts: [],
            settings: TeamSettings.default,
            graphLayout: TeamGraphLayout()
        )
    }
}
