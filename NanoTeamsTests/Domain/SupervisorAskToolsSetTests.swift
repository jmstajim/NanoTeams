import XCTest

@testable import NanoTeams

/// `ToolNames.supervisorAskTools` — the ONE closed set of tools whose call PARKS a step
/// waiting for the Supervisor.
///
/// It exists because the name `ask_supervisor` was spelled as a literal at five BEHAVIOURAL
/// sites (`AskCallIndex`, `activeAskCall`, two in `CompactionPolicy`,
/// and the non-productive-turn gate), and each of them fails DIFFERENTLY and SILENTLY for a
/// second parking tool: no question identity, a compaction that folds across an open park,
/// and — the worst of them — a human's answer dropped from the compacted wire with an
/// identical result and a clean log.
///
/// The tests here pin the SET. The per-site behaviour is pinned next to each site, because a
/// set that is correct and unread would be exactly as useless as the literals it replaces.
final class SupervisorAskToolsSetTests: XCTestCase {

    func testSetContainsBothParkingTools() {
        XCTAssertTrue(ToolNames.supervisorAskTools.contains(ToolNames.askSupervisor))
        XCTAssertTrue(ToolNames.supervisorAskTools.contains(ToolNames.askSupervisorForm))
    }

    /// The set is exactly the parking tools — not "every supervisor-ish tool". `wait_for_events`
    /// also suspends a role, but it is the Autovisor's idle park and is answered by folder
    /// EVENTS, not by a person; folding it in here would make `SupervisorQuestionInbox` invent
    /// a question for a step nobody is being asked about.
    func testSetIsExactlyTheTwo() {
        XCTAssertEqual(
            ToolNames.supervisorAskTools,
            [ToolNames.askSupervisor, ToolNames.askSupervisorForm])
        XCTAssertFalse(ToolNames.supervisorAskTools.contains(ToolNames.waitForEvents))
    }

    /// Both members are real, registered tool names. A typo here would make the set look
    /// populated while matching nothing the model can actually call.
    func testBothMembersAreKnownToolNames() {
        for name in ToolNames.supervisorAskTools {
            XCTAssertTrue(
                ToolNames.allNames.contains(name),
                "\(name) is in supervisorAskTools but not in allNames")
        }
    }

    func testFormNameIsDistinctFromPlainAsk() {
        XCTAssertNotEqual(ToolNames.askSupervisorForm, ToolNames.askSupervisor)
        XCTAssertEqual(ToolNames.askSupervisorForm, "ask_supervisor_form")
    }

    // MARK: - Granted as a pair

    /// Every bundled role that holds `ask_supervisor` holds the questionnaire beside it.
    ///
    /// A closed SET is only half the idea: while the two names were granted separately, the
    /// set said "these behave alike" about tools fifteen roles held one of and one role held
    /// both. From 2026-09-10 the grant is the pair — in the role templates, in the four
    /// `TeamTemplateFactory` closures that overwrite a toolset, and (step 4) in the resolver
    /// for a role that spells no toolset at all.
    ///
    /// The converse is asserted in the same pass and is the older rule: the form NEVER ships
    /// alone, because three correction texts name the plain tool and only it.
    ///
    /// RED: drop `TN.askSupervisorForm` from any one template entry → that role is named.
    func testEveryBundledRoleHoldingThePlainAskHoldsTheFormToo() {
        var holders: [String] = []
        var missingForm: [String] = []
        var missingPlainAsk: [String] = []

        func inspect(_ row: String, _ toolIDs: [String]) {
            let held = Set(toolIDs)
            if held.contains(ToolNames.askSupervisor) {
                holders.append(row)
                if !held.contains(ToolNames.askSupervisorForm) { missingForm.append(row) }
            } else if held.contains(ToolNames.askSupervisorForm) {
                missingPlainAsk.append(row)
            }
        }

        // Both tables, because they are two tables. `TeamTemplateFactory` closures OVERWRITE
        // `roles[i].toolIDs` for five templates, so a bundled TEAM can be right while the
        // `SystemTemplates.roles` entry behind it is wrong — and that entry is what the role
        // editor offers when a user re-adds a deleted system role, and what
        // `fallbackToolIDs` derives from. Checked separately: an earlier version of this test
        // read only the teams and a mutation removing the form from the `assistant` template
        // stayed green.
        let bundled = Team.defaultTeams
            + [TeamTemplateFactory.autovisor(), TeamTemplateFactory.empty(name: "Alpha Team")]
        for team in bundled {
            for role in team.roles { inspect("\(team.name)/\(role.name)", role.toolIDs) }
        }
        for (id, template) in SystemTemplates.roles {
            inspect("SystemTemplates.roles[\(id)]", template.toolIDs)
        }

        XCTAssertEqual(missingForm, [],
                       "these hold the plain ask without the questionnaire: \(missingForm)")
        XCTAssertEqual(missingPlainAsk, [],
                       "the form never ships alone: \(missingPlainAsk)")
        // Anti-vacuum: a template table that stopped granting the ask at all would pass every
        // assertion above by having nothing to check.
        XCTAssertGreaterThanOrEqual(
            holders.count, 20,
            "too few bundled askers (\(holders.count)) — the population, not the rule, moved")
    }

    /// The same rule in the two tables the resolver falls back to when the team lookup misses.
    ///
    /// A lookup miss is not a reason to lose the questionnaire: the fallback exists precisely
    /// because no role definition reached the resolver, so step 4 never fires and whatever the
    /// table says is the whole toolset.
    ///
    /// RED: revert `fallbackToolIDs` to `.union([TN.askSupervisor])` → every team role but the
    /// planner is listed.
    func testBothFallbackTablesGrantThePairOrNeither() {
        for (id, tools) in SystemTemplates.fallbackToolIDs {
            let held = tools.intersection(ToolNames.supervisorAskTools)
            XCTAssertTrue(
                held.isEmpty || held == ToolNames.supervisorAskTools,
                "fallbackToolIDs[\(id)] grants half the pair: \(held.sorted())")
        }
        XCTAssertEqual(
            SystemTemplates.fallbackCustomRoleToolIDs.intersection(ToolNames.supervisorAskTools),
            ToolNames.supervisorAskTools,
            "a custom role reached by fallback can still ask, and ask with a form")
        // The two keys that are deliberately mute stay mute — the Supervisor is a human and
        // the Autovisor manager IS the top Supervisor.
        for mute in ["supervisor", AutovisorConstants.managerRoleSystemID] {
            XCTAssertTrue(
                (SystemTemplates.fallbackToolIDs[mute] ?? []).isDisjoint(with: ToolNames.supervisorAskTools),
                "\(mute) must hold neither ask tool")
        }
    }
}
