import XCTest
@testable import NanoTeams

/// The role-list tool badge.
///
/// The invariant under test is that the badge NEVER models the injection rules
/// itself: it runs `EffectiveToolset` (the same three-stage chain the wire uses)
/// and classifies the leftovers. So these tests are as much a pin on "the badge
/// agrees with the runtime" as on the classification.
final class RoleToolBadgePolicyTests: XCTestCase {

    // A path that is definitely not a git repository, so the git-availability
    // stage strips git tools deterministically.
    private let nonGitRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("RoleToolBadgePolicyTests-not-a-repo")

    private func role(
        id: String = "r1",
        name: String = "Role",
        toolIDs: [String],
        produces: [String] = [],
        requires: [String] = [],
        systemRoleID: String? = nil,
        delegationTeamIDs: [String] = [],
        allowGenerated: Bool = false,
        attachedSkillIDs: [String] = []
    ) -> TeamRoleDefinition {
        var def = TeamRoleDefinition(
            id: id,
            name: name,
            prompt: "",
            toolIDs: toolIDs,
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: requires, producesArtifacts: produces),
            allowedDelegationTeamIDs: delegationTeamIDs,
            allowDelegationToGeneratedTeams: allowGenerated,
            isSystemRole: systemRoleID != nil,
            systemRoleID: systemRoleID
        )
        def.attachedSkillIDs = attachedSkillIDs
        return def
    }

    private func team(
        _ roles: [TeamRoleDefinition],
        id: String = "team",
        templateID: String? = nil,
        settings: TeamSettings = TeamSettings()
    ) -> Team {
        var t = Team(
            id: id, name: "Team",
            roles: roles, artifacts: [],
            settings: settings, graphLayout: TeamGraphLayout()
        )
        t.templateID = templateID
        return t
    }

    private func model(
        _ def: TeamRoleDefinition,
        team: Team?,
        allTeams: [Team] = [],
        storage: EffectiveToolset.Storage? = nil,
        selectedScheme: String? = nil,
        isVisionConfigured: Bool = false,
        isComputerUseEnabled: Bool = false
    ) -> RoleToolBadgePolicy.Model {
        RoleToolBadgePolicy.model(
            role: def,
            team: team,
            allTeams: allTeams,
            storage: storage ?? .realFolder(root: nonGitRoot),
            selectedScheme: selectedScheme,
            isVisionConfigured: isVisionConfigured,
            isComputerUseEnabled: isComputerUseEnabled,
            autovisorTeamPolicy: .unrestricted
        )
    }

    // MARK: - Auto-injection

    func testProducingRole_getsCreateArtifactAsAutoInjected() {
        let def = role(toolIDs: [ToolNames.readFile], produces: ["Notes"])
        let m = model(def, team: team([def]))

        XCTAssertTrue(m.autoInjected.contains(ToolNames.createArtifact))
        XCTAssertTrue(m.effective.contains(ToolNames.createArtifact))
        XCTAssertFalse(m.configured.contains(ToolNames.createArtifact),
                       "it was injected, not selected — it must not read as the user's choice")
    }

    func testAdvisoryRole_getsAskSupervisorAsAutoInjected() {
        let def = role(toolIDs: [ToolNames.readFile], requires: ["Brief"])
        let m = model(def, team: team([def]))

        XCTAssertTrue(m.autoInjected.contains(ToolNames.askSupervisor))
    }

    func testAutovisorManager_neverGetsAskSupervisor() {
        let def = role(toolIDs: [ToolNames.readFile], requires: ["Brief"],
                       systemRoleID: AutovisorConstants.managerRoleSystemID)
        let m = model(def, team: team([def], templateID: AutovisorConstants.teamTemplateID))

        XCTAssertFalse(m.effective.contains(ToolNames.askSupervisor),
                       "the manager IS the top Supervisor — a self-escalation loop")
        XCTAssertFalse(m.autoInjected.contains(ToolNames.askSupervisor))
    }

    func testMeetingRole_inAutoCoordinatorMode_getsConcludeMeeting() {
        let def = role(toolIDs: [ToolNames.requestTeamMeeting])
        let m = model(def, team: team([def]))

        XCTAssertTrue(m.autoInjected.contains(ToolNames.concludeMeeting))
    }

    // MARK: - Delegation pack

    func testDelegationWithUsableTeam_injectsTheWholeFourToolPack() {
        // The target must NOT be chat-mode — chat teams never auto-complete, so
        // `Team.isValidDelegationTarget` excludes them. A team is chat-mode exactly
        // when its Supervisor requires no artifact back.
        let target = team([
            role(id: "sup", name: "Supervisor", toolIDs: [],
                 requires: ["Result"], systemRoleID: "supervisor"),
            role(id: "x", toolIDs: [], produces: ["Result"]),
        ], id: "target")
        let def = role(toolIDs: [ToolNames.readFile], delegationTeamIDs: ["target"])
        let m = model(def, team: team([def]), allTeams: [target])

        for name in [ToolNames.delegateToTeam, ToolNames.cancelDelegation,
                     ToolNames.resumeDelegation, ToolNames.forwardToTeam] {
            XCTAssertTrue(m.autoInjected.contains(name), "missing \(name) — the pack is a unit")
        }
    }

    func testNoDelegationTargets_injectsNothing() {
        let def = role(toolIDs: [ToolNames.readFile])
        let m = model(def, team: team([def]))

        XCTAssertFalse(m.effective.contains(ToolNames.delegateToTeam))
    }

    /// The improvement over the editor's old boolean model, which advertised the
    /// pack whenever ANY target id was configured.
    func testWhitelistedTeamDeleted_andGeneratedOff_injectsNoPack() {
        let def = role(toolIDs: [ToolNames.readFile], delegationTeamIDs: ["gone"])
        let m = model(def, team: team([def]), allTeams: [])

        XCTAssertFalse(m.effective.contains(ToolNames.delegateToTeam),
                       "every whitelisted team is gone — the tool could only ever fail")
    }

    // MARK: - Unavailable here

    func testVisionOff_reportsAnalyzeImageAsRequiringAVisionModel() {
        let def = role(toolIDs: [ToolNames.readFile, ToolNames.analyzeImage])
        let m = model(def, team: team([def]), isVisionConfigured: false)

        XCTAssertEqual(m.unavailableHere[.visionModel], [ToolNames.analyzeImage])
        XCTAssertTrue(m.notInstalled.isEmpty, "a disabled feature is not a broken toolset")
    }

    func testComputerUseOff_reportsTheFiveToolsUnderOneReason() {
        let tools = Array(ToolHandlerRegistry.computerUseTools)
        let def = role(toolIDs: tools + [ToolNames.readFile])
        let m = model(def, team: team([def]), isComputerUseEnabled: false)

        XCTAssertEqual(Set(m.unavailableHere[.computerUse] ?? []), Set(tools))
    }

    func testNoXcodeScheme_reportsTheXcodeTools() {
        let def = role(toolIDs: [ToolNames.runXcodebuild, ToolNames.runXcodetests])
        let m = model(def, team: team([def]), selectedScheme: nil)

        XCTAssertEqual(m.unavailableHere[.xcodeScheme],
                       [ToolNames.runXcodebuild, ToolNames.runXcodetests].sorted())
    }

    func testNonGitFolder_reportsGitToolsAsRequiringARepo() {
        let def = role(toolIDs: [ToolNames.gitStatus, ToolNames.readFile])
        let m = model(def, team: team([def]))

        XCTAssertEqual(m.unavailableHere[.gitRepository], [ToolNames.gitStatus])
    }

    /// Work folder beats git: telling the user to `git init` a folder they have
    /// not opened sends them to the wrong fix.
    func testDefaultStorage_reportsGitToolsAsRequiringAWorkFolder_notARepo() {
        let def = role(toolIDs: [ToolNames.gitStatus])
        let m = model(def, team: team([def]), storage: .defaultStorage)

        XCTAssertEqual(m.unavailableHere[.workFolder], [ToolNames.gitStatus])
        XCTAssertNil(m.unavailableHere[.gitRepository])
    }

    // MARK: - Classification of the rest

    func testUnknownToolName_isReportedAsNotInstalled() {
        let def = role(toolIDs: [ToolNames.readFile, "frobnicate"])
        let m = model(def, team: team([def]))

        XCTAssertEqual(m.notInstalled, ["frobnicate"])
        XCTAssertTrue(m.needsAttention, "a tool with no handler is the one real problem")
    }

    func testDelegationToolInToolIDs_isQuietNotAProblem() {
        let def = role(toolIDs: [ToolNames.readFile, ToolNames.delegateToTeam])
        let m = model(def, team: team([def]))

        XCTAssertTrue(m.policyBlocked.contains(ToolNames.delegateToTeam))
        XCTAssertTrue(m.notInstalled.isEmpty)
        XCTAssertFalse(m.needsAttention)
    }

    func testDuplicateToolIDs_countedOnce() {
        let def = role(toolIDs: [ToolNames.readFile, ToolNames.readFile, ToolNames.search])
        let m = model(def, team: team([def]))

        XCTAssertEqual(m.configured.count, 2)
        XCTAssertEqual(m.effective.count, Set(m.effective).count)
    }

    func testRoleWithNoTools_isSilent() {
        let def = role(toolIDs: [])
        let m = model(def, team: team([def]))

        XCTAssertTrue(m.isSilent, "nothing selected and nothing injected — no badge at all")
    }

    func testEverythingWithheld_isNotSilent_soTheReasonStillSurfaces() {
        let def = role(toolIDs: [ToolNames.analyzeImage])
        let m = model(def, team: team([def]), isVisionConfigured: false)

        XCTAssertTrue(m.isEmpty)
        XCTAssertFalse(m.isSilent)
        XCTAssertTrue(m.needsAttention)
    }

    // MARK: - The lossy-lookup regression

    /// RED against the pre-fix design, which reached the resolver via
    /// `Role.fromDefinition(role)` → `Team.findRole(byIdentifier:)`.
    /// `fromDefinition` collapses every role sharing a `systemRoleID` onto one enum
    /// case and `findRole` returns the FIRST match, so the duplicate produced by one
    /// "Duplicate" click in the team editor rendered — and RAN with — its twin's
    /// toolset, silently.
    func testDuplicatedSystemRole_eachCopyResolvesToItsOwnToolset() {
        let original = role(id: "orig", name: "Software Engineer",
                            toolIDs: [ToolNames.readFile],
                            systemRoleID: "softwareEngineer")
        let copy = role(id: "copy", name: "Software Engineer Copy",
                        toolIDs: [ToolNames.search, ToolNames.updateScratchpad],
                        systemRoleID: "softwareEngineer")
        let t = team([original, copy])

        let originalModel = model(original, team: t)
        let copyModel = model(copy, team: t)

        XCTAssertEqual(originalModel.configured, [ToolNames.readFile])
        XCTAssertEqual(copyModel.configured, [ToolNames.search, ToolNames.updateScratchpad].sorted())
    }

    /// Pins WHY the definition-taking entry point exists: the `Role` round-trip
    /// still binds both copies to the first role. If this ever starts agreeing, the
    /// lookup became injective and the overload's rationale needs revisiting.
    func testRoleRoundTrip_stillCollapsesDuplicates_whichIsWhyTheOverloadExists() {
        let original = role(id: "orig", name: "Software Engineer",
                            toolIDs: [ToolNames.readFile],
                            systemRoleID: "softwareEngineer")
        let copy = role(id: "copy", name: "Software Engineer Copy",
                        toolIDs: [ToolNames.search],
                        systemRoleID: "softwareEngineer")
        let t = team([original, copy])

        let viaRole = LLMExecutionService.resolveToolSchemas(
            for: Role.fromDefinition(copy), team: t).map(\.name)
        let viaDefinition = LLMExecutionService.resolveToolSchemas(
            forDefinition: copy, team: t).map(\.name)

        XCTAssertTrue(viaRole.contains(ToolNames.readFile),
                      "the lossy path picks up the FIRST systemRoleID match")
        XCTAssertFalse(viaRole.contains(ToolNames.search))
        XCTAssertTrue(viaDefinition.contains(ToolNames.search))
        XCTAssertFalse(viaDefinition.contains(ToolNames.readFile))
    }

    // MARK: - Memo signature

    /// Every field the model reads must move the signature, or the row keeps a
    /// stale badge after an edit.
    func testResolutionSignature_movesForEveryFieldTheModelReads() {
        let base = role(toolIDs: [ToolNames.readFile])
        let baseline = RoleToolBadgePolicy.resolutionSignature(for: base)

        var mutations: [(String, TeamRoleDefinition)] = []
        mutations.append(("id", role(id: "other", toolIDs: [ToolNames.readFile])))
        mutations.append(("toolIDs", role(toolIDs: [ToolNames.search])))
        mutations.append(("produces", role(toolIDs: [ToolNames.readFile], produces: ["X"])))
        mutations.append(("requires", role(toolIDs: [ToolNames.readFile], requires: ["Y"])))
        mutations.append(("systemRoleID", role(toolIDs: [ToolNames.readFile], systemRoleID: "pm")))
        mutations.append(("delegationTeams",
                          role(toolIDs: [ToolNames.readFile], delegationTeamIDs: ["t"])))
        mutations.append(("allowGenerated",
                          role(toolIDs: [ToolNames.readFile], allowGenerated: true)))
        mutations.append(("attachedSkills",
                          role(toolIDs: [ToolNames.readFile], attachedSkillIDs: ["s"])))

        for (field, mutated) in mutations {
            XCTAssertNotEqual(RoleToolBadgePolicy.resolutionSignature(for: mutated), baseline,
                              "\(field) changes resolution but not the memo key — stale badge")
        }
    }

    func testResolutionSignature_isStableForAnIdenticalRole() {
        let a = role(toolIDs: [ToolNames.search, ToolNames.readFile])
        let b = role(toolIDs: [ToolNames.readFile, ToolNames.search])

        XCTAssertEqual(RoleToolBadgePolicy.resolutionSignature(for: a),
                       RoleToolBadgePolicy.resolutionSignature(for: b),
                       "toolIDs order is not resolution-relevant — reordering must not rebuild")
    }

    // MARK: - Tooltip

    func testTooltip_separatesSelectedFromAutoInjected_andNamesTheScope() {
        let def = role(toolIDs: [ToolNames.readFile], produces: ["Notes"])
        let text = RoleToolBadgePolicy.tooltip(model(def, team: team([def])))

        XCTAssertTrue(text.contains("step execution"),
                      "the count excludes meeting / planning narrowing — say which set it is")
        XCTAssertTrue(text.contains("Selected: \(ToolNames.readFile)"))
        XCTAssertTrue(text.contains("Auto-injected: \(ToolNames.createArtifact)"))
    }

    func testTooltip_groupsWithheldToolsUnderTheirReason() {
        let def = role(toolIDs: [ToolNames.readFile, ToolNames.analyzeImage])
        let text = RoleToolBadgePolicy.tooltip(model(def, team: team([def])))

        XCTAssertTrue(text.contains("Requires vision model: \(ToolNames.analyzeImage)"))
    }

    func testTooltip_singularNoun() {
        let def = role(toolIDs: [ToolNames.readFile])
        let text = RoleToolBadgePolicy.tooltip(model(def, team: team([def])))

        XCTAssertTrue(text.hasPrefix("1 tool ship"), "got: \(text)")
    }
}
