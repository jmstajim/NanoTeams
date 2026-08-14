import XCTest

@testable import NanoTeams

/// A team's id is derived from its NAME (`NTMSID.from(name:)`), and until 2026-08-10 the three
/// doors that add one — "New Team", "Duplicate", "Import Team" — each did a bare
/// `project.teams.append(...)` with no collision check.
///
/// `TeamImportExportService` knows the rule and states it: `importRole` resolves a name clash
/// "before generating ID so ID matches final name", and `importArtifact` does the same. Only the
/// TEAM-level doors skipped it, and `importTeam` structurally cannot do it alone — it never sees
/// the folder's other teams.
///
/// Two teams under one id is not a cosmetic duplicate:
///   - `activeTeam` and every `teams.first(where:)` resolve the FIRST, so the second copy is
///     unreachable and every edit silently lands on the other one;
///   - `removeTeam` is `teams.removeAll { $0.id == teamID }` — deleting one deletes BOTH;
///   - a run pinned to `run.teamID` can resolve the wrong roster;
///   - the team pickers hand SwiftUI a duplicate `ForEach` id (CLAUDE.md #22).
///
/// Reachable in two clicks: "Duplicate" twice names both copies `<team> Copy`.
final class WorkFolderProjectionAddTeamTests: XCTestCase {

