import XCTest
@testable import NanoTeams

/// The meeting-coordinator invariant: every team with a non-Supervisor role has a
/// coordinator, chosen by `TeamSettings.defaultCoordinatorID(among:)` whenever the stored id
/// does not name a live one, and written back by `Team.healMeetingCoordinator()` on every
/// roster change. Plus the two per-team switches this wave added to `TeamSettings`
/// (`meetingsEnabled` and `SupervisorMode.off`) and the one partner rule
/// (`Team.hasTeammatePartner`) that `meetingAvailability` reads.
final class TeamSettingsCoordinatorRuleTests: XCTestCase {

    private func role(_ id: String, tools: [String] = [], supervisor: Bool = false) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: id.uppercased(), prompt: supervisor ? "" : "p", toolIDs: tools,
            usePlanningPhase: false, dependencies: RoleDependencies(),
            isSystemRole: supervisor, systemRoleID: supervisor ? "supervisor" : nil)
    }

    private func team(_ roles: [TeamRoleDefinition], coordID: String? = nil) -> Team {
        Team(name: "T", roles: roles, artifacts: [],
             settings: TeamSettings(meetingCoordinatorRoleID: coordID),
             graphLayout: TeamGraphLayout())
    }

    // MARK: - defaultCoordinatorID

    /// The first role that can START a meeting wins over an earlier role that cannot.
    func testDefaultCoordinatorID_prefersTheFirstMeetingStarter() {
        let roles = [role("sup", supervisor: true), role("a"), role("b", tools: [ToolNames.requestTeamMeeting]),
                     role("c", tools: [ToolNames.requestTeamMeeting])]
        XCTAssertEqual(TeamSettings.defaultCoordinatorID(among: roles), "b")
    }

    func testDefaultCoordinatorID_fallsBackToTheFirstNonSupervisorRole() {
        let roles = [role("sup", supervisor: true), role("a"), role("b")]
        XCTAssertEqual(TeamSettings.defaultCoordinatorID(among: roles), "a")
    }

    /// The Supervisor is the human — never a coordinator, even when it is the only role
    /// or the only one holding `request_team_meeting`.
    func testDefaultCoordinatorID_neverTheSupervisor() {
        XCTAssertNil(TeamSettings.defaultCoordinatorID(among: [role("sup", supervisor: true)]))
        var sup = role("sup", supervisor: true)
        sup.toolIDs = [ToolNames.requestTeamMeeting]
        XCTAssertEqual(TeamSettings.defaultCoordinatorID(among: [sup, role("a")]), "a")
    }

    func testDefaultCoordinatorID_emptyRoster_isNil() {
        XCTAssertNil(TeamSettings.defaultCoordinatorID(among: []))
    }

    // MARK: - Team.meetingCoordinatorID

    func testMeetingCoordinatorID_storedLiveRole_wins() {
        let t = team([role("sup", supervisor: true), role("a", tools: [ToolNames.requestTeamMeeting]), role("b")], coordID: "b")
        XCTAssertEqual(t.meetingCoordinatorID, "b", "an explicit live pick beats the default rule")
        XCTAssertEqual(t.meetingCoordinator?.id, "b")
        XCTAssertFalse(t.meetingCoordinatorNeedsHealing)
    }

    func testMeetingCoordinatorID_nilOrOrphanOrSupervisor_resolvesByTheDefaultRule() {
        let roles = [role("sup", supervisor: true), role("a"), role("b", tools: [ToolNames.requestTeamMeeting])]
        for stored in [nil, "ghost", "sup", ""] {
            let t = team(roles, coordID: stored)
            XCTAssertEqual(t.meetingCoordinatorID, "b", "stored \(String(describing: stored))")
            XCTAssertTrue(t.meetingCoordinatorNeedsHealing, "stored \(String(describing: stored))")
        }
    }

    func testMeetingCoordinatorID_rolelessTeam_isNil_andNeedsNoHealing() {
        let t = team([role("sup", supervisor: true)])
        XCTAssertNil(t.meetingCoordinatorID)
        XCTAssertNil(t.meetingCoordinator)
        XCTAssertFalse(t.meetingCoordinatorNeedsHealing, "nil == nil — nothing to write")
    }

    // MARK: - healMeetingCoordinator

    func testHeal_writesTheResolvedID_once_andBumpsUpdatedAt() {
        var t = team([role("sup", supervisor: true), role("a")], coordID: "ghost")
        let before = t.updatedAt

        XCTAssertTrue(t.healMeetingCoordinator())
        XCTAssertEqual(t.settings.meetingCoordinatorRoleID, "a")
        XCTAssertGreaterThan(t.updatedAt, before, "observers must see the write (CLAUDE.md #42)")

        let healedAt = t.updatedAt
        XCTAssertFalse(t.healMeetingCoordinator(), "idempotent: a resolved id is not rewritten")
        XCTAssertEqual(t.updatedAt, healedAt, "no phantom bump on the no-op")
    }

    // MARK: - addRole / removeRole keep the invariant

    func testAddRole_firstRoleBecomesCoordinator_laterRoleDoesNotDisplaceIt() {
        var t = team([role("sup", supervisor: true)])
        XCTAssertNil(t.settings.meetingCoordinatorRoleID)

        t.addRole(role("a"))
        XCTAssertEqual(t.settings.meetingCoordinatorRoleID, "a")

        t.addRole(role("b", tools: [ToolNames.requestTeamMeeting]))
        XCTAssertEqual(t.settings.meetingCoordinatorRoleID, "a",
                       "a stored, still-live pick survives a later addition even if the newcomer could start meetings")
    }

    func testRemoveRole_removingTheCoordinator_rePicksByTheDefaultRule_neverNil() {
        var t = team([role("sup", supervisor: true), role("a"), role("b", tools: [ToolNames.requestTeamMeeting])], coordID: "a")

        t.removeRole("a")

        XCTAssertEqual(t.settings.meetingCoordinatorRoleID, "b")
        XCTAssertFalse(t.meetingCoordinatorNeedsHealing)
    }

    func testRemoveRole_removingTheLastRole_leavesNil() {
        var t = team([role("sup", supervisor: true), role("a")], coordID: "a")
        t.removeRole("a")
        XCTAssertNil(t.settings.meetingCoordinatorRoleID, "nobody left to coordinate")
    }

    func testRemoveRole_removingAnotherRole_keepsTheCoordinator() {
        var t = team([role("sup", supervisor: true), role("a"), role("b")], coordID: "b")
        t.removeRole("a")
        XCTAssertEqual(t.settings.meetingCoordinatorRoleID, "b")
    }

    // MARK: - Every bundled team names a coordinator

    func testEveryBundledTeam_hasALiveNonSupervisorCoordinator() {
        let teams = Team.defaultTeams + [TeamTemplateFactory.autovisor(), TeamTemplateFactory.empty(name: "E")]
        XCTAssertGreaterThanOrEqual(teams.count, 10, "anti-vacuum")
        for t in teams where !t.nonSupervisorRoles.isEmpty {
            let stored = t.settings.meetingCoordinatorRoleID
            XCTAssertNotNil(stored, "\(t.name): a bundled team names its coordinator")
            XCTAssertTrue(t.roles.contains { $0.id == stored && !$0.isSupervisor },
                          "\(t.name): the stored coordinator is a live non-Supervisor role")
            XCTAssertFalse(t.meetingCoordinatorNeedsHealing, "\(t.name)")
        }
    }

    // MARK: - meetingsEnabled

    func testMeetingsEnabled_defaultsOn_andDecodesTrueWhenAbsent() throws {
        XCTAssertTrue(TeamSettings().meetingsEnabled)
        let legacy = try JSONDecoder().decode(TeamSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.meetingsEnabled, "a teams.json from before the switch existed keeps meetings on")
    }

    func testMeetingsEnabled_falseRoundTrips() throws {
        var settings = TeamSettings()
        settings.meetingsEnabled = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TeamSettings.self, from: data)
        XCTAssertFalse(decoded.meetingsEnabled)
    }

    // MARK: - meetingAvailability (a meeting needs somebody to invite)

    func testMeetingAvailability_needsASecondParticipant() {
        let sup = role("sup", supervisor: true)
        XCTAssertEqual(team([sup]).meetingAvailability, .noPartner)
        XCTAssertEqual(team([sup, role("a")]).meetingAvailability, .noPartner, "one role has nobody to invite")
        XCTAssertEqual(team([sup, role("a"), role("b")]).meetingAvailability, .available)
        XCTAssertTrue(team([sup, role("a"), role("b")]).canHoldMeetings)
        XCTAssertFalse(team([sup, role("a")]).canHoldMeetings)
    }

    /// The ONE partner rule for both collaboration channels (`ask_teammate` and meetings):
    /// a role has a teammate when the roster holds two non-Supervisor roles. The Supervisor
    /// is the human and never counts — until 2026-09-07 a `supervisorCanBeInvited` seat let
    /// an LLM speak AS the Supervisor and stood in as the "second participant" on every
    /// single-role bundled team. With the switch on, `meetingAvailability` is `.noPartner`
    /// exactly when the rule says no; the rule itself ignores the switch, so `ask_teammate`
    /// stays reachable on a two-role team with meetings off.
    func testHasTeammatePartner_isTheOnePartnerRule() {
        let sup = role("sup", supervisor: true)
        let matrix: [(roster: [TeamRoleDefinition], partner: Bool, label: String)] = [
            ([sup], false, "the Supervisor alone"),
            ([sup, role("a")], false, "one role — the Supervisor is not its partner"),
            ([sup, role("a"), role("b")], true, "two roles"),
            ([role("a"), role("b")], true, "no Supervisor at all — two roles still pair"),
        ]
        for entry in matrix {
            let t = team(entry.roster)
            XCTAssertEqual(t.hasTeammatePartner, entry.partner, entry.label)
            XCTAssertEqual(t.meetingAvailability, entry.partner ? .available : .noPartner,
                           "\(entry.label): with the switch on, noPartner ⇔ !hasTeammatePartner")
        }

        var off = team([sup, role("a"), role("b")])
        off.settings.meetingsEnabled = false
        XCTAssertTrue(off.hasTeammatePartner, "the partner rule ignores the meetings switch")
        XCTAssertEqual(off.meetingAvailability, .switchedOff, "the switch is reported, the partner is still there")
    }

    /// The switch is the user's explicit choice and is reported before the roster.
    func testMeetingAvailability_theSwitchIsReportedFirst() {
        var pair = team([role("sup", supervisor: true), role("a"), role("b")])
        pair.settings.meetingsEnabled = false
        XCTAssertEqual(pair.meetingAvailability, .switchedOff)
        var solo = team([role("sup", supervisor: true), role("a")])
        solo.settings.meetingsEnabled = false
        XCTAssertEqual(solo.meetingAvailability, .switchedOff, "the choice names the reason, not the roster")
    }

    /// The five single-role bundled teams cannot meet; every multi-role one can. The
    /// stored switch is untouched (`true`) so adding a second role enables meetings at once.
    func testBundledTeams_singleRoleOnesCannotMeet_multiRoleOnesCan() {
        let all = Team.defaultTeams + [TeamTemplateFactory.autovisor(), TeamTemplateFactory.empty(name: "E")]
        for t in all {
            let expected: MeetingAvailability = t.nonSupervisorRoles.count >= 2 ? .available : .noPartner
            XCTAssertEqual(t.hasTeammatePartner, t.nonSupervisorRoles.count >= 2, t.name)
            XCTAssertEqual(t.meetingAvailability, expected, t.name)
            XCTAssertTrue(t.settings.meetingsEnabled, "\(t.name): the switch stays on; the roster decides")
        }
        let solo = all.filter { $0.meetingAvailability == .noPartner }.compactMap(\.templateID).sorted()
        XCTAssertEqual(solo, ["assistant", "autovisor", "codingAgent", "codingAssistant", "startup"])
        XCTAssertGreaterThanOrEqual(all.filter(\.canHoldMeetings).count, 4, "anti-vacuum: FAANG, Engineering, Quest Party, Discussion Club")
    }

    // MARK: - SupervisorMode.off

    func testSupervisorModeOff_roundTrips_andLegacyDefaultsToManual() throws {
        var settings = TeamSettings()
        settings.supervisorMode = .off
        let decoded = try JSONDecoder().decode(TeamSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.supervisorMode, .off)
        XCTAssertEqual(SupervisorMode(rawValue: "off"), .off)
        let legacy = try JSONDecoder().decode(TeamSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.supervisorMode, .manual)
    }

    /// The segment order in Team Settings → Ask Supervisor IS `allCases`; Off is last.
    func testSupervisorMode_allCasesOrder_andGenerationModesExcludeOff() {
        XCTAssertEqual(SupervisorMode.allCases, [.manual, .autonomous, .off])
        XCTAssertEqual(SupervisorMode.generationModes, [.manual, .autonomous])
        XCTAssertEqual(SupervisorMode.off.displayName, "Off")
        XCTAssertTrue(SupervisorMode.off.description.contains("ask_supervisor"))
    }
}
