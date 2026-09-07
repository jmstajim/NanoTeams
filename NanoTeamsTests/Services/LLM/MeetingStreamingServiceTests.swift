import XCTest
@testable import NanoTeams

@MainActor
final class MeetingStreamingServiceTests: XCTestCase {

    // MARK: - determineNextSpeaker — the coordinator opens, closes each round, and ends

    // Production shape since 2026-09-07: `handleTeamMeeting` seats the initiator at
    // index 0 (`TeamMeetingService.InitiatorSeat.speaks`) and appends the coordinator,
    // so the coordinator is INSIDE `participants`. `determineNextSpeaker` rotates over
    // the participants minus the coordinator, which is why the two fixtures right below
    // (coordinator outside the list) and production (inside) give the same sequence —
    // pinned by `…_coordinatorInsideOrOutside_sameSequence`.
    func testDetermineNextSpeaker_emptyMeeting_firstSpeakerIsCoordinator() {
        let participants: [Role] = [.techLead, .softwareEngineer]
        let meeting = TeamMeeting(topic: "T", initiatedBy: .productManager, participants: participants)
        let next = MeetingStreamingService.determineNextSpeaker(
            meeting: meeting, participants: participants, coordinator: .techLead, maxTurns: 10
        )
        XCTAssertEqual(next, .techLead, "empty meeting: the coordinator speaks first")
    }

    func testDetermineNextSpeaker_allSpoke_roundRobinReturnsToCoordinator() {
        let coordinator: Role = .productManager
        let participants: [Role] = [.techLead, .softwareEngineer]
        var meeting = TeamMeeting(topic: "T", initiatedBy: coordinator, participants: participants)
        for p in participants {
            meeting.addMessage(TeamMessage(
                id: UUID(), createdAt: MonotonicClock.shared.now(),
                role: p, content: "msg",
                messageType: .discussion
            ))
        }
        let next = MeetingStreamingService.determineNextSpeaker(
            meeting: meeting, participants: participants, coordinator: coordinator, maxTurns: 10
        )
        XCTAssertEqual(next, coordinator, "all spoke: the round-robin fallback returns to the coordinator")
    }

    /// The LAST turn under the limit is the coordinator's whatever the rotation says —
    /// that turn carries the `conclude_meeting` directive, and only the coordinator holds
    /// the tool. Here the rotation would otherwise hand turn 4 to the Software Engineer.
    func testDetermineNextSpeaker_lastTurnUnderTheLimit_isTheCoordinators() {
        let coordinator: Role = .productManager
        let participants: [Role] = [.techLead, .softwareEngineer]
        var meeting = TeamMeeting(topic: "T", initiatedBy: coordinator, participants: participants)
        for role in [coordinator, Role.techLead, Role.softwareEngineer] {
            meeting.addMessage(TeamMessage(role: role, content: "msg"))
        }
        // 3 turns taken; with maxTurns 4 the next one is the last.
        let rotation = MeetingStreamingService.determineNextSpeaker(
            meeting: meeting, participants: participants, coordinator: coordinator, maxTurns: 10
        )
        let last = MeetingStreamingService.determineNextSpeaker(
            meeting: meeting, participants: participants, coordinator: coordinator, maxTurns: 4
        )
        XCTAssertEqual(rotation, coordinator, "sanity: after a full round the coordinator is next anyway")
        meeting.addMessage(TeamMessage(role: coordinator, content: "round two"))
        let midRotation = MeetingStreamingService.determineNextSpeaker(
            meeting: meeting, participants: participants, coordinator: coordinator, maxTurns: 10
        )
        let forcedLast = MeetingStreamingService.determineNextSpeaker(
            meeting: meeting, participants: participants, coordinator: coordinator, maxTurns: 5
        )
        XCTAssertEqual(last, coordinator)
        XCTAssertEqual(midRotation, .techLead, "with room left, the rotation continues")
        XCTAssertEqual(forcedLast, coordinator, "turn 5 of 5 goes to the coordinator, not the rotation")
    }

    // MARK: - The coordinator inside the list: once per round, never twice

    /// Production shape since 2026-09-06: `handleTeamMeeting` appends the coordinator to
    /// `participants`, so the rotation window must be counted over the OTHERS. With the
    /// coordinator inside the list the old `suffix(participants.count)` window read
    /// `[coord, A]` as "A still pending? no — coord still pending? no" only AFTER a second
    /// coordinator message, so every round ended `…, A, coord, coord`: two coordinator
    /// turns back to back, one of them spent on nothing. Until 2026-09-07 these tests held
    /// the coordinator OUTSIDE the list and never saw it.
    ///
    /// RED: restore `suffix(participants.count)` over the unfiltered list → turn 3 answers
    /// the coordinator again instead of `.techLead`.
    func testDetermineNextSpeaker_coordinatorInsideParticipants_speaksOncePerRound() {
        let coordinator: Role = .productManager
        let participants: [Role] = [.techLead, coordinator]
        var meeting = TeamMeeting(topic: "T", initiatedBy: .techLead, participants: participants)
        var spoken: [Role] = []
        for _ in 0..<6 {
            let next = MeetingStreamingService.determineNextSpeaker(
                meeting: meeting, participants: participants, coordinator: coordinator, maxTurns: 100)
            spoken.append(next)
            meeting.addMessage(TeamMessage(role: next, content: "msg"))
        }
        XCTAssertEqual(spoken, [coordinator, .techLead, coordinator, .techLead, coordinator, .techLead],
                       "coordinator opens, the one other participant speaks, the coordinator closes — no doubled turn")
    }

