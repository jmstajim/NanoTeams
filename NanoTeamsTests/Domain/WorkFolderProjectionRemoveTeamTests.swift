import XCTest
@testable import NanoTeams

/// Tests for `WorkFolderProjection.removeTeam` — specifically the
/// `deletedTeamTemplateIDs` tracking that prevents `migrateIfNeeded`
/// from resurrecting user-deleted built-in teams on version bumps.
///
/// Pinned behavior:
/// - Removing a template-backed team appends its `templateID` to
///   `state.deletedTeamTemplateIDs`.
/// - Removing a custom team (nil `templateID`) does NOT append anything
///   (there's nothing for bootstrap to resurrect anyway).
/// - Removing a Generated-Team placeholder (templateID == "generated")
///   does NOT append either — these are ephemeral placeholders, not
///   template teams.
/// - Removing the SAME template twice (shouldn't happen in practice — it
///   requires first re-adding — but still) must not duplicate the entry.
/// - Removing the LAST team is refused (teams.count > 1 guard) — no
///   mutation anywhere.
/// - Active team reassignment: removing the currently-active team sets
///   activeTeamID to the first remaining team.
@MainActor
final class WorkFolderProjectionRemoveTeamTests: XCTestCase {

    // MARK: - Helpers

    private func makeTeam(id: String, name: String, templateID: String? = nil) -> Team {
        Team(
            id: id,
            name: name,
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
        return WorkFolderProjection(
            state: state,
            settings: .defaults,
            teams: teams
        )
    }

    // MARK: - Template-backed deletion: tracked

    func testRemoveTeam_templateBacked_appendsToDeletedTemplates() {
        let templateTeam = makeTeam(id: "faang", name: "FAANG", templateID: "faang")
        let other = makeTeam(id: "other", name: "Other")
        var proj = makeProjection(teams: [templateTeam, other])

        XCTAssertTrue(proj.state.deletedTeamTemplateIDs.isEmpty)

        proj.removeTeam("faang")

        XCTAssertEqual(proj.state.deletedTeamTemplateIDs, ["faang"],
                       "Deleting a template-backed team must append its templateID")
        XCTAssertNil(proj.teams.first(where: { $0.id == "faang" }))
    }

    func testRemoveTeam_multipleTemplates_appendedInOrder() {
        let a = makeTeam(id: "faang", name: "FAANG", templateID: "faang")
        let b = makeTeam(id: "startup", name: "Startup", templateID: "startup")
        let c = makeTeam(id: "personal", name: "Personal", templateID: "personal_assistant")
        var proj = makeProjection(teams: [a, b, c])

        proj.removeTeam("faang")
        proj.removeTeam("startup")

        XCTAssertEqual(proj.state.deletedTeamTemplateIDs, ["faang", "startup"])
    }

    /// Append-only: if someone somehow re-adds and re-deletes the same
    /// template, the ID must not appear twice (guard `!contains`).
    func testRemoveTeam_sameTemplateTwice_notDuplicated() {
        let a = makeTeam(id: "faang", name: "FAANG", templateID: "faang")
        let b = makeTeam(id: "other", name: "Other")
        let c = makeTeam(id: "faang_2", name: "FAANG copy", templateID: "faang")
        var proj = makeProjection(teams: [a, b, c])

        proj.removeTeam("faang")
        proj.removeTeam("faang_2")  // same templateID

        XCTAssertEqual(proj.state.deletedTeamTemplateIDs, ["faang"],
                       "`faang` must appear exactly once in deletedTeamTemplateIDs")
    }

    // MARK: - Custom / generated: NOT tracked

    func testRemoveTeam_customTeamNoTemplate_doesNotAppend() {
        let custom = makeTeam(id: "my_team", name: "My Team", templateID: nil)
        let other = makeTeam(id: "other", name: "Other")
        var proj = makeProjection(teams: [custom, other])

        proj.removeTeam("my_team")

        XCTAssertTrue(proj.state.deletedTeamTemplateIDs.isEmpty,
                      "Custom team (no templateID) must not be tracked as a deleted template")
        XCTAssertNil(proj.teams.first(where: { $0.id == "my_team" }))
    }

    func testRemoveTeam_generatedPlaceholder_notTracked() {
        let generated = makeTeam(id: "gen_xyz", name: "Gen", templateID: "generated")
        let other = makeTeam(id: "other", name: "Other")
        var proj = makeProjection(teams: [generated, other])

        proj.removeTeam("gen_xyz")

        XCTAssertTrue(proj.state.deletedTeamTemplateIDs.isEmpty,
                      "Generated-team placeholder must NOT be recorded — it's ephemeral")
    }

    // MARK: - Last-team guard

    func testRemoveTeam_lastTeam_refused_noMutation() {
        let only = makeTeam(id: "last", name: "Last", templateID: "faang")
        var proj = makeProjection(teams: [only], activeTeamID: "last")

        proj.removeTeam("last")

        XCTAssertEqual(proj.teams.count, 1,
                       "Cannot remove the last team — `teams.count > 1` guard")
        XCTAssertTrue(proj.state.deletedTeamTemplateIDs.isEmpty,
                      "Refused deletion must not touch deletedTeamTemplateIDs")
        XCTAssertEqual(proj.activeTeamID, "last",
                       "Active team untouched")
    }

    // MARK: - Active team reassignment

    func testRemoveTeam_active_reassignsToFirstRemaining() {
        let a = makeTeam(id: "a", name: "A", templateID: "faang")
        let b = makeTeam(id: "b", name: "B")
        let c = makeTeam(id: "c", name: "C")
        var proj = makeProjection(teams: [a, b, c], activeTeamID: "a")

        proj.removeTeam("a")

        XCTAssertEqual(proj.activeTeamID, "b",
                       "Removing the active team must point activeTeamID at the first remaining team")
        XCTAssertEqual(proj.teams.count, 2)
    }

    func testRemoveTeam_nonActive_activeUnchanged() {
        let a = makeTeam(id: "a", name: "A")
        let b = makeTeam(id: "b", name: "B", templateID: "startup")
        var proj = makeProjection(teams: [a, b], activeTeamID: "a")

        proj.removeTeam("b")

        XCTAssertEqual(proj.activeTeamID, "a",
                       "Removing a non-active team must not change activeTeamID")
    }

    // MARK: - Timestamp

    func testRemoveTeam_bumpsUpdatedAt() {
        MonotonicClock.shared.reset()
        let a = makeTeam(id: "a", name: "A", templateID: "faang")
        let b = makeTeam(id: "b", name: "B")
        var proj = makeProjection(teams: [a, b])
        let before = proj.state.updatedAt

        proj.removeTeam("a")

        XCTAssertGreaterThan(proj.state.updatedAt, before,
                             "Removing a team is a meaningful mutation — bump updatedAt")
    }

    func testRemoveTeam_refusedBecauseLast_doesNotBumpUpdatedAt() {
        MonotonicClock.shared.reset()
        let only = makeTeam(id: "only", name: "Only")
        var proj = makeProjection(teams: [only])
        let before = proj.state.updatedAt

        proj.removeTeam("only")

        XCTAssertEqual(proj.state.updatedAt, before,
                       "Refused removal is a no-op — updatedAt must not move")
    }
}
