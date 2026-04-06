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
        XCTAssertTrue(rejected[0].contains("initiator"))
    }

    func testFilterParticipants_supervisorNotInvitable_rejected() {
        let team = makeTeam()
        var settings = team.settings
        settings.supervisorCanBeInvited = false
        let (participants, rejected) = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["supervisor"],
            initiatingRole: .softwareEngineer,
            team: team,
            teamSettings: settings
        )
        XCTAssertTrue(participants.isEmpty)
        XCTAssertEqual(rejected.count, 1)
        XCTAssertTrue(rejected[0].contains("not invitable"))
    }

    func testFilterParticipants_supervisorInvitable_accepted() {
        let team = makeTeam()
        var settings = team.settings
        settings.supervisorCanBeInvited = true
        settings.invitableRoles = []  // Clear to allow all roles
        let (participants, rejected) = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["supervisor"],
            initiatingRole: .softwareEngineer,
            team: team,
            teamSettings: settings
        )
        XCTAssertEqual(participants.count, 1)
        XCTAssertTrue(rejected.isEmpty)
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

    func testAvailableTeammatesList_excludesSupervisorWhenNotInvitable() {
        let team = makeTeam()
        var settings = team.settings
        settings.supervisorCanBeInvited = false
        let list = MeetingParticipantResolver.availableTeammatesList(
            team: team, teamSettings: settings, excludeRoleID: "softwareEngineer"
        )
        XCTAssertFalse(list.contains("supervisor"))
    }

    func testAvailableTeammatesList_noTeam_usesBuiltInRoles() {
        let list = MeetingParticipantResolver.availableTeammatesList(
            team: nil, teamSettings: TeamSettings(), excludeRoleID: "supervisor"
        )
        XCTAssertFalse(list.contains("supervisor"))
        XCTAssertFalse(list.isEmpty)
        XCTAssertNotEqual(list, "none")
    }

    func testAvailableTeammatesList_allExcluded_returnsNone() {
        // Single-role team (only Supervisor + excluding everyone else)
        let team = makeTeam()
        var settings = team.settings
        settings.invitableRoles = Set(["nonexistent_role"])
        settings.supervisorCanBeInvited = false
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
