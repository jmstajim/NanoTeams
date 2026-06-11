import XCTest
@testable import NanoTeams

/// Pins the structural invariants the Autovisor relies on: the team must be
/// chat-mode + autonomous (so `attemptAdvisoryAutoFinish` ends each review pass),
/// its role must be ADVISORY (not observer — else the engine skips it), it must be
/// hidden from pickers, and it must NOT pollute the bundled-template set.
final class AutovisorTeamTests: XCTestCase {

    private func managerTeam() -> Team { TeamTemplateFactory.autovisor() }

    func testTeam_isChatMode_autonomous() {
        let team = managerTeam()
        XCTAssertTrue(team.isChatMode, "single-role, no supervisor deliverables → chat mode")
        XCTAssertEqual(team.settings.supervisorMode, .autonomous,
                       "MUST be autonomous so the advisory auto-finish ends a review pass")
        XCTAssertEqual(team.templateID, AutovisorConstants.teamTemplateID)
    }

    func testTeam_usesDedicatedSingleRoleTemplate() {
        // The manager is a one-role team — it gets its own template (no `## Team`
        // / `## Deliverables` / "submit each deliverable" noise the shared generic
        // template carried). The version-bump reconcile re-applies this to stored
        // teams by templateID, so the creation path is the source of truth.
        let team = managerTeam()
        XCTAssertEqual(team.systemPromptTemplate, SystemTemplates.autovisorTemplate)
        XCTAssertEqual(SystemTemplates.defaultSystemTemplate(for: AutovisorConstants.teamTemplateID),
                       SystemTemplates.autovisorTemplate)
    }

    func testManagerRole_isAdvisory_notObserver() {
        // The single line that makes the engine actually RUN the role: it requires
        // the Supervisor Task artifact (advisory), so it isn't classified observer.
        guard let role = managerTeam().nonSupervisorRoles.first else {
            return XCTFail("manager team must have a non-supervisor role")
        }
        XCTAssertEqual(role.completionType, .advisory)
        XCTAssertFalse(role.isObserver)
        XCTAssertFalse(role.dependencies.requiredArtifacts.isEmpty)
    }

    func testManagerRole_hasManagementToolset_plusFileAndGit_notDelegation() {
        guard let role = managerTeam().nonSupervisorRoles.first else { return XCTFail() }
        let ids = Set(role.toolIDs)
        for t in [ToolNames.listTasks, ToolNames.taskStatus, ToolNames.createManagedTask,
                  ToolNames.controlTask, ToolNames.manageRole, ToolNames.answerTaskQuestion,
                  ToolNames.messageTask, ToolNames.scheduleTask, ToolNames.setWorkFolderContext,
                  ToolNames.waitForEvents, ToolNames.updateScratchpad] {
            XCTAssertTrue(ids.contains(t), "manager toolset must include \(t)")
        }
        // It can do file work + git directly…
        XCTAssertTrue(ids.contains(ToolNames.writeFile))
        XCTAssertTrue(ids.contains(ToolNames.gitCommit))
        // …but never delegates (it IS the top Supervisor).
        XCTAssertFalse(ids.contains(ToolNames.delegateToTeam))
    }

    /// The manager prompt must tell it to FINALIZE reviewed work (accept + close), not leave it
    /// sitting in Review — otherwise a finished task keeps re-waking the manager every window.
    func testManagerPrompt_finalizesReviewedTasks() {
        let prompt = SystemTemplates.rolePrompts["autovisor"] ?? ""
        XCTAssertTrue(prompt.contains("needsSupervisorAcceptance"),
                      "manager prompt must address the Review (awaiting-acceptance) state explicitly")
        XCTAssertTrue(prompt.contains("close"),
                      "manager prompt must instruct closing to finalize reviewed work")
    }

    /// The Work Folder Context refresh must be an active pre-task check (workers read
    /// it at task start, so updating it after `create_managed_task` is too late for
    /// that task), and it must name the staleness conditions explicitly — a purely
    /// conditional "if you learned something" phrasing lets the model skip it forever.
    func testManagerPrompt_refreshesWorkFolderContextBeforeCreatingTasks() {
        let prompt = SystemTemplates.rolePrompts["autovisor"] ?? ""
        XCTAssertTrue(prompt.contains(ToolNames.setWorkFolderContext),
                      "manager prompt must instruct updating the Work Folder Context")
        XCTAssertTrue(prompt.contains("empty"), "prompt must cover the empty-context case")
        XCTAssertTrue(prompt.contains("stale"), "prompt must cover the stale-context case")
        guard let contextStep = prompt.range(of: ToolNames.setWorkFolderContext),
              let createStep = prompt.range(of: ToolNames.createManagedTask)
        else { return XCTFail("prompt must mention both tools") }
        XCTAssertLessThan(contextStep.lowerBound, createStep.lowerBound,
                          "context refresh must be instructed BEFORE task creation")
    }

    func testManagerTeam_excludedFromBundledTemplates() {
        XCTAssertFalse(
            TeamTemplateFactory.allTemplates.contains { $0.templateID == AutovisorConstants.teamTemplateID },
            "the manager team is infrastructure — never an offered/bootstrapped template"
        )
        XCTAssertFalse(
            TeamTemplateFactory.templateMetadata.contains { $0.id == AutovisorConstants.teamTemplateID },
            "never in the New Team picker metadata"
        )
    }

    // MARK: - isHiddenFromPickers

    func testIsHiddenFromPickers() {
        XCTAssertTrue(managerTeam().isHiddenFromPickers)
        XCTAssertTrue(TeamTemplateFactory.generatedTeam().isHiddenFromPickers)
        XCTAssertFalse(TeamTemplateFactory.faang().isHiddenFromPickers)
        XCTAssertFalse(TeamTemplateFactory.codingAssistant().isHiddenFromPickers)
    }

    func testSelectableInPicker_dropsHiddenTeams() {
        let teams = [TeamTemplateFactory.faang(), managerTeam(), TeamTemplateFactory.generatedTeam()]
        let selectable = teams.selectableInPicker
        XCTAssertEqual(selectable.map(\.templateID), ["faang"])
    }

    // MARK: - isHiddenFromTeamEditor / isManagedSingleton

    func testIsHiddenFromTeamEditor_onlyGenerated() {
        // Autovisor IS shown in the config editor (protected entry); only the
        // Generated Team placeholder is hidden there.
        XCTAssertFalse(managerTeam().isHiddenFromTeamEditor)
        XCTAssertTrue(TeamTemplateFactory.generatedTeam().isHiddenFromTeamEditor)
        XCTAssertFalse(TeamTemplateFactory.faang().isHiddenFromTeamEditor)
        XCTAssertFalse(TeamTemplateFactory.codingAssistant().isHiddenFromTeamEditor)
    }

    func testIsManagedSingleton_onlyAutovisor() {
        XCTAssertTrue(managerTeam().isManagedSingleton)
        XCTAssertFalse(TeamTemplateFactory.generatedTeam().isManagedSingleton)
        XCTAssertFalse(TeamTemplateFactory.faang().isManagedSingleton)
        XCTAssertFalse(TeamTemplateFactory.codingAssistant().isManagedSingleton)
    }

    // MARK: - Role enum

    func testRoleEnum_autovisor() {
        XCTAssertTrue(Role.builtInCases.contains(.autovisor))
        XCTAssertEqual(Role.autovisor.displayName, "Autovisor")
        XCTAssertEqual(Role.builtInID(.autovisor), AutovisorConstants.managerRoleSystemID)
        XCTAssertEqual(Role.builtInRole(for: "autovisor"), .autovisor)
    }
}