    private func projection(_ teams: [Team]) -> WorkFolderProjection {
        WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: teams)
    }

    // MARK: - availableTeamName

    /// RED: return `desired` unconditionally → the second name is unchanged.
    func testAvailableTeamName_freeName_isReturnedUnchanged() {
        let name = WorkFolderProjection.availableTeamName("Alpha", existingIDs: ["beta"])
        XCTAssertEqual(name, "Alpha", "a name with no collision must not be decorated")
    }

    /// RED: stop at the first suffix instead of walking → returns "Alpha 2", which is taken.
    func testAvailableTeamName_walksPastEveryTakenSuffix() {
        let taken: Set<NTMSID> = ["alpha", "alpha_2", "alpha_3"]
        XCTAssertEqual(WorkFolderProjection.availableTeamName("Alpha", existingIDs: taken), "Alpha 4")
    }

    /// The reason the check is on the DERIVED id and not on the display name: the derivation
    /// lowercases, folds spaces to underscores and strips everything else, so names a user
    /// would call distinct arrive as one id. Measured against `NTMSID.from`: `MY TEAM`,
    /// `My Team!` and `My_Team` all derive `my_team` — while `My: Team` (`my__team`) and
    /// `My-Team` (`myteam`) do NOT, which is why the fixture states each case rather than
    /// assuming punctuation folds one way.
    ///
    /// RED: compare display names instead of derived ids → "MY TEAM" is judged free and lands
    /// on top of "My Team".
    func testAvailableTeamName_namesThatDeriveTheSameID_areTreatedAsTaken() {
        let base = NTMSID.from(name: "My Team")
        for spelling in ["MY TEAM", "My Team!", "My_Team"] {
            XCTAssertEqual(NTMSID.from(name: spelling), base,
                           "precondition: '\(spelling)' must collide, or the row proves nothing")
            XCTAssertEqual(
                WorkFolderProjection.availableTeamName(spelling, existingIDs: [base]),
                "\(spelling) 2")
        }

        // The other side of the same measurement: a name that does NOT derive the taken id is
        // left alone, so the guard is keyed on the derivation and not on "looks similar".
        for distinct in ["My: Team", "My-Team"] {
            XCTAssertNotEqual(NTMSID.from(name: distinct), base)
            XCTAssertEqual(
                WorkFolderProjection.availableTeamName(distinct, existingIDs: [base]), distinct)
        }
    }

    // MARK: - addTeam

    /// RED: drop the rename from `addTeam` → both teams carry `alpha_copy` and the count of
    /// distinct ids is 1.
    func testAddTeam_collidingCustomTeam_isRenamed() {
        var wf = projection([Team(name: "Alpha Copy")])
        wf.addTeam(Team(name: "Alpha Copy"))

        XCTAssertEqual(wf.teams.count, 2)
        XCTAssertEqual(Set(wf.teams.map(\.id)).count, 2, "ids: \(wf.teams.map(\.id))")
        XCTAssertEqual(wf.teams[1].name, "Alpha Copy 2")
        XCTAssertEqual(wf.teams[1].id, NTMSID.from(name: "Alpha Copy 2"))
    }

    /// The half that makes the rename usable. Every call site selects the team it just added,
    /// and on a collision the value's own `id` is no longer the id in the folder — selecting by
    /// it lands on the OTHER team, which is the same bug wearing a different hat.
    ///
    /// RED: make `addTeam` return `team.id` instead of `incoming.id` → `activeTeam` is the first
    /// copy and the new one is unreachable, exactly as before the fix.
    func testAddTeam_returnedID_selectsTheTeamThatWasActuallyAdded() {
        var wf = projection([Team(name: "Alpha Copy")])
        let incoming = Team(name: "Alpha Copy")

        wf.activeTeamID = wf.addTeam(incoming)

        XCTAssertEqual(wf.teams.count, 2)
        XCTAssertEqual(wf.activeTeam?.name, "Alpha Copy 2")
        XCTAssertNotEqual(wf.activeTeamID, incoming.id, "the incoming id was the taken one")
    }

    /// "Duplicate" three times. Each copy must land on its own id rather than the second and
    /// third sharing one.
    ///
    /// RED: derive the free name from the DESIRED name only once (no loop) → the third copy is
    /// named "Alpha Copy 2" again.
    func testAddTeam_threeCollidingTeams_eachGetsItsOwnID() {
        var wf = projection([Team(name: "Alpha Copy")])
        wf.addTeam(Team(name: "Alpha Copy"))
        wf.addTeam(Team(name: "Alpha Copy"))

        XCTAssertEqual(Set(wf.teams.map(\.id)).count, 3, "ids: \(wf.teams.map(\.id))")
        XCTAssertEqual(wf.teams.map(\.name), ["Alpha Copy", "Alpha Copy 2", "Alpha Copy 3"])
    }

    /// Anti-vacuity: every assertion above is satisfied by a version that renames on every add.
    /// A team whose id is free must keep the name the user typed.
    ///
    /// RED: needs BOTH mutations — the property is guarded twice, once in `addTeam`'s
    /// collision check and once in `availableTeamName`'s own guard, so either alone is
    /// absorbed by the other. Replace `addTeam`'s condition with `if true` AND drop the
    /// resolver's `guard` → the name is "Beta 2".
    func testAddTeam_noCollision_leavesTheNameTheUserTyped() {
        var wf = projection([Team(name: "Alpha")])
        let beta = Team(name: "Beta")

        let addedID = wf.addTeam(beta)

        XCTAssertEqual(wf.teams[1].name, "Beta")
        XCTAssertEqual(addedID, beta.id)
    }

    /// The documented carve-out. A template team's id is a fixed identity that bootstrap's
    /// missing-template detection, `removeTeam`'s tombstone and "Restore Default Teams" key on,
    /// so it is deliberately NOT renamed — the guard is scoped to `templateID == nil`.
    ///
    /// RED: drop the `templateID == nil` condition → the bundled team is renamed and its id no
    /// longer matches the one every template-keyed path expects.
    func testAddTeam_templateTeam_keepsItsFixedIdentity() throws {
        let bundled = try XCTUnwrap(Team.defaultTeams.first)
        XCTAssertNotNil(bundled.templateID, "precondition: the fixture must be a template team")
        var wf = projection([bundled])

        let addedID = wf.addTeam(bundled)

        XCTAssertEqual(addedID, bundled.id, "a template id is an identity, not a uniqueness token")
        XCTAssertEqual(wf.teams[1].name, bundled.name)
    }

    // MARK: - Ids reserved by a template that does not exist yet

    /// The Autovisor team and the Generated placeholder are created LAZILY — on first enable and
    /// on the first "Generate Team..." pick — so they are absent from `teams` exactly when a
    /// custom team could take their id. And a template team's id comes from its NAME
    /// (`buildTeam` calls `NTMSID.from(name:)`), so a user team called "Autovisor" derives
    /// `autovisor` outright.
    ///
    /// Neither creator can resolve the clash later: `ensureAutovisorTeam` appends when no team
    /// carries `templateID == "autovisor"` — a test the custom team passes — and `addTeam`
    /// deliberately never renames a TEMPLATE team, because its id is the identity that
    /// bootstrap, the delete tombstone and Restore Defaults all key on. So the custom team has
    /// to yield here, while it is the one being added.
    ///
    /// RED: drop `.union(TeamTemplateFactory.lazilyMaterialisedTeamIDs)` → the custom team keeps
    /// `autovisor`, and enabling the feature later puts two teams on that id.
    func testAddTeam_customTeamNamedLikeALazyTemplate_yieldsTheReservedID() {
        let reserved = TeamTemplateFactory.autovisor().id
        var wf = projection([Team(name: "Keeper")])
        XCTAssertFalse(
            wf.teams.contains { $0.id == reserved },
            "precondition: the Autovisor team is NOT in the folder — that is the whole case")

        let addedID = wf.addTeam(Team(name: "Autovisor"))

        XCTAssertNotEqual(addedID, reserved, "the reserved id must survive for its template")
        XCTAssertEqual(wf.teams[1].name, "Autovisor 2")
    }

    /// Same for the Generated placeholder, and asserted through the factory rather than a
    /// literal so renaming the template cannot leave this pinning a dead string.
    ///
    /// RED: same mutation → `addedID` equals the placeholder's id.
    func testAddTeam_customTeamNamedLikeTheGeneratedPlaceholder_yieldsToo() {
        let reserved = TeamTemplateFactory.generatedTeam().id
        var wf = projection([Team(name: "Keeper")])

        let addedID = wf.addTeam(Team(name: TeamTemplateFactory.generatedTeam().name))

        XCTAssertNotEqual(addedID, reserved)
    }

    /// Anti-vacuity: reserving must not decorate a name that merely resembles one. Only the two
    /// lazily-created templates are reserved — the bundled ones are already IN `teams`, so they
    /// are covered by the ordinary collision check and need no reservation.
    ///
    /// RED: reserve every template id instead of the lazy two → "FAANG Team" is renamed in a
    /// folder that does not contain it.
    func testAddTeam_reservationIsOnlyTheLazyPair() {
        XCTAssertEqual(TeamTemplateFactory.lazilyMaterialisedTeamIDs.count, 2)
        var wf = projection([Team(name: "Keeper")])

        let addedID = wf.addTeam(Team(name: "FAANG Team"))

        XCTAssertEqual(addedID, NTMSID.from(name: "FAANG Team"))
        XCTAssertEqual(wf.teams[1].name, "FAANG Team")
    }

    // MARK: - The consequence

    /// Why the rename is worth doing at all, asserted where the user feels it: `removeTeam`
    /// deletes by id with `removeAll`, so before the fix the user who noticed two identical
    /// entries and deleted one lost both — including whatever they had already built in the copy.
    ///
    /// RED: drop the rename from `addTeam` → both teams share `alpha_copy`, `removeAll` takes
    /// them both, and `teams.count` is 1.
    func testRemoveTeam_afterTwoAdds_removesExactlyOne() {
        var wf = projection([Team(name: "Keeper"), Team(name: "Alpha Copy")])
        let addedID = wf.addTeam(Team(name: "Alpha Copy"))

        wf.removeTeam(addedID)

        XCTAssertEqual(wf.teams.count, 2, "remaining: \(wf.teams.map(\.name))")
        XCTAssertTrue(wf.teams.contains { $0.name == "Alpha Copy" },
                      "deleting the copy must leave the original standing")
    }
}
