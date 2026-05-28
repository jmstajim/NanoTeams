import XCTest
@testable import NanoTeams

@MainActor
final class MeetingStreamingServiceTests: XCTestCase {

    // MARK: - determineNextSpeaker — Auto mode (initiator is the effective coordinator)

    // Production-fidelity fixture: `MeetingParticipantResolver.filterParticipants`
    // strips the initiator from `participants`, so in Auto mode the initiator-
    // as-coordinator is NOT a member of the `participants` list passed here.
    // (Round-2 review code-reviewer S1.)
    func testDetermineNextSpeaker_initiatorAsCoordinator_firstSpeakerIsInitiator() {
        let initiator: Role = .productManager
        let participantsExclInitiator: [Role] = [.techLead, .softwareEngineer]
        let meeting = TeamMeeting(
            topic: "T",
            initiatedBy: initiator,
            participants: participantsExclInitiator
        )
        let next = MeetingStreamingService.determineNextSpeaker(
            meeting: meeting, participants: participantsExclInitiator, coordinator: initiator
        )
        XCTAssertEqual(next, initiator,
                       "Auto mode + empty meeting: initiator-as-coordinator speaks first")
    }

    func testDetermineNextSpeaker_initiatorAsCoordinator_roundRobinFallbackIsInitiator() {
        let initiator: Role = .productManager
        let participantsExclInitiator: [Role] = [.techLead, .softwareEngineer]
        var meeting = TeamMeeting(
            topic: "T",
            initiatedBy: initiator,
            participants: participantsExclInitiator
        )
        // All participants spoke once → round-robin fallback fires and
        // returns to the coordinator (= initiator in Auto mode).
        for p in participantsExclInitiator {
            meeting.addMessage(TeamMessage(
                id: UUID(), createdAt: MonotonicClock.shared.now(),
                role: p, content: "msg",
                messageType: .discussion
            ))
        }
        let next = MeetingStreamingService.determineNextSpeaker(
            meeting: meeting, participants: participantsExclInitiator, coordinator: initiator
        )
        XCTAssertEqual(next, initiator,
                       "Auto mode + all-spoke: fallback returns the initiator-as-coordinator")
    }

    // MARK: - determineNextSpeaker — designated coordinator

    // Same production fidelity: when a designated coordinator is set AND is
    // NOT the initiator, the coordinator IS a regular participant.
    func testDetermineNextSpeaker_coordinatorSet_firstSpeakerIsCoordinator() {
        let participants: [Role] = [.techLead, .softwareEngineer]
        let meeting = TeamMeeting(
            topic: "T",
            initiatedBy: .productManager,
            participants: participants
        )
        let next = MeetingStreamingService.determineNextSpeaker(
            meeting: meeting, participants: participants, coordinator: .techLead
        )
        XCTAssertEqual(next, .techLead,
                       "Designated-coordinator mode + empty meeting: coordinator speaks first")
    }
}
