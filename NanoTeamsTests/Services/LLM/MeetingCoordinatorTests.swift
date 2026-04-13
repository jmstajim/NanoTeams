import XCTest
@testable import NanoTeams

@MainActor
final class MeetingCoordinatorTests: XCTestCase {

    private typealias TN = ToolNames

    // MARK: - meetingExcludedTools

    func testMeetingExcludedTools_containsAllCollaborativeTools() {
        let excluded = MeetingCoordinator.meetingExcludedTools
        XCTAssertTrue(excluded.contains(TN.askTeammate))
        XCTAssertTrue(excluded.contains(TN.requestTeamMeeting))
        XCTAssertTrue(excluded.contains(TN.concludeMeeting))
        XCTAssertTrue(excluded.contains(TN.askSupervisor))
        XCTAssertTrue(excluded.contains(TN.requestChanges))
        XCTAssertTrue(excluded.contains(TN.createArtifact))
        XCTAssertTrue(excluded.contains(TN.analyzeImage))
        XCTAssertTrue(excluded.contains(TN.createTeam))
        XCTAssertEqual(excluded.count, 8)
    }

    // MARK: - filterMeetingTools

    func testFilterMeetingTools_removesExcludedTools() {
        let tools = [
            makeSchema(TN.readFile),
            makeSchema(TN.askTeammate),
            makeSchema(TN.gitStatus),
            makeSchema(TN.requestTeamMeeting),
        ]
        let filtered = MeetingCoordinator.filterMeetingTools(tools)
        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(filtered.map(\.name), [TN.readFile, TN.gitStatus])
    }

    func testFilterMeetingTools_keepsNonExcludedTools() {
        let tools = [makeSchema(TN.readFile), makeSchema(TN.editFile), makeSchema(TN.listFiles)]
        let filtered = MeetingCoordinator.filterMeetingTools(tools)
        XCTAssertEqual(filtered.count, 3)
    }

    func testFilterMeetingTools_emptyInput_returnsEmpty() {
        let filtered = MeetingCoordinator.filterMeetingTools([])
        XCTAssertTrue(filtered.isEmpty)
    }

    func testFilterMeetingTools_allExcluded_returnsEmpty() {
        let tools = [makeSchema(TN.askTeammate), makeSchema(TN.createArtifact)]
        let filtered = MeetingCoordinator.filterMeetingTools(tools)
        XCTAssertTrue(filtered.isEmpty)
    }

    // MARK: - buildTurnMessage

    func testBuildTurnMessage_includesTopicAndParticipants() {
        let (meeting, context) = makeMeetingAndContext(topic: "Design review")
        let msg = MeetingCoordinator.buildTurnMessage(
            speaker: .techLead,
            meeting: meeting,
            context: context
        )
        XCTAssertTrue(msg.contains("Design review"))
        XCTAssertTrue(msg.contains("TEAM MEETING"))
        XCTAssertTrue(msg.contains("END MEETING CONTEXT"))
    }

    func testBuildTurnMessage_includesAdditionalContext() {
        var (meeting, context) = makeMeetingAndContext(topic: "API design")
        meeting.context = "We need to decide on REST vs GraphQL"
        let msg = MeetingCoordinator.buildTurnMessage(
            speaker: .techLead,
            meeting: meeting,
            context: context
        )
        XCTAssertTrue(msg.contains("REST vs GraphQL"))
    }

    func testBuildTurnMessage_noMessages_noDiscussionSection() {
        let (meeting, context) = makeMeetingAndContext(topic: "First topic")
        let msg = MeetingCoordinator.buildTurnMessage(
            speaker: .techLead,
            meeting: meeting,
            context: context
        )
        XCTAssertFalse(msg.contains("Discussion so far"))
    }

