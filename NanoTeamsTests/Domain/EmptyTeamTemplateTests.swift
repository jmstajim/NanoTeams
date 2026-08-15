import XCTest
@testable import NanoTeams

/// User-path: picking "Empty Team" in the New Team sheet must produce an EMPTY team —
/// not the 9-role FAANG roster the deleted `TeamManagementService.createTeam` cloned.
///
/// "Empty" means the smallest team that actually RUNS:
/// - the **Supervisor** (which the role editor can never re-create —
///   `RoleEditorMutations.applyCreate` hardcodes `systemRoleID: nil`);
/// - a **Teammate** that takes the Supervisor's task and reports a **Result** back. The
///   Supervisor is the user, not an LLM, so a Supervisor-only team has nothing to execute;
///   reaching a runnable one took four non-obvious Team Editor edits.
/// - the two artifacts that connect them, without which any role the user adds has empty
///   required AND produced lists, becomes an observer, and is skipped by
///   `TeamEngine.findReadyRoles`.
@MainActor
final class EmptyTeamTemplateTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Shape

    func testEmpty_usesGivenName() {
        let team = TeamTemplateFactory.empty(name: "Alpha Team")

        XCTAssertEqual(team.name, "Alpha Team")
        XCTAssertEqual(team.id, NTMSID.from(name: "Alpha Team"))
    }

    func testEmpty_hasSupervisorAndOneTeammate() {
        let team = TeamTemplateFactory.empty(name: "Alpha Team")

        XCTAssertEqual(team.roles.count, 2, "Supervisor + the one Teammate that takes its task.")
        XCTAssertTrue(team.roles[0].isSupervisor)
        XCTAssertEqual(team.roles[0].systemRoleID, "supervisor")
        XCTAssertEqual(team.nonSupervisorRoles.count, 1)
        XCTAssertEqual(team.nonSupervisorRoles[0].name, TeamTemplateFactory.teammateRoleName)
        // The headline regression: "Empty Team" used to clone FAANG.
        XCTAssertNotEqual(team.roles.count, TeamTemplateFactory.faang().roles.count,
                          "Empty must not carry a FAANG-sized roster.")
    }

    func testEmpty_carriesTheSupervisorTaskAndResultArtifacts() {
        let team = TeamTemplateFactory.empty(name: "Alpha Team")

        XCTAssertEqual(team.artifactNames,
                       [SystemTemplates.supervisorTaskArtifactName,
                        TeamTemplateFactory.resultArtifactName])
    }

    func testEmpty_supervisorProducesTheTaskAndRequiresTheResult() {
        // Why the artifacts ship at all: `ArtifactDependencyEditor` offers
        // `team.artifactNames` as the Required options, so any role the user adds has
        // something to depend on and is advisory/producing rather than an observer.
        let team = TeamTemplateFactory.empty(name: "Alpha Team")

        XCTAssertEqual(team.roles[0].dependencies.producesArtifacts,
                       [SystemTemplates.supervisorTaskArtifactName])
        XCTAssertEqual(team.roles[0].dependencies.requiredArtifacts,
                       [TeamTemplateFactory.resultArtifactName])
    }

    func testEmpty_teammateConsumesTheSupervisorTaskAndProducesTheResult() {
        // The user-visible ask: a role that RECEIVES the task from the Supervisor.
        let team = TeamTemplateFactory.empty(name: "Alpha Team")
        let teammate = team.nonSupervisorRoles[0]

        XCTAssertEqual(teammate.dependencies.requiredArtifacts,
                       [SystemTemplates.supervisorTaskArtifactName])
        XCTAssertEqual(teammate.dependencies.producesArtifacts,
                       [TeamTemplateFactory.resultArtifactName])
        XCTAssertEqual(teammate.completionType, .producing,
                       "Producing ⇒ self-completes on create_artifact; observer would be skipped by findReadyRoles.")
        XCTAssertFalse(teammate.isObserver)
    }

    func testEmpty_isAPipelineTeam_notChatMode() {
        let team = TeamTemplateFactory.empty(name: "Alpha Team")

        XCTAssertEqual(team.supervisorRequiredArtifacts, [TeamTemplateFactory.resultArtifactName])
        XCTAssertFalse(team.isChatMode,
                       "A supervisor deliverable exists ⇒ pipeline with Review/Accept, not chat.")
        XCTAssertTrue(team.requiresSupervisorFinalReview)
    }

    func testEmpty_teammateHasReadOnlyToolsAndCanAskTheSupervisor() {
        typealias TN = ToolNames
        let teammate = TeamTemplateFactory.empty(name: "Alpha Team").nonSupervisorRoles[0]

        // Ordered, not a Set: tool order is segment-0 prompt bytes.
        XCTAssertEqual(teammate.toolIDs, [
            TN.readFile, TN.readLines, TN.listFiles, TN.search,
            TN.updateScratchpad,
            TN.askSupervisor,
        ])
        // `ask_supervisor` auto-injects only for NON-producing roles
        // (`shouldAutoInjectAskSupervisor`), so a producing role that omits it is mute.
        XCTAssertFalse(teammate.shouldAutoInjectAskSupervisor)
        XCTAssertTrue(teammate.toolIDs.contains(TN.askSupervisor))
        // `create_artifact` is auto-injected for any role with producesArtifacts —
        // storing it would double-register the tool.
        XCTAssertFalse(teammate.toolIDs.contains(TN.createArtifact))
        // Nothing that mutates the work folder leaked into a read-only starter.
        for mutating in [TN.writeFile, TN.editFile, TN.deleteFile,
                         TN.gitAdd, TN.gitCommit,
                         TN.runXcodebuild, TN.runXcodetests,
                         TN.bash, TN.bashOutput] {
            XCTAssertFalse(teammate.toolIDs.contains(mutating),
                           "\(mutating) must not ship in the read-only starter toolset.")
        }
    }

    /// Drives the real `LLMExecutionService.resolveToolSchemas` — the stored `toolIDs` are
    /// only half the story: `create_artifact` and `ask_supervisor` are decided at resolve
    /// time, and the schema set is what `allowedToolNames` (+ToolIteration) is derived
    /// from, so a tool missing here is a runtime `tool_not_authorized`.
    func testEmpty_resolvedSchemaAutoInjectsCreateArtifactConstrainedToResult() {
        let team = TeamTemplateFactory.empty(name: "Alpha Team")
        // The Teammate has no systemRoleID, so `Role.fromDefinition` yields `.custom(name)`.
        let schemas = LLMExecutionService.resolveToolSchemas(
            for: .custom(id: TeamTemplateFactory.teammateRoleName), team: team
        )

        let createArtifact = schemas.filter { $0.name == ToolNames.createArtifact }
        XCTAssertEqual(createArtifact.count, 1,
                       "create_artifact auto-injects exactly once for a producing role.")
        // The per-role schema inlines the role's deliverables as a JSON-schema enum on
        // `name` — that is what stops the model inventing an artifact name the
        // `isValidArtifactName` guard would then reject.
        XCTAssertEqual(createArtifact.first?.parameters.properties?["name"]?.enumValues,
                       [TeamTemplateFactory.resultArtifactName])

        XCTAssertEqual(schemas.filter { $0.name == ToolNames.askSupervisor }.count, 1,
                       "ask_supervisor ships once — from toolIDs, not from auto-injection.")

        // The read-only contract survives resolution (nothing re-adds a mutating tool).
        for mutating in [ToolNames.writeFile, ToolNames.editFile, ToolNames.deleteFile,
                         ToolNames.gitCommit, ToolNames.bash, ToolNames.runXcodebuild] {
            XCTAssertFalse(schemas.contains { $0.name == mutating },
                           "\(mutating) must not appear in the starter role's resolved schema.")
        }
        // No delegation pack: the starter role has no delegation settings configured.
        XCTAssertFalse(schemas.contains { $0.name == ToolNames.delegateToTeam })
    }

    func testEmpty_teammatePromptIsNonEmptyAndComesFromRolePrompts() {
        // `empty(name:)` reads `SystemTemplates.rolePrompts["teammate"] ?? ""` — the key has
        // no `SystemTemplates.roles` entry by design, so a rename would silently degrade the
        // starter role to an EMPTY system prompt with nothing red.
        let teammate = TeamTemplateFactory.empty(name: "Alpha Team").nonSupervisorRoles[0]

        XCTAssertFalse(teammate.prompt.isEmpty)
        XCTAssertEqual(teammate.prompt, SystemTemplates.rolePrompts["teammate"])
    }

    // MARK: - Identity

    func testEmpty_differentNames_produceDisjointRoleAndArtifactIDs() {
        // The collision defect the deleted `createTeam` had: it re-seeded only `team.id`,
        // so every team it built shared FAANG's role ids. Role ids are a live namespace
        // (`StepExecution.id == roleID`, `settings.hierarchy.reportsTo`).
        let a = TeamTemplateFactory.empty(name: "Alpha")
        let b = TeamTemplateFactory.empty(name: "Beta")

        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(Set(a.roles.map(\.id)).isDisjoint(with: Set(b.roles.map(\.id))),
                      "Two empty teams must not share role ids.")
        XCTAssertTrue(Set(a.artifacts.map(\.id)).isDisjoint(with: Set(b.artifacts.map(\.id))),
                      "Two empty teams must not share artifact ids.")
    }

    func testEmpty_sameName_isDeterministic() {
        // Ids only — `createdAt`/`updatedAt` differ by design under MonotonicClock.
        let a = TeamTemplateFactory.empty(name: "Alpha")
        let b = TeamTemplateFactory.empty(name: "Alpha")

        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.roles.map(\.id), b.roles.map(\.id))
        XCTAssertEqual(a.artifacts.map(\.id), b.artifacts.map(\.id))
    }

    // MARK: - Custom-team invariants

    func testEmpty_isACustomTeam_notATemplate() {
        let team = TeamTemplateFactory.empty(name: "Alpha Team")

        XCTAssertNil(team.templateID,
                     "templateID must be nil so version-bump reconcile never rewrites this team.")
        XCTAssertNotEqual(team.templateID, TeamTemplateFactory.emptyTemplateID,
                          "\"empty\" is a picker token, never a stored templateID.")
        XCTAssertTrue(team.deletedSystemRoleIDs.isEmpty)
        XCTAssertTrue(team.deletedSystemArtifactIDs.isEmpty)
    }

    func testEmpty_contentIsFlaggedCustom_butSupervisorDetectionSurvives() {
        let team = TeamTemplateFactory.empty(name: "Alpha Team")

        for role in team.roles {
            XCTAssertFalse(role.isSystemRole,
                           "templateID == nil ⇒ system flags would be claims with no referent.")
        }
        for artifact in team.artifacts {
            XCTAssertFalse(artifact.isSystemArtifact)
        }
        XCTAssertTrue(team.roles[0].isSupervisor,
                      "isSupervisor keys on systemRoleID, not on isSystemRole.")
        // The Teammate carries NO systemRoleID at all — that is what keeps
        // `TeamManagementService.syncSystemRoleDependencies` (which gates on isSystemRole)
        // from rewriting the user's first edit to it on every work-folder open.
        XCTAssertNil(team.nonSupervisorRoles[0].systemRoleID)
    }

    func testEmpty_usesGenericPromptTemplates() {
        let team = TeamTemplateFactory.empty(name: "Alpha Team")

        XCTAssertEqual(team.systemPromptTemplate, SystemTemplates.genericTemplate)
        XCTAssertEqual(team.consultationPromptTemplate, SystemTemplates.genericConsultationTemplate)
        XCTAssertEqual(team.meetingPromptTemplate, SystemTemplates.genericMeetingTemplate)
        XCTAssertNotEqual(team.systemPromptTemplate, TeamTemplateFactory.faang().systemPromptTemplate,
                          "A custom team must not inherit FAANG's software template.")
    }

    // MARK: - Wiring

    func testEmpty_settingsWireTheTeammateToTheSupervisorWithAutoCoordinator() {
        let team = TeamTemplateFactory.empty(name: "Alpha Team")
        let supervisorID = team.roles[0].id
        let teammateID = team.nonSupervisorRoles[0].id

        XCTAssertEqual(team.settings.hierarchy.reportsTo, [teammateID: supervisorID])
        XCTAssertEqual(team.settings.invitableRoles, [teammateID])
        XCTAssertNil(team.settings.meetingCoordinatorRoleID, "nil == Auto mode.")
    }

    func testEmpty_graphLayoutHasOneNodePerRole() {
        let team = TeamTemplateFactory.empty(name: "Alpha Team")

        XCTAssertEqual(team.graphLayout.nodePositions.count, team.roles.count)
        XCTAssertEqual(Set(team.graphLayout.nodePositions.map(\.roleID)),
                       Set(team.roles.map(\.id)))
        XCTAssertTrue(team.graphLayout.hiddenRoleIDs.isEmpty)
    }

    func testEmpty_passesStructuralValidation() {
        // Specifically: no `.noRoles`. This is what fails if someone later "simplifies"
        // the factory to zero roles.
        let team = TeamTemplateFactory.empty(name: "Alpha Team")

        XCTAssertTrue(TeamManagementService.validate(team).isEmpty)
    }

    func testEmpty_supervisorTeammateLoopIsNotACircularDependency() {
        // Non-obvious and load-bearing: Supervisor requires "Result", Teammate requires
        // "Supervisor Task" — a cycle on paper. It is legal only because
        // `validateNoCircularDependencies` skips Supervisor edges ("review requirements,
        // not execution edges"). `startup()` relies on the same rule. Asserting merely
        // "no errors" would not say WHICH rule a future validator refactor broke.
        let team = TeamTemplateFactory.empty(name: "Alpha Team")
        let result = TeamValidationService.validate(team: team, allTeams: [team])

        XCTAssertTrue(result.isValid, "Unexpected errors: \(result.errors)")
        XCTAssertFalse(result.errors.contains { if case .circularDependency = $0 { return true }; return false })
        XCTAssertFalse(result.errors.contains { if case .missingProducer = $0 { return true }; return false })
        // Both artifacts are consumed, so the freshly created team shows no warning banner.
        XCTAssertFalse(result.warnings.contains { if case .orphanArtifact = $0 { return true }; return false },
                       "Unexpected warnings: \(result.warnings)")
    }

    func testEmpty_isNotABundledTemplate() {
        // The 9-vs-8 skew between metadata and allTemplates is intentional.
        XCTAssertFalse(TeamTemplateFactory.allTemplates.contains { $0.templateID == TeamTemplateFactory.emptyTemplateID })
        XCTAssertTrue(TeamTemplateFactory.templateMetadata.contains { $0.id == TeamTemplateFactory.emptyTemplateID })
    }

    // MARK: - makeTeam resolution

    func testMakeTeam_emptyID_returnsTheEmptyTeam() {
        let team = TeamTemplateFactory.makeTeam(templateID: TeamTemplateFactory.emptyTemplateID, name: "Mine")

        XCTAssertEqual(team.name, "Mine")
        XCTAssertEqual(team.roles.count, 2)
        XCTAssertTrue(team.roles[0].isSupervisor)
        XCTAssertNil(team.templateID)
    }

    func testMakeTeam_realTemplateID_duplicatesThatTemplate() {
        let faang = TeamTemplateFactory.faang()
        let team = TeamTemplateFactory.makeTeam(templateID: "faang", name: "Mine")

        XCTAssertEqual(team.name, "Mine")
        XCTAssertEqual(team.roles.count, faang.roles.count)
        XCTAssertEqual(team.artifacts.count, faang.artifacts.count)
        XCTAssertNil(team.templateID, "A duplicate is a CUSTOM team.")
    }

    func testMakeTeam_codingAgentID_preservesPromptsAndDelegationPolicy() {
        // Exercises the `Team.duplicate` regression documented in Team.swift — a
        // memberwise rebuild silently dropped the prompt templates and the two
        // delegation fields.
        let source = TeamTemplateFactory.codingAgent()
        let team = TeamTemplateFactory.makeTeam(templateID: "codingAgent", name: "Mine")

        XCTAssertEqual(team.systemPromptTemplate, source.systemPromptTemplate)
        XCTAssertEqual(team.nonSupervisorRoles.count, 1)
        XCTAssertEqual(team.nonSupervisorRoles[0].allowedDelegationTeamIDs.count,
                       source.nonSupervisorRoles[0].allowedDelegationTeamIDs.count)
        XCTAssertTrue(team.nonSupervisorRoles[0].allowDelegationToGeneratedTeams)
        XCTAssertTrue(team.nonSupervisorRoles[0].hasDelegationConfigured)
    }

    func testMakeTeam_unknownID_doesNotYieldFAANG() {
        // The reported bug in one assertion: an unrecognised selection must never fall
        // through to a populated roster. The old view-layer `else` branch called
        // `TeamManagementService.createTeam`, which cloned `Team.default`.
        let team = TeamTemplateFactory.makeTeam(templateID: "no_such_template", name: "Mine")

        XCTAssertEqual(team.roles.count, 2)
        XCTAssertTrue(team.roles[0].isSupervisor)
        XCTAssertNotEqual(team.roles.count, TeamTemplateFactory.faang().roles.count)
    }

    func testMakeTeam_emptyStringID_doesNotYieldFAANG() {
        let team = TeamTemplateFactory.makeTeam(templateID: "", name: "Mine")

        XCTAssertEqual(team.roles.count, 2)
        XCTAssertTrue(team.roles[0].isSupervisor)
    }

    func testMakeTeam_hiddenTemplateIDs_doNotResolve() {
        // "generated" and the Autovisor's are real templateIDs but are deliberately
        // absent from `allTemplates` — a picker string must never instantiate
        // infrastructure teams.
        for hidden in ["generated", AutovisorConstants.teamTemplateID] {
            let team = TeamTemplateFactory.makeTeam(templateID: hidden, name: "Mine")
            XCTAssertEqual(team.roles.count, 2, "\(hidden) must fall back to the empty team.")
            XCTAssertNil(team.templateID)
        }
    }
}
