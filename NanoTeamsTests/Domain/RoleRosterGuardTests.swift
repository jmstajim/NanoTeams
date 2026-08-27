import XCTest

@testable import NanoTeams

/// `RoleRosterGuard` is `nonisolated`, so this suite is a plain `XCTestCase`.
final class RoleRosterGuardTests: XCTestCase {

    private func team(roles: [String], name: String = "Fixture") -> Team {
        var team = Team(name: name)
        team.roles = roles.map {
            TeamRoleDefinition(id: $0, name: $0, prompt: "", toolIDs: [],
                               usePlanningPhase: false, dependencies: RoleDependencies())
        }
        return team
    }

    // MARK: - refusal

    /// RED: invert the predicate → every real role is refused and every ghost accepted.
    func testRefusal_roleOnRoster_isNil() {
        XCTAssertNil(RoleRosterGuard.refusal(
            roleID: "software_engineer", team: team(roles: ["software_engineer", "pm"])))
    }

    /// RED: same inversion → this returns nil and the caller proceeds to write a phantom
    /// `roleStatuses` entry (or, in `restartRole`, to `reset()` a step for a role the engine
    /// can never start).
    func testRefusal_roleNotOnRoster_namesTheRoleAndTheTeam() {
        let refusal = RoleRosterGuard.refusal(
            roleID: "deleted_role", team: team(roles: ["pm"], name: "Engineering"))
        guard let refusal else { return XCTFail("a role off the roster must be refused") }
        XCTAssertTrue(refusal.contains("deleted_role"), "must name the role; got \(refusal)")
        XCTAssertTrue(refusal.contains("Engineering"), "must name the team; got \(refusal)")
    }

    /// The guard resolves through `Team.findRole(byIdentifier:)`, not by raw id equality — a
    /// stricter check would refuse the snake_case identifiers the LLM legitimately produces and
    /// that `findOrCreateStep` already accepts.
    ///
    /// RED: compare `roleID` against `roles.map(\.id)` directly → this fails, and every
    /// `manage_role` call the manager writes in snake_case starts being refused.
    func testRefusal_toleratesTheIdentifierFormsFindOrCreateStepAccepts() {
        var t = Team(name: "T")
        t.roles = [TeamRoleDefinition(
            id: UUID().uuidString, name: "Software Engineer", prompt: "", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies())]
        XCTAssertNil(RoleRosterGuard.refusal(roleID: "software_engineer", team: t))
    }

    // MARK: - orphanRoleIDs

    /// RED: drop the roster filter → every role is reported as an orphan and recovery strips
    /// the whole status map.
    func testOrphanRoleIDs_reportsOnlyRolesOffTheRoster() {
        let orphans = RoleRosterGuard.orphanRoleIDs(
            roleStatuses: ["pm": .done, "gone": .revisionRequested, "swe": .working],
            team: team(roles: ["pm", "swe"]))
        XCTAssertEqual(orphans, ["gone"])
    }

    /// The Supervisor is the user, never a roster entry.
    ///
    /// RED: remove the Supervisor exclusion → recovery strips `roleStatuses["supervisor"]` on
    /// every task, and the Supervisor's own gate disappears from the run.
    func testOrphanRoleIDs_supervisorIsNeverAnOrphan() {
        let orphans = RoleRosterGuard.orphanRoleIDs(
            roleStatuses: [Role.supervisor.id: .done], team: team(roles: ["pm"]))
        XCTAssertTrue(orphans.isEmpty, "got \(orphans)")
    }

    /// The third state (CLAUDE.md #97): "could not resolve the team" is NOT "the team has no
    /// roles". Conflating them strips every role status from every task pinned to a deleted
    /// team, and the task then silently reads Done.
    ///
    /// RED: treat `nil` as an empty roster → this returns both ids.
    func testOrphanRoleIDs_nilTeam_reportsNothing() {
        XCTAssertTrue(RoleRosterGuard.orphanRoleIDs(
            roleStatuses: ["pm": .done, "gone": .working], team: nil).isEmpty)
    }

    /// A team that resolved and genuinely has no roles IS the empty-roster case, and it is
    /// distinct from the row above. The pair is what pins that the two are separate states
    /// rather than one.
    ///
    /// RED: return `[]` whenever `team.roles.isEmpty` (a plausible "be safe" shortcut) → this
    /// fails while the `nil` test above stays green.
    func testOrphanRoleIDs_resolvedButEmptyRoster_reportsTheOrphans() {
        XCTAssertEqual(
            RoleRosterGuard.orphanRoleIDs(roleStatuses: ["gone": .working], team: team(roles: [])),
            ["gone"])
    }
}
