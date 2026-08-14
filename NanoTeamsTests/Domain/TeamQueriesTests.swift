import XCTest

@testable import NanoTeams

/// Corner / boundary coverage for the pure read-only query layer extracted into
/// `Team+Queries.swift`. Every member is a pure function of stored fields, so
/// these tests build `Team` values directly — no orchestrator, no I/O. Focused
/// on the under-tested edges (tolerant `findRole` precedence + ambiguity,
/// `supervisorRequiredArtifacts` trim/dedup/sort, the templateID visibility
/// matrix); the delegation-predicate truth tables are exhaustively pinned by
/// `DelegateToTeamPeerLevelRuleTests`, so only boundary spot-checks live here.
final class TeamQueriesTests: XCTestCase {

    // MARK: - Fixtures

    private func role(
        id: String,
        name: String,
        systemRoleID: String? = nil,
        requires: [String] = [],
        produces: [String] = [],
        allowGenerated: Bool = false
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: name,
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: requires, producesArtifacts: produces),
            allowDelegationToGeneratedTeams: allowGenerated,
            systemRoleID: systemRoleID
        )
    }

    private func supervisor(requires: [String]) -> TeamRoleDefinition {
        role(id: "sup", name: "Supervisor", systemRoleID: "supervisor", requires: requires)
    }

    private func makeTeam(
        roles: [TeamRoleDefinition],
        artifacts: [TeamArtifact] = [],
        templateID: String? = nil,
        reportsTo: [String: String] = [:]
    ) -> Team {
        var settings = TeamSettings.default
        settings.hierarchy = TeamHierarchy(reportsTo: reportsTo)
        return Team(
            name: "T",
            templateID: templateID,
            roles: roles,
            artifacts: artifacts,
            settings: settings,
            graphLayout: .default
        )
    }

    private func artifact(_ name: String) -> TeamArtifact {
        TeamArtifact(id: name.lowercased(), name: name, icon: "doc", mimeType: "text/markdown", description: "")
    }

    // MARK: - Roster Queries

    func testMemberCount_matchesRoleArrayLength() {
        XCTAssertEqual(makeTeam(roles: []).memberCount, 0)
        XCTAssertEqual(makeTeam(roles: [role(id: "a", name: "A"), role(id: "b", name: "B")]).memberCount, 2)
    }

    func testHasRole_presentAndAbsent() {
        let t = makeTeam(roles: [role(id: "a", name: "A")])
        XCTAssertTrue(t.hasRole("a"))
        XCTAssertFalse(t.hasRole("b"))
    }

    func testRoleWithID_returnsMatchOrNil() {
        let t = makeTeam(roles: [role(id: "a", name: "A")])
        XCTAssertEqual(t.role(withID: "a")?.name, "A")
        XCTAssertNil(t.role(withID: "missing"))
    }

    func testCompletionTypeForRoleID_resolvesKindOrNil() {
        let t = makeTeam(roles: [
            role(id: "prod", name: "Prod", produces: ["Out"]),
            role(id: "adv", name: "Adv", requires: ["In"]),
            role(id: "obs", name: "Obs"),
        ])
        XCTAssertEqual(t.completionType(forRoleID: "prod"), .producing)
        XCTAssertEqual(t.completionType(forRoleID: "adv"), .advisory)
        XCTAssertEqual(t.completionType(forRoleID: "obs"), .observer)
        XCTAssertNil(t.completionType(forRoleID: "missing"),
                     "an unknown role id must return nil, not a default kind")
    }

    func testArtifactWithName_andArtifactNames() {
        let t = makeTeam(roles: [], artifacts: [artifact("Plan"), artifact("Spec")])
        XCTAssertEqual(t.artifact(withName: "Plan")?.id, "plan")
        XCTAssertNil(t.artifact(withName: "Nope"))
        XCTAssertEqual(t.artifactNames, ["Plan", "Spec"])
    }

    func testArtifactWithName_isCaseSensitive() {
        // Lookup is an exact `==` (artifacts are addressed by their canonical display name).
        let t = makeTeam(roles: [], artifacts: [artifact("Plan")])
        XCTAssertNotNil(t.artifact(withName: "Plan"))
        XCTAssertNil(t.artifact(withName: "plan"), "case-mismatch is not a match")
    }

    func testNonSupervisorRoles_excludesSupervisorOnly() {
        let t = makeTeam(roles: [supervisor(requires: []), role(id: "e", name: "Engineer")])
        XCTAssertEqual(t.nonSupervisorRoles.map(\.id), ["e"])
    }

    // MARK: - rolesProducing / rolesRequiring

    func testRolesProducing_none_one_many() {
        let t = makeTeam(roles: [
            role(id: "a", name: "A", produces: ["X"]),
            role(id: "b", name: "B", produces: ["X", "Y"]),
            role(id: "c", name: "C", produces: ["Z"]),
        ])
        XCTAssertEqual(Set(t.rolesProducing(artifactName: "X").map(\.id)), ["a", "b"])
        XCTAssertEqual(t.rolesProducing(artifactName: "Z").map(\.id), ["c"])
        XCTAssertTrue(t.rolesProducing(artifactName: "absent").isEmpty)
    }

    func testRolesRequiring_none_one_many() {
        let t = makeTeam(roles: [
            role(id: "a", name: "A", requires: ["X"]),
            role(id: "b", name: "B", requires: ["X"]),
            role(id: "c", name: "C", requires: []),
        ])
        XCTAssertEqual(Set(t.rolesRequiring(artifactName: "X").map(\.id)), ["a", "b"])
        XCTAssertTrue(t.rolesRequiring(artifactName: "absent").isEmpty)
    }

    // MARK: - findRole (tolerant) — precedence + ambiguity + degenerate

    func testFindRole_exactIDWinsOverSystemRoleIDAndName() {
        // b collides on BOTH systemRoleID (pass 2) and name (pass 3); a's exact id (pass 1) still wins.
        let a = role(id: "x", name: "Alpha")
        let b = role(id: "b", name: "x", systemRoleID: "x")
        let t = makeTeam(roles: [a, b])
        XCTAssertEqual(t.findRole(byIdentifier: "x")?.id, "x", "Exact id (pass 1) wins over systemRoleID + name")
    }

    func testFindRole_systemRoleIDWinsOverName() {
        // No id match; a systemRoleID match (pass 2) must beat a name match (pass 3).
        let a = role(id: "a", name: "x")                       // name would match pass 3
        let b = role(id: "b", name: "Beta", systemRoleID: "x") // systemRoleID matches pass 2
        let t = makeTeam(roles: [a, b])
        XCTAssertEqual(t.findRole(byIdentifier: "x")?.id, "b", "systemRoleID (pass 2) wins over name (pass 3)")
    }

    func testFindRole_caseInsensitiveName() {
        let t = makeTeam(roles: [role(id: "a", name: "Software Engineer")])
        XCTAssertEqual(t.findRole(byIdentifier: "software engineer")?.id, "a")
        XCTAssertEqual(t.findRole(byIdentifier: "SOFTWARE ENGINEER")?.id, "a")
    }

    func testFindRole_normalizedFallback_snakeCaseAndHyphen() {
        let t = makeTeam(roles: [role(id: "a", name: "Software Engineer", systemRoleID: "softwareEngineer")])
        XCTAssertEqual(t.findRole(byIdentifier: "software_engineer")?.id, "a", "snake_case normalizes")
        XCTAssertEqual(t.findRole(byIdentifier: "software-engineer")?.id, "a", "hyphen normalizes")
    }

    func testFindRole_ambiguousNormalizedCollision_returnsNil() {
        // Two roles normalize to the same token; no exact/systemRoleID/case-insensitive
        // match for the query → ambiguous → nil (caller surfaces its own error).
        let a = role(id: "a", name: "User Manager")
        let b = role(id: "b", name: "user-manager")
        let t = makeTeam(roles: [a, b])
        XCTAssertNil(t.findRole(byIdentifier: "USER_MANAGER"), "Ambiguous normalized collision must not bind silently")
    }

    func testFindRole_emptyAndWhitespaceIdentifier_returnsNil() {
        let t = makeTeam(roles: [role(id: "a", name: "Alpha")])
        XCTAssertNil(t.findRole(byIdentifier: ""))
        XCTAssertNil(t.findRole(byIdentifier: "    "))
    }

    func testFindRole_miss_returnsNil() {
        let t = makeTeam(roles: [role(id: "a", name: "Alpha")])
        XCTAssertNil(t.findRole(byIdentifier: "totally_unrelated"))
    }

    // MARK: - normalizedRoleIdentifier

    func testNormalizedRoleIdentifier_collapsesSeparatorsAndCase() {
        XCTAssertEqual(Team.normalizedRoleIdentifier("software_engineer"), "softwareengineer")
        XCTAssertEqual(Team.normalizedRoleIdentifier("Software Engineer"), "softwareengineer")
        XCTAssertEqual(Team.normalizedRoleIdentifier("softwareEngineer"), "softwareengineer")
        XCTAssertEqual(Team.normalizedRoleIdentifier("Code-Reviewer #1"), "codereviewer1")
        XCTAssertEqual(Team.normalizedRoleIdentifier(""), "")
        XCTAssertEqual(Team.normalizedRoleIdentifier("   -_-   "), "")
    }

    // MARK: - supervisorRequiredArtifacts (trim / drop-empty / dedup / sort)

    func testSupervisorRequiredArtifacts_trimsDropsEmptyAndSortsCaseInsensitive() {
        let t = makeTeam(roles: [supervisor(requires: ["  Release Notes  ", "", "Design Spec", "   "])])
        XCTAssertEqual(t.supervisorRequiredArtifacts, ["Design Spec", "Release Notes"])
    }

    func testSupervisorRequiredArtifacts_dedupsExactDuplicates() {
        let t = makeTeam(roles: [supervisor(requires: ["Release Notes", "Release Notes", "Design Spec"])])
        XCTAssertEqual(t.supervisorRequiredArtifacts, ["Design Spec", "Release Notes"])
    }

    func testSupervisorRequiredArtifacts_noSupervisor_returnsEmpty() {
        let t = makeTeam(roles: [role(id: "e", name: "Engineer", requires: ["Anything"])])
        XCTAssertTrue(t.supervisorRequiredArtifacts.isEmpty, "Only the Supervisor role's deps count")
    }

    func testSupervisorRequiredArtifacts_supervisorWithNoDeps_returnsEmpty() {
        XCTAssertTrue(makeTeam(roles: [supervisor(requires: [])]).supervisorRequiredArtifacts.isEmpty)
    }

    func testSupervisorRequiredArtifacts_whitespaceOnlyNames_returnEmpty() {
        let t = makeTeam(roles: [supervisor(requires: ["   ", "\n\t"])])
        XCTAssertTrue(t.supervisorRequiredArtifacts.isEmpty)
    }

    // MARK: - isChatMode / requiresSupervisorFinalReview / isValidDelegationTarget

    func testChatModeBoundary_bothDirections() {
        let chat = makeTeam(roles: [supervisor(requires: [])])
        XCTAssertTrue(chat.isChatMode)
        XCTAssertFalse(chat.requiresSupervisorFinalReview)
        XCTAssertFalse(chat.isValidDelegationTarget, "chat mode ⇒ not a delegation target")

        let pipeline = makeTeam(roles: [supervisor(requires: ["Release Notes"])])
        XCTAssertFalse(pipeline.isChatMode)
        XCTAssertTrue(pipeline.requiresSupervisorFinalReview)
        XCTAssertTrue(pipeline.isValidDelegationTarget)
    }

    func testChatMode_whitespaceOnlyRequirement_isChatMode() {
        // A requirement that trims to empty is dropped → no real deliverable → chat mode.
        let t = makeTeam(roles: [supervisor(requires: ["   "])])
        XCTAssertTrue(t.isChatMode)
    }

    // MARK: - templateID visibility matrix

    func testVisibilityMatrix_generatedSentinel() {
        let t = makeTeam(roles: [], templateID: DelegationConstants.generatedTeamSentinel)
        XCTAssertTrue(t.isHiddenFromPickers)
        XCTAssertTrue(t.isHiddenFromTeamEditor)
        XCTAssertFalse(t.isManagedSingleton)
    }

    func testVisibilityMatrix_autovisor() {
        let t = makeTeam(roles: [], templateID: AutovisorConstants.teamTemplateID)
        XCTAssertTrue(t.isHiddenFromPickers, "Autovisor hidden from task-assignment pickers")
        XCTAssertFalse(t.isHiddenFromTeamEditor, "...but visible (protected) in the Team editor")
        XCTAssertTrue(t.isManagedSingleton)
    }

    func testVisibilityMatrix_nilAndCustomTemplate_allFalse() {
        for tid in [nil, "faang", "custom"] as [String?] {
            let t = makeTeam(roles: [], templateID: tid)
            XCTAssertFalse(t.isHiddenFromPickers, "templateID=\(String(describing: tid))")
            XCTAssertFalse(t.isHiddenFromTeamEditor, "templateID=\(String(describing: tid))")
            XCTAssertFalse(t.isManagedSingleton, "templateID=\(String(describing: tid))")
        }
    }

    // MARK: - Delegation predicates (boundary spot-checks; full matrix in DelegateToTeamPeerLevelRuleTests)

    func testRoleIsTopLevelDelegator_peerAndSelfReportingAndChild() {
        let peer = role(id: "p", name: "Peer")
        let child = role(id: "c", name: "Child")
        let t = makeTeam(roles: [peer, child], reportsTo: ["c": "p", "p": "p"]) // p reports to itself
        XCTAssertTrue(t.roleIsTopLevelDelegator(peer), "self-reportsTo counts as peer-level")
        XCTAssertFalse(t.roleIsTopLevelDelegator(child), "an upstream parent ⇒ not top-level")
    }

    func testRoleIsTopLevelDelegator_supervisorAlwaysFalse() {
        let sup = supervisor(requires: [])
        let t = makeTeam(roles: [sup])
        XCTAssertFalse(t.roleIsTopLevelDelegator(sup))
    }

    func testDelegationEnabled_requiresBothPeerStatusAndConfiguration() {
        let configuredPeer = role(id: "a", name: "A", allowGenerated: true)
        let unconfiguredPeer = role(id: "b", name: "B", allowGenerated: false)
        let configuredChild = role(id: "c", name: "C", allowGenerated: true)
        let t = makeTeam(roles: [configuredPeer, unconfiguredPeer, configuredChild], reportsTo: ["c": "a"])
        XCTAssertTrue(t.delegationEnabled(for: configuredPeer))
        XCTAssertFalse(t.delegationEnabled(for: unconfiguredPeer), "peer but no target configured")
        XCTAssertFalse(t.delegationEnabled(for: configuredChild), "configured but not peer-level")
    }

    // MARK: - isGeneratedPlaceholder / seedChatModeForNewTask

    func testIsGeneratedPlaceholder_trueOnlyForTheSentinelTemplateID() {
        XCTAssertTrue(
            makeTeam(roles: [], templateID: DelegationConstants.generatedTeamSentinel)
                .isGeneratedPlaceholder)
        for tid: String? in [nil, "faang", "startup", "custom", AutovisorConstants.teamTemplateID] {
            XCTAssertFalse(
                makeTeam(roles: [], templateID: tid).isGeneratedPlaceholder,
                "templateID=\(String(describing: tid))")
        }
    }

    /// The asymmetry the whole fix rests on, asserted in ONE test so it cannot rot
    /// into "the placeholder just isn't chat-mode": its `isChatMode` really IS true
    /// (vacuously — a Supervisor with no required artifacts because there is no
    /// roster), and that is exactly why a separate seeding predicate exists.
    func testSeedChatModeForNewTask_generatedPlaceholder_isFalseDespiteVacuousChatMode() {
        let placeholder = TeamTemplateFactory.generatedTeam()
        XCTAssertTrue(
            placeholder.isChatMode,
            "precondition: the placeholder is vacuously chat-mode — that is the trap")
        XCTAssertFalse(
            placeholder.seedChatModeForNewTask,
            "a task on the placeholder must not inherit the vacuous value")
    }

    /// The placeholder is the ONLY team where the two predicates differ — including
    /// the genuinely chat-mode bundled teams and the Autovisor's own.
    func testSeedChatModeForNewTask_equalsIsChatMode_forEveryNonPlaceholderTeam() {
        let teams = Team.defaultTeams + [TeamTemplateFactory.autovisor()]
        XCTAssertFalse(teams.isEmpty)
        for team in teams {
            XCTAssertFalse(team.isGeneratedPlaceholder, "fixture sanity: \(team.name)")
            XCTAssertEqual(
                team.seedChatModeForNewTask, team.isChatMode,
                "\(team.name) must seed exactly its own chat mode")
        }
    }

    /// Guards the tempting one-line "simplification" of folding
    /// `isGeneratedPlaceholder` into `isChatMode`. `isValidDelegationTarget` is
    /// `!isChatMode`, and `RoleEditorDelegationPolicy.delegatableTeams` filters on
    /// that ALONE without checking `isHiddenFromPickers` — so the placeholder's
    /// vacuous `isChatMode` is the only thing keeping "Generated Team" out of a
    /// user-facing delegation whitelist, and out of
    /// `LLMExecutionService+DelegateToTeam`'s chat rejection for an LLM that passes
    /// the placeholder's UUID as `team_id`.
    func testIsValidDelegationTarget_generatedPlaceholder_staysFalse() {
        XCTAssertFalse(TeamTemplateFactory.generatedTeam().isValidDelegationTarget)
    }
}
