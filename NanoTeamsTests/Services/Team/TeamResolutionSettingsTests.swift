import XCTest

@testable import NanoTeams

/// Pins `TeamResolution.teamSettings(for:in:)` — the resolver `StatusRecoveryService`'s
/// acceptance gate is built from.
///
/// Every bundled team is `.finalOnly`, so an integration test cannot tell "resolved the
/// right team" from "resolved SOME team". These drive the resolver directly with teams
/// whose modes differ, which is the only way to see a mis-resolution.
final class TeamResolutionSettingsTests: XCTestCase {

    private func makeTeam(id: NTMSID, mode: AcceptanceMode, checkpoints: Set<String> = []) -> Team {
        Team(
            id: id,
            name: "Team \(id)",
            roles: [],
            artifacts: [],
            settings: TeamSettings(defaultAcceptanceMode: mode, acceptanceCheckpoints: checkpoints),
            graphLayout: TeamGraphLayout()
        )
    }

    private func makeProjection(teams: [Team], activeTeamID: NTMSID?) -> WorkFolderProjection {
        WorkFolderProjection(
            state: WorkFolderState(name: "WF", activeTeamID: activeTeamID),
            settings: ProjectSettings(),
            teams: teams
        )
    }

    private func makeTask(preferredTeamID: NTMSID? = nil, runTeamID: NTMSID? = nil) -> NTMSTask {
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "goal", preferredTeamID: preferredTeamID)
        if let runTeamID {
            task.runs = [Run(id: 0, steps: [], roleStatuses: [:], teamID: runTeamID)]
        }
        return task
    }

    // MARK: - Resolution order

    /// The PIN wins: once a run exists, its `teamID` is authoritative — the acceptance
    /// gate must not swap under a live run any more than the roster may.
    func testRunPinnedTeam_winsOverPreferredAndActive() {
        let pinned = makeTeam(id: "pinned", mode: .finalOnly)
        let preferred = makeTeam(id: "preferred", mode: .afterEachRole)
        let active = makeTeam(id: "active", mode: .afterEachArtifact)
        let projection = makeProjection(teams: [pinned, preferred, active], activeTeamID: "active")
        let task = makeTask(preferredTeamID: "preferred", runTeamID: "pinned")

        XCTAssertEqual(
            TeamResolution.teamSettings(for: task, in: projection)?.defaultAcceptanceMode,
            .finalOnly
        )
    }

    func testPreferredTeam_usedWhenRunHasNoPin() {
        let preferred = makeTeam(id: "preferred", mode: .afterEachRole)
        let active = makeTeam(id: "active", mode: .finalOnly)
        let projection = makeProjection(teams: [preferred, active], activeTeamID: "active")

        XCTAssertEqual(
            TeamResolution.teamSettings(for: makeTask(preferredTeamID: "preferred"), in: projection)?
                .defaultAcceptanceMode,
            .afterEachRole
        )
    }

    func testActiveTeam_isTheRootFallback() {
        let active = makeTeam(id: "active", mode: .afterEachArtifact)
        let projection = makeProjection(teams: [active], activeTeamID: "active")

        XCTAssertEqual(
            TeamResolution.teamSettings(for: makeTask(), in: projection)?.defaultAcceptanceMode,
            .afterEachArtifact
        )
    }

    func testCheckpointsRideAlong() {
        let team = makeTeam(id: "t", mode: .customCheckpoints, checkpoints: ["eng"])
        let projection = makeProjection(teams: [team], activeTeamID: "t")

        let settings = TeamResolution.teamSettings(for: makeTask(), in: projection)

        XCTAssertEqual(settings?.acceptanceCheckpoints, ["eng"])
    }

    // MARK: - nil, not a substitute

    /// A run pinned to a DELETED team must not borrow another team's acceptance mode —
    /// that is precisely what `NTMSOrchestrator.resolvedTeam(for:)`'s display-oriented
    /// `?? activeTeam ?? .default` coalescing would do.
    func testPinnedTeamDeleted_returnsNil_ratherThanBorrowingActive() {
        let active = makeTeam(id: "active", mode: .afterEachArtifact)
        let projection = makeProjection(teams: [active], activeTeamID: "active")
        let task = makeTask(preferredTeamID: "active", runTeamID: "deleted")

        XCTAssertNil(TeamResolution.teamSettings(for: task, in: projection))
    }

    func testNoTeamAtAll_returnsNil() {
        let projection = makeProjection(teams: [], activeTeamID: nil)

        XCTAssertNil(TeamResolution.teamSettings(for: makeTask(), in: projection))
    }

    /// A generated / delegated child owns its team, so its own settings must win.
    func testGeneratedTeam_ownsItsSettings() {
        let active = makeTeam(id: "active", mode: .finalOnly)
        let projection = makeProjection(teams: [active], activeTeamID: "active")
        var task = makeTask()
        task.adoptGeneratedTeam(makeTeam(id: "gen", mode: .afterEachRole))

        XCTAssertEqual(
            TeamResolution.teamSettings(for: task, in: projection)?.defaultAcceptanceMode,
            .afterEachRole
        )
    }

    // MARK: - Composition with the gate

    /// The whole point of returning `nil`: the caller picks the fail-VISIBLE default.
    func testUnresolvedTeam_composesIntoTheVisibleGate() {
        let projection = makeProjection(teams: [], activeTeamID: nil)
        let task = makeTask()

        let gate = AcceptanceService.Gate(
            task: task,
            teamSettings: TeamResolution.teamSettings(for: task, in: projection)
        )

        XCTAssertEqual(gate.mode, .afterEachRole)
        XCTAssertTrue(gate.requestsAcceptance(roleID: "eng"),
                      "an unresolvable team must surface an Accept card, never silently self-accept")
    }
}
