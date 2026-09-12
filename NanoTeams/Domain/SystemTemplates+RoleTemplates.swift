import Foundation

// MARK: - Role Templates

nonisolated extension SystemTemplates {

    private typealias TN = ToolNames

    /// System role ids that NO bundled template carries any more, and that reconciliation
    /// must therefore delete from a stored team rather than leave beside their replacements.
    ///
    /// Reconciliation is otherwise strictly additive — "existing entries (including roles no
    /// longer present in the bundled template) are never removed" — and that invariant is
    /// right for what it was written to protect: the USER's roles. It is wrong for a system
    /// role the bundle itself retired. Renaming Ultra Team's three would otherwise give a
    /// stored copy THIRTEEN roles — the seven stored (four shared, matched by `systemRoleID`
    /// and never doubled, plus the three under retired ids) and the six the bundle appends:
    /// two planners, both holding `ask_supervisor` (ONE ASKER
    /// broken, the human interrupted twice), and two engineers, both holding
    /// `write_file`/`edit_file`/`delete_file` on one shared tree (ONE WRITER broken — the
    /// silent-corruption failure the pin exists for). The ONE WRITER pin would have stayed
    /// green throughout: it asserts over `TeamTemplateFactory.ultraTeam()`, the fresh
    /// template, not over what is on disk.
    ///
    /// A roster with no expiry date, by the same reasoning as
    /// `AppDefaults.retiredGlobalContextDefaults`: the list IS the permanent input of the
    /// cleanup, not a dated one-shot, so `DatedObligationPinTests` has nothing to guard.
    ///
    /// Matching is by `systemRoleID`, so a role the user renamed in the editor is still
    /// recognised and removed — it is the same system role wearing a different label.
    static let retiredSystemRoleIDs: Set<String> = [
        // Ultra Team, 2026-09-11: renamed for a pipeline that is no longer feature-shaped.
        "featurePlanner", "featureEngineer", "buildVerifier",
        // Ultra Team, 2026-09-12: retired with the wave it owned, because the pipeline stopped
        // being Swift-shaped. The Feasibility Critic's whole contract was a COMPILED probe — one
        // `FeasibilityProbe.swift` placed inside an Xcode target, built, and read back off the
        // compiler's output — and there is no stack-neutral form of that: the file extension, the
        // placement rule (beside an existing source of the target, never at the work-folder root)
        // and the deliberate-syntax-error control are all facts about Xcode. Retiring it matters
        // more than usual: it held `write_file` + `delete_file` on the tree the engineer writes,
        // so a stored folder that kept it would keep a second writer.
        "feasibilityCritic",
    ]

    /// The toolset floor for every Ultra Team role.
    ///
    /// Named rather than repeated nine times: it is a DECISION ("every role can read the
    /// repository and settle the state of the build for itself"), and nine copies of a decision
    /// is nine places for it to half-change.
    ///
    /// **Two build channels, and the pair is the point.** `run_xcodebuild` / `run_xcodetests` are
    /// the fast, structured path — and step 3.1 of `resolveToolSchemasCore` removes BOTH the
    /// moment no Xcode scheme is selected, which is every SwiftPM package, every folder not yet
    /// pointed at a scheme, and every repository that is not Swift at all. `bash` is the channel
    /// that survives there. Naming both HERE is what lets the prompts name neither: a prompt that
    /// orders a tool the resolver may have taken away is an unfulfillable directive, not
    /// disobedience (playbook R5.2.4 / E7.7.6), and this team runs on repositories where exactly
    /// that happens.
    ///
    /// `bash` is NOT a build channel at every setting, and the gap is wider than "the tool is
    /// there". Three modes, three outcomes, none of them this list's to change:
    ///
    /// - `.manual` (the fresh install's DEFAULT) — every command waits for a human; with no human
    ///   `ApprovalGatedAvailability.forBash` withholds `bash` and `bash_output` outright.
    /// - `.semiAutomatic` — the tool ships, but only the read-only bypass runs unattended, and
    ///   `BashConstants.readOnlyPrograms` is `ls`/`cat`/`grep`/`jq` and friends. No build program
    ///   is in it — not `xcodebuild`, not `swift`, not `make`, `cargo`, `npm` or `pytest` — so an
    ///   unattended build is refused as `APPROVAL_UNAVAILABLE`. The roles can READ the repository
    ///   through the shell; they cannot build with it.
    /// - `.auto` — the judge rules, and the build actually runs.
    ///
    /// So on a repository with no Xcode scheme, an unattended run has a build channel only at
    /// `.auto`. `KNOWN_ISSUES` carries that as an open item rather than this list papering over
    /// it with a tool name.
    private static let ultraToolFloor: [String] = [
        TN.readFile, TN.readLines, TN.listFiles, TN.search,
        TN.gitLog, TN.updateScratchpad,
        TN.analyzeImage, TN.runXcodebuild, TN.runXcodetests,
        TN.bash, TN.bashOutput,
    ]

    /// Factory helper — eliminates boilerplate in role template entries.
    /// Adding a new role = one `role(...)` call.
    private static func role(
        _ id: String,
        name: String,
        icon: String,
        toolIDs: [String] = [],
        usePlanningPhase: Bool = false,
        requires: [String] = [],
        produces: [String] = []
    ) -> (String, SystemRoleTemplate) {
        (id, SystemRoleTemplate(
            id: id,
            name: name,
            icon: icon,
            prompt: rolePrompts[id] ?? "",
            meetingGuidance: roleMeetingGuidance[id],
            toolIDs: toolIDs,
            usePlanningPhase: usePlanningPhase,
            dependencies: RoleDependencies(
                requiredArtifacts: requires,
                producesArtifacts: produces
            )
        ))
    }

    /// All available system role templates.
    static let roles: [String: SystemRoleTemplate] = Dictionary(uniqueKeysWithValues: [
        // MARK: Software (FAANG / Startup)
        role("supervisor", name: "Supervisor", icon: "crown",
             produces: [supervisorTaskArtifactName]),
        role("productManager", name: "Product Manager", icon: "doc.text",
             toolIDs: [TN.readFile, TN.readLines, TN.listFiles, TN.search,
                       TN.updateScratchpad, TN.analyzeImage,
                       TN.askTeammate, TN.requestTeamMeeting,
                       TN.askSupervisor, TN.askSupervisorForm],
             requires: [supervisorTaskArtifactName], produces: ["Product Requirements"]),
        // Both UX roles are told to read the codebase ("read files to understand the
        // existing user experience", "reference existing patterns") — the same read set
        // the PM and Tech Lead hold; until 2026-09-06 they held no file tool at all.
        role("uxResearcher", name: "UX Researcher", icon: "person.2",
             toolIDs: [TN.readFile, TN.readLines, TN.listFiles, TN.search,
                       TN.updateScratchpad, TN.analyzeImage,
                       TN.askTeammate, TN.requestTeamMeeting,
                       TN.askSupervisor, TN.askSupervisorForm],
             requires: [supervisorTaskArtifactName], produces: ["Research Report"]),
        role("uxDesigner", name: "UX Designer", icon: "paintbrush.pointed",
             toolIDs: [TN.readFile, TN.readLines, TN.listFiles, TN.search,
                       TN.updateScratchpad, TN.analyzeImage,
                       TN.askTeammate, TN.requestTeamMeeting,
                       TN.askSupervisor, TN.askSupervisorForm],
             requires: ["Product Requirements", "Research Report"], produces: ["Design Spec"]),
        role("techLead", name: "Tech Lead", icon: "brain.head.profile",
             toolIDs: [TN.readFile, TN.readLines, TN.listFiles, TN.search,
                       TN.updateScratchpad, TN.analyzeImage,
                       TN.askTeammate, TN.requestTeamMeeting,
                       TN.askSupervisor, TN.askSupervisorForm],
             requires: [supervisorTaskArtifactName, "Product Requirements"], produces: ["Implementation Plan"]),
        role("softwareEngineer", name: "Software Engineer", icon: "hammer",
             toolIDs: [TN.readFile, TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile,
                       TN.listFiles, TN.search, TN.updateScratchpad,
                       TN.gitAdd, TN.gitCommit,
                       TN.runXcodebuild, TN.runXcodetests,
                       TN.bash, TN.bashOutput,
                       TN.requestTeamMeeting, TN.askTeammate,
                       TN.askSupervisor, TN.askSupervisorForm],
             usePlanningPhase: true,
             requires: ["Implementation Plan", "Design Spec"], produces: ["Engineering Notes"]),
        role("codeReviewer", name: "Code Reviewer", icon: "doc.text.magnifyingglass",
             toolIDs: [TN.readFile, TN.readLines, TN.listFiles, TN.search,
                       TN.gitDiff, TN.gitLog, TN.askTeammate,
                       TN.requestTeamMeeting, TN.updateScratchpad, TN.requestChanges],
             requires: ["Implementation Plan", "Engineering Notes"], produces: ["Code Review Summary"]),
        role("sre", name: "SRE", icon: "shield.checkered",
             toolIDs: [TN.readFile, TN.readLines, TN.listFiles, TN.search,
                       TN.askTeammate, TN.requestTeamMeeting,
                       TN.updateScratchpad, TN.requestChanges],
             requires: ["Engineering Notes"], produces: ["Production Readiness", "Production Readiness Summary"]),
        role("tpm", name: "TPM", icon: "checklist",
             toolIDs: [TN.readFile, TN.readLines, TN.listFiles, TN.search,
                       TN.updateScratchpad, TN.gitLog,
                       TN.askTeammate, TN.requestTeamMeeting, TN.requestChanges,
                       TN.askSupervisor, TN.askSupervisorForm],
             requires: ["Code Review Summary", "Production Readiness Summary"], produces: ["Release Notes"]),

        // MARK: Quest Party
        role("loreMaster", name: "Lore Master", icon: "book",
             requires: [supervisorTaskArtifactName], produces: ["World Compendium"]),
        role("npcCreator", name: "NPC Creator", icon: "theatermasks",
             requires: ["World Compendium"], produces: ["NPC Compendium"]),
        role("encounterArchitect", name: "Encounter Architect", icon: "map",
             requires: ["World Compendium", "NPC Compendium"], produces: ["Encounter Guide"]),
        role("rulesArbiter", name: "Rules Arbiter", icon: "scalemass",
             toolIDs: [TN.requestChanges],
             requires: ["NPC Compendium", "Encounter Guide"], produces: ["Balance Review"]),
        role("questMaster", name: "Quest Master", icon: "scroll",
             toolIDs: [TN.askSupervisor, TN.askSupervisorForm],
             requires: ["World Compendium", "NPC Compendium", "Encounter Guide", "Balance Review"]),

        // MARK: Discussion Club
        role("theAgreeable", name: "The Agreeable", icon: "bubble.left.and.bubble.right",
             toolIDs: [TN.requestTeamMeeting],
             requires: [supervisorTaskArtifactName], produces: ["Discussion Summary"]),
        role("theOpen",          name: "The Open",           icon: "lightbulb"),
        role("theConscientious", name: "The Conscientious",  icon: "list.clipboard"),
        role("theExtrovert",     name: "The Extrovert",      icon: "bolt"),
        role("theNeurotic",      name: "The Neurotic",       icon: "exclamationmark.triangle"),

        // MARK: Personal Assistant
        role("assistant", name: "Assistant", icon: "bubble.left.and.text.bubble.right",
             toolIDs: [TN.askSupervisor, TN.askSupervisorForm,
                       TN.screenCapture, TN.uiClick, TN.uiType, TN.uiKey, TN.uiScroll],
             requires: [supervisorTaskArtifactName]),

        // MARK: Coding Assistant
        role("codingAssistant", name: "Coding Assistant", icon: "curlybraces",
             toolIDs: [TN.readFile, TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile,
                       TN.listFiles, TN.search, TN.updateScratchpad,
                       TN.gitStatus, TN.gitDiff, TN.gitLog, TN.gitBranchList,
                       TN.gitAdd, TN.gitCommit, TN.gitCheckout, TN.gitBranch,
                       TN.gitMerge, TN.gitPull, TN.gitStash,
                       TN.runXcodebuild, TN.runXcodetests,
                       TN.bash, TN.bashOutput,
                       TN.askSupervisor, TN.askSupervisorForm, TN.analyzeImage,
                       TN.screenCapture, TN.uiClick, TN.uiType, TN.uiKey, TN.uiScroll],
             requires: [supervisorTaskArtifactName]),

        // MARK: Coding Agent — hybrid: handles small edits directly, delegates complex work
        // Delegation tools (delegate_to_team, cancel/resume/forward) are
        // NOT in toolIDs — they auto-inject when `hasDelegationConfigured` is true (see
        // `LLMExecutionService+ToolResolution`). The whitelist + generated permission
        // are wired in `TeamTemplateFactory.codingAgent()`.
        role("codingAgent", name: "Coding Agent", icon: "wand.and.rays",
             toolIDs: [TN.readFile, TN.readLines, TN.listFiles, TN.search,
                       TN.writeFile, TN.editFile, TN.deleteFile,
                       TN.gitStatus, TN.gitDiff, TN.gitLog, TN.gitBranchList,
                       TN.bash, TN.bashOutput,
                       TN.updateScratchpad,
                       TN.askSupervisor, TN.askSupervisorForm, TN.analyzeImage],
             requires: [supervisorTaskArtifactName]),

        // MARK: Autovisor — per-folder automated Supervisor (hidden singleton team)
        // Mandatory management tools + optional read-only/inspection tools — single
        // source of truth in `AutovisorConstants` (also drives the role-editor's
        // locked/hidden tool policy + the union-enforce on folder open).
        // `requires: supervisorTaskArtifactName` makes it ADVISORY (not observer → engine
        // runs it). Toolset = `managerDefaultToolIDs` (management + file READ + git READ +
        // analyze_image + update_scratchpad + the Xcode build/test runners, which VERIFY the
        // repo's state rather than change it); NO repo-mutation tools (no write_file/edit_file/
        // delete_file, no git-write), NOT delegate_to_team. The manager inspects the repo and
        // delegates every change via `create_managed_task` — it cannot edit anything.
        role("autovisor", name: "Autovisor", icon: AutovisorConstants.symbolName,
             toolIDs: AutovisorConstants.managerDefaultToolIDs,
             requires: [supervisorTaskArtifactName]),

        // MARK: Ultra Team — a general change pipeline that argues before the code and
        // measures after it
        //
        // Three rules shape these toolsets.
        //
        // ONE WRITER: only the engineer holds file-mutating tools for the repository, because
        // `workFolderRoot` is one tree shared by every role — two parallel implementers would
        // overwrite each other, which is why the divergence lives at the design level and never
        // in the working copy. There is no exception left: the one role that had one wrote a
        // compiled probe, and it retired with the Swift binding on 2026-09-12.
        //
        // The TOOLSET is no longer what enforces this. `bash` is a shell, so by the project's own
        // definition — `ToolHandlerRegistry.repositoryMutatingTools`, the union of the file
        // writers, the mutating Git tools and the shell — all nine roles can now change the tree.
        // What holds the line instead is the approval gate (`BashExecutionMode`: a command runs
        // unattended only under `.semiAutomatic` read-only bypass or `.auto`) plus nine prompts,
        // and a prompt has no power to compel (playbook R3.1.5). `testOnlyTheEngineerHolds…`
        // narrowed to the file writers to match, and says so: it covers less than it did, and
        // pretending otherwise would be the worse of the two.
        //
        // ONE ASKER: only the planner holds the supervisor-ask tools, so the pipeline ASKS the
        // human exactly once, at the stage whose job is to interrogate them
        // (auto-injection cannot add them back — every role here produces artifacts, and
        // `shouldAutoInjectAskSupervisor` requires an EMPTY `producesArtifacts`). It holds
        // BOTH shapes: the questionnaire is what one interruption is FOR — several decisions
        // at once, each carrying the answers the planner already thinks likely — and the plain
        // `ask_supervisor` stays beside it for the follow-up on a contradiction, and because
        // every escalation reminder names that tool and only that one.
        //
        // One ask is not one INTERRUPTION any more, and the rule cannot promise what it used to.
        // At the fresh install's `.manual` bash mode every command — `ls` included — raises an
        // approval card, which is a second channel to the same human that no toolset rule here
        // governs. `.semiAutomatic` is where ordinary reads stop asking.
        //
        // EVERY ROLE MEASURES: all nine hold `analyze_image`, both Xcode runners and `bash`
        // (`ultraToolFloor`). MeditationApp task 48 run 1 cost four reading reviewers
        // 16 min 05 s to find zero defects and produce one harmful artifact, while four build
        // and test calls found everything in 13.8 seconds. A role asked about the state of
        // the build can establish it instead of inferring it. The price is named rather
        // than waved through — five extra schemas on nine roles is the largest block of the
        // first prompt (playbook R3.5.2 / KF5), measured per role in
        // `train-first-prompt/RUN_HISTORY.md`. `XcodeBuildGate` holds a process-wide token, so
        // two roles calling the RUNNERS cannot corrupt one DerivedData and hand somebody a red
        // build indistinguishable from a real one — but a build launched through `bash` takes no
        // token and stands outside that protection, which is the price of the channel that works
        // on a repository Xcode has never heard of.
        //
        // No role holds `ask_teammate` or `request_team_meeting`: a branch that can read a
        // sibling's reasoning mid-flight is no longer independent, and independence is the
        // whole point of running the two architects and the two critics in parallel. That
        // also keeps `maxMeetingsPerRun` entirely for `request_changes` votes, which persist
        // as meetings and share the budget.
        //
        /// Everything every Ultra role holds: read the repository, look at an image, and
        /// settle the state of the build for itself.
        role("changePlanner", name: "Change Planner", icon: "list.clipboard",
             toolIDs: ultraToolFloor + [TN.askSupervisor, TN.askSupervisorForm],
             requires: [supervisorTaskArtifactName], produces: ["Change Brief"]),
        // The brief is the root document and nothing reviewed it. In MeditationApp task 48
        // run 1 it carried `=== BUILD SUCCESS ===` written eleven minutes before the first
        // line of code, and everything below inherited the invention. The correction goes
        // FORWARD, not back through a vote: `Brief Critique` is a required input of both
        // architects, so it reaches the roles that can act on it and costs no meeting.
        role("briefCritic", name: "Brief Critic", icon: "text.magnifyingglass",
             toolIDs: ultraToolFloor,
             requires: ["Change Brief"], produces: ["Brief Critique"]),
        role("solutionArchitect", name: "Solution Architect", icon: "square.stack.3d.up",
             toolIDs: ultraToolFloor + [TN.gitDiff],
             requires: ["Change Brief", "Brief Critique"], produces: ["Approach A"]),
        role("pragmaticArchitect", name: "Pragmatic Architect", icon: "scissors",
             toolIDs: ultraToolFloor + [TN.gitDiff],
             requires: ["Change Brief", "Brief Critique"], produces: ["Approach B"]),
        // Both critics judge the two designs with no separate wave of measurement in front of
        // them: the role that held one was Xcode-only and retired on 2026-09-12. The `### Unverified`
        // list each architect is required to leave is what replaces it, and it is settled by
        // whoever needs the fact — every role here can read the repository and run the build.
        // The cost is recorded rather than hidden (MeditationApp task 48 run 1: the spec critic
        // ranked a design built on invented `.onOpenIntent` / `.intentLink(_:)` above an honest
        // one, having no verdict in hand): an opportunity to check is weaker than a wave that
        // must. `KNOWN_ISSUES` carries it as an open item.
        //
        // The brief is required HERE and not by the regression critic: this role's contract is
        // a table over the acceptance criteria, and the criteria exist in exactly one document.
        // A path in the handoff would make that table depend on a read the model may skip.
        role("specCritic", name: "Spec Critic", icon: "checklist",
             toolIDs: ultraToolFloor + [TN.gitDiff],
             requires: ["Change Brief", "Approach A", "Approach B"],
             produces: ["Spec Critique"]),
        role("regressionCritic", name: "Regression Critic", icon: "exclamationmark.triangle",
             toolIDs: ultraToolFloor + [TN.gitDiff],
             requires: ["Approach A", "Approach B"],
             produces: ["Regression Critique"]),
        // The approaches are deliberately NOT required here: they are done by now, so they
        // reach the handoff as path metadata and the engineer reads the recommended one from
        // disk. Four inlined documents instead of six — the fan-in's required-artifacts
        // turn carries whole bodies, uncapped.
        role("changeEngineer", name: "Change Engineer", icon: "hammer.fill",
             toolIDs: ultraToolFloor + [TN.writeFile, TN.editFile, TN.deleteFile, TN.gitDiff],
             usePlanningPhase: true,
             requires: ["Change Brief", "Spec Critique", "Regression Critique"],
             produces: ["Implementation Notes"]),
        // The diff is the only record of what the repository actually received; the notes are
        // a claim about it. Sequential with the verifier rather than parallel, and that is
        // forced: a `request_changes` from here convenes the CONSUMERS of the engineer's
        // artifact, and `MeetingParticipantResolver` never filters by execution status — a
        // parallel verifier would be pulled into a vote in the middle of its own build.
        role("diffReviewer", name: "Diff Reviewer", icon: "arrow.triangle.branch",
             toolIDs: ultraToolFloor + [TN.gitDiff, TN.gitStatus, TN.requestChanges],
             requires: ["Implementation Notes"], produces: ["Diff Review"]),
        // No writers, deliberately: a verifier that can fix what it finds is verifying itself.
        // That rule protects the VERDICT from its author; the compiler returns a fact, so the
        // runners are not a violation of it — the verifier still runs the commands itself and
        // still owns the report.
        // The brief rides in alongside the notes because the pipeline's success has three parts —
        // it builds, the tests pass, the requirement is met — and the third is settled nowhere
        // else: the spec critic judged DESIGNS against the criteria, before any code existed.
        role("changeVerifier", name: "Change Verifier", icon: "checkmark.seal",
             toolIDs: ultraToolFloor + [TN.gitDiff, TN.gitStatus, TN.requestChanges],
             requires: ["Change Brief", "Implementation Notes", "Diff Review"],
             produces: ["Verification Report"]),
    ])
}
