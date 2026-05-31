import XCTest
@testable import NanoTeams

/// Tests for `WorkFolderProjection.setActiveTeam` and the `activeTeam`
/// resolution it feeds — the persistence mechanism the QuickCapture team
/// picker relies on (the picker button calls `mutateWorkFolder { $0.setActiveTeam(...) }`).
///
/// End-to-end persistence across an app restart is already pinned by
/// `EndToEndWorkFolderReopenTests.testReopen_activeTeamPointer_survives`; these
/// pin the in-projection rules at the Information Expert without standing up an
/// orchestrator.
///
/// Pinned behavior:
/// - `setActiveTeam(validID)` sets `activeTeamID` and bumps `updatedAt`.
/// - `setActiveTeam(invalidID)` is a guarded no-op — no change, no bump.
/// - `activeTeam` resolves a valid id; falls back to `teams.first` when nil.
/// - `activeTeam` returns nil for a stale id — the `setActiveTeam` membership
///   guard keeps the public API from ever producing that state.
@MainActor
final class WorkFolderProjectionSetActiveTeamTests: XCTestCase {

    // MARK: - Helpers

    private func makeTeam(id: String, templateID: String? = nil) -> Team {
        Team(
            id: id,
            name: id,
            templateID: templateID,
            roles: [],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )
    }

    private func makeProjection(teams: [Team], activeTeamID: NTMSID? = nil)
        -> WorkFolderProjection
    {
        var state = WorkFolderState(name: "test")
        state.activeTeamID = activeTeamID
        return WorkFolderProjection(state: state, settings: .defaults, teams: teams)
    }

    // MARK: - setActiveTeam: valid

    func testSetActiveTeam_validID_setsActiveTeamID() {
        var proj = makeProjection(teams: [makeTeam(id: "a"), makeTeam(id: "b")], activeTeamID: "a")
        proj.setActiveTeam("b")
        XCTAssertEqual(proj.activeTeamID, "b")
        XCTAssertEqual(proj.activeTeam?.id, "b", "activeTeam computed property resolves to the new team")
    }

    func testSetActiveTeam_validID_bumpsUpdatedAt() {
        MonotonicClock.shared.reset()
        var proj = makeProjection(teams: [makeTeam(id: "a"), makeTeam(id: "b")], activeTeamID: "a")
        let before = proj.state.updatedAt
        proj.setActiveTeam("b")
        XCTAssertGreaterThan(proj.state.updatedAt, before,
                             "Switching the active team is a meaningful mutation — bump updatedAt")
    }

    // MARK: - setActiveTeam: invalid (guarded no-op)

    func testSetActiveTeam_invalidID_isNoOp() {
        var proj = makeProjection(teams: [makeTeam(id: "a"), makeTeam(id: "b")], activeTeamID: "a")
        proj.setActiveTeam("ghost")
        XCTAssertEqual(proj.activeTeamID, "a", "Setting a non-existent team id is a guarded no-op")
        XCTAssertNotNil(proj.activeTeam, "activeTeam still resolves after a refused set")
    }

    func testSetActiveTeam_invalidID_doesNotBumpUpdatedAt() {
        MonotonicClock.shared.reset()
        var proj = makeProjection(teams: [makeTeam(id: "a"), makeTeam(id: "b")], activeTeamID: "a")
        let before = proj.state.updatedAt
        proj.setActiveTeam("ghost")
        XCTAssertEqual(proj.state.updatedAt, before, "Refused set is a no-op — updatedAt must not move")
    }

    // MARK: - activeTeam resolution

    func testActiveTeam_nilActiveTeamID_returnsFirstTeam() {
        let proj = makeProjection(teams: [makeTeam(id: "a"), makeTeam(id: "b")], activeTeamID: nil)
        XCTAssertEqual(proj.activeTeam?.id, "a")
    }

    func testActiveTeam_validActiveTeamID_returnsThatTeam() {
        let proj = makeProjection(teams: [makeTeam(id: "a"), makeTeam(id: "b")], activeTeamID: "b")
        XCTAssertEqual(proj.activeTeam?.id, "b")
    }

    /// Characterizes current behavior: a stale `activeTeamID` resolves to nil
    /// (NOT `teams.first`). The `setActiveTeam` membership guard prevents the
    /// public API from ever reaching this state; it only arises from external
    /// corruption, which the orchestrator recovers on open.
    func testActiveTeam_staleActiveTeamID_returnsNil() {
        let proj = makeProjection(teams: [makeTeam(id: "a"), makeTeam(id: "b")], activeTeamID: "ghost")
        XCTAssertNil(proj.activeTeam)
    }
}
