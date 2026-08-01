import XCTest
@testable import NanoTeams

/// Pins that every reader of `team.settings.meetingCoordinatorRoleID`
/// agrees on the orphan-self-heal contract under the same `Team` snapshot:
///
///   1. Picker UI       — `MeetingCoordinatorPickerLogic.normalizedSelection`
///   2. Editor list   — `RoleToolBadgePolicy.model(...).autoInjected`
///                         (via internal `DesignatedCoordinatorResolver.normalize`)
///   3. Schema-build    — `LLMExecutionService+ToolResolution` step 6
///                         (via internal `DesignatedCoordinatorResolver.normalize`)
///   4. Runtime         — `LLMExecutionService.resolveCoordinatorRole`
///                         (funneled through `DesignatedCoordinatorResolver.normalize`)
///
/// If any reader diverges, the consequence is a UI/runtime/schema discrepancy
/// like the round-3 review C2.1 bug — picker shows "Auto", runtime self-heals
/// to initiator-as-coordinator, but schema-build silently denies
/// `conclude_meeting` because it read the raw orphan ID. Round-3 closed that
/// by funneling all four readers through `DesignatedCoordinatorResolver.normalize`;
/// this test guards against future divergence.
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

    // MARK: - Helpers

    private func makeTeam(coordID: String?) -> Team {
        Team(
            name: "T",
            roles: [supervisor, live],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: coordID),
            graphLayout: TeamGraphLayout()
        )
    }

    /// Pure-logic resolution from the picker UI's perspective.
    private func pickerResolves(team: Team) -> String? {
        let nonSupervisorRoleIDs = team.roles.filter { !$0.isSupervisor }.map(\.id)
        return MeetingCoordinatorPickerLogic.normalizedSelection(
            stored: team.settings.meetingCoordinatorRoleID,
            availableIDs: nonSupervisorRoleIDs
        )
    }

    /// Pure-logic resolution from the predicate's perspective — emulates the
    /// orphan-normalize step `fromEditorContext` performs before evaluating.
    private func predicateResolves(team: Team) -> String? {
        DesignatedCoordinatorResolver.normalize(
            storedID: team.settings.meetingCoordinatorRoleID,
            availableIDs: team.roles.filter { !$0.isSupervisor }.map(\.id)
        )
    }

    /// Pure-logic resolution from the schema-build's perspective.
    private func schemaResolves(team: Team) -> String? {
        DesignatedCoordinatorResolver.normalize(
            storedID: team.settings.meetingCoordinatorRoleID,
            availableIDs: team.roles.filter { !$0.isSupervisor }.map(\.id)
        )
    }

    /// Runtime resolution — yields the role ID portion of the resolved `Role?`.
    private func runtimeResolves(team: Team) -> String? {
        let service = LLMExecutionService(repository: NTMSRepository())
        return service.resolveCoordinatorRole(team: team)?.baseID
    }

    private func assertAllAgree(
        on team: Team,
        expectedNormalizedID: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(pickerResolves(team: team), expectedNormalizedID,
                       "picker disagrees", file: file, line: line)
        XCTAssertEqual(predicateResolves(team: team), expectedNormalizedID,
                       "predicate disagrees", file: file, line: line)
        XCTAssertEqual(schemaResolves(team: team), expectedNormalizedID,
                       "schema-build disagrees", file: file, line: line)
        XCTAssertEqual(runtimeResolves(team: team), expectedNormalizedID,
                       "runtime disagrees", file: file, line: line)
    }

    // MARK: - Consistency across all 4 readers

    func testAllReaders_agreeOnNilCoord_Auto() {
        assertAllAgree(on: makeTeam(coordID: nil), expectedNormalizedID: nil)
    }

    func testAllReaders_agreeOnLiveCoord() {
        assertAllAgree(on: makeTeam(coordID: "live"), expectedNormalizedID: "live")
    }

    func testAllReaders_agreeOnOrphanCoord_collapsedToNil() {
        assertAllAgree(on: makeTeam(coordID: "ghost-of-deleted-role"),
                       expectedNormalizedID: nil)
    }

    func testAllReaders_agreeOnSupervisorAsCoord_rejected() {
        // Supervisor ID is structurally invalid as a coordinator — every
        // reader filters Supervisor out of `availableIDs` so the stored ID
        // becomes orphan-like and self-heals to nil.
        assertAllAgree(on: makeTeam(coordID: "sup"), expectedNormalizedID: nil)
    }

    func testAllReaders_agreeOnEmptyStoredCoord_collapsedToNil() {
        assertAllAgree(on: makeTeam(coordID: ""), expectedNormalizedID: nil)
    }
}
