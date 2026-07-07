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

    func testManagerRole_isReadOnly_plusManagement_notDelegation() {
        guard let role = managerTeam().nonSupervisorRoles.first else { return XCTFail() }
        let ids = Set(role.toolIDs)
        for t in [ToolNames.listTasks, ToolNames.taskStatus, ToolNames.createManagedTask,
                  ToolNames.controlTask, ToolNames.manageRole, ToolNames.answerTaskQuestion,
                  ToolNames.messageTask, ToolNames.scheduleTask, ToolNames.setWorkFolderContext,
                  ToolNames.waitForEvents, ToolNames.updateScratchpad] {
            XCTAssertTrue(ids.contains(t), "manager toolset must include \(t)")
        }
        // READ-only investigation tools are present (file read + git read + image).
        for readTool in [ToolNames.readFile, ToolNames.readLines, ToolNames.listFiles, ToolNames.search,
                         ToolNames.gitStatus, ToolNames.gitLog, ToolNames.gitDiff, ToolNames.gitBranchList,
                         ToolNames.analyzeImage] {
            XCTAssertTrue(ids.contains(readTool), "manager must keep read tool \(readTool)")
        }
        // It has NO repo-mutation tools — neither file-write nor git-write. It delegates instead.
        for writeTool in [ToolNames.writeFile, ToolNames.editFile, ToolNames.deleteFile,
                          ToolNames.gitAdd, ToolNames.gitCommit, ToolNames.gitPull,
                          ToolNames.gitCheckout, ToolNames.gitMerge, ToolNames.gitStash, ToolNames.gitBranch] {
            XCTAssertFalse(ids.contains(writeTool), "manager must NOT have write tool \(writeTool)")
        }
        // … and it never delegates via delegate_to_team (it IS the top Supervisor).
        XCTAssertFalse(ids.contains(ToolNames.delegateToTeam))
        // … and it never escalates via ask_supervisor — there is no one above it.
        // (A schema-level strip + the "autovisor" fallbackToolIDs key enforce this
        // at resolve time; this pins the factory toolset itself.)
        XCTAssertFalse(ids.contains(ToolNames.askSupervisor),
                       "the manager IS the top Supervisor — never ask_supervisor")
        XCTAssertFalse(AutovisorConstants.managerDefaultToolIDs.contains(ToolNames.askSupervisor),
                       "managerDefaultToolIDs feeds fallbackToolIDs[\"autovisor\"] — must exclude ask_supervisor")
    }

    /// The manager prompt must tell it to FINALIZE reviewed work via `control_task close`
    /// (which accepts all roles), not leave it sitting in Review — otherwise a finished task
    /// keeps re-waking the manager every window.
    func testManagerPrompt_finalizesReviewedTasks() {
        let prompt = SystemTemplates.rolePrompts["autovisor"] ?? ""
        XCTAssertTrue(prompt.contains("needsSupervisorAcceptance"),
                      "manager prompt must address the Review (awaiting-acceptance) state explicitly")
        XCTAssertTrue(prompt.contains("control_task close"),
                      "manager prompt must instruct `control_task close` to finalize reviewed work (not a bare 'close' substring)")
    }

    /// Regression pin for the "accepts every done role" bug: the prompt must NOT tell the
    /// manager to accept every role of a finished task, and must point it at the explicit
    /// `roles_needing_acceptance` signal so it only accepts roles that genuinely await it.
    func testManagerPrompt_doesNotInstructAcceptingEveryRole() {
        let prompt = SystemTemplates.rolePrompts["autovisor"] ?? ""
        // The exact bug wording was "`manage_role accept` each role" — match that precise
        // phrase, not a bare "each role" (which legitimately appears in the timing sentence
        // "how long each role has run").
        XCTAssertFalse(prompt.contains("accept` each role"),
                       "prompt must not instruct `manage_role accept` each role (the reported bug)")
        XCTAssertTrue(prompt.contains("roles_needing_acceptance"),
                      "prompt must point the manager at the explicit acceptance signal")
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

    /// Bug fix: a direct Supervisor message (e.g. "shows error Load failed" + a screenshot) must be
    /// handled — the manager opens attachments via `analyze_image` and acknowledges + delegates
    /// rather than ignoring the image or silently self-fixing. Pin the dedicated section (header +
    /// a clause unique to it) so a future rewrite can't silently drop the bug-3 guidance.
    /// (The "never implement" rule is pinned on the TEMPLATE, not here — the body must not
    /// duplicate it; see testManagerPrompt_bodyDoesNotDuplicateTemplateRules.)
    func testManagerPrompt_handlesAttachmentsAndSupervisorMessages() {
        let prompt = SystemTemplates.rolePrompts["autovisor"] ?? ""
        // Attachments (bug 2): must name analyze_image and the `## Attached Files` section.
        XCTAssertTrue(prompt.contains(ToolNames.analyzeImage),
                      "manager prompt must tell it to analyze images via analyze_image")
        XCTAssertTrue(prompt.contains("## Attached Files"),
                      "manager prompt must reference the `## Attached Files` section it receives")
        XCTAssertTrue(prompt.contains("### When your Supervisor messages you"),
                      "manager prompt must carry the dedicated Supervisor-message section (bug 3)")
        XCTAssertTrue(prompt.contains("takes precedence"),
                      "Supervisor-message section must say it takes precedence over the explore-and-wait stance")
        XCTAssertTrue(prompt.contains(ToolNames.createManagedTask),
                      "manager prompt must steer any change to a delegated managed task")
    }

    /// F1 (pass-2 review): wake handling must branch on OBSERVABLE conversation content, not on an
    /// unobservable "kind of wake". The runtime gives the model no structural marker distinguishing
    /// a Supervisor message from an automated event notice (both arrive the same way) or a silent
    /// scheduled pass — so the old "a wake is one of two kinds" framing asked the model to branch on
    /// something it can't see. Pin the content-based reframe.
    func testManagerPrompt_wakeBranchesOnObservableContent() {
        let prompt = SystemTemplates.rolePrompts["autovisor"] ?? ""
        XCTAssertFalse(prompt.contains("two kinds"),
                       "must not frame wakes as unobservable 'kinds'")
        XCTAssertTrue(prompt.contains("the latest turn"),
                      "must branch on the observable latest turn")
        XCTAssertTrue(prompt.contains("automated event notice"),
                      "must collapse Supervisor-message vs event (both arrive the same way), not classify the wake")
    }

    /// Supervisor terminology: the entity that messages the manager is its Supervisor, not a generic
    /// "human". Neither the role guidance nor the template may call it "human".
    func testManagerPrompt_refersToSupervisorNotHuman() {
        let prompt = SystemTemplates.rolePrompts["autovisor"] ?? ""
        XCTAssertFalse(prompt.contains("human"),
                       "manager role guidance must say 'your Supervisor', never 'human'")
        XCTAssertFalse(SystemTemplates.autovisorTemplate.contains("human"),
                       "manager template must say 'your Supervisor', never 'human'")
        XCTAssertTrue(prompt.contains("your Supervisor"),
                      "manager role guidance must refer to its Supervisor explicitly")
    }

    /// The Supervisor-not-"human" rule must also hold for the manager's TOOL descriptions —
    /// they ship inlined in its first wire payload (caught by a `train-first-prompt` audit:
    /// `wait_for_events`'s description still said "a message from the human").
    func testManagerToolDescriptions_sayNoHuman() {
        guard let role = managerTeam().nonSupervisorRoles.first else { return XCTFail() }
        let ids = Set(role.toolIDs)
        let managerSchemas = ToolHandlerRegistry.allSchemas.filter { ids.contains($0.name) }
        XCTAssertFalse(managerSchemas.isEmpty, "manager tool schemas must resolve")
        for s in managerSchemas {
            XCTAssertFalse(s.description.lowercased().contains("human"),
                           "manager tool '\(s.name)' description must say 'Supervisor', not 'human'")
        }
    }

    /// F4 / no-body-duplication: the body ({roleGuidance}) must NOT restate the delegate /
    /// never-implement / tool-inventory rule that already lives in the template's `## Role` +
    /// `## Final reminder` attention sinks. Pin the body clean of those phrases so a future edit
    /// can't re-bloat the mid-prompt repetition.
    func testManagerPrompt_bodyDoesNotDuplicateTemplateRules() {
        let prompt = SystemTemplates.rolePrompts["autovisor"] ?? ""
        XCTAssertFalse(prompt.contains("never implement"),
                       "the never-implement rule lives on the template (start + end sinks), not in the body")
        XCTAssertFalse(prompt.contains("no file-write"),
                       "the tool-inventory phrasing lives on the template, not duplicated in the body")
    }

    /// Steering rule: when the manager needs direction, a product-development idea becomes a task
    /// for the right team (it acts — picking a catalog team or `"generated"`), while anything else
    /// is a question for its Supervisor (it asks, then waits). Pin both branches.
    func testManagerPrompt_directionRoutesIdeaToTeamElseAsksSupervisor() {
        let prompt = SystemTemplates.rolePrompts["autovisor"] ?? ""
        XCTAssertTrue(prompt.contains("product-development idea"),
                      "a product-development idea must route to a team task, not a question")
        XCTAssertTrue(prompt.contains("\"generated\""),
                      "the idea branch must offer `\"generated\"` when no catalog team fits")
        XCTAssertTrue(prompt.contains("ask your Supervisor"),
                      "anything else needing direction must be asked of the Supervisor")
    }

    /// F5 (pass-2 review): the Supervisor-message and attachments guidance must be DECOMPOSED into
    /// ordered steps / a typed-dispatch list (not narrative prose), matching the numbered review
    /// pass — decomposition beats wall-of-text for weak local models.
    func testManagerPrompt_supervisorMessageAndAttachmentsAreDecomposed() {
        let prompt = SystemTemplates.rolePrompts["autovisor"] ?? ""
        func lines(after header: String) -> [String] {
            guard let r = prompt.range(of: header) else { return [] }
            let rest = String(prompt[r.upperBound...])
            let body = rest.range(of: "\n### ").map { String(rest[..<$0.lowerBound]) } ?? rest
            return body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let hm = lines(after: "### When your Supervisor messages you")
        XCTAssertTrue(hm.contains { $0.hasPrefix("1.") } && hm.contains { $0.hasPrefix("4.") },
                      "Supervisor-message guidance must be numbered steps (decomposed), not prose")
        let att = lines(after: "### Attachments")
        XCTAssertGreaterThanOrEqual(att.filter { $0.hasPrefix("- ") }.count, 2,
                      "attachments guidance must be a typed-dispatch bullet list (decomposed), not prose")
    }

    /// Regression guard for the read-only fix: the manager prompt must NOT name a repo-mutation
    /// tool it no longer has. The prior prompt listed `edit_file`/`write_file` in its boundary;
    /// after the toolset removal those names were dropped (it describes itself as "no file-write,
    /// no git-write" and delegates). If a future edit re-introduces "use edit_file…" guidance,
    /// the model would emit a call the runtime rejects — fail here instead.
    func testManagerPrompt_namesNoRepoMutationTools() {
        let prompt = SystemTemplates.rolePrompts["autovisor"] ?? ""
        for t in [ToolNames.writeFile, ToolNames.editFile, ToolNames.deleteFile,
                  ToolNames.gitAdd, ToolNames.gitCommit, ToolNames.gitMerge] {
            XCTAssertFalse(prompt.contains(t),
                           "manager prompt must not name repo-mutation tool \(t) (the manager has none)")
        }
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
