import XCTest
@testable import NanoTeams

/// Pins the safe-orphan prune step in `applyBundledContentUpdates`. The
/// motivating regression: the "Code Review" artifact was renamed to
/// "Code Review Summary" in the bundled FAANG / Engineering templates. Without
/// this prune, legacy stored teams keep the old artifact in `team.artifacts`
/// as a selectable ghost in the team editor (no producer, no consumer, but
/// still pickable as a dependency target → engine wedge if a user picks it).
///
/// Safety contract: only system artifacts (`isSystemArtifact == true`) that
/// are missing from the bundled team AND not referenced by any role or by
/// `supervisorRequiredArtifacts` are removed. Custom artifacts and
/// still-referenced artifacts are preserved.
@MainActor
final class PruneOrphanSystemArtifactsTests: XCTestCase {

    private func makeArtifact(name: String, isSystem: Bool) -> TeamArtifact {
        TeamArtifact(
            id: NTMSID.from(name: "test:artifact:\(name)"),
            name: name,
            icon: "doc",
            mimeType: "text/markdown",
            description: "",
            isSystemArtifact: isSystem
        )
    }

    private func makeRole(name: String, requires: [String], produces: [String]) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "role-\(name)",
            name: name,
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: requires,
                producesArtifacts: produces
            )
        )
    }

    /// `Team.supervisorRequiredArtifacts` is computed from the Supervisor
    /// role's `requiredArtifacts`. Tests pass `supervisorRequires` and we
    /// synthesize a Supervisor role with those deps.
    private func makeTeam(
        artifacts: [TeamArtifact],
        roles: [TeamRoleDefinition] = [],
        supervisorRequires: [String] = []
    ) -> Team {
        var allRoles = roles
        if !supervisorRequires.isEmpty {
            let supervisor = TeamRoleDefinition(
                id: "role-supervisor",
                name: "Supervisor",
                prompt: "",
                toolIDs: [],
                usePlanningPhase: false,
                dependencies: RoleDependencies(
                    requiredArtifacts: supervisorRequires,
                    producesArtifacts: []
                ),
                isSystemRole: true,
                systemRoleID: "supervisor"
            )
            allRoles.append(supervisor)
        }
        return Team(
            id: NTMSID.from(name: "Team-\(UUID().uuidString)"),
            name: "Team",
            roles: allRoles,
            artifacts: artifacts,
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
    }

    // MARK: - Removes orphan system artifact

    /// The motivating regression: legacy team has both "Code Review" (orphan)
    /// and "Code Review Summary" (new). Bundled team has only the new name.
    /// No role or setting references the legacy name (post-step-1 reconcile).
    /// → orphan must be pruned, new name preserved.
    func testPrune_removesOrphanSystemArtifactNotInBundled() {
        var stored = makeTeam(artifacts: [
            makeArtifact(name: "Code Review", isSystem: true),
            makeArtifact(name: "Code Review Summary", isSystem: true),
        ])
        let bundled = makeTeam(artifacts: [
            makeArtifact(name: "Code Review Summary", isSystem: true),
        ])

        let changed = NTMSRepository.pruneOrphanSystemArtifacts(in: &stored, bundled: bundled)

        XCTAssertTrue(changed, "Prune must report a mutation when an orphan was removed")
        XCTAssertEqual(stored.artifacts.map(\.name), ["Code Review Summary"])
    }

    // MARK: - Preserves user-customized (non-system) artifacts

    func testPrune_preservesCustomArtifactNotInBundled() {
        var stored = makeTeam(artifacts: [
            makeArtifact(name: "User Custom Doc", isSystem: false),
        ])
        let bundled = makeTeam(artifacts: [])

        let changed = NTMSRepository.pruneOrphanSystemArtifacts(in: &stored, bundled: bundled)

        XCTAssertFalse(changed, "Custom artifacts must never be pruned regardless of bundled state")
        XCTAssertEqual(stored.artifacts.map(\.name), ["User Custom Doc"])
    }

    // MARK: - Preserves system artifact still referenced by a role

    /// If a custom role still requires the legacy name, removing the artifact
    /// would orphan the role. The reference scan must catch this.
    func testPrune_preservesArtifactRequiredByCustomRole() {
        let customRole = makeRole(
            name: "Custom",
            requires: ["Code Review"],
            produces: []
        )
        var stored = makeTeam(
            artifacts: [makeArtifact(name: "Code Review", isSystem: true)],
            roles: [customRole]
        )
        let bundled = makeTeam(artifacts: [])

        let changed = NTMSRepository.pruneOrphanSystemArtifacts(in: &stored, bundled: bundled)

        XCTAssertFalse(changed, "An artifact still required by any role must never be pruned")
        XCTAssertEqual(stored.artifacts.map(\.name), ["Code Review"])
    }

    func testPrune_preservesArtifactProducedByCustomRole() {
        let customRole = makeRole(
            name: "Custom",
            requires: [],
            produces: ["Code Review"]
        )
        var stored = makeTeam(
            artifacts: [makeArtifact(name: "Code Review", isSystem: true)],
            roles: [customRole]
        )
        let bundled = makeTeam(artifacts: [])

        let changed = NTMSRepository.pruneOrphanSystemArtifacts(in: &stored, bundled: bundled)

        XCTAssertFalse(changed)
        XCTAssertEqual(stored.artifacts.map(\.name), ["Code Review"])
    }

    // MARK: - Preserves artifact in supervisorRequiredArtifacts

    func testPrune_preservesArtifactInSupervisorRequired() {
        var stored = makeTeam(
            artifacts: [makeArtifact(name: "Code Review", isSystem: true)],
            supervisorRequires: ["Code Review"]
        )
        let bundled = makeTeam(artifacts: [])

        let changed = NTMSRepository.pruneOrphanSystemArtifacts(in: &stored, bundled: bundled)

        XCTAssertFalse(changed, "Artifacts named in supervisorRequiredArtifacts must never be pruned")
        XCTAssertEqual(stored.artifacts.map(\.name), ["Code Review"])
    }

    // MARK: - Idempotence

    func testPrune_idempotentSecondCallIsNoOp() {
        var stored = makeTeam(artifacts: [
            makeArtifact(name: "Code Review", isSystem: true),
            makeArtifact(name: "Code Review Summary", isSystem: true),
        ])
        let bundled = makeTeam(artifacts: [
            makeArtifact(name: "Code Review Summary", isSystem: true),
        ])

        let firstChanged = NTMSRepository.pruneOrphanSystemArtifacts(in: &stored, bundled: bundled)
        XCTAssertTrue(firstChanged)

        let secondChanged = NTMSRepository.pruneOrphanSystemArtifacts(in: &stored, bundled: bundled)
        XCTAssertFalse(secondChanged, "Prune must be idempotent — second call is a no-op")
    }

    // MARK: - No-op when nothing to prune

    func testPrune_noOpWhenStoredMatchesBundled() {
        var stored = makeTeam(artifacts: [
            makeArtifact(name: "Code Review Summary", isSystem: true),
        ])
        let bundled = makeTeam(artifacts: [
            makeArtifact(name: "Code Review Summary", isSystem: true),
        ])

        let changed = NTMSRepository.pruneOrphanSystemArtifacts(in: &stored, bundled: bundled)

        XCTAssertFalse(changed)
        XCTAssertEqual(stored.artifacts.map(\.name), ["Code Review Summary"])
    }
}
