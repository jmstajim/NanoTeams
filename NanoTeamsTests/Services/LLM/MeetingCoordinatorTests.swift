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
        XCTAssertTrue(excluded.contains(TN.delegateToTeam))
        XCTAssertTrue(excluded.contains(TN.cancelDelegation))
        XCTAssertTrue(excluded.contains(TN.resumeDelegation))
        XCTAssertTrue(excluded.contains(TN.forwardToTeam))
        // Autovisor management tools (all excludedInMeetings).
        XCTAssertTrue(excluded.contains(TN.listTasks))
        XCTAssertTrue(excluded.contains(TN.taskStatus))
        XCTAssertTrue(excluded.contains(TN.createManagedTask))
        XCTAssertTrue(excluded.contains(TN.controlTask))
        XCTAssertTrue(excluded.contains(TN.manageRole))
        XCTAssertTrue(excluded.contains(TN.answerTaskQuestion))
        XCTAssertTrue(excluded.contains(TN.messageTask))
        XCTAssertTrue(excluded.contains(TN.scheduleTask))
        XCTAssertTrue(excluded.contains(TN.setWorkFolderContext))
        XCTAssertTrue(excluded.contains(TN.waitForEvents))
        // Shell tools run a login shell — never available in a meeting turn.
        XCTAssertTrue(excluded.contains(TN.bash))
        XCTAssertTrue(excluded.contains(TN.bashOutput))
        XCTAssertEqual(excluded.count, 24)
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
        XCTAssertTrue(msg.contains("## Team meeting"))
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

    // MARK: - buildTurnMessage: Auto mode (initiator IS the coordinator)

    // Auto mode is normalized at the call site — the meeting context's
    // `coordinatorRole` is set to the initiating role when no coordinator is
    // designated. The initiator therefore receives mid-meeting steering and
    // wrap-up prompts on the same turn-threshold rules as a designated
    // coordinator would.
    func testBuildTurnMessage_autoMode_initiatorAsCoordinator_getsSteering() {
        // maxTurns=6 → steering at turn ≥ maxTurns/2 = 3, wrap-up at turn ≥ maxTurns-2 = 4.
        let limits = TeamLimits(maxMeetingTurns: 6)
        let initiator: Role = .productManager
        var (meeting, context) = makeMeetingAndContext(
            topic: "Auto-mode topic", limits: limits, coordinator: initiator
        )

        // Turn 1 (empty meeting) — generic input branch (coordinator gets
        // steering only past half-way, not at turn 1).
        let turn1 = MeetingCoordinator.buildTurnMessage(
            speaker: initiator, meeting: meeting, context: context
        )
        XCTAssertFalse(turn1.contains("WRAP UP"))
        XCTAssertFalse(turn1.contains("As coordinator"))

        // Mid-meeting (turnNumber = 2+1 = 3, ≥ maxTurns/2 and < maxTurns-2)
        // — initiator-as-coordinator gets the steering hint, no wrap-up yet.
        for _ in 0..<2 {
            meeting.addMessage(TeamMessage(
                id: UUID(), createdAt: MonotonicClock.shared.now(),
                role: initiator, content: "msg",
                messageType: .discussion
            ))
        }
        let turnMid = MeetingCoordinator.buildTurnMessage(
            speaker: initiator, meeting: meeting, context: context
        )
        XCTAssertTrue(turnMid.contains("As coordinator"),
                      "Auto-mode initiator must receive coordinator steering past half-way")
        XCTAssertFalse(turnMid.contains("WRAP UP"),
                       "Wrap-up must NOT fire until last-2 turns")

        // Last-2 turns (turnNumber = 3+1 = 4, ≥ maxTurns-2) — wrap-up kicks in.
        meeting.addMessage(TeamMessage(
            id: UUID(), createdAt: MonotonicClock.shared.now(),
            role: initiator, content: "msg",
            messageType: .discussion
        ))
        let turnLate = MeetingCoordinator.buildTurnMessage(
            speaker: initiator, meeting: meeting, context: context
        )
        XCTAssertTrue(turnLate.contains("WRAP UP"),
                      "Auto-mode initiator must receive WRAP UP at last-2 turns")
    }

    // A non-initiator participant must NOT receive coordinator-specific
    // prompts in Auto mode (only the initiator-as-coordinator does).
    func testBuildTurnMessage_autoMode_nonInitiator_getsGenericPrompt() {
        let limits = TeamLimits(maxMeetingTurns: 6)
        let initiator: Role = .productManager
        var (meeting, context) = makeMeetingAndContext(
            topic: "Auto-mode topic", limits: limits, coordinator: initiator
        )
        // Push past half-way to ensure the test would catch a leaking steering hint
        for _ in 0..<3 {
            meeting.addMessage(TeamMessage(
                id: UUID(), createdAt: MonotonicClock.shared.now(),
                role: initiator, content: "msg",
                messageType: .discussion
            ))
        }
        let msg = MeetingCoordinator.buildTurnMessage(
            speaker: .softwareEngineer, meeting: meeting, context: context
        )
        XCTAssertTrue(msg.contains("Provide your input"))
        XCTAssertFalse(msg.contains("WRAP UP"))
        XCTAssertFalse(msg.contains("As coordinator"))
    }

    // MARK: - Helpers

    private func makeSchema(_ name: String) -> ToolSchema {
        ToolSchema(name: name, description: "test", parameters: .object(properties: [:]))
    }

    private func makeMeetingAndContext(
        topic: String,
        limits: TeamLimits = .default,
        templateID: String? = nil,
        coordinator: Role = .productManager
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
            coordinatorRole: coordinator,
            limits: limits
        )
        return (meeting, context)
    }
}