    func testBuildTurnMessage_withMessages_includesDiscussion() {
        var (meeting, context) = makeMeetingAndContext(topic: "Topic")
        meeting.addMessage(TeamMessage(
            id: UUID(), createdAt: MonotonicClock.shared.now(),
            role: .productManager, content: "I think we should...",
            messageType: .proposal
        ))
        let msg = MeetingCoordinator.buildTurnMessage(
            speaker: .techLead,
            meeting: meeting,
            context: context
        )
        XCTAssertTrue(msg.contains("Discussion so far"))
        XCTAssertTrue(msg.contains("I think we should..."))
    }

    func testBuildTurnMessage_coordinatorNearEnd_wrapUpMessage() {
        let limits = TeamLimits(maxMeetingTurns: 6)
        var (meeting, context) = makeMeetingAndContext(topic: "Topic", limits: limits)
        // Add 4 messages so turnCount=4, next turn=5, maxTurns-2=4 → wrap up
        for _ in 0..<4 {
            meeting.addMessage(TeamMessage(
                id: UUID(), createdAt: MonotonicClock.shared.now(),
                role: .productManager, content: "msg",
                messageType: .discussion
            ))
        }
        let msg = MeetingCoordinator.buildTurnMessage(
            speaker: context.coordinatorRole,
            meeting: meeting,
            context: context
        )
        XCTAssertTrue(msg.contains("WRAP UP NOW"))
    }

    func testBuildTurnMessage_nonCoordinator_genericMessage() {
        let (meeting, context) = makeMeetingAndContext(topic: "Topic")
        let msg = MeetingCoordinator.buildTurnMessage(
            speaker: .softwareEngineer,
            meeting: meeting,
            context: context
        )
        XCTAssertTrue(msg.contains("Be concise and focused"))
    }

    func testBuildTurnMessage_discussionClub_concisenessVaries() {
        let limits = TeamLimits(maxMeetingTurns: 10)
        var (meeting, context) = makeMeetingAndContext(
            topic: "Discussion", limits: limits, templateID: "discussionClub"
        )
        // Early turn (0 messages, turnNumber=1): "3-5 sentences"
        let earlyMsg = MeetingCoordinator.buildTurnMessage(
            speaker: .theAgreeable, meeting: meeting, context: context
        )
        XCTAssertTrue(earlyMsg.contains("3-5 sentences"))

        // Late turn: add enough messages for final remarks
        for _ in 0..<8 {
            meeting.addMessage(TeamMessage(
                id: UUID(), createdAt: MonotonicClock.shared.now(),
                role: .theAgreeable, content: "m",
                messageType: .discussion
            ))
        }
        let lateMsg = MeetingCoordinator.buildTurnMessage(
            speaker: .theAgreeable, meeting: meeting, context: context
        )
        XCTAssertTrue(lateMsg.contains("Final remarks only"))
    }

    // MARK: - Helpers

    private func makeSchema(_ name: String) -> ToolSchema {
        ToolSchema(name: name, description: "test", parameters: .object(properties: [:]))
    }

    private func makeMeetingAndContext(
        topic: String,
        limits: TeamLimits = .default,
        templateID: String? = nil
    ) -> (TeamMeeting, TeamMeetingService.MeetingContext) {
        let meeting = TeamMeeting(
            topic: topic,
            initiatedBy: .productManager,
            participants: [.productManager, .techLead, .softwareEngineer]
        )
        var team = Team.defaultTeams.first { $0.templateID == "faang" }!
        if let tid = templateID {
            team.templateID = tid
        }
        let context = TeamMeetingService.MeetingContext(
            topic: topic,
            initiatedBy: .productManager,
            participants: [.productManager, .techLead, .softwareEngineer],
            additionalContext: nil,
            task: NTMSTask(id: 0, title: "Test", supervisorTask: "Test goal"),
            availableArtifacts: [],
            artifactReader: { _ in nil },
            team: team,
            coordinatorRole: .productManager,
            limits: limits
        )
        return (meeting, context)
    }
}
