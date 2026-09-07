import XCTest
@testable import NanoTeams

@MainActor
final class MeetingParticipantResolverTests: XCTestCase {

    // MARK: - filterParticipants

    func testFilterParticipants_validBuiltInRoles_resolved() {
        let team = makeTeam()
        let (participants, rejected) = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["softwareEngineer", "techLead"],
            initiatingRole: .productManager,
            team: team,
            teamSettings: team.settings
        )
        XCTAssertEqual(participants.count, 2)
        XCTAssertTrue(rejected.isEmpty)
    }

    func testFilterParticipants_unknownRole_rejected() {
        let team = makeTeam()
        let (participants, rejected) = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["nonexistent_role"],
            initiatingRole: .productManager,
            team: team,
            teamSettings: team.settings
        )
        XCTAssertTrue(participants.isEmpty)
        XCTAssertEqual(rejected.count, 1)
        XCTAssertTrue(rejected[0].contains("unknown role"))
    }

    func testFilterParticipants_selfExcluded() {
        let team = makeTeam()
        let (participants, rejected) = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["productManager"],
            initiatingRole: .productManager,
            team: team,
            teamSettings: team.settings
        )
        XCTAssertTrue(participants.isEmpty)
        XCTAssertEqual(rejected.count, 1)
        XCTAssertTrue(rejected[0].contains("already a participant"),
                      "self-invitation is redundant, not wrong — handleTeamMeeting seats the initiator; got: \(rejected[0])")
    }

    /// The Supervisor is the human and never a meeting participant, whatever the settings
    /// say. `invitableRoles` is cleared so nothing but that rule can explain the rejection.
    /// Until 2026-09-07 a `supervisorCanBeInvited` seat let an LLM turn speak AS the
    /// Supervisor; the seat is gone and the rejection is unconditional.
    func testFilterParticipants_supervisor_rejectedUnconditionally() {
        let team = makeTeam()
        var settings = team.settings
        settings.invitableRoles = []  // no whitelist — only the Supervisor rule remains
        let (participants, rejected) = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["supervisor"],
            initiatingRole: .softwareEngineer,
            team: team,
            teamSettings: settings
        )
        XCTAssertTrue(participants.isEmpty)
        XCTAssertEqual(rejected.count, 1)
        XCTAssertTrue(rejected[0].contains("not a meeting participant"))
        XCTAssertTrue(rejected[0].hasPrefix("Supervisor"))
    }

    /// Without a team the membership check is skipped, and the Supervisor is still
    /// rejected by the built-in `.supervisor` identity alone.
    func testFilterParticipants_noTeam_supervisorStillRejected() {
        let (participants, rejected) = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["supervisor", "techLead"],
            initiatingRole: .softwareEngineer,
            team: nil,
            teamSettings: TeamSettings()
        )
        XCTAssertEqual(participants, [.techLead])
        XCTAssertEqual(rejected.count, 1)
        XCTAssertTrue(rejected[0].contains("not a meeting participant"))
    }

    func testFilterParticipants_notInInvitableRoles_rejected() {
        let team = makeTeam()
        let techLeadRole = team.roles.first { $0.systemRoleID == "techLead" }!
        var settings = team.settings
        settings.invitableRoles = Set([techLeadRole.id])
        let sweRole = team.roles.first { $0.systemRoleID == "softwareEngineer" }!
        let (participants, rejected) = MeetingParticipantResolver.filterParticipants(
            participantIDs: [sweRole.systemRoleID ?? sweRole.id],
            initiatingRole: .productManager,
            team: team,
            teamSettings: settings
        )
        XCTAssertTrue(participants.isEmpty)
        XCTAssertEqual(rejected.count, 1)
        XCTAssertTrue(rejected[0].contains("not in invitable"))
    }

    func testFilterParticipants_mixedValidAndInvalid() {
        let team = makeTeam()
        let (participants, rejected) = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["techLead", "nonexistent", "softwareEngineer"],
            initiatingRole: .productManager,
            team: team,
            teamSettings: team.settings
        )
        XCTAssertEqual(participants.count, 2)
        XCTAssertEqual(rejected.count, 1)
    }

    func testFilterParticipants_emptyList_returnsEmpty() {
        let team = makeTeam()
        let (participants, rejected) = MeetingParticipantResolver.filterParticipants(
            participantIDs: [],
            initiatingRole: .productManager,
            team: team,
            teamSettings: team.settings
        )
        XCTAssertTrue(participants.isEmpty)
        XCTAssertTrue(rejected.isEmpty)
    }

    // MARK: - availableTeammatesList

    func testAvailableTeammatesList_excludesSelf() {
        let team = makeTeam()
        let pmRole = team.roles.first { $0.systemRoleID == "productManager" }!
        let list = MeetingParticipantResolver.availableTeammatesList(
            team: team, teamSettings: team.settings, excludeRoleID: pmRole.systemRoleID ?? pmRole.id
        )
        XCTAssertFalse(list.contains("productManager"))
    }

    /// The Supervisor is never listed as a teammate — the roster it is dropped from is
    /// otherwise non-empty, so the omission is the rule and not an empty list.
    func testAvailableTeammatesList_neverListsSupervisor() {
        let team = makeTeam()
        let list = MeetingParticipantResolver.availableTeammatesList(
            team: team, teamSettings: team.settings, excludeRoleID: "softwareEngineer"
        )
        XCTAssertFalse(list.contains("supervisor"))
        XCTAssertNotEqual(list, "none")
        XCTAssertTrue(list.contains("productManager"))
    }

    func testAvailableTeammatesList_noTeam_usesBuiltInRoles() {
        let list = MeetingParticipantResolver.availableTeammatesList(
            team: nil, teamSettings: TeamSettings(), excludeRoleID: "supervisor"
        )
        XCTAssertFalse(list.contains("supervisor"))
        XCTAssertFalse(list.isEmpty)
        XCTAssertNotEqual(list, "none")
    }

    /// The no-team branch drops the Supervisor too — not merely when it is the requester.
    /// Until 2026-09-07 this branch listed every built-in id, the Supervisor included.
    func testAvailableTeammatesList_noTeam_dropsSupervisorEvenWhenNotTheRequester() {
        let list = MeetingParticipantResolver.availableTeammatesList(
            team: nil, teamSettings: TeamSettings(), excludeRoleID: "softwareEngineer"
        )
        XCTAssertFalse(list.contains("supervisor"))
        XCTAssertFalse(list.contains("softwareEngineer"))
        XCTAssertNotEqual(list, "none")
        XCTAssertTrue(list.contains("techLead"))
    }

    func testAvailableTeammatesList_allExcluded_returnsNone() {
        // Single-role team (only Supervisor + excluding everyone else)
        let team = makeTeam()
        var settings = team.settings
        settings.invitableRoles = Set(["nonexistent_role"])
        let sweRole = team.roles.first { $0.systemRoleID == "softwareEngineer" }!
        let list = MeetingParticipantResolver.availableTeammatesList(
            team: team, teamSettings: settings, excludeRoleID: sweRole.systemRoleID ?? sweRole.id
        )
        XCTAssertEqual(list, "none")
    }

    // MARK: - Helpers

    private func makeTeam() -> Team {
        Team.defaultTeams.first { $0.templateID == "faang" }!
    }
}
