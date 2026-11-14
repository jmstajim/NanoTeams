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
        // Helper default, not the runtime's: computer-use Off, bash available — the reading
        // every existing case was written against when the parameter was a Bool.
        approval: ToolApprovalAvailability = ToolApprovalAvailability(bash: .available, computerUse: .withheld(.switchedOff), humanPresent: true),
        mcpGrants: MCPGrantCatalogue = .empty
    ) -> RoleToolBadgePolicy.Model {
        RoleToolBadgePolicy.model(
            role: def,
            team: team,
            allTeams: allTeams,
            storage: storage ?? .realFolder(root: nonGitRoot),
            selectedScheme: selectedScheme,
            isVisionConfigured: isVisionConfigured,
            approval: approval,
            autovisorTeamPolicy: .unrestricted,
            mcpGrants: mcpGrants
        )
    }

    // MARK: - MCP and the run's human (F46)

    private static let telegramID = UUID(uuidString: "00000000-0000-0000-0000-0000000E4601")!
    private static let tradeID = UUID(uuidString: "00000000-0000-0000-0000-0000000E4602")!

    /// Telegram in Manual mode with `send_message` approved — a Manual server's tool never runs
    /// unattended — and Trade-Room trusted and Semi-automatic, whose read-only `get_orders`
    /// runs unattended and whose `place_order` does not.
    private func mcpCatalogue() throws -> MCPGrantCatalogue {
        MCPGrantCatalogue(servers: [
            try MCPGrantCatalogueTests.makeServer(
                slug: "telegram", id: Self.telegramID, approvalMode: .manual,
                tools: [try MCPGrantCatalogueTests.makeTool(slug: "telegram", tool: "send_message")]),
            try MCPGrantCatalogueTests.makeServer(
                slug: "trade_room", id: Self.tradeID, approvalMode: .semiAutomatic, isTrusted: true,
                tools: [
                    try MCPGrantCatalogueTests.makeTool(slug: "trade_room", tool: "get_orders", runsUnattended: true),
                    try MCPGrantCatalogueTests.makeTool(slug: "trade_room", tool: "place_order"),
                ]),
        ])
    }

    /// Supervisor mode Autonomous — the families' modes are beside the point here.
    private let nobodyThere = ToolApprovalAvailability(bashMode: .auto, computerUseMode: .auto, humanPresent: false)

    /// The runtime withholds every tool of a Manual server from a run with nobody to approve;
    /// the badge says so, with the same words bash and computer-use get.
    ///
    /// RED until 2026-09-24: the editor asked the catalogue with a person present "by
    /// construction", counted the tool as shipped, and showed no hint (F46).
    func testAnMCPToolOfAManualServerIsWithheldOnAnAutonomousTeam() throws {
        let def = role(toolIDs: ["mcp__telegram__send_message"])
        let m = model(def, team: team([def]), approval: nobodyThere, mcpGrants: try mcpCatalogue())

        XCTAssertFalse(m.effective.contains("mcp__telegram__send_message"))
        XCTAssertEqual(m.unavailableHere[.humanApprover], ["mcp__telegram__send_message"])
        XCTAssertNil(m.unavailableHere[.mcpToolLive], "not a missing tool — a missing person")
        XCTAssertEqual(
            ToolAvailabilityRequirement.governing(
                "mcp__telegram__send_message", isDefaultStorage: false,
                approval: nobodyThere, mcpGrants: try mcpCatalogue()),
            .humanApprover)
    }

    func testTheSameToolShipsWhenAPersonIsThere() throws {
        let def = role(toolIDs: ["mcp__telegram__send_message"])
        let m = model(def, team: team([def]), approval: .available, mcpGrants: try mcpCatalogue())

        XCTAssertEqual(m.effective, ["mcp__telegram__send_message"])
        XCTAssertTrue(m.unavailableHere.isEmpty)
        XCTAssertNil(
            ToolAvailabilityRequirement.governing(
                "mcp__telegram__send_message", isDefaultStorage: false,
                approval: .available, mcpGrants: try mcpCatalogue()))
    }

    /// The split is per tool: a server's read-only tool that clears its policy unattended ships
    /// to an Autonomous team while its order-placing one is withheld.
    func testOnlyTheToolsThatRunUnattendedShipOnAnAutonomousTeam() throws {
        let def = role(toolIDs: ["mcp__trade_room__get_orders", "mcp__trade_room__place_order"])
        let m = model(def, team: team([def]), approval: nobodyThere, mcpGrants: try mcpCatalogue())

        XCTAssertEqual(m.effective, ["mcp__trade_room__get_orders"])
        XCTAssertEqual(m.unavailableHere[.humanApprover], ["mcp__trade_room__place_order"])
    }

    /// A whole-server grant of a server nothing of which could run without a person is
    /// reported under the missing person, like its tools.
    func testAWholeServerGrantWithNothingThatRunsUnattendedNeedsAPerson() throws {
        let def = role(toolIDs: ["mcp__telegram"])
        let m = model(def, team: team([def]), approval: nobodyThere, mcpGrants: try mcpCatalogue())

        XCTAssertTrue(m.effective.isEmpty)
        XCTAssertEqual(m.unavailableHere[.humanApprover], ["mcp__telegram"])
        XCTAssertNil(m.unavailableHere[.mcpToolLive])
    }

    /// A whole-server grant that BRINGS tools is not a withheld grant, and the tools it brings
    /// are the role's own choice, not something the runtime injected.
    ///
    /// RED until 2026-09-24: the grant's own name never ships (its tools do), so the badge filed
    /// it under "No configured MCP server offers this — uncheck it here", and listed the tools
    /// it brought as auto-injected.
    func testAWholeServerGrantThatBringsToolsIsTheRolesOwnChoice() throws {
        let def = role(toolIDs: ["mcp__trade_room"])
        let attended = model(def, team: team([def]), approval: .available, mcpGrants: try mcpCatalogue())

        XCTAssertEqual(attended.effective, ["mcp__trade_room__get_orders", "mcp__trade_room__place_order"])
        XCTAssertTrue(attended.unavailableHere.isEmpty)
        XCTAssertEqual(attended.autoInjected, [])
        XCTAssertEqual(attended.configured, ["mcp__trade_room__get_orders", "mcp__trade_room__place_order"])

        let unattended = model(def, team: team([def]), approval: nobodyThere, mcpGrants: try mcpCatalogue())
        XCTAssertEqual(unattended.effective, ["mcp__trade_room__get_orders"])
        XCTAssertTrue(unattended.unavailableHere.isEmpty, "the grant still brings a tool")
        XCTAssertEqual(unattended.autoInjected, [])
    }

    /// A whole-server grant of a connected server that publishes tools and has none approved
    /// brings the role nothing, and the badge says why — with a person there to approve or not,
    /// since review comes before presence.
    ///
    /// RED until 2026-09-24: the grant read `.live`, the loop skipped a live whole-server grant
    /// as one whose tools had shipped, and the role held `mcp__folio`, received no tool at run
    /// time, and showed no badge.
    func testAWholeServerGrantOfAServerWithNothingApprovedWaitsForReview() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try MCPGrantCatalogueTests.makeServer(
                slug: "folio", id: Self.telegramID, approvalMode: .semiAutomatic,
                tools: [
                    try MCPGrantCatalogueTests.makeTool(slug: "folio", tool: "get_screenshot", pinState: .new),
                    try MCPGrantCatalogueTests.makeTool(
                        slug: "folio", tool: "get_metadata", pinState: .changed(approvedHash: "old")),
                ]),
        ])
        let def = role(toolIDs: ["mcp__folio"])
        for approval in [ToolApprovalAvailability.available, nobodyThere] {
            let m = model(def, team: team([def]), approval: approval, mcpGrants: catalogue)

            XCTAssertTrue(m.effective.isEmpty, "\(approval.humanPresent)")
            XCTAssertEqual(m.unavailableHere[.mcpToolUnreviewed], ["mcp__folio"], "\(approval.humanPresent)")
            XCTAssertEqual(m.unavailableHere.count, 1, "\(approval.humanPresent)")
            XCTAssertEqual(
                ToolAvailabilityRequirement.governing(
                    "mcp__folio", isDefaultStorage: false, approval: approval, mcpGrants: catalogue),
                .mcpToolUnreviewed)
        }
    }

    /// A server that publishes nothing gives the grant nothing to wait for: no badge, since no
    /// repair exists — whatever the server publishes and a person approves later rides in on it.
    func testAWholeServerGrantOfAServerThatPublishesNothingCarriesNoBadge() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try MCPGrantCatalogueTests.makeServer(slug: "folio", id: Self.telegramID),
        ])
        let def = role(toolIDs: ["mcp__folio"])
        let m = model(def, team: team([def]), approval: .available, mcpGrants: catalogue)

        XCTAssertTrue(m.effective.isEmpty)
        XCTAssertTrue(m.unavailableHere.isEmpty)
        XCTAssertTrue(m.notInstalled.isEmpty)
        XCTAssertTrue(m.policyBlocked.isEmpty)
    }

    // MARK: - A refused text, a withdrawn tool (2026-10-28)

    /// A grant of a text the person refused is filed under the refusal — with the words that
    /// say they rejected it and where to review it again — not under "Waiting for review",
    /// which is what the Settings list counts it apart from. A whole-server grant of a server
    /// whose every text was refused gets the whole-server form.
    ///
    /// RED until 2026-10-28: both were filed under `.mcpToolUnreviewed`.
    func testARefusedGrantIsFiledUnderTheRefusalNotUnderWaitingForReview() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try MCPGrantCatalogueTests.makeServer(
                slug: "folio", id: Self.telegramID,
                tools: [
                    try MCPGrantCatalogueTests.makeTool(
                        slug: "folio", tool: "get_screenshot", pinState: .new, isRejected: true),
                    try MCPGrantCatalogueTests.makeTool(
                        slug: "folio", tool: "get_metadata", pinState: .changed(approvedHash: "old"), isRejected: true),
                ]),
        ])
        let def = role(toolIDs: ["mcp__folio", "mcp__folio__get_screenshot"])
        let m = model(def, team: team([def]), approval: .available, mcpGrants: catalogue)

        XCTAssertTrue(m.effective.isEmpty)
        XCTAssertEqual(m.unavailableHere[.mcpToolRefused], ["mcp__folio__get_screenshot"])
        XCTAssertEqual(m.unavailableHere[.mcpServerToolsRefused], ["mcp__folio"])
        XCTAssertNil(m.unavailableHere[.mcpToolUnreviewed], "nothing is waiting for review")
        XCTAssertEqual(
            ToolAvailabilityRequirement.governing(
                "mcp__folio__get_screenshot", isDefaultStorage: false, approval: .available, mcpGrants: catalogue),
            .mcpToolRefused)

        let tooltip = RoleToolBadgePolicy.tooltip(m)
        XCTAssertTrue(tooltip.contains(
            "You rejected this tool's text — review it again in Settings → MCP Servers to grant it: "
                + "mcp__folio__get_screenshot"), tooltip)
        XCTAssertTrue(tooltip.contains(
            "You rejected the text of every tool this server publishes — review them again in "
                + "Settings → MCP Servers to grant them: mcp__folio"), tooltip)
        XCTAssertFalse(tooltip.contains("Waiting for review"), tooltip)
    }

    /// A grant of a tool its connected server does not publish sits under that server's own
    /// header, so its words name the server's answer and the repair that is the role's — not
    /// "No configured MCP server offers this … or add the server", which stays for a grant
    /// naming no configured server at all.
    ///
    /// RED until 2026-10-28: `.toolMissing` and `.unknownServer` shared `.mcpToolLive`.
    func testAToolItsServerDoesNotOfferSaysSoApartFromAnUnknownServer() throws {
        let def = role(toolIDs: ["mcp__telegram__get_updates", "mcp__gone__x"])
        let m = model(def, team: team([def]), approval: .available, mcpGrants: try mcpCatalogue())

        XCTAssertEqual(m.unavailableHere[.mcpToolNotOffered], ["mcp__telegram__get_updates"])
        XCTAssertEqual(m.unavailableHere[.mcpToolLive], ["mcp__gone__x"])
        XCTAssertEqual(ToolAvailabilityRequirement.forMCPGrant(.toolMissing), .mcpToolNotOffered)
        XCTAssertEqual(ToolAvailabilityRequirement.forMCPGrant(.unknownServer), .mcpToolLive)
        XCTAssertEqual(
            ToolAvailabilityRequirement.mcpToolNotOffered.unmetHint,
            "Its MCP server does not offer this tool — uncheck it here")
        XCTAssertNil(ToolAvailabilityRequirement.mcpToolNotOffered.metHint)
    }

    /// A tool the APP cannot offer is badged as the app's refusal — pointing at the Settings page
    /// that says why — never as the server's withdrawal, and a whole-server grant of a server
    /// the app can offer nothing of is badged rather than silent. The words change; what ships
    /// does not: neither brings a tool, as before.
    ///
    /// RED until 2026-10-28: the per-tool grant read "Its MCP server does not offer this tool
    /// — uncheck it here", and the whole-server grant read live — no badge.
    func testAToolTheAppCannotOfferIsBadgedAsSuchAndAServerOfNothingOfferableIsNotSilent() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try MCPGrantCatalogueTests.makeServer(
                slug: "orders", id: Self.tradeID, nothingOffered: true, refused: ["mcp__orders__get_orders"]),
            try MCPGrantCatalogueTests.makeServer(
                slug: "telegram", id: Self.telegramID,
                tools: [try MCPGrantCatalogueTests.makeTool(slug: "telegram", tool: "send_message")],
                refused: ["mcp__telegram__get_updates"]),
        ])
        let def = role(toolIDs: ["mcp__orders__get_orders", "mcp__orders", "mcp__telegram__get_updates"])
        let m = model(def, team: team([def]), approval: .available, mcpGrants: catalogue)

        XCTAssertEqual(m.unavailableHere[.mcpToolNotOfferable], ["mcp__orders__get_orders", "mcp__telegram__get_updates"])
        XCTAssertEqual(m.unavailableHere[.mcpServerToolsNotOfferable], ["mcp__orders"])
        XCTAssertNil(m.unavailableHere[.mcpToolNotOffered], "not the server's withdrawal")
        XCTAssertFalse(m.isSilent, "a grant that brings nothing is badged")
        XCTAssertTrue(m.effective.filter(MCPToolNaming.isMCPName).isEmpty, "nothing of it ships, as before")

        XCTAssertEqual(ToolAvailabilityRequirement.forMCPGrant(.toolNotOfferable), .mcpToolNotOfferable)
        XCTAssertEqual(ToolAvailabilityRequirement.forMCPGrant(.noToolOfferable), .mcpServerToolsNotOfferable)
        XCTAssertEqual(
            ToolAvailabilityRequirement.mcpToolNotOfferable.unmetHint,
            "The app cannot offer what its MCP server publishes as this tool — see Settings → MCP Servers")
        XCTAssertEqual(
            ToolAvailabilityRequirement.mcpServerToolsNotOfferable.unmetHint,
            "The app cannot offer any tool its MCP server publishes — see Settings → MCP Servers")
        for requirement in [ToolAvailabilityRequirement.mcpToolNotOfferable, .mcpServerToolsNotOfferable] {
            XCTAssertNil(requirement.metHint)
            XCTAssertTrue(ToolAvailabilityRequirement.allCases.contains(requirement),
                          "the tooltip iterates allCases — a case missing there never renders")
            XCTAssertTrue(RoleToolBadgePolicy.tooltip(m).contains(requirement.unmetHint), "\(requirement)")
        }
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

    // MARK: - Meeting-only tools

    /// `conclude_meeting` is never a STEP tool — not injected, not selectable — but the
    /// team's coordinator holds it inside meeting turns, and the badge says so through
    /// `meetingOnly`, read from the same list the meeting runtime appends.
    func testCoordinator_getsConcludeMeetingAsMeetingOnly_neverAsAutoInjected() {
        let coordinator = role(id: "coord", toolIDs: [ToolNames.requestTeamMeeting])
        let other = role(id: "other", toolIDs: [ToolNames.requestTeamMeeting])
        let t = team([coordinator, other],
                     settings: TeamSettings(meetingCoordinatorRoleID: "coord"))

        let coordModel = model(coordinator, team: t)
        let otherModel = model(other, team: t)

        XCTAssertEqual(coordModel.meetingOnly, [ToolNames.concludeMeeting])
        XCTAssertFalse(coordModel.autoInjected.contains(ToolNames.concludeMeeting))
        XCTAssertFalse(coordModel.effective.contains(ToolNames.concludeMeeting),
                       "the step set never carries it")
        XCTAssertEqual(otherModel.meetingOnly, [], "only the coordinator holds it")
        XCTAssertTrue(RoleToolBadgePolicy.tooltip(coordModel).contains("In meeting turns only"))
    }

    /// A legacy `toolIDs` entry for `conclude_meeting` cannot ship from a step schema —
    /// it is `availableToRoles == false` — and the badge files it as policy-blocked.
    func testLegacyConcludeMeetingInToolIDs_isPolicyBlocked() {
        let def = role(toolIDs: [ToolNames.requestTeamMeeting, ToolNames.concludeMeeting])
        let m = model(def, team: team([def]))

        XCTAssertTrue(m.policyBlocked.contains(ToolNames.concludeMeeting))
        XCTAssertFalse(m.effective.contains(ToolNames.concludeMeeting))
    }

    func testMeetingsOff_withholdsMeetingToolsUnderTheirOwnRequirement_andNoMeetingOnly() {
        let def = role(id: "coord", toolIDs: [ToolNames.requestTeamMeeting, ToolNames.requestChanges, ToolNames.readFile])
        let t = team([def], settings: TeamSettings(meetingCoordinatorRoleID: "coord", meetingsEnabled: false))
        let m = model(def, team: t)

        XCTAssertEqual(m.unavailableHere[.meetingsEnabled],
                       [ToolNames.requestChanges, ToolNames.requestTeamMeeting])
        XCTAssertFalse(m.effective.contains(ToolNames.requestTeamMeeting))
        XCTAssertEqual(m.meetingOnly, [], "no meetings ⇒ nothing to conclude")
        XCTAssertTrue(RoleToolBadgePolicy.tooltip(m).contains("Meetings are off"))
    }

    /// Switch on, nobody to reach: the two meeting tools AND `ask_teammate` file under the
    /// ONE partner requirement (`Team.hasTeammatePartner`) with a hint about the roster,
    /// not the switch; the lone coordinator has no meeting to conclude. Until 2026-09-07
    /// the `supervisorCanBeInvited` seat made an LLM answering AS the Supervisor this
    /// role's only "partner", so a single-role team still shipped `ask_teammate`.
    func testSingleRoleTeam_withholdsCollaborationToolsUnderTeammatePartner_andNoMeetingOnly() {
        let def = role(id: "coord", toolIDs: [ToolNames.requestTeamMeeting, ToolNames.requestChanges,
                                              ToolNames.askTeammate, ToolNames.readFile])
        let t = team([def], settings: TeamSettings(meetingCoordinatorRoleID: "coord"))
        XCTAssertFalse(t.hasTeammatePartner)
        let m = model(def, team: t)

        XCTAssertEqual(m.unavailableHere[.teammatePartner],
                       [ToolNames.askTeammate, ToolNames.requestChanges, ToolNames.requestTeamMeeting].sorted())
        XCTAssertNil(m.unavailableHere[.meetingsEnabled], "the switch is on — the roster is the reason")
        XCTAssertFalse(m.effective.contains(ToolNames.askTeammate))
        XCTAssertTrue(m.effective.contains(ToolNames.readFile))
        XCTAssertEqual(m.meetingOnly, [], "no partner ⇒ no meeting ⇒ nothing to conclude")
        XCTAssertTrue(RoleToolBadgePolicy.tooltip(m).contains("second teammate"))
    }

    /// The meetings switch governs meetings alone: a two-role team with meetings off still
    /// ships `ask_teammate`, and only `request_team_meeting` files under the switch.
    func testMeetingsOff_withAPartner_keepsAskTeammate() {
        let def = role(id: "coord", toolIDs: [ToolNames.askTeammate, ToolNames.requestTeamMeeting])
        let partner = role(id: "partner", toolIDs: [ToolNames.readFile])
        let t = team([def, partner],
                     settings: TeamSettings(meetingCoordinatorRoleID: "coord", meetingsEnabled: false))
        XCTAssertTrue(t.hasTeammatePartner)
        let m = model(def, team: t)

        XCTAssertEqual(m.unavailableHere[.meetingsEnabled], [ToolNames.requestTeamMeeting])
        XCTAssertTrue(m.effective.contains(ToolNames.askTeammate))
        XCTAssertNil(m.unavailableHere[.teammatePartner],
                     "a partner exists — the switch is not the partner rule")
    }

    /// The Supervisor is the human and never counts as a partner: Supervisor + one role is
    /// still a single-role roster, so `ask_teammate` has nobody to reach. Until 2026-09-07
    /// this was exactly the roster on which the seat let an LLM answer AS the Supervisor.
    func testSupervisorPlusOneRole_isNoPartner_askTeammateWithheld() {
        let supervisor = role(id: "sup", name: "Supervisor", toolIDs: [], systemRoleID: "supervisor")
        let def = role(toolIDs: [ToolNames.askTeammate, ToolNames.readFile])
        let t = team([supervisor, def])
        XCTAssertFalse(t.hasTeammatePartner, "the Supervisor is not a partner")
        let m = model(def, team: t)

        XCTAssertEqual(m.unavailableHere[.teammatePartner], [ToolNames.askTeammate])
        XCTAssertFalse(m.effective.contains(ToolNames.askTeammate))
        XCTAssertTrue(m.effective.contains(ToolNames.readFile))
    }

    /// Two non-Supervisor roles ARE a partner: `ask_teammate` ships and no requirement names it.
    func testTwoRoleTeam_shipsAskTeammate() {
        let def = role(id: "a", toolIDs: [ToolNames.askTeammate])
        let partner = role(id: "b", toolIDs: [])
        let t = team([def, partner])
        XCTAssertTrue(t.hasTeammatePartner)
        let m = model(def, team: t)

        XCTAssertTrue(m.effective.contains(ToolNames.askTeammate))
        XCTAssertTrue(m.unavailableHere.isEmpty)
    }

    /// No team ⇒ no roster to apply the partner rule to: resolver step 3.0c withholds
    /// `ask_teammate` only under `if let team`, and the badge agrees.
    func testNoTeam_keepsAskTeammate_thePartnerRuleNeedsARoster() {
        let def = role(toolIDs: [ToolNames.askTeammate])
        let m = model(def, team: nil)

        XCTAssertTrue(m.effective.contains(ToolNames.askTeammate))
        XCTAssertNil(m.unavailableHere[.teammatePartner])
    }

    // MARK: - ToolAvailabilityRequirement.governing

    /// The one partner rule read directly: `ask_teammate` is governed by the roster alone —
    /// neither the meetings switch nor anything else reaches a consultation.
    func testGoverning_askTeammate_readsThePartnerAlone() {
        XCTAssertEqual(
            ToolAvailabilityRequirement.governing(
                ToolNames.askTeammate, isDefaultStorage: false, approval: .available, hasTeammatePartner: false),
            .teammatePartner)
        XCTAssertNil(
            ToolAvailabilityRequirement.governing(
                ToolNames.askTeammate, isDefaultStorage: false, approval: .available, hasTeammatePartner: true))
        XCTAssertNil(
            ToolAvailabilityRequirement.governing(
                ToolNames.askTeammate, isDefaultStorage: false, approval: .available,
                meetings: .switchedOff, hasTeammatePartner: true),
            "the meetings switch does not govern consultations")
        XCTAssertEqual(
            ToolAvailabilityRequirement.governing(
                ToolNames.askTeammate, isDefaultStorage: false, approval: .available,
                meetings: .switchedOff, hasTeammatePartner: false),
            .teammatePartner,
            "with meetings off AND no partner, ask_teammate still names the roster, not the switch")
    }

    /// Both meeting tools name the same partner requirement under `.noPartner`; the switch
    /// is the user's explicit choice and wins the wording when it is off.
    func testGoverning_meetingTools_underNoPartner_nameTheTeammatePartner() {
        for name in [ToolNames.requestTeamMeeting, ToolNames.requestChanges] {
            XCTAssertEqual(
                ToolAvailabilityRequirement.governing(name, isDefaultStorage: false, approval: .available, meetings: .noPartner),
                .teammatePartner, name)
            XCTAssertEqual(
                ToolAvailabilityRequirement.governing(
                    name, isDefaultStorage: false, approval: .available, meetings: .switchedOff, hasTeammatePartner: false),
                .meetingsEnabled, "\(name): the switch is reported before the roster")
            XCTAssertNil(
                ToolAvailabilityRequirement.governing(name, isDefaultStorage: false, approval: .available, meetings: .available),
                "\(name): meetings on and a partner present — no precondition at all")
        }
    }

    /// `.teammatePartner` replaced `.meetingPartner` on 2026-09-07 — one hint for both
    /// collaboration channels, worded for the roster, not for meetings.
    func testTeammatePartner_unmetHint_namesTheRoster() {
        XCTAssertEqual(ToolAvailabilityRequirement.teammatePartner.unmetHint,
                       "Needs a second teammate in this team")
        XCTAssertNil(ToolAvailabilityRequirement.teammatePartner.metHint,
                     "a present partner needs no annotation")
        XCTAssertTrue(ToolAvailabilityRequirement.allCases.contains(.teammatePartner),
                      "the tooltip iterates allCases — a case missing there never renders")
    }

    // MARK: - Ask Supervisor switch

    func testAskSupervisorOff_withholdsAskSupervisorUnderItsOwnRequirement() {
        // Explicit in `toolIDs` AND advisory (would be auto-injected): both routes close.
        let def = role(toolIDs: [ToolNames.askSupervisor, ToolNames.readFile], requires: ["Brief"])
        let t = team([def], settings: TeamSettings(supervisorMode: .off))
        let m = model(def, team: t)

        XCTAssertEqual(m.unavailableHere[.askSupervisorEnabled], [ToolNames.askSupervisor])
        XCTAssertFalse(m.effective.contains(ToolNames.askSupervisor))
        XCTAssertFalse(m.autoInjected.contains(ToolNames.askSupervisor))
    }

    /// The questionnaire wears the same badge, because Off withholds it too — the resolver
    /// strips the whole `supervisorAskTools` set. A row with no badge beside a tool the run
    /// removes is the editor claiming a capability that never ships.
    ///
    /// RED: keep `toolName == ToolNames.askSupervisor` in `governing` → the form is absent
    /// from `unavailableHere[.askSupervisorEnabled]` while still absent from `effective`.
    func testAskSupervisorOff_putsTheQuestionnaireUnderTheSameRequirement() {
        let def = role(
            toolIDs: [ToolNames.askSupervisor, ToolNames.askSupervisorForm, ToolNames.readFile],
            requires: ["Brief"])
        let m = model(def, team: team([def], settings: TeamSettings(supervisorMode: .off)))

        XCTAssertEqual(m.unavailableHere[.askSupervisorEnabled]?.sorted(),
                       ToolNames.supervisorAskTools.sorted(),
                       "both parking tools are unavailable, and the editor says so about both")
        XCTAssertTrue(Set(m.effective).isDisjoint(with: ToolNames.supervisorAskTools))
    }

    /// With a mode that DOES answer, the questionnaire carries no requirement of its own —
    /// it is the plain ask's companion, not a gated family.
    func testAskSupervisorManual_questionnaireHasNoRequirement() {
        let def = role(
            toolIDs: [ToolNames.askSupervisor, ToolNames.askSupervisorForm], requires: ["Brief"])
        let m = model(def, team: team([def], settings: TeamSettings(supervisorMode: .manual)))

        XCTAssertNil(m.unavailableHere[.askSupervisorEnabled])
        XCTAssertTrue(Set(m.effective).isSuperset(of: ToolNames.supervisorAskTools))
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
        let m = model(def, team: team([def]),
                      approval: ToolApprovalAvailability(bash: .available, computerUse: .withheld(.switchedOff), humanPresent: true))

        XCTAssertEqual(Set(m.unavailableHere[.computerUse] ?? []), Set(tools))
    }

    // MARK: - The approval-gated families (B3, 2026-09-07)

    func testBashOff_reportsTheShellToolsUnderTheOffSwitch() {
        let def = role(toolIDs: [ToolNames.bash, ToolNames.bashOutput, ToolNames.readFile])
        let m = model(def, team: team([def]),
                      approval: ToolApprovalAvailability(bash: .withheld(.switchedOff), computerUse: .available, humanPresent: true))
        XCTAssertEqual(Set(m.unavailableHere[.bashEnabled] ?? []), [ToolNames.bash, ToolNames.bashOutput])
        XCTAssertNil(m.unavailableHere[.humanApprover])
        XCTAssertTrue(m.effective.contains(ToolNames.readFile))
    }

    /// Manual with nobody to approve: the shell tools are withheld for want of a HUMAN, and
    /// the badge says so — not "Bash is Off", which the user would go and check.
    func testBashManualWithNoHuman_reportsTheShellToolsUnderHumanApprover() {
        let def = role(toolIDs: [ToolNames.bash, ToolNames.bashOutput])
        let m = model(def, team: team([def]),
                      approval: ToolApprovalAvailability(bashMode: .manual, computerUseMode: .manual, humanPresent: false))
        XCTAssertEqual(Set(m.unavailableHere[.humanApprover] ?? []), [ToolNames.bash, ToolNames.bashOutput])
        XCTAssertNil(m.unavailableHere[.bashEnabled])
        XCTAssertTrue(m.effective.isEmpty)
        XCTAssertTrue(m.needsAttention, "a selection that ships nothing wants the badge")
    }

    /// Semi-automatic with no human keeps `bash` (read-only commands run): nothing to report.
    func testBashSemiAutomaticWithNoHuman_shipsTheShellTools() {
        let def = role(toolIDs: [ToolNames.bash, ToolNames.bashOutput])
        let m = model(def, team: team([def]),
                      approval: ToolApprovalAvailability(bashMode: .semiAutomatic, computerUseMode: .manual, humanPresent: false))
        XCTAssertEqual(Set(m.effective), [ToolNames.bash, ToolNames.bashOutput])
        XCTAssertTrue(m.unavailableHere.isEmpty)
    }

    func testComputerUseManualWithNoHuman_reportsAllFiveUnderHumanApprover() {
        let tools = Array(ToolHandlerRegistry.computerUseTools)
        let def = role(toolIDs: tools)
        let m = model(def, team: team([def]),
                      approval: ToolApprovalAvailability(bashMode: .auto, computerUseMode: .manual, humanPresent: false))
        XCTAssertEqual(Set(m.unavailableHere[.humanApprover] ?? []), Set(tools))
        XCTAssertNil(m.unavailableHere[.computerUse], "not Off — a human is what is missing")
    }

    /// Semi-automatic with no human: the mutating trio is withheld under the human reason, the
    /// read-only two ship.
    func testComputerUseSemiAutomaticWithNoHuman_splitsTheTrioFromTheReadOnlyTier() {
        let tools = Array(ToolHandlerRegistry.computerUseTools)
        let def = role(toolIDs: tools)
        let m = model(def, team: team([def]),
                      approval: ToolApprovalAvailability(bashMode: .auto, computerUseMode: .semiAutomatic, humanPresent: false))
        XCTAssertEqual(Set(m.unavailableHere[.humanApprover] ?? []), ToolHandlerRegistry.computerUseMutatingTools)
        XCTAssertEqual(Set(m.effective), ToolHandlerRegistry.computerUseTools.subtracting(ToolHandlerRegistry.computerUseMutatingTools))
    }

    func testApprovalRequirements_haveHintsAndRenderInTheTooltip() {
        XCTAssertEqual(ToolAvailabilityRequirement.bashEnabled.unmetHint, "Bash is Off in Settings → Bash")
        XCTAssertEqual(ToolAvailabilityRequirement.bashEnabled.metHint, "Bash enabled")
        XCTAssertTrue(ToolAvailabilityRequirement.humanApprover.unmetHint.contains("human"))
        XCTAssertTrue(ToolAvailabilityRequirement.humanApprover.unmetHint.contains("Autonomous"))
        XCTAssertNil(ToolAvailabilityRequirement.humanApprover.metHint)
        for requirement in [ToolAvailabilityRequirement.bashEnabled, .humanApprover] {
            XCTAssertTrue(ToolAvailabilityRequirement.allCases.contains(requirement),
                          "the tooltip iterates allCases — a case missing there never renders")
        }
    }

    /// `governing` reads `approval` the way the resolver does — one reading per family.
    func testGoverning_readsEachFamilyAgainstItsAvailability() {
        let unattended = ToolApprovalAvailability(bashMode: .manual, computerUseMode: .semiAutomatic, humanPresent: false)
        XCTAssertEqual(ToolAvailabilityRequirement.governing(ToolNames.bash, isDefaultStorage: false, approval: unattended), .humanApprover)
        XCTAssertEqual(ToolAvailabilityRequirement.governing(ToolNames.uiClick, isDefaultStorage: false, approval: unattended), .humanApprover)
        XCTAssertEqual(ToolAvailabilityRequirement.governing(ToolNames.screenCapture, isDefaultStorage: false, approval: unattended), .computerUse)
        XCTAssertEqual(ToolAvailabilityRequirement.governing(ToolNames.bash, isDefaultStorage: false, approval: .available), .bashEnabled)
        XCTAssertEqual(ToolAvailabilityRequirement.governing(ToolNames.uiClick, isDefaultStorage: false, approval: .available), .computerUse)
        let off = ToolApprovalAvailability(bash: .withheld(.switchedOff), computerUse: .withheld(.switchedOff), humanPresent: true)
        XCTAssertEqual(ToolAvailabilityRequirement.governing(ToolNames.bash, isDefaultStorage: false, approval: off), .bashEnabled)
        XCTAssertEqual(ToolAvailabilityRequirement.governing(ToolNames.uiKey, isDefaultStorage: false, approval: off), .computerUse)
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
            for: Role.fromDefinition(copy), team: t,
            approval: .available).map(\.name)
        let viaDefinition = LLMExecutionService.resolveToolSchemas(
            forDefinition: copy, team: t,
            approval: .available).map(\.name)

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
