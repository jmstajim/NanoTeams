import XCTest
@testable import NanoTeams

/// Corner cases and lifecycle surfaces for the starter team `TeamTemplateFactory.empty(name:)`.
///
/// `EmptyTeamTemplateTests` pins the SHAPE at construction. This file pins what happens to
/// that shape afterwards — whether the team actually runs, survives `teams.json`, and
/// survives the three copy paths the UI exposes (duplicate / export+import) — plus the
/// degenerate names the New Team sheet will happily accept.
///
/// The starter team exists to be EDITED, so its lifecycle is not incidental: every one of
/// these surfaces is one click away from the moment it is created.
@MainActor
final class EmptyTeamLifecycleTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
    }

    private func makeStarter(_ name: String = "Alpha Team") -> Team {
        TeamTemplateFactory.empty(name: name)
    }

    // MARK: - Does it actually run?

    /// The whole point of shipping a second role: with the Supervisor Task in hand the
    /// Teammate must be pickable. `TeamEngine.findReadyRoles` delegates here, so this is
    /// the closest pure-function proxy for "the team runs".
    func testTeammate_becomesReadyOnceTheSupervisorTaskExists() {
        let team = makeStarter()
        let teammateID = team.nonSupervisorRoles[0].id

        let ready = ArtifactDependencyResolver.findReadyRoles(
            roles: team.roles,
            producedArtifacts: [SystemTemplates.supervisorTaskArtifactName]
        )

        XCTAssertTrue(ready.contains(teammateID),
                      "With the Supervisor Task produced, the starter role must be ready to execute.")
    }

    func testTeammate_isBlockedBeforeTheSupervisorTaskExists() {
        let team = makeStarter()
        let teammateID = team.nonSupervisorRoles[0].id

        let ready = ArtifactDependencyResolver.findReadyRoles(
            roles: team.roles,
            producedArtifacts: []
        )
        XCTAssertFalse(ready.contains(teammateID))

        let readiness = ArtifactDependencyResolver.getRoleReadiness(
            roleID: teammateID,
            roles: team.roles,
            producedArtifacts: []
        )
        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.missingArtifacts, [SystemTemplates.supervisorTaskArtifactName],
                       "The blocking reason must name the Supervisor Task, not be silently empty.")
    }

    /// The starter is not a novel graph shape — it is `startup()` with generic names. This
    /// pins that equivalence across every dependency-graph query at once, so a future change
    /// to either the starter or the resolver cannot make them diverge unnoticed.
    ///
    /// Includes the counter-intuitive one: `getExecutionOrder()` returns **nil** for BOTH,
    /// because the resolver's graph (unlike `validateNoCircularDependencies`) does NOT
    /// exclude Supervisor edges, so Supervisor→Teammate→Supervisor reads as a cycle. That is
    /// pre-existing and harmless — the engine schedules via `findReadyRoles`, never via
    /// `getExecutionOrder` — but a test asserting a non-nil order here would be wrong.
    func testStarterDependencyGraph_behavesExactlyLikeTheStartupTemplate() {
        let starter = makeStarter()
        let startup = TeamTemplateFactory.startup()

        for team in [starter, startup] {
            let worker = team.nonSupervisorRoles[0]
            let supervisor = team.roles[0]
            let deliverable = worker.dependencies.producesArtifacts[0]
            let resolver = ArtifactDependencyResolver(roles: team.roles)

            XCTAssertEqual(team.roles.count, 2, "[\(team.name)]")
            XCTAssertEqual(supervisor.dependencies.requiredArtifacts, [deliverable], "[\(team.name)]")
            XCTAssertEqual(worker.dependencies.requiredArtifacts,
                           [SystemTemplates.supervisorTaskArtifactName], "[\(team.name)]")
            XCTAssertEqual(worker.completionType, .producing, "[\(team.name)]")
            XCTAssertFalse(team.isChatMode, "[\(team.name)]")
            XCTAssertEqual(
                ArtifactDependencyResolver.findReadyRoles(
                    roles: team.roles,
                    producedArtifacts: [SystemTemplates.supervisorTaskArtifactName]
                ),
                team.roles.filter {
                    $0.dependencies.requiredArtifacts == [SystemTemplates.supervisorTaskArtifactName]
                }.map(\.id),
                "[\(team.name)] only the worker unblocks on the Supervisor Task"
            )
            XCTAssertNil(resolver.getExecutionOrder(),
                         "[\(team.name)] the resolver counts the Supervisor's review edge, so both teams cycle")
            XCTAssertTrue(TeamValidationService.validate(team: team, allTeams: [team]).isValid,
                          "[\(team.name)] and neither is a validation error")
        }
    }

    // MARK: - Persistence (teams.json)

    /// The starter role is the only role in the app built inline with `systemRoleID: nil` at
    /// TEMPLATE time, so its decode path is the custom-role one. `TeamRoleDefinition.init(from:)`
    /// defaults `icon` and `iconBackground` from `systemRoleID` — with nil that resolves to
    /// "person" / the custom blue, and only an explicitly-encoded value survives.
    func testStarter_survivesTeamsJSONRoundTrip() throws {
        let original = makeStarter()
        let data = try JSONCoderFactory.makePersistenceEncoder()
            .encode(TeamsFile(teams: [original]))
        let decoded = try JSONCoderFactory.makeDateDecoder()
            .decode(TeamsFile.self, from: data)

        let team = try XCTUnwrap(decoded.teams.first)
        XCTAssertEqual(team.id, original.id)
        XCTAssertNil(team.templateID)
        XCTAssertEqual(team.roles.map(\.id), original.roles.map(\.id))
        XCTAssertEqual(team.artifactNames, original.artifactNames)

        let before = original.nonSupervisorRoles[0]
        let after = try XCTUnwrap(team.roles.first { $0.id == before.id })
        XCTAssertEqual(after.name, before.name)
        XCTAssertEqual(after.icon, before.icon, "icon must be encoded, not re-derived from a nil systemRoleID")
        XCTAssertEqual(after.iconBackground, before.iconBackground)
        XCTAssertEqual(after.prompt, before.prompt)
        XCTAssertEqual(after.toolIDs, before.toolIDs, "tool ORDER is prompt bytes — it must round-trip exactly")
        XCTAssertEqual(after.dependencies, before.dependencies)
        XCTAssertFalse(after.isSystemRole)
        XCTAssertNil(after.systemRoleID)
        XCTAssertEqual(after.completionType, .producing)
        XCTAssertEqual(team.settings.hierarchy.reportsTo, original.settings.hierarchy.reportsTo)
    }

    /// `syncSystemRoleDependencies` runs on EVERY work-folder open and rewrites
    /// `producesArtifacts` from the template for system roles. The starter role carries
    /// `isSystemRole == false` precisely so a user who repoints it is not silently undone
    /// on the next launch.
    func testUserEditedStarterRole_isNotRewrittenByTheSystemRoleSync() {
        var team = makeStarter()
        let idx = try! XCTUnwrap(team.roles.firstIndex { !$0.isSupervisor })
        team.roles[idx].dependencies.producesArtifacts = ["My Deliverable"]
        team.roles[idx].toolIDs = [ToolNames.readFile]

        let changed = TeamManagementService.syncSystemRoleDependencies(
            team: &team,
            templates: SystemTemplates.roles,
            teamProducers: Set(team.roles.flatMap(\.dependencies.producesArtifacts))
        )

        XCTAssertFalse(changed, "a custom role must be invisible to the system-role sync")
        XCTAssertEqual(team.roles[idx].dependencies.producesArtifacts, ["My Deliverable"])
        XCTAssertEqual(team.roles[idx].toolIDs, [ToolNames.readFile])
    }

    // MARK: - Copy paths (Duplicate / Export+Import)

    func testDuplicate_preservesTheTeammateWiring_andReSeedsEveryID() {
        let original = makeStarter("Alpha Team")
        let copy = TeamManagementService.duplicateTeam(original, newName: "Beta Team")

        XCTAssertEqual(copy.roles.count, 2)
        XCTAssertNil(copy.templateID)

        let before = original.nonSupervisorRoles[0]
        let after = copy.nonSupervisorRoles[0]
        XCTAssertEqual(after.name, before.name)
        XCTAssertEqual(after.prompt, before.prompt)
        XCTAssertEqual(after.toolIDs, before.toolIDs)
        XCTAssertEqual(after.dependencies, before.dependencies)
        XCTAssertEqual(copy.roles[0].dependencies.requiredArtifacts,
                       [TeamTemplateFactory.resultArtifactName],
                       "the Supervisor's review requirement must survive the copy")
        XCTAssertEqual(copy.artifactNames, original.artifactNames)

        XCTAssertTrue(Set(copy.roles.map(\.id)).isDisjoint(with: Set(original.roles.map(\.id))),
                      "role ids are a live namespace (StepExecution.id) — a copy must not share them")
        XCTAssertTrue(Set(copy.artifacts.map(\.id)).isDisjoint(with: Set(original.artifacts.map(\.id))))
        // The hierarchy must be remapped onto the NEW ids, not left pointing at the original's.
        XCTAssertEqual(copy.settings.hierarchy.reportsTo, [after.id: copy.roles[0].id])
    }

    func testExportImport_roundTripsTheTeammate() throws {
        let original = makeStarter("Alpha Team")
        let data = try TeamImportExportService.exportTeam(original)
        let imported = try TeamImportExportService.importTeam(from: data, newName: "Gamma Team")

        XCTAssertEqual(imported.name, "Gamma Team")
        XCTAssertEqual(imported.roles.count, 2)
        XCTAssertNil(imported.templateID)

        let after = imported.nonSupervisorRoles[0]
        XCTAssertEqual(after.name, TeamTemplateFactory.teammateRoleName)
        XCTAssertEqual(after.toolIDs, original.nonSupervisorRoles[0].toolIDs)
        XCTAssertEqual(after.dependencies, original.nonSupervisorRoles[0].dependencies)
        XCTAssertEqual(after.completionType, .producing)
        XCTAssertEqual(imported.artifactNames, original.artifactNames)
        XCTAssertTrue(Set(imported.roles.map(\.id)).isDisjoint(with: Set(original.roles.map(\.id))))
        XCTAssertEqual(imported.settings.hierarchy.reportsTo, [after.id: imported.roles[0].id],
                       "hierarchy must be remapped to the imported ids")
    }

    // MARK: - The edit the starter invites

    /// The starter is a scaffold — deleting the Teammate is an expected first move. It must
    /// fail LOUDLY (the Team Editor banner), not leave a team that silently never completes:
    /// the Supervisor still requires "Result" and now nothing produces it.
    func testDeletingTheTeammate_surfacesAMissingProducerError() {
        var team = makeStarter()
        team.removeRole(team.nonSupervisorRoles[0].id)

        let result = TeamValidationService.validate(team: team, allTeams: [team])

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(
            result.errors.contains {
                if case .missingProducer(let artifact, _) = $0 {
                    return artifact == TeamTemplateFactory.resultArtifactName
                }
                return false
            },
            "Expected a missingProducer('Result') error, got: \(result.errors)"
        )
    }

    /// The mirror image: clearing the Supervisor's requirement turns the starter back into a
    /// chat team, and the now-unconsumed "Result" is a WARNING (orphan), never an error — so
    /// the user is informed without being blocked.
    func testClearingTheSupervisorRequirement_degradesToChatModeWithAnOrphanWarning() {
        var team = makeStarter()
        team.roles[0].dependencies.requiredArtifacts = []

        XCTAssertTrue(team.isChatMode)
        let result = TeamValidationService.validate(team: team, allTeams: [team])
        XCTAssertTrue(result.isValid, "an orphan artifact must not block the team: \(result.errors)")
        XCTAssertTrue(
            result.warnings.contains {
                if case .orphanArtifact(let artifact, _) = $0 {
                    return artifact == TeamTemplateFactory.resultArtifactName
                }
                return false
            },
            "Expected an orphanArtifact('Result') warning, got: \(result.warnings)"
        )
    }

    // MARK: - Degenerate names

    /// Non-ASCII names must survive: `NTMSID.from` keeps anything `isLetter`, so Cyrillic
    /// yields real, distinct ids rather than collapsing to the empty-seed case below.
    func testCyrillicName_producesDistinctNonEmptyIDs() {
        let a = makeStarter("Моя Команда")
        let b = makeStarter("Другая Команда")

        XCTAssertFalse(a.id.isEmpty)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(Set(a.roles.map(\.id)).isDisjoint(with: Set(b.roles.map(\.id))))
        XCTAssertTrue(Set(a.artifacts.map(\.id)).isDisjoint(with: Set(b.artifacts.map(\.id))))
    }

    func testEmptyName_doesNotTrap_andValidationFlagsIt() {
        // `buildSettings` indexes `roles[0]` unguarded and `autoLayout` walks the roster —
        // neither may trap on a degenerate name. The name itself is then rejected downstream.
        let team = makeStarter("")

        XCTAssertEqual(team.roles.count, 2)
        XCTAssertEqual(team.graphLayout.nodePositions.count, 2)
        XCTAssertTrue(TeamManagementService.validate(team).contains(.emptyName))
    }

    /// CHARACTERIZATION — documents a pre-existing limit of `NTMSID.from(name:)`, NOT desired
    /// behaviour. It strips every character that is not a letter, digit or underscore (and
    /// maps `:` and space to `_`), so distinct names can normalize to the SAME seed — and the
    /// seed is what every id is derived from. `"My Team"` and `"My:Team"` therefore produce
    /// two teams that collide on the team id, both role ids and both artifact ids.
    ///
    /// This predates the starter Teammate (the Supervisor and its artifact collided the same
    /// way); shipping a second role and a second artifact only widens it. It is also NOT
    /// caught by `hasDuplicateName`, which compares the RAW names case-insensitively —
    /// `"My Team"` != `"My:Team"`, so the guard passes. `testEmpty_differentNames_produce
    /// DisjointRoleAndArtifactIDs` gives false confidence here because "Alpha"/"Beta" do not
    /// collide; this test states the real boundary.
    func testPunctuationVariantNames_collideOnEveryDerivedID_knownLimit() {
        let a = makeStarter("My Team")
        let b = makeStarter("My:Team")

        XCTAssertEqual(a.id, b.id, "seed derivation maps ':' and ' ' to the same '_'")
        XCTAssertEqual(a.roles.map(\.id), b.roles.map(\.id))
        XCTAssertEqual(a.artifacts.map(\.id), b.artifacts.map(\.id))
        // …and the guard that is supposed to prevent two same-named teams does not fire,
        // because it compares names rather than the ids that must actually be unique.
        XCTAssertFalse(TeamManagementService.hasDuplicateName("My:Team", in: [a]),
                       "documents the gap: the uniqueness guard is name-based, the collision is id-based")
    }

    /// CHARACTERIZATION — the extreme of the same limit: a name with NO id-safe characters
    /// collapses the seed to "", so every such team lands on byte-identical ids. Pinned so
    /// that any future change to id derivation has to confront this case deliberately.
    func testNameWithNoIDSafeCharacters_collapsesToASharedIDSpace_knownLimit() {
        let rocket = makeStarter("🚀")
        let bang = makeStarter("!!!")

        XCTAssertEqual(rocket.id, "")
        XCTAssertEqual(rocket.roles.map(\.id), bang.roles.map(\.id))
        XCTAssertEqual(rocket.artifacts.map(\.id), bang.artifacts.map(\.id))
        // The ids are still internally well-formed — non-empty and distinct WITHIN a team —
        // so the failure mode is cross-team collision only.
        XCTAssertEqual(Set(rocket.roles.map(\.id)).count, rocket.roles.count)
        XCTAssertEqual(Set(rocket.artifacts.map(\.id)).count, rocket.artifacts.count)
    }

    /// Whitespace-only names normalize to underscores rather than to "", so they do NOT join
    /// the shared id space above — but they are still rejected as an empty NAME. Pins that the
    /// two normalizations (id seed vs. name validation) disagree by design.
    func testWhitespaceOnlyName_isRejectedAsEmpty_butKeepsItsOwnIDSpace() {
        let team = makeStarter("  ")

        XCTAssertEqual(team.id, "__")
        XCTAssertNotEqual(team.roles.map(\.id), makeStarter("🚀").roles.map(\.id))
        XCTAssertTrue(TeamManagementService.validate(team).contains(.emptyName))
    }

    // MARK: - On-disk artifact naming

    /// `Artifact.slugify` decides the artifact filename (`artifact_<slug>.md`). Both starter
    /// artifacts must slug to distinct, non-empty names or they overwrite each other on disk.
    func testStarterArtifactSlugs_areDistinctAndNonEmpty() {
        let team = makeStarter()
        let slugs = team.artifacts.map { Artifact.slugify($0.name) }

        XCTAssertEqual(slugs, ["supervisor_task", "result"])
        XCTAssertEqual(Set(slugs).count, slugs.count)
        XCTAssertFalse(slugs.contains(where: \.isEmpty))
    }
}
