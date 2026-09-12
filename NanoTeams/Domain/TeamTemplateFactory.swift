import Foundation

/// Creates built-in Team instances from system templates.
/// Use `Team.defaultTeams` or `Team.default` as entry points — they delegate here.
nonisolated enum TeamTemplateFactory {

    // MARK: - Template Metadata

    /// Display metadata for the team template picker UI (NewTeamSheet).
    struct TeamTemplateMetadata: Identifiable {
        let id: String
        let name: String
        let icon: String
        let description: String
    }

    /// Synthetic id for the "Empty Team" picker card. NOT a real template:
    /// `allTemplates` never contains it, `SystemTemplates.templateConfigs` has no
    /// entry for it, and no `Team.templateID` is ever set to it — an empty team is
    /// a CUSTOM team (`templateID == nil`). It exists only as the picker's
    /// selection token, resolved by `makeTeam(templateID:name:)`.
    static let emptyTemplateID = "empty"

    /// Ordered list of template metadata including the "Empty Team" entry.
    static let templateMetadata: [TeamTemplateMetadata] = [
        TeamTemplateMetadata(id: emptyTemplateID, name: "Empty Team", icon: "plus.square.dashed", description: "A Supervisor and one Teammate — rename them and add your own roles"),
        TeamTemplateMetadata(id: "codingAssistant", name: "Coding Assistant", icon: "curlybraces", description: "Interactive coding companion with files, git, and Xcode tools"),
        TeamTemplateMetadata(id: "codingAgent", name: "Coding Agent", icon: "wand.and.rays", description: "Hybrid coding agent: handles small edits directly, delegates complex work to teams"),
        TeamTemplateMetadata(id: "assistant", name: "Personal Assistant", icon: "bubble.left.and.text.bubble.right", description: "Interactive assistant for any task"),
        TeamTemplateMetadata(id: "faang", name: "FAANG Team", icon: "building.2", description: "Full product development pipeline"),
        TeamTemplateMetadata(id: "engineering", name: "Engineering Team", icon: "wrench.and.screwdriver", description: "Lean engineering pipeline"),
        TeamTemplateMetadata(id: "ultra", name: "Ultra Team", icon: "arrow.triangle.branch", description: "Change pipeline: brief critique, two competing designs, two adversarial critiques, diff review, verified build"),
        TeamTemplateMetadata(id: "startup", name: "Startup", icon: "bolt", description: "Minimal team for rapid prototyping"),
        TeamTemplateMetadata(id: "questParty", name: "Quest Party", icon: "scroll", description: "Adventure creation and management"),
        TeamTemplateMetadata(id: "discussionClub", name: "Discussion Club", icon: "bubble.left.and.bubble.right", description: "Meeting-driven discussion"),
    ]

    // MARK: - Public API

    static var allTemplates: [Team] {
        [codingAssistant(), codingAgent(), assistant(), faang(), engineering(), ultraTeam(), startup(), questParty(), discussionClub()]
    }

    /// Resolves a New Team sheet selection (a `templateMetadata` id) into a brand-new team.
    ///
    /// - `emptyTemplateID` → `empty(name:)`.
    /// - A real template id → that template `.duplicate(withName:)`, which is what makes the
    ///   result CUSTOM (`templateID = nil`, role/artifact ids re-seeded from the new name)
    ///   rather than a second team wearing the template's identity.
    /// - Anything else — a stale persisted id, a typo, a metadata row whose factory method was
    ///   removed, or a hidden templateID like `"generated"` / the Autovisor's (both real ids
    ///   that are deliberately absent from `allTemplates`) → `empty(name:)`. Falling through
    ///   to a POPULATED team is the exact bug this method exists to prevent: the old
    ///   view-layer `else` branch called `TeamManagementService.createTeam`, which cloned
    ///   `Team.default` (== FAANG), so picking "Empty Team" produced a full 9-role roster.
    ///
    /// Resolution lives here rather than in `TeamEditorView+Actions` because that call site
    /// needs a live orchestrator and `mutateWorkFolder`, which makes the unresolved-id case
    /// effectively untestable — which is why the FAANG fallback shipped unnoticed.
    static func makeTeam(templateID: String, name: String) -> Team {
        // The `emptyTemplateID` check is redundant with the lookup below (no template
        // carries that id), but it states the intent — the fallback is the safety net,
        // not the mechanism.
        guard templateID != emptyTemplateID,
              let template = allTemplates.first(where: { $0.templateID == templateID })
        else { return empty(name: name) }
        return template.duplicate(withName: name)
    }

    static func faang() -> Team {
        buildTeam(
            name: "FAANG Team",
            description: "Full product development pipeline with specialized roles for requirements, design, architecture, implementation, code review, SRE, and release management.",
            templateID: "faang",
            roleIDs: ["productManager", "uxResearcher", "uxDesigner", "techLead",
                      "softwareEngineer", "codeReviewer", "sre", "tpm"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName, "Product Requirements", "Research Report", "Design Spec",
                            "Implementation Plan", "Engineering Notes",
                            "Code Review Summary", "Production Readiness", "Production Readiness Summary", "Release Notes"],
            coordinatorIndex: 8,
            supervisorRequires: ["Release Notes"],
            supervisorMode: .autonomous
        )
    }

    static func engineering() -> Team {
        buildTeam(
            name: "Engineering Team",
            description: "Lean engineering pipeline: architecture, implementation, code review, and release management.",
            templateID: "engineering",
            roleIDs: ["techLead", "softwareEngineer", "codeReviewer", "tpm"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName,
                            "Implementation Plan", "Engineering Notes",
                            "Code Review Summary", "Release Notes"],
            coordinatorIndex: 4,
            supervisorRequires: ["Release Notes"],
            supervisorMode: .autonomous
        ) { roles in
            // TechLead depends on Supervisor Task directly (no PM in this team)
            roles[1].dependencies.requiredArtifacts = [SystemTemplates.supervisorTaskArtifactName]
            // SWE depends on Implementation Plan only
            roles[2].dependencies.requiredArtifacts = ["Implementation Plan"]
            // TPM depends on Code Review Summary only (no SRE in this team)
            roles[4].dependencies.requiredArtifacts = ["Code Review Summary"]
        }
    }

    /// Ultra Team — a general CHANGE pipeline that argues before the code and measures after
    /// it. Not feature-shaped: the first line of the brief names the kind of work (defect, new
    /// behaviour, refactor, a question about the code, a one-file edit) and the pipeline sizes
    /// itself to that.
    ///
    /// Seven waves, two of them internally parallel:
    /// brief → brief critique → two independent designs → spec + regression critiques →
    /// implementation → diff review → verification.
    ///
    /// A lens is added when and only when it is settled by a DIFFERENT source of truth — any
    /// other lens is a second opinion, and one role already holds that job (playbook R3.1.1).
    /// Before code exists there are three sources: the brief itself (Brief Critic), the brief
    /// as a requirement on the design (Spec Critic) and the existing code (Regression Critic).
    /// Security and performance need running code
    /// and live after the build, where the Diff Reviewer and the Change Verifier already
    /// stand. "Shape of the code" is not a lens: it is precisely what the two architects
    /// argue about.
    ///
    /// **There were four, and the fourth was the compiler.** It had a wave of its own — the
    /// Feasibility Critic, which wrote one `FeasibilityProbe.swift` beside a source file of the
    /// target it was probing, built it, and reported what the compiler said. It retired on
    /// 2026-09-12 with the rest of the Swift binding, because every part of that contract was a
    /// fact about Xcode: the file extension, the placement rule, and the deliberate-syntax-error
    /// control that caught a project with explicit build-file lists compiling the probe into
    /// nothing. This pipeline has to run on repositories Xcode has never heard of.
    ///
    /// The cost is recorded rather than argued away. In MeditationApp task 48 run 1 the spec
    /// critic ranked a design built on invented `.onOpenIntent` and `.intentLink(_:)` ABOVE an
    /// honest one, and punished the honest one for saying "Awaiting execution" — it judged with
    /// no compiler verdict, because nobody in the team had one. What replaces the wave is an
    /// opportunity rather than an obligation: every role holds `bash` and both runners, and the
    /// Spec Critic is the one told to settle the `### Unverified` entries its verdict rests on.
    /// `KNOWN_ISSUES` carries it as an open item, unmeasured.
    ///
    /// **Diff review and verification are SEQUENTIAL, not parallel**, and that is forced by
    /// the meeting machinery rather than chosen: a `request_changes` from the Diff Reviewer
    /// convenes the CONSUMERS of the engineer's artifact, and
    /// `MeetingParticipantResolver.filterParticipants` filters by identity, membership,
    /// Supervisor and `invitableRoles` — never by execution status. A parallel verifier would
    /// be pulled into that vote in the middle of its own build. One extra stage buys the
    /// verifier a diff review to check the notes against.
    ///
    /// **`coordinatorIndex: 1` — the Change Planner chairs.** The coordinator sits in EVERY
    /// meeting by construction, so a `request_changes` holder in that seat would judge its
    /// neighbours' cases as a matter of routine. The planner holds no `request_changes`, is
    /// `.done` from wave 2 onward, and is a legal `request_changes` target for exactly one
    /// role — the Change Verifier, which requires the brief and runs at wave 7 when every
    /// consumer of the brief is already `.done` (`UltraTeamTests` pins the edge). On that
    /// vote the planner is the target, so `effectiveCoordinator` seats a stand-in chair; the
    /// same runtime rule closes the hole for user-authored teams, and this index is the
    /// second layer.
    ///
    /// Dependencies come from the role templates unchanged — no `customize` closure — because
    /// the graph IS the design.
    ///
    /// `.manual`, not `.autonomous`: the planner's whole value is pulling missing detail out of
    /// the human, and an autonomous run would answer it with `SupervisorAutoAnswerService`.
    /// The ASK channel is bounded by the toolset — only the planner holds `ask_supervisor`, so
    /// the pipeline asks once, at stage 0, and every later wave runs without asking.
    ///
    /// That is one channel, not the human's whole exposure, and it stopped being the only one on
    /// 2026-09-12 when `bash` joined the toolset floor. Approval cards are the second, and no
    /// rule here bounds them: at `BashConstants.defaultMode` — `.manual`, the fresh install's —
    /// every shell command from any of the nine roles waits for a human, `ls` included, because
    /// Manual asks ABOVE the read-only bypass. `.semiAutomatic` is where ordinary reads stop
    /// asking. Sized honestly in `KNOWN_ISSUES`; the toolset comment in
    /// `SystemTemplates+RoleTemplates.swift` carries the same correction beside the rule itself.
    static func ultraTeam() -> Team {
        buildTeam(
            name: "Ultra Team",
            description: "Change pipeline: a planner who asks for what is missing, a critique of the brief itself, two competing designs, two adversarial critiques of them, one implementation, a diff review, and a verifier that builds and tests it.",
            templateID: "ultra",
            roleIDs: ["changePlanner", "briefCritic", "solutionArchitect", "pragmaticArchitect",
                      "specCritic", "regressionCritic",
                      "changeEngineer", "diffReviewer", "changeVerifier"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName,
                            "Change Brief", "Brief Critique", "Approach A", "Approach B",
                            "Spec Critique", "Regression Critique",
                            "Implementation Notes", "Diff Review", "Verification Report"],
            coordinatorIndex: 1,
            supervisorRequires: ["Implementation Notes", "Diff Review", "Verification Report"],
            limits: .ultra,
            supervisorMode: .manual
        )
    }

    static func startup() -> Team {
        buildTeam(
            name: "Startup",
            description: "Lean two-person team where the Supervisor provides direction and a Software Engineer handles all implementation.",
            templateID: "startup",
            roleIDs: ["softwareEngineer"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName, "Engineering Notes"],
            coordinatorIndex: 1,
            supervisorRequires: ["Engineering Notes"]
        ) { roles in
            typealias TN = ToolNames
            // SWE depends on Supervisor Task directly and has no teammate tools
            roles[1].toolIDs = [
                TN.readFile, TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile,
                TN.listFiles, TN.search, TN.updateScratchpad,
                TN.gitAdd, TN.gitCommit,
                TN.runXcodebuild, TN.runXcodetests,
                TN.bash, TN.bashOutput,
                TN.askSupervisor, TN.askSupervisorForm,
            ]
            roles[1].dependencies.requiredArtifacts = [SystemTemplates.supervisorTaskArtifactName]
        }
    }

    static func questParty() -> Team {
        buildTeam(
            name: "Quest Party",
            description: "Single-player adventure team: specialists build a personalized world, characters, and encounters, then the Quest Master narrates an interactive story where the Supervisor plays the hero.",
            templateID: "questParty",
            roleIDs: ["loreMaster", "npcCreator", "encounterArchitect", "rulesArbiter", "questMaster"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName, "World Compendium", "NPC Compendium",
                            "Encounter Guide", "Balance Review"],
            coordinatorIndex: 5,
            supervisorRequires: []
        )
    }

    static func discussionClub() -> Team {
        buildTeam(
            name: "Discussion Club",
            description: "Lively discussion group where strong personalities engage, debate, and challenge each other in natural conversation.",
            templateID: "discussionClub",
            roleIDs: ["theAgreeable", "theOpen", "theConscientious", "theExtrovert", "theNeurotic"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName, "Discussion Summary"],
            coordinatorIndex: 1,
            supervisorRequires: ["Discussion Summary"],
            limits: .discussionClub,
            supervisorMode: .autonomous
        )
    }

    static func assistant() -> Team {
        buildTeam(
            name: "Personal Assistant",
            description: "One-on-one assistant that handles any task through interactive dialog — reading and writing documents, analyzing images, research, planning, and more.",
            templateID: "assistant",
            roleIDs: ["assistant"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName],
            coordinatorIndex: 1,
            supervisorRequires: []
        ) { roles in
            typealias TN = ToolNames
            // Document-focused: files (read + write) + scratchpad + supervisor + vision
            // + computer use (screen control — gated per-action by the permission layer).
            // NO git, xcode, or teammate tools
            roles[1].toolIDs = [
                TN.readFile, TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile,
                TN.listFiles, TN.search,
                TN.updateScratchpad,
                TN.askSupervisor, TN.askSupervisorForm, TN.analyzeImage,
                TN.screenCapture, TN.uiClick, TN.uiType, TN.uiKey, TN.uiScroll,
            ]
            roles[1].dependencies.requiredArtifacts = [SystemTemplates.supervisorTaskArtifactName]
        }
    }

    /// Coding Agent — hybrid coding agent that handles small edits directly and
    /// delegates complex implementation work to other teams via `delegate_to_team`.
    /// Default whitelist includes the built-in programming-focused teams except
    /// FAANG: Engineering and Startup. Generated teams are enabled by default so
    /// the agent can spawn a tailored team when no stored team is a good fit.
    static func codingAgent() -> Team {
        // Default delegation whitelist — IDs are deterministic via NTMSID.from(name:),
        // so we can refer to siblings before they're built.
        let engineeringID = NTMSID.from(name: "Engineering Team")
        let startupID = NTMSID.from(name: "Startup")

        return buildTeam(
            name: "Coding Agent",
            description: "Hybrid coding agent: edits files directly for small changes, delegates complex implementation to a chosen team.",
            templateID: "codingAgent",
            roleIDs: ["codingAgent"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName],
            coordinatorIndex: 1,
            supervisorRequires: [],
            supervisorMode: .manual
        ) { roles in
            roles[1].dependencies.requiredArtifacts = [SystemTemplates.supervisorTaskArtifactName]
            // Programming-focused teams except FAANG. Coding Assistant is chat-mode and
            // therefore filtered out at delegate time even if listed — omit for clarity.
            //
            // These two assignments together flip `hasDelegationConfigured` to true, which
            // (a) makes `buildSettings` skip the `reportsTo` wiring (peer-with-Supervisor),
            // and (b) makes `LLMExecutionService+ToolResolution` auto-inject the 4-tool
            // delegation pack into the LLM schema. The role's `toolIDs` does NOT contain
            // `delegate_to_team` — that's an auto-injected tool now (like `ask_supervisor`).
            roles[1].allowedDelegationTeamIDs = [engineeringID, startupID]
            roles[1].allowDelegationToGeneratedTeams = true
        }
    }

    static func codingAssistant() -> Team {
        buildTeam(
            name: "Coding Assistant",
            description: "One-on-one coding companion that reads, edits, and ships code via git + Xcode tools through interactive dialog.",
            templateID: "codingAssistant",
            roleIDs: ["codingAssistant"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName],
            coordinatorIndex: 1,
            supervisorRequires: [],
            supervisorMode: .manual
        ) { roles in
            typealias TN = ToolNames
            // Full coding kit: files (read + write) + search + scratchpad + git + xcode
            // + vision + computer use (gated per-action by the permission layer) + supervisor
            // NO teammate tools (single-role team has no consultations)
            roles[1].toolIDs = [
                TN.readFile, TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile,
                TN.listFiles, TN.search, TN.updateScratchpad,
                TN.gitStatus, TN.gitDiff, TN.gitLog, TN.gitBranchList,
                TN.gitAdd, TN.gitCommit, TN.gitCheckout, TN.gitBranch,
                TN.gitMerge, TN.gitPull, TN.gitStash,
                TN.runXcodebuild, TN.runXcodetests,
                TN.bash, TN.bashOutput,
                TN.askSupervisor, TN.askSupervisorForm, TN.analyzeImage,
                TN.screenCapture, TN.uiClick, TN.uiType, TN.uiKey, TN.uiScroll,
            ]
            roles[1].dependencies.requiredArtifacts = [SystemTemplates.supervisorTaskArtifactName]
        }
    }

    /// Ids that a template team WILL claim once it is materialised, for the two templates
    /// created lazily rather than at bootstrap: the Autovisor team on first enable, the
    /// Generated placeholder on the first "Generate Team..." pick. Exactly `Team.isHiddenFromPickers`.
    ///
    /// They need reserving because a template team's id is derived from its NAME
    /// (`buildTeam` does `NTMSID.from(name:)`), not from its `templateID` — so a user team
    /// named "Autovisor" derives `autovisor` — and because both creators guard on
    /// `templateID`, which a custom team does not carry:
    /// `ensureAutovisorTeam` appends when no team has `templateID == "autovisor"`, and the
    /// QuickCapture picker appends the placeholder on the same test. Neither sees the
    /// custom team sitting on the id, and `WorkFolderProjection.addTeam` deliberately does
    /// not rename a TEMPLATE team (its id is the identity bootstrap and the tombstone key
    /// on), so without this the collision is unresolvable at the later door.
    ///
    /// Consequence if unreserved: the Autovisor task's `preferredTeamID` is that id, and
    /// every resolution is `teams.first { $0.id == ... }` — which returns the user's team,
    /// so the manager runs on the wrong roster; and `removeTeam` is `removeAll`, so deleting
    /// either deletes both.
    ///
    /// Derived, never spelled: reading the ids off the factories is what keeps this true
    /// when a template is renamed.
    nonisolated static var lazilyMaterialisedTeamIDs: Set<NTMSID> {
        [autovisor().id, generatedTeam().id]
    }

    /// "Generated Team" — Supervisor-only placeholder. When a task is started with this
    /// template, the orchestrator triggers a background `create_team` generation (attributed
    /// to Supervisor, shown in activity feed like `analyze_image`). The resulting team is
    /// stored on `NTMSTask.generatedTeam` and takes over the run.
    static func generatedTeam() -> Team {
        buildTeam(
            name: "Generated Team",
            description: "AI assembles the optimal team from your task description.",
            templateID: "generated",
            roleIDs: [],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName],
            coordinatorIndex: 0,
            supervisorRequires: [],
            supervisorMode: .manual
        )
    }

    /// "Autovisor" — the per-folder automated Supervisor. A hidden singleton
    /// chat-mode team with one advisory `Manager` role, instantiated lazily by
    /// `ensureAutovisorTask` when the user enables the feature. NOT part of
    /// `allTemplates` / `templateMetadata` — it is infrastructure, not a user-pickable
    /// template, and is filtered out of every team picker (same as `"generated"`).
    ///
    /// MUST be `supervisorMode: .autonomous` + chat-mode (empty `supervisorRequires`)
    /// + advisory (role requires the Supervisor Task artifact) so the engine runs it
    /// and the flow-control backstops apply. A healthy pass ends at `wait_for_events`;
    /// `.autonomous` is what arms `noteNonProductiveTurn`, which parks a
    /// manager that stops calling tools instead of letting it spin forever.
    static func autovisor() -> Team {
        buildTeam(
            name: "Autovisor",
            description: "Autonomous per-folder Supervisor: watches all tasks, creates/runs/stops them, answers their questions, and maintains the folder's goal, memory, and shared context.",
            templateID: AutovisorConstants.teamTemplateID,
            roleIDs: ["autovisor"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName],
            // The lone Manager role is the only possible coordinator.
            coordinatorIndex: 1,
            supervisorRequires: [],
            supervisorMode: .autonomous
        ) { roles in
            // Advisory (not observer) so the engine executes the step; this is the
            // single line that makes the Manager run (see CLAUDE.md role completion types).
            roles[1].dependencies.requiredArtifacts = [SystemTemplates.supervisorTaskArtifactName]
        }
    }

    // MARK: - Empty Team

    /// A brand-new user team: the Supervisor, one Teammate that takes its task, and the
    /// two artifacts that connect them. The smallest team that actually RUNS, and the
    /// starting point behind "Empty Team" in the New Team sheet.
    ///
    /// Unlike its siblings this takes a `name` — it has no fixed identity, because it is
    /// not a template. The result is a CUSTOM team (`templateID == nil`), so
    /// `NTMSRepository+Reconcile` never rewrites its prompts or roles on a version bump,
    /// and the three prompt templates fall to `Team.init`'s generic defaults.
    ///
    /// Deliberately NOT routed through `buildTeam`, for three independent reasons:
    /// 1. `buildTeam` force-unwraps `SystemTemplates.templateConfigs[templateID]!` and
    ///    there is no `"empty"` key. Registering one would fabricate a template identity
    ///    for something that is deliberately not a template, and that unwrap is a
    ///    load-bearing "you forgot to register a config" tripwire for the ten real ones.
    /// 2. `buildTeam` requires a non-optional `templateID` and writes it onto the team.
    /// 3. `buildTeam` overrides the prompt templates from the config.
    ///
    /// Why "empty" is not literally empty:
    /// - **Supervisor.** `RoleEditorMutations.applyCreate` hardcodes
    ///   `isSystemRole: false, systemRoleID: nil`, so the UI can never add a Supervisor
    ///   back. A team without one is permanently unusable — the acceptance flow, the
    ///   graph, and `Team.supervisorRequiredArtifacts` all read `roles.first(where: \.isSupervisor)`.
    /// - **"Supervisor Task".** `ArtifactDependencyEditor` offers `team.artifactNames` as
    ///   the Required options. With zero artifacts the first role the user adds would have
    ///   empty required AND produced lists → `completionType == .observer` →
    ///   `TeamEngine.findReadyRoles` filters it out and the team never runs.
    /// - **"Teammate" + "Result".** The Supervisor is the user, not an LLM — a
    ///   Supervisor-only team has nothing to execute and cannot run at all. Reaching a
    ///   team that does took four non-obvious edits in the Team Editor (add a role, point
    ///   its Required at "Supervisor Task", invent an output artifact, then list that
    ///   artifact on the Supervisor). Shipping the pair makes the smallest team the
    ///   RUNNABLE one, and it doubles as the worked example of the artifact-dependency
    ///   model every other template is built on.
    ///
    /// Shape (structurally identical to `startup()`): Supervisor produces "Supervisor Task"
    /// and requires "Result"; Teammate requires "Supervisor Task" and produces "Result" —
    /// i.e. `.producing`, so it self-completes on `create_artifact` and the task lands in
    /// Review. The Supervisor↔Teammate artifact loop is a cycle on paper but never a
    /// scheduling one: `TeamEngine.findReadyRoles` puts every Supervisor id into
    /// `excludeRoleIDs` before asking `ArtifactDependencyResolver.findReadyRoles`, which only
    /// checks that a role's `requiredArtifacts` have been produced — the Supervisor's
    /// requirement is the review gate (`Team.requiresSupervisorFinalReview`), not an edge.
    static func empty(name: String) -> Team {
        typealias TN = ToolNames

        // The seed is what keeps two empty teams apart: `SystemTemplates.createRole` /
        // `createArtifact` derive ids as `NTMSID.from(name: "\(seed):…")`. Re-seeding only
        // `team.id` (what the deleted `TeamManagementService.createTeam` did) left every
        // such team sharing role ids — a live namespace shared with `StepExecution.id`
        // and `settings.hierarchy.reportsTo`.
        let teamSeed = NTMSID.from(name: name)

        var supervisor = SystemTemplates.createRole(
            from: SystemTemplates.roles["supervisor"]!,
            teamSeed: teamSeed
        )
        // The Supervisor template already declares `produces: [supervisorTaskArtifactName]`;
        // requiring the Teammate's output is what makes this a pipeline team rather than a
        // chat one (`Team.isChatMode == supervisorRequiredArtifacts.isEmpty`).
        supervisor.dependencies.requiredArtifacts = [resultArtifactName]

        var supervisorTask = SystemTemplates.createArtifact(
            from: SystemTemplates.artifacts[SystemTemplates.supervisorTaskArtifactName]!,
            teamSeed: teamSeed
        )
        // `templateID == nil` ⇒ nothing ever reconciles this content against a bundled
        // template, so the system flags would be claims with no referent — and
        // `Team.removeRole` / `removeArtifact` would record tombstones nothing reads.
        // Same normalization `Team.duplicate` and `TeamImportExportService.importTeam`
        // apply. `isSupervisor` keys on `systemRoleID`, which is preserved, so Supervisor
        // detection is unaffected.
        supervisor.isSystemRole = false
        supervisorTask.isSystemArtifact = false

        // "Result" is built inline rather than registered in `SystemTemplates.artifacts`:
        // it belongs to this one custom team, and a generic entry there would offer itself
        // in every team's artifact picker. Id shape matches `createArtifact` exactly so
        // two empty teams stay disjoint.
        let result = TeamArtifact(
            id: NTMSID.from(name: "\(teamSeed):artifact:\(resultArtifactName)"),
            name: resultArtifactName,
            icon: "doc.text",
            mimeType: "text/markdown",
            description: "What the Teammate did and found: the outcome of the Supervisor's task, the steps taken, and anything the Supervisor needs to decide next.",
            isSystemArtifact: false,
            systemArtifactName: nil
        )

        // Built INLINE as a custom role — mirroring `RoleEditorMutations.applyCreate`, the
        // one path that creates roles in this app — rather than from a
        // `SystemTemplates.roles` entry. Three reasons, all structural:
        //   1. `templateID == nil` makes this a custom team; a `systemRoleID` here would be
        //      a claim with no referent, exactly as for the Supervisor two blocks up.
        //   2. `TeamManagementService.syncSystemRoleDependencies` gates on `isSystemRole`
        //      and rewrites `producesArtifacts` from the template on EVERY work-folder
        //      open. A system-flagged starter role would silently undo the user's first
        //      edit to it.
        //   3. A `roles` entry drags in a `Role` enum case + `Role.metadata` +
        //      `RoleColorDefaults.backgroundHex` (pinned via `Role.builtInCases`) +
        //      `fallbackToolIDs`, for a role that exists only in custom teams.
        // `iconBackground` MUST be passed: the memberwise-init default is "#007AFF", not
        // the custom-role blue `RoleColorDefaults.defaultBackgroundHex(for: nil)` returns.
        let teammate = TeamRoleDefinition(
            id: NTMSID.from(name: "\(teamSeed):\(teammateRoleName)"),
            name: teammateRoleName,
            icon: "person.fill",
            prompt: SystemTemplates.rolePrompts[teammateRolePromptID] ?? "",
            meetingGuidance: SystemTemplates.roleMeetingGuidance[teammateRolePromptID],
            // Ordered literal, never a `Set` union: tool order feeds `{toolList}` and the
            // tool-schema section, i.e. segment-0 prompt bytes, and Swift reshuffles a
            // `Set` per process launch — which would re-prefill the prompt cache on every
            // launch. Read-only by design; the user grants more in the role editor.
            // `create_artifact` is deliberately absent (auto-injected for any role with
            // `producesArtifacts`), while `ask_supervisor` must be explicit — it
            // auto-injects only for NON-producing roles (`shouldAutoInjectAskSupervisor`).
            toolIDs: [
                TN.readFile, TN.readLines, TN.listFiles, TN.search,
                TN.updateScratchpad,
                TN.askSupervisor, TN.askSupervisorForm,
            ],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [SystemTemplates.supervisorTaskArtifactName],
                producesArtifacts: [resultArtifactName]
            ),
            isSystemRole: false,
            systemRoleID: nil,
            iconBackground: RoleColorDefaults.defaultHex
        )

        let roles = [supervisor, teammate]
        return Team(
            id: teamSeed,
            name: name,
            description: "Custom team — a starting point: the Supervisor briefs one Teammate, who reports back a Result. Rename the roles and artifacts to fit the real workflow.",
            templateID: nil,
            roles: roles,
            artifacts: [supervisorTask, result],
            // Reuse the shared builder rather than `TeamSettings.default` so settings stay
            // DERIVED from the roster: the Teammate reports to the Supervisor, is invitable
            // to meetings, and coordinates them (the only role that could).
            settings: buildSettings(roles: roles, coordinatorIndex: 1),
            graphLayout: TeamGraphLayout.autoLayout(for: roles)
        )
    }

    /// Display name of the starter role in `empty(name:)`. Also the join key its role id
    /// is derived from — renaming it changes every future empty team's role id.
    static let teammateRoleName = "Teammate"

    /// The one artifact the starter Teammate produces and the Supervisor requires.
    static let resultArtifactName = "Result"

    /// Key into `SystemTemplates.rolePrompts` for the starter role's guidance. Deliberately
    /// NOT a `SystemTemplates.roles` id — see the comment inside `empty(name:)`.
    private static let teammateRolePromptID = "teammate"

    // MARK: - Shared Builder

    private static func buildTeam(
        name: String,
        description: String,
        templateID: String,
        roleIDs: [String],
        artifactNames: [String],
        coordinatorIndex: Int,
        supervisorRequires: [String],
        limits: TeamLimits = .default,
        acceptanceMode: AcceptanceMode = .finalOnly,
        supervisorMode: SupervisorMode = .manual,
        customize: ((inout [TeamRoleDefinition]) -> Void)? = nil
    ) -> Team {
        let teamSeed = NTMSID.from(name: name)
        let supervisorTemplate = SystemTemplates.roles["supervisor"]!
        var roles = [SystemTemplates.createRole(from: supervisorTemplate, teamSeed: teamSeed)]
        roles += roleIDs.compactMap { id in
            SystemTemplates.roles[id].map { SystemTemplates.createRole(from: $0, teamSeed: teamSeed) }
        }
        roles[0].dependencies.requiredArtifacts = supervisorRequires
        customize?(&roles)

        let artifacts = artifactNames.compactMap { artifactName in
            SystemTemplates.artifacts[artifactName].map { SystemTemplates.createArtifact(from: $0, teamSeed: teamSeed) }
        }

        let config = SystemTemplates.templateConfigs[templateID]!

        return Team(
            id: NTMSID.from(name: name),
            name: name,
            description: description,
            templateID: templateID,
            systemPromptTemplate: config.system,
            consultationPromptTemplate: config.consultation,
            meetingPromptTemplate: config.meeting,
            roles: roles,
            artifacts: artifacts,
            settings: buildSettings(
                roles: roles,
                coordinatorIndex: coordinatorIndex,
                limits: limits,
                acceptanceMode: acceptanceMode,
                supervisorMode: supervisorMode
            ),
            graphLayout: TeamGraphLayout.autoLayout(for: roles)
        )
    }

    /// Builds TeamSettings from a role array, wiring up hierarchy, invitable roles and the
    /// meeting coordinator. `coordinatorIndex` indexes `roles` and is never the Supervisor
    /// (index 0): every bundled team names a coordinator — there is no "Auto".
    private static func buildSettings(
        roles: [TeamRoleDefinition],
        coordinatorIndex: Int,
        limits: TeamLimits = .default,
        acceptanceMode: AcceptanceMode = .finalOnly,
        supervisorMode: SupervisorMode = .manual
    ) -> TeamSettings {
        let supervisorID = roles[0].id
        let nonSupervisorRoles = roles.filter { $0.id != supervisorID }
        let invitableRoles = Set(nonSupervisorRoles.map(\.id))

        // Auto-wire non-Supervisor roles to report to Supervisor — EXCEPT roles
        // configured for delegation (whitelist non-empty OR generated permission).
        // Those are peer-level with the human Supervisor by definition (only peer-
        // level roles may delegate; see `Team.roleIsTopLevelDelegator`). Skipping
        // the entry here is the single source of truth: delegation settings alone
        // decide peer status — no extra flag, no post-mutation. The toolset is
        // independent (delegation tools auto-inject from settings, not toolIDs).
        var reportsTo: [String: String] = [:]
        for role in nonSupervisorRoles where !role.hasDelegationConfigured {
            reportsTo[role.id] = supervisorID
        }

        return TeamSettings(
            hierarchy: TeamHierarchy(reportsTo: reportsTo),
            meetingCoordinatorRoleID: roles[coordinatorIndex].id,
            invitableRoles: invitableRoles,
            limits: limits,
            defaultAcceptanceMode: acceptanceMode,
            supervisorMode: supervisorMode
        )
    }
}