    /// Lists with the coordinator inside and outside give the SAME sequence — the contract
    /// the two fixtures above (coordinator outside) and production (inside) both rely on.
    func testDetermineNextSpeaker_coordinatorInsideOrOutside_sameSequence() {
        let coordinator: Role = .productManager
        let outside: [Role] = [.techLead, .softwareEngineer]
        let inside: [Role] = [.techLead, .softwareEngineer, coordinator]
        func sequence(_ participants: [Role]) -> [Role] {
            var meeting = TeamMeeting(topic: "T", initiatedBy: .techLead, participants: participants)
            var spoken: [Role] = []
            for _ in 0..<7 {
                let next = MeetingStreamingService.determineNextSpeaker(
                    meeting: meeting, participants: participants, coordinator: coordinator, maxTurns: 100)
                spoken.append(next)
                meeting.addMessage(TeamMessage(role: next, content: "msg"))
            }
            return spoken
        }
        let expected: [Role] = [coordinator, .techLead, .softwareEngineer, coordinator, .techLead, .softwareEngineer, coordinator]
        XCTAssertEqual(sequence(outside), expected)
        XCTAssertEqual(sequence(inside), expected, "the coordinator's own seat in the list must not enter the rotation")
    }

    /// The initiator is inserted at index 0 of `participants` by `handleTeamMeeting`
    /// (`InitiatorSeat.speaks`), so it speaks right after the coordinator's opening — the
    /// meeting is its topic — and the invited roles follow in invitation order.
    func testDetermineNextSpeaker_initiatorFirstAfterTheOpening() {
        let coordinator: Role = .productManager
        let initiator: Role = .softwareEngineer
        let participants: [Role] = [initiator, .techLead, coordinator]
        var meeting = TeamMeeting(topic: "T", initiatedBy: initiator, participants: participants)
        var spoken: [Role] = []
        for _ in 0..<5 {
            let next = MeetingStreamingService.determineNextSpeaker(
                meeting: meeting, participants: participants, coordinator: coordinator, maxTurns: 100)
            spoken.append(next)
            meeting.addMessage(TeamMessage(role: next, content: "msg"))
        }
        XCTAssertEqual(spoken, [coordinator, initiator, .techLead, coordinator, initiator])
    }

    /// Only the coordinator in the list (a `request_changes` vote whose sole voter is the
    /// coordinator): every turn is the coordinator's, and the empty rotation must not trap
    /// on `suffix(0)`.
    func testDetermineNextSpeaker_onlyTheCoordinator_everyTurnIsTheCoordinators() {
        let coordinator: Role = .productManager
        var meeting = TeamMeeting(topic: "T", initiatedBy: .softwareEngineer, participants: [coordinator])
        for _ in 0..<3 {
            let next = MeetingStreamingService.determineNextSpeaker(
                meeting: meeting, participants: [coordinator], coordinator: coordinator, maxTurns: 100)
            XCTAssertEqual(next, coordinator)
            meeting.addMessage(TeamMessage(role: next, content: "msg"))
        }
    }

    // MARK: - The speaker's system prompt reads the MEETING body, else the step prompt

    private func context(team: Team) -> TeamMeetingService.MeetingContext {
        TeamMeetingService.MeetingContext(
            initiatedBy: .productManager, participants: [.techLead, .softwareEngineer],
            availableArtifacts: [], artifactReader: { _ in nil }, team: team,
            coordinatorRole: .techLead, limits: .default)
    }

    func testSpeakerSystemPrompt_usesTheMeetingBody_notTheStepPrompt() throws {
        let faang = try XCTUnwrap(Team.defaultTeams.first { $0.templateID == "faang" })
        let pm = try XCTUnwrap(faang.roles.first { $0.systemRoleID == "productManager" })
        let body = try XCTUnwrap(pm.meetingGuidance)
        let stepOnly = try XCTUnwrap(pm.prompt.split(separator: "\n").first.map(String.init))
        let meeting = TeamMeeting(topic: "T", initiatedBy: .productManager, participants: [.techLead])
        let system = MeetingStreamingService.buildMeetingMessages(
            speaker: .productManager, meeting: meeting, context: context(team: faang)).first?.content ?? ""
        XCTAssertTrue(system.contains(body.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertFalse(system.contains(stepOnly), "the step prompt names create_artifact — a tool the meeting turn does not hold")
    }

    func testSpeakerSystemPrompt_fallsBackToTheDerivedStance_whenNoBodyIsAuthored() throws {
        var faang = try XCTUnwrap(Team.defaultTeams.first { $0.templateID == "faang" })
        let i = try XCTUnwrap(faang.roles.firstIndex { $0.systemRoleID == "techLead" })
        faang.roles[i].meetingGuidance = nil
        let stance = SystemTemplates.meetingStance(derivedFrom: faang.roles[i].prompt)
        let meeting = TeamMeeting(topic: "T", initiatedBy: .productManager, participants: [.techLead])
        let system = MeetingStreamingService.buildMeetingMessages(
            speaker: .techLead, meeting: meeting, context: context(team: faang)).first?.content ?? ""
        XCTAssertTrue(system.contains(stance),
                      "no authored body ⇒ the stance derived from the step prompt, not the step prompt (R3.1.1)")
        XCTAssertFalse(system.contains(faang.roles[i].prompt),
                       "the step contract — deliverables, tools it does not hold here — never rides a meeting turn")
    }
}
