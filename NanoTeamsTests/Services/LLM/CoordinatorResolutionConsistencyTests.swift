import XCTest
@testable import NanoTeams

/// Pins that every reader of the meeting coordinator agrees under the same `Team`
/// snapshot, and that none of them ever answers "Auto":
///
///   1. Picker UI    — `MeetingCoordinatorPickerLogic.selection(for:)`
///   2. Editor badge — `RoleToolBadgePolicy.model(..., approval: .available).meetingOnly` (the coordinator's
///                     `conclude_meeting`)
///   3. Meeting turn — `MeetingCoordinator.speakerTools` for the coordinator
///   4. Runtime      — `LLMExecutionService.resolveCoordinatorRole`
///
/// All four resolve through `Team.meetingCoordinatorID`. Until 2026-09-06 a `nil` or
/// orphan id meant "Auto" (the initiator coordinates), and the readers disagreed about
/// it once — the picker showed "Auto", the runtime promoted the initiator, and the
/// schema build silently gave `conclude_meeting` to nobody. There is no Auto now: a
/// team with a role always has a coordinator, chosen by `TeamSettings.defaultCoordinatorID`
/// when the stored id does not resolve.
@MainActor
final class CoordinatorResolutionConsistencyTests: XCTestCase {

    private let supervisor = TeamRoleDefinition(
        id: "sup",
        name: "Supervisor",
        prompt: "",
        toolIDs: [],
        usePlanningPhase: false,
        dependencies: RoleDependencies(),
        systemRoleID: "supervisor"
    )
    private let live = TeamRoleDefinition(
        id: "live",
        name: "Live Role",
        prompt: "p",
        toolIDs: [ToolNames.requestTeamMeeting],
        usePlanningPhase: false,
        dependencies: RoleDependencies()
    )
    private let other = TeamRoleDefinition(
        id: "other",
        name: "Other Role",
        prompt: "p",
        toolIDs: [ToolNames.readFile],
        usePlanningPhase: false,
        dependencies: RoleDependencies()
    )

    // MARK: - Helpers

    private func makeTeam(coordID: String?) -> Team {
        Team(
            name: "T",
            roles: [supervisor, other, live],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: coordID),
            graphLayout: TeamGraphLayout()
        )
    }

    private func pickerResolves(team: Team) -> String? {
        MeetingCoordinatorPickerLogic.selection(for: team)
    }

    /// The editor badge's view: the role whose `meetingOnly` carries `conclude_meeting`.
    private func badgeResolves(team: Team) -> String? {
        team.roles.first { role in
            RoleToolBadgePolicy.model(
                role: role, team: team, allTeams: [team], storage: .defaultStorage,
                selectedScheme: nil, isVisionConfigured: false, approval: ToolApprovalAvailability(bash: .available, computerUse: .withheld(.switchedOff)),
                autovisorTeamPolicy: .unrestricted
            ).meetingOnly.contains(ToolNames.concludeMeeting)
        }?.id
    }

    /// The meeting turn's view: the role whose speaker tools carry `conclude_meeting`.
    private func meetingTurnResolves(team: Team) -> String? {
        team.roles.first { role in
            MeetingCoordinator.speakerTools(
                base: [], isCoordinator: team.meetingCoordinatorID == role.id
            ).contains { $0.name == ToolNames.concludeMeeting }
        }?.id
    }

    /// Resolved back to the role-definition id, which is what the other three readers
    /// return. `Role.baseID` is a REPRESENTATION — `.custom(id: name)` for a user-authored
    /// role since the chair and the participant resolver were unified on
    /// `Role.fromDefinition` — and comparing representations across readers that legitimately
    /// hold different ones is what `findRole(byIdentifier:)` exists to avoid.
    private func runtimeResolves(team: Team) -> String? {
        let service = LLMExecutionService(repository: NTMSRepository())
        guard let role = service.resolveCoordinatorRole(team: team) else { return nil }
        return team.findRole(byIdentifier: role.baseID)?.id
    }

    private func assertAllAgree(
        on team: Team,
        expectedID: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(pickerResolves(team: team), expectedID, "picker disagrees", file: file, line: line)
        XCTAssertEqual(badgeResolves(team: team), expectedID, "badge disagrees", file: file, line: line)
        XCTAssertEqual(meetingTurnResolves(team: team), expectedID, "meeting turn disagrees", file: file, line: line)
        XCTAssertEqual(runtimeResolves(team: team), expectedID, "runtime disagrees", file: file, line: line)
    }

    // MARK: - Consistency across all 4 readers

    func testAllReaders_agreeOnLiveCoord() {
        assertAllAgree(on: makeTeam(coordID: "other"), expectedID: "other")
    }

    /// `nil` is not Auto: the default rule picks the first role that can START a
    /// meeting — `live` holds `request_team_meeting`, `other` (listed first) does not.
    func testAllReaders_agreeOnNilCoord_defaultRulePrefersAMeetingStarter() {
        assertAllAgree(on: makeTeam(coordID: nil), expectedID: "live")
    }

    func testAllReaders_agreeOnOrphanCoord_healedToTheDefaultRule() {
        assertAllAgree(on: makeTeam(coordID: "ghost-of-deleted-role"), expectedID: "live")
    }

    /// The Supervisor is the human — structurally never a coordinator; the stored id
    /// is treated like an orphan and heals to the default rule.
    func testAllReaders_agreeOnSupervisorAsCoord_healedToTheDefaultRule() {
        assertAllAgree(on: makeTeam(coordID: "sup"), expectedID: "live")
    }

    func testAllReaders_agreeOnEmptyStoredCoord_healedToTheDefaultRule() {
        assertAllAgree(on: makeTeam(coordID: ""), expectedID: "live")
    }

    /// No non-Supervisor role ⇒ nobody to coordinate; every reader answers `nil` and
    /// none fabricates one.
    func testAllReaders_agreeOnRolelessTeam_nil() {
        let team = Team(
            name: "T", roles: [supervisor], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: nil),
            graphLayout: TeamGraphLayout()
        )
        assertAllAgree(on: team, expectedID: nil)
    }
}
