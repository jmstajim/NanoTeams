import Foundation

// MARK: - Bundled Content Reconcile
//
// Version-bump-triggered pass that brings a work folder's stored teams / roles /
// prompt templates / tools back in line with the bundled definitions (team settings
// only additively — see the invariants below)
// shipped in the current app binary. Called from `migrateIfNeeded` whenever
// `AppVersion.current > state.lastAppliedAppVersion`.
//
// Design invariants:
//  * Scalar fields of system roles (`prompt`, `meetingGuidance`, `toolIDs`, `dependencies`,
//    `icon`, `iconColor`, `iconBackground`, `usePlanningPhase`) are overwritten
//    unconditionally. User customizations to system-role fields are a known
//    trade-off, documented in the plan — inline apply without preview.
//  * Team settings are the user's after first creation: a bump never rewrites a value
//    the Team Settings editor can change (limits, acceptance mode and checkpoints, Ask
//    Supervisor mode, the meetings switch, the coordinator, invitable roles, the
//    hierarchy). The bundle contributes STRUCTURE only — a re-added system role's
//    `reportsTo` edge and its `invitableRoles` membership when the stored set is
//    explicit (empty means "everyone" and is left alone) — and step 5 heals a
//    coordinator that names nobody. A changed bundled default (a new limit, another
//    acceptance mode) therefore reaches only a team created afresh from the template.
//    Until 2026-09-06 a bump reset every setting; until 2026-09-07 all but three, so a
//    user's limits and acceptance choices were lost on every update.
//  * Structural changes are **additive for the USER's entries**: missing system roles and
//    missing system artifacts are added, and nothing the user authored is ever removed.
//    The one exception is a system role the BUNDLE itself retired
//    (`SystemTemplates.retiredSystemRoleIDs`, step 4a): leaving it beside its replacement
//    is not conservatism but duplication — two planners both holding `ask_supervisor`, two
//    engineers both writing to one tree. The invariant protects user data; it was never a
//    promise that a template cannot forget anything.
//  * Tombstones (`team.deletedSystemRoleIDs` / `team.deletedSystemArtifactIDs`)
//    suppress additive resurrection of roles/artifacts the user explicitly
//    removed via the editor.
//  * Teams whose roles are actively executing (any `roleStatus` in
//    `.working`/`.needsAcceptance`/`.revisionRequested`) are deferred so
//    mid-run changes to `role.toolIDs` can't break tool-call authorization — and so
//    is a team whose retirement (step 4a) would orphan a role an UNCLOSED task still
//    holds, in any status (`retiredRoleIDsInUse`): the banner names the task to close.
//    The watermark (`state.lastAppliedAppVersion`) ALWAYS advances — the
//    outstanding work is carried in `state.pendingReconcileTeamIDs` instead,
//    which `bootstrapIfNeeded` retries independently of the version compare.
//    Holding the watermark back would force a full `.allTemplated` pass (and a
//    fresh clobber of every other team's stored prompts) on every launch for as
//    long as one team stayed busy. The advancing site is
//    `NTMSRepository+Bootstrap.swift`'s version gate; the contract is pinned by
//    `NTMSRepositoryReconcileDeferralTests` ("watermark must not flap").

nonisolated extension NTMSRepository {

    struct BundledReconcileResult {
        /// True if any team was mutated (roles/templates/settings/structure).
        /// Caller writes `teams.json` iff this is `true`.
        var touched: Bool
        /// True if the bundled tool merge produced a change.
        /// Caller writes `tools.json` iff this is `true`.
        var toolsTouched: Bool
        /// What could not be applied, and why — for the user-facing banner and
        /// the pending-retry set. See `BundledUpdateReport`.
        var report: BundledUpdateReport

        /// Team IDs owed a scoped retry on the next open.
        var deferredTeamIDs: [NTMSID] { report.deferred.map(\.teamID) }
    }

    /// Apply all bundled-content updates to teams and tools.
    ///
    /// - Parameters:
    ///   - teams: inout — scalar fields, prompt templates and additive structure
    ///     (roles, artifacts, a re-added role's settings entries) are updated in
    ///     place; stored team settings are never rewritten.
    ///   - tools: inout — merged with `ToolDefinitionRecord.defaultDefinitions()`.
    ///   - paths: used for the running-role scan (`internalTasksDir`).
    /// Which teams a pass is allowed to touch.
    enum ReconcileScope {
        /// A version bump: every templated team is re-applied.
        case allTemplated
        /// A retry of teams deferred by an earlier pass. Everything else already
        /// reconciled at this app version and must not be rewritten again.
        case only(Set<NTMSID>)

        func includes(_ team: Team) -> Bool {
            switch self {
            case .allTemplated: return true
            case .only(let ids): return ids.contains(team.id)
            }
        }

        var isFullPass: Bool {
            if case .allTemplated = self { return true }
            return false
        }
    }

    func applyBundledContentUpdates(
        teams: inout [Team],
        tools: inout [ToolDefinitionRecord],
        tasksIndex: TasksIndex,
        activeTeamID: NTMSID?,
        scope: ReconcileScope = .allTemplated,
        paths: NTMSPaths
    ) -> BundledReconcileResult {
        var touched = false
        var deferred: [BundledUpdateReport.DeferredTeam] = []

        /// Resolves the scan's role IDs to display names using the team's own
        /// roster, and folds several blocking tasks into one reportable entry.
        func makeDeferredTeam(
            team: Team,
            evidence: [RunningRoleEvidence]
        ) -> BundledUpdateReport.DeferredTeam {
            let nameByRoleID = Dictionary(
                team.roles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }
            )
            var seen = Set<String>()
            let roleNames = evidence
                .flatMap(\.roleIDs)
                .compactMap { nameByRoleID[$0] }
                .filter { seen.insert($0).inserted }
            // The retirement reason outranks "busy" in the copy: a busy task resolves
            // itself, a task holding a retired role needs the user to close it. One pass:
            // the first entry and the distinct-task count are kept per reason, and the
            // retirement's pair wins when it exists.
            var firstAny: RunningRoleEvidence?
            var firstRetirement: RunningRoleEvidence?
            var anyTasks = Set<Int>()
            var retirementTasks = Set<Int>()
            for item in evidence {
                if firstAny == nil { firstAny = item }
                anyTasks.insert(item.taskID)
                if item.reason == .retiredRoleInUnclosedTask {
                    if firstRetirement == nil { firstRetirement = item }
                    retirementTasks.insert(item.taskID)
                }
            }
            let first = firstRetirement ?? firstAny
            let blockingTaskCount = firstRetirement == nil ? anyTasks.count : retirementTasks.count
            return BundledUpdateReport.DeferredTeam(
                teamID: team.id,
                teamName: team.name,
                roleNames: roleNames,
                taskID: first?.taskID ?? -1,
                taskTitle: first?.taskTitle ?? "",
                otherBlockingTaskCount: max(0, blockingTaskCount - 1),
                reason: firstRetirement == nil ? .busy : .retiredRoleInUnclosedTask
            )
        }

        // 0. Tools — merged BEFORE the running-role scan, so a scan that can't
        //    complete no longer blocks it. `mergeWithDefaults` is additive and
        //    normalizing: it never REMOVES a tool, so it cannot revoke anything a
        //    live tool loop is currently authorized to call, which is the only
        //    thing deferral protects. Blocking it on the scan just meant a single
        //    unreadable task.json also froze the built-in tool definitions.
        //
        //    Skipped on a scoped retry: the merge is version-keyed and already
        //    ran on the pass that deferred these teams.
        var toolsTouched = false
        if scope.isFullPass {
            let merged = ToolDefinitionRecord.mergeWithDefaults(existing: tools)
            if merged != tools {
                tools = merged
                toolsTouched = true
            }
        }

        // Index bundled defaults by templateID once. Hoisted above the scan so
        // the fail-closed arm below can tell a team that HAS a bundled
        // counterpart from one whose template this build no longer ships —
        // reporting the latter as "deferred" would name a team reconcile would
        // never have touched anyway.
        var bundledByTemplateID: [String: Team] = [:]
        for t in Team.defaultTeams {
            if let tid = t.templateID { bundledByTemplateID[tid] = t }
        }
        // The Autovisor team is bundled but hidden (not in `Team.defaultTeams`) —
        // index it explicitly so its manager role's prompt reconciles on version
        // bumps like every other system role. Without this, prompt improvements
        // never reach work folders whose Autovisor team was seeded by an older build.
        bundledByTemplateID[AutovisorConstants.teamTemplateID] = TeamTemplateFactory.autovisor()

        /// Teams the reconcile could actually act on — the only ones worth
        /// deferring or reporting.
        func isReconcilable(_ team: Team) -> Bool {
            guard !team.isGeneratedPlaceholder, let tid = team.templateID else { return false }
            return bundledByTemplateID[tid] != nil || SystemTemplates.templateConfigs[tid] != nil
        }

        // Fail-closed: if the running-role scan can't complete, treat every
        // reconcilable team as busy. An I/O failure tells us nothing about
        // whether a role is live, and changing `role.toolIDs` under a live tool
        // loop silently breaks tool authorization.
        //
        // Modelled as "everything is busy" rather than an early return so the
        // single deferral branch below — including its Autovisor carve-out — is
        // shared by both arms. An early return here duplicated that carve-out,
        // and the duplicate skipped the Autovisor from the DEFERRED list without
        // actually reconciling it, so its prompt silently never updated.
        let evidenceByTeam: [NTMSID: [RunningRoleEvidence]]
        var scanFailure: BundledUpdateReport.ScanFailure?
        switch scanRunningTeamRoles(
            tasksIndex: tasksIndex, teams: teams, activeTeamID: activeTeamID, paths: paths
        ) {
        case .clean(let map):
            evidenceByTeam = map
        case .inconclusive(let taskID, let relativePath, let reason):
            evidenceByTeam = Dictionary(
                teams.filter { isReconcilable($0) }.map { ($0.id, []) },
                uniquingKeysWith: { first, _ in first }
            )
            scanFailure = .taskFileUnreadable(
                taskID: taskID, relativePath: relativePath, reason: reason
            )
        }

        for i in teams.indices {
            guard !teams[i].isGeneratedPlaceholder, let tid = teams[i].templateID else { continue }
            guard scope.includes(teams[i]) else { continue }

            if let evidence = evidenceByTeam[teams[i].id] {
                // The Autovisor manager parks at `.needsSupervisorInput` at the
                // end of every review pass while its role status stays `.working`,
                // so an enabled Autovisor would defer reconcile — and hold the
                // watermark — on EVERY open, and bundled updates would never land.
                // Deferral exists to protect `role.toolIDs` under a live tool
                // loop, and the autovisor branch below never rewrites toolIDs, so
                // reconciling this team is safe: the refreshed prompt/template
                // are only read at the next pass start.
                if tid != AutovisorConstants.teamTemplateID {
                    // Only report a team the reconcile could actually have acted
                    // on. A stored `templateID` this build no longer ships has no
                    // bundled counterpart, so steps 1/3/4 would skip it anyway —
                    // naming it as "deferred" would blame a team that was never
                    // going to change, and (with the pending set) keep the retry
                    // gate open forever for nothing.
                    if isReconcilable(teams[i]) {
                        deferred.append(
                            makeDeferredTeam(team: teams[i], evidence: evidence)
                        )
                    }
                    continue
                }
            }

            var teamChanged = false

            // 1. System roles — scalar field overwrite.
            //
            // Uses per-team bundled values (`Team.defaultTeams`), not the
            // generic `SystemTemplates.roles`: FAANG's Supervisor requires
            // "Release Notes" while the generic template is empty, and
            // Engineering's TechLead must not pick up PM-dependent artifacts
            // since PM isn't in the team.
            let bundledRolesBySystemID: [String: TeamRoleDefinition]? = bundledByTemplateID[tid]
                .map { Dictionary(uniqueKeysWithValues: $0.roles.compactMap { r in
                    r.systemRoleID.map { ($0, r) }
                }) }
            for r in teams[i].roles.indices where teams[i].roles[r].isSystemRole {
                guard let systemID = teams[i].roles[r].systemRoleID,
                      let bundled = bundledRolesBySystemID?[systemID]
                else { continue }

                let role = teams[i].roles[r]
                let nextPrompt = bundled.prompt
                let nextMeetingGuidance = bundled.meetingGuidance
                // The Autovisor manager's tool policy is owned by
                // `syncAutovisorTeamToTemplate` (runs on every open): it union-enforces the
                // mandatory tools, preserves the user's choices among the allowed-optional
                // tools, and strips any tool outside the allowed set (mandatory ∪ optional).
                // The reconcile therefore does NOT overwrite the manager's toolIDs — but it
                // IS the delivery path for optional-tool GROUPS newly bundled in this app
                // version (e.g. computer-use): a group entirely absent from the stored
                // toolset predates its introduction and is added whole; a partially-present
                // group means the user has seen it and pruned — their per-tool toggles are
                // preserved (pinned by `testVersionBump_..._preservingToolToggles`).
                let nextToolIDs: [String]
                if tid == AutovisorConstants.teamTemplateID {
                    let stored = Set(role.toolIDs)
                    let bundledSet = Set(bundled.toolIDs)
                    var toolIDs = role.toolIDs
                    for group in AutovisorConstants.managerOptionalToolGroups
                        where stored.isDisjoint(with: group) {
                        toolIDs.append(contentsOf: group.filter { bundledSet.contains($0) })
                    }
                    nextToolIDs = toolIDs
                } else {
                    nextToolIDs = bundled.toolIDs
                }
                let nextDeps = bundled.dependencies
                let nextIcon = bundled.icon
                let nextIconColor = bundled.iconColor
                let nextIconBG = bundled.iconBackground
                // Template-owned like the prompt and the toolset. The phase used
                // to be a single `update_scratchpad` call and was on for every
                // role; it is now a multi-turn read-and-plan stretch that only
                // the Software Engineer gets. Without this line a folder created
                // before that change keeps `usePlanningPhase: true` on all eight
                // FAANG roles and pays the phase everywhere. CUSTOM roles are
                // untouched (the loop is `isSystemRole`-gated), so a user's own
                // choice survives — which is also why the decoder's legacy-key
                // fallback in `TeamRoleDefinition` still matters.
                let nextUsesPlanning = bundled.usePlanningPhase

                let changed = role.prompt != nextPrompt
                    || role.meetingGuidance != nextMeetingGuidance
                    || role.toolIDs != nextToolIDs
                    || role.dependencies != nextDeps
                    || role.icon != nextIcon
                    || role.iconColor != nextIconColor
                    || role.iconBackground != nextIconBG
                    || role.usePlanningPhase != nextUsesPlanning

                if changed {
                    teams[i].roles[r].prompt = nextPrompt
                    teams[i].roles[r].meetingGuidance = nextMeetingGuidance
                    teams[i].roles[r].toolIDs = nextToolIDs
                    teams[i].roles[r].dependencies = nextDeps
                    teams[i].roles[r].icon = nextIcon
                    teams[i].roles[r].iconColor = nextIconColor
                    teams[i].roles[r].iconBackground = nextIconBG
                    teams[i].roles[r].usePlanningPhase = nextUsesPlanning
                    teams[i].roles[r].updatedAt = MonotonicClock.shared.now()
                    teamChanged = true
                }
            }

            // 2. Prompt templates (system/consultation/meeting).
            if let cfg = SystemTemplates.templateConfigs[tid] {
                if teams[i].systemPromptTemplate != cfg.system {
                    teams[i].systemPromptTemplate = cfg.system
                    teamChanged = true
                }
                if teams[i].consultationPromptTemplate != cfg.consultation {
                    teams[i].consultationPromptTemplate = cfg.consultation
                    teamChanged = true
                }
                if teams[i].meetingPromptTemplate != cfg.meeting {
                    teams[i].meetingPromptTemplate = cfg.meeting
                    teamChanged = true
                }
            }

            // 3. Team settings are NOT rewritten — they are the user's (see the header).
            //    The only settings writes below are additive, for a role step 4 re-adds.

            // 4. Team structure — additive: add missing system roles/artifacts,
            //    never remove stored entries the user may be using. Respects
            //    tombstones.
            if let bundledTeam = bundledByTemplateID[tid] {
                // 4a. Retire system roles the BUNDLE dropped. Runs before the additive pass,
                //     so a renamed role is replaced rather than doubled. `Team.removeRole`
                //     clears `reportsTo`, `invitableRoles` and `graphLayout` with it, and the
                //     orphan-artifact prune below then takes the artifacts that lose their
                //     only producer.
                let retiredIDs = teams[i].roles
                    .filter { $0.systemRoleID.map(SystemTemplates.retiredSystemRoleIDs.contains) == true }
                    .map(\.id)
                // Whether the chair is about to be deleted — read BEFORE the removals, because
                // `removeRole` heals the coordinator itself and the healed value would hide the
                // answer. `defaultCoordinatorID` picks the first non-Supervisor role in STORED
                // order, and the additive pass below appends new roles at the END — so on a
                // stored Ultra Team the heal lands on the Solution Architect, a role that IS a
                // repair target, which is the seat `coordinatorIndex: 1` exists to keep clear.
                // The carry-over itself has to wait until the replacement role EXISTS, so it
                // runs after the additive pass.
                let chairWasRetired = teams[i].settings.meetingCoordinatorRoleID
                    .flatMap { id in teams[i].roles.first { $0.id == id } }
                    .flatMap(\.systemRoleID)
                    .map(SystemTemplates.retiredSystemRoleIDs.contains) == true
                if !retiredIDs.isEmpty {
                    // `retireSystemRole`, not `removeRole`: no tombstone. The tombstone is the
                    // USER's mark, and this is the bundle's decision.
                    for roleID in retiredIDs { teams[i].retireSystemRole(roleID) }
                    teamChanged = true
                }

                let storedSystemRoleIDs = Set(teams[i].roles.compactMap(\.systemRoleID))
                let tombstonedRoles = Set(teams[i].deletedSystemRoleIDs)

                for bundledRole in bundledTeam.roles where bundledRole.isSystemRole {
                    guard let sid = bundledRole.systemRoleID else { continue }
                    if storedSystemRoleIDs.contains(sid) { continue }
                    if tombstonedRoles.contains(sid) { continue }
                    teams[i].roles.append(bundledRole)
                    if let supervisorID = bundledTeam.settings.hierarchy.reportsTo[bundledRole.id] {
                        teams[i].settings.hierarchy.reportsTo[bundledRole.id] = supervisorID
                    }
                    // `Team.removeRole` drops a role from `invitableRoles`, so a role that
                    // comes back must be re-admitted to an EXPLICIT list — otherwise it
                    // returns silently un-invitable. An empty list means "everyone" and
                    // must stay empty. The Supervisor is never in the list (it is not a
                    // meeting participant), even if a hand-edited file lost its row.
                    if !bundledRole.isSupervisor, !teams[i].settings.invitableRoles.isEmpty {
                        teams[i].settings.invitableRoles.insert(bundledRole.id)
                    }
                    teamChanged = true
                }

                let tombstonedArtifacts = Set(teams[i].deletedSystemArtifactIDs)
                for bundledArt in bundledTeam.artifacts where bundledArt.isSystemArtifact {
                    if tombstonedArtifacts.contains(bundledArt.id) { continue }
                    guard let a = teams[i].artifacts.firstIndex(where: { $0.id == bundledArt.id })
                    else {
                        teams[i].artifacts.append(bundledArt)
                        teamChanged = true
                        continue
                    }
                    // REFRESH, not merely add. A system artifact's `description` is SHIPPED
                    // CONTENT: `PromptBuilder+TeamContext` puts it on the wire beside the role's
                    // prompt, so the two are one contract for one deliverable and an edit to
                    // either half must reach a stored folder. Until 2026-09-12 this loop skipped
                    // every artifact it already had, so a description edit reached NO existing
                    // work folder at any version — the prompt half moved (step 1 rewrites it) and
                    // the description half stayed, which is worse than neither moving. Same
                    // ownership rule as step 1: `isSystemArtifact`-gated, so a user's own
                    // artifacts are untouched, and a user's edit to a SYSTEM one survives until
                    // the next app upgrade exactly as their edit to a system prompt does.
                    // `id` is `Artifact.slugify(name)`, so a renamed artifact is a different id
                    // and arrives through the append branch above; the old one is taken by
                    // `pruneOrphanSystemArtifacts` below.
                    let stored = teams[i].artifacts[a]
                    if stored.name != bundledArt.name
                        || stored.icon != bundledArt.icon
                        || stored.mimeType != bundledArt.mimeType
                        || stored.description != bundledArt.description
                        || stored.isSystemArtifact != bundledArt.isSystemArtifact
                    {
                        teams[i].artifacts[a] = bundledArt
                        teamChanged = true
                    }
                }

                // 4b. The chair the bundle chose, now that its role exists. Inside the one
                //     settings write reconciliation already allows for the coordinator
                //     (step 5), and narrower: it fires only when the stored chair was a role
                //     the BUNDLE retired.
                if chairWasRetired,
                   let bundledChairSystemID = bundledTeam.settings.meetingCoordinatorRoleID
                   .flatMap({ id in bundledTeam.roles.first { $0.id == id } })
                   .flatMap(\.systemRoleID),
                   let stored = teams[i].roles.first(where: { $0.systemRoleID == bundledChairSystemID }),
                   teams[i].settings.meetingCoordinatorRoleID != stored.id
                {
                    teams[i].settings.meetingCoordinatorRoleID = stored.id
                    teamChanged = true
                }

                // Prune orphan system artifacts — see helper for safety
                // contract. Without this, a bundled rename ("Code Review" →
                // "Code Review Summary") leaves the legacy artifact in the
                // team editor's list as a selectable but unproduced ghost.
                if Self.pruneOrphanSystemArtifacts(in: &teams[i], bundled: bundledTeam) {
                    teamChanged = true
                }

                // Refresh layout — keeps user-dragged positions for existing
                // nodes, auto-positions any newly-added role.
                let nextLayout = TeamGraphLayoutCalculator.mergeLayout(
                    existing: teams[i].graphLayout,
                    roles: teams[i].roles
                )
                if nextLayout != teams[i].graphLayout {
                    teams[i].graphLayout = nextLayout
                    teamChanged = true
                }
            }

            // 5. The coordinator must name a live role after step 4 moved the roster
            //    (a coordinator the user deleted heals to the default rule; there is
            //    no "Auto"). The one settings field a bump may still change.
            if teams[i].healMeetingCoordinator() {
                teamChanged = true
            }

            if teamChanged {
                teams[i].updatedAt = MonotonicClock.shared.now()
                touched = true
            }
        }

        return BundledReconcileResult(
            touched: touched,
            toolsTouched: toolsTouched,
            report: BundledUpdateReport(scanFailure: scanFailure, deferred: deferred)
        )
    }

    // MARK: - Orphan system artifact prune

    /// Removes system artifacts (`isSystemArtifact == true`) whose name is no
    /// longer in the bundled team AND that no role / setting references.
    /// Custom (`isSystemArtifact == false`) artifacts and any artifact still
    /// referenced by a role's dependencies or by `supervisorRequiredArtifacts`
    /// are preserved. Returns `true` iff at least one artifact was removed.
    ///
    /// Safety: this runs AFTER the role-dependency reconcile (step 1) inside
    /// `applyBundledContentUpdates`, so the reference scan reflects
    /// post-reconcile dependencies — orphans here are truly dead. Custom roles
    /// the user added that still depend on the legacy name are protected via
    /// the reference scan.
    static func pruneOrphanSystemArtifacts(in team: inout Team, bundled: Team) -> Bool {
        let bundledArtifactNames = Set(bundled.artifacts.map(\.name))
        // `supervisorRequiredArtifacts` is a computed property on `Team`
        // (derived from the Supervisor role's `requiredArtifacts`). The role
        // loop below already covers it via `dependencies.requiredArtifacts`,
        // but reading it explicitly here documents the intent.
        var referencedNames = Set(team.supervisorRequiredArtifacts)
        for r in team.roles {
            referencedNames.formUnion(r.dependencies.requiredArtifacts)
            referencedNames.formUnion(r.dependencies.producesArtifacts)
        }
        let prePruneCount = team.artifacts.count
        team.artifacts.removeAll { art in
            art.isSystemArtifact
                && !bundledArtifactNames.contains(art.name)
                && !referencedNames.contains(art.name)
        }
        return team.artifacts.count != prePruneCount
    }

    // MARK: - Running-role scan

    /// One task that pins a team as busy, with enough detail for the user-facing
    /// message. `roleIDs` (not names) because the scan has no roster — the
    /// reconcile loop, which does, resolves them (GRASP Information Expert).
    struct RunningRoleEvidence: Hashable {
        let taskID: Int
        let taskTitle: String
        let roleIDs: [String]
        var reason: BundledUpdateReport.DeferralReason = .busy
    }

    /// The retired roles (`SystemTemplates.retiredSystemRoleIDs`) an UNCLOSED task's last
    /// run still references — by a step or by a role status, in any status at all.
    ///
    /// A second reason to defer a team, beside `busyRoleIDs`, and deliberately not a
    /// widening of it: that predicate is "a live tool loop", pinned narrow so a paused or
    /// finished task can never freeze its team's prompts. This one is "step 4a would delete
    /// a role this task still holds", and the harm is different in kind. Retiring the
    /// definition under a task leaves its steps orphaned: a `.paused` step of a role no
    /// longer on the roster pins the derived status at Paused with nothing to resume
    /// (`parkedRoleIDs` restarts `.working` roles only, and status recovery demotes the
    /// parked one to `.idle`), and a `.done` step's ARTIFACTS stay in the run's produced
    /// pool — `computeProducedArtifactNames` reads every `.done` step regardless of
    /// roster — so the retired engineer's "Implementation Notes" makes the new Diff
    /// Reviewer ready in wave 1, on notes the new engineer never wrote, and
    /// `hasBlockingUpstream` cannot see it because the roster's producer of that artifact
    /// is a role with no status. The only sanctioned cleanup for a roster change under a
    /// task destroys the run (`switchTeam`); deferring until the task is closed destroys
    /// nothing and names the task.
    nonisolated static func retiredRoleIDsInUse(
        _ task: NTMSTask, retiredRoleIDs: Set<String>
    ) -> [String] {
        guard !retiredRoleIDs.isEmpty, task.closedAt == nil, let run = task.runs.last else {
            return []
        }
        var referenced = Set(run.steps.map(\.effectiveRoleID))
        referenced.formUnion(run.roleStatuses.keys)
        return referenced.intersection(retiredRoleIDs).sorted()
    }

    enum RunningTeamsScanResult {
        /// Scan completed cleanly. Empty map means "no active roles anywhere".
        case clean([NTMSID: [RunningRoleEvidence]])
        /// Scan could not complete because a task file could not be READ. Caller
        /// must fail-closed and defer — reconcile must not overwrite
        /// `role.toolIDs` while we cannot prove the role is idle.
        ///
        /// Carries the offending task and the reason so the caller can tell the
        /// user which file to repair; a bare case left this as a `print` nobody
        /// ever sees, and the resulting block is permanent.
        case inconclusive(taskID: Int, relativePath: String, reason: String)
    }

    /// Does this task hold a role that could be running a LIVE tool loop right now?
    ///
    /// True only for a `.working` role whose step is `.running` or
    /// `.needsSupervisorInput`.
    ///
    /// ## Why exactly this set — the self-heal contract
    ///
    /// Deferral is only ever meant to be temporary; the banner promises "will
    /// retry on next open". That promise holds only if something HEALS the
    /// status, and the healers are `openWorkFolder` (active task only) and
    /// `recoverStaleStatusesAcrossIndex`, which filters on the *derived summary*
    /// status being `.running` / `.needsSupervisorInput`.
    ///
    /// This set is exactly what `StatusRecoveryService` parks — step → `.paused`,
    /// role → `.idle` — which is exactly the set whose derived summary status is
    /// sweepable. Widening it breaks the promise and turns a deferral into a
    /// PERMANENT freeze:
    ///
    ///  * `.working` + `.paused` step derives `.paused`, which the sweep skips —
    ///    and `pauseRun` leaves precisely that pair behind, since it moves steps
    ///    to `.paused` and never touches `roleStatuses`.
    ///  * `.needsAcceptance` / `.revisionRequested` are `.noAction` in
    ///    `RoleStepReconciler` (live Supervisor gates), so recovery will never
    ///    heal them at all. Neither holds a tool loop: the first has a terminal
    ///    step, the second is re-run only after the folder is open.
    ///  * A `.pending` or absent step has not started, so it builds a fresh
    ///    schema from whatever `toolIDs` says when it does. Counting it busy is
    ///    also unsafe: paired with a `.paused` sibling the task derives `.paused`
    ///    and drops out of the sweep.
    ///
    /// `ReconcileDeferralEquivalenceTests` pins the subset relation directly, so
    /// a future widening fails loudly instead of silently freezing a folder.
    ///
    /// Only `runs.last` is examined. Earlier runs legitimately retain
    /// `.needsAcceptance` / `.revisionRequested` forever (`StatusRecoveryService`
    /// collapses historical `.needsAcceptance` to `.done` but never revisits the
    /// rest), so scanning them would MANUFACTURE permanent deferrals.
    nonisolated static func pinsTeamAsBusy(_ task: NTMSTask) -> Bool {
        !busyRoleIDs(task).isEmpty
    }

    /// The roles making `pinsTeamAsBusy` true, sorted for a stable message.
    /// Empty ⟺ the task does not pin its team.
    nonisolated static func busyRoleIDs(_ task: NTMSTask) -> [String] {
        // A closed task cannot be executing: `closeTask` is the only writer of
        // `closedAt`, `resumeRun` refuses to revive a closed task, and
        // `createNewRun` / `restartRole` clear it before anything goes live.
        // This also covers legacy files closed by a build whose close pass only
        // finalized `.needsAcceptance`, which strand a `.working` role behind
        // `closedAt` where nothing ever sweeps it.
        guard task.closedAt == nil else { return [] }
        guard let run = task.runs.last else { return [] }

        let stepByRole = run.stepsByRoleBaseID()
        return run.roleStatuses.compactMap { roleID, status -> String? in
            guard status == .working else { return nil }
            switch stepByRole[roleID]?.status {
            case .running, .needsSupervisorInput: return roleID
            default: return nil
            }
        }
        // `roleStatuses` is a Dictionary, so iteration order varies per process.
        // Sorting keeps the banner text stable across launches.
        .sorted()
    }

    /// Identifies team IDs that have at least one role holding a live tool loop
    /// (see `pinsTeamAsBusy` for the predicate and why it is this narrow).
    ///
    /// The index is passed IN rather than read here: `openOrCreateWorkFolder`
    /// loads it through `loadOrRecoverFile`, which backs up and resets a corrupt
    /// `tasks_index.json`. Reading it independently (as this used to) meant a
    /// corrupt index poisoned the whole pass for one open even though the very
    /// same open was about to recover it three lines later.
    func scanRunningTeamRoles(
        tasksIndex: TasksIndex,
        teams: [Team],
        activeTeamID: NTMSID?,
        paths: NTMSPaths
    ) -> RunningTeamsScanResult {
        let teamsByID = Dictionary(teams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Mirror `WorkFolderProjection.activeTeam`: a stored id that no longer
        // resolves falls back to the first team, so resolving against the raw
        // stored id would disagree with what the app actually runs.
        let effectiveActiveTeam = activeTeamID.flatMap { teamsByID[$0] } ?? teams.first

        var running: [NTMSID: [RunningRoleEvidence]] = [:]
        // One hop map for the whole sweep — per-entry `ancestorIDs(of:)` would
        // rebuild it per row, making this loop O(tasks²).
        let links = tasksIndex.parentLinks()
        for entry in tasksIndex.tasks {
            let ancestors = tasksIndex.ancestorIDs(of: entry.id, links: links)
            let taskURL = paths.taskJSON(taskID: entry.id, ancestors: ancestors)
            guard fileManager.fileExists(atPath: taskURL.path) else { continue }
            let task: NTMSTask
            do {
                task = try store.read(NTMSTask.self, from: taskURL)
            } catch let error as DecodingError {
                // Fail OPEN for this one task. A task.json that won't DECODE
                // cannot be executing: `loadTask` uses this same `store.read`,
                // `ensureTaskLoaded` surfaces the error and returns false, and
                // both `createNewRun` and `resumeRun` bail on
                // `guard let task = loadedTask(taskID)`. So no role inside it can
                // hold a live tool loop — it cannot be what deferral protects.
                //
                // Nothing ever auto-recovers an individual task.json (unlike the
                // index), so poisoning the whole pass for it froze bundled
                // updates for EVERY team in the folder, permanently.
                print("[NTMSRepository] WARNING: task \(entry.id) task.json is undecodable — "
                    + "skipping it in the reconcile scan (it cannot be running): \(error)")
                continue
            } catch {
                // An I/O error (permissions, unmounted volume, transient read)
                // says NOTHING about the file's contents — the task may be fine
                // and running. Stay fail-closed.
                print("[NTMSRepository] WARNING: task.json for task \(entry.id) "
                    + "unreadable during reconcile scan — deferring team updates (\(error))")
                return .inconclusive(
                    taskID: entry.id,
                    relativePath: paths.relativePathFromProjectRoot(for: taskURL),
                    reason: error.localizedDescription
                )
            }
            // Same order the engine, the LLM services and the deletion guard use.
            guard let teamID = TeamResolution.resolveTeamID(
                task: task,
                teamProvider: { teamsByID[$0] },
                activeTeam: effectiveActiveTeam
            ) else { continue }

            let busyRoleIDs = Self.busyRoleIDs(task)
            if !busyRoleIDs.isEmpty {
                running[teamID, default: []].append(
                    RunningRoleEvidence(
                        taskID: task.id, taskTitle: task.title, roleIDs: busyRoleIDs
                    )
                )
            }
            // The second reason, evaluated against the team as STORED — the retired
            // definitions are still on its roster at scan time, which is what makes them
            // resolvable to ids here.
            let retiredIDs = Set(
                (teamsByID[teamID]?.roles ?? [])
                    .filter { $0.systemRoleID.map(SystemTemplates.retiredSystemRoleIDs.contains) == true }
                    .map(\.id))
            let retiredInUse = Self.retiredRoleIDsInUse(task, retiredRoleIDs: retiredIDs)
            if !retiredInUse.isEmpty {
                running[teamID, default: []].append(
                    RunningRoleEvidence(
                        taskID: task.id, taskTitle: task.title, roleIDs: retiredInUse,
                        reason: .retiredRoleInUnclosedTask
                    )
                )
            }
        }

        return .clean(running)
    }

    // MARK: - Generated-placeholder chat mode

    /// Self-healing migration for the Generated Team placeholder's vacuous chat mode.
    ///
    /// Until `Team.seedChatModeForNewTask` existed, `createTask` seeded
    /// `NTMSTask.storedIsChatMode` from `team.isChatMode`, which is trivially `true` for
    /// the roleless placeholder. `storedIsChatMode` has no failure-path writer, so any
    /// generated task whose generation failed, was cancelled, or never ran carries that
    /// lie forever — reporting `chat_mode: true` to the Autovisor (whose role prompt
    /// answers that with `control_task close`), masking `.needsSupervisorAcceptance`
    /// behind `.running`, and routing `manage_role accept` to `.finishChatRole` on a real
    /// build role.
    ///
    /// Heals BOTH surfaces in one pass — `task.json` (what every later load reads) and the
    /// `tasks_index.json` entry (what `list_tasks` reads for tasks nobody opens). The
    /// stale-status sweep is NOT a usable seam for this: it only visits `.running` /
    /// `.needsSupervisorInput` entries, and a failed generation derives `.failed` while a
    /// cancelled one derives `.paused`. Writing only the index would be worse than nothing
    /// — `updateTaskOnly` recomputes the row from `toSummary()`, so the first later
    /// `mutateTask` would restore the lie.
    ///
    /// NARROW by construction: it only ever turns `true` into `false`, and only when the
    /// task's effective team IS the placeholder. It deliberately does NOT re-sync
    /// `storedIsChatMode` against the team in general — chat mode is snapshotted at
    /// creation and re-synced only by `adoptGeneratedTeam` and `switchTeam`, and
    /// broadening it here would flip acceptance semantics under a task whose team was
    /// merely edited.
    ///
    /// Team identity comes from `TeamResolution.resolveTeamID` — the same order the
    /// engine, the LLM services and the deletion guard use. Its first rung short-circuits
    /// on `generatedTeam`, so an adopted task can never be touched.
    ///
    /// Fail-open per task, matching `scanRunningTeamRoles`: an undecodable or unwritable
    /// `task.json` is skipped WITHOUT marking its index entry healed, so the two never
    /// diverge and the next open retries.
    ///
    /// Idempotent — after one healing open, the candidate filter matches nothing.
    ///
    /// - Returns: `true` iff `tasksIndex` was mutated, so the caller knows to write it.
    func normalizeGeneratedPlaceholderChatMode(
        tasksIndex: inout TasksIndex,
        teams: [Team],
        activeTeamID: NTMSID?,
        paths: NTMSPaths
    ) -> Bool {
        let placeholderIDs = Set(teams.filter(\.isGeneratedPlaceholder).map(\.id))
        let teamsByID = Dictionary(teams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Mirror `WorkFolderProjection.activeTeam` exactly as `scanRunningTeamRoles` does:
        // a stored id that no longer resolves falls back to the first team, so resolving
        // against the raw stored id would disagree with what the app actually runs.
        let effectiveActiveTeam = activeTeamID.flatMap { teamsByID[$0] } ?? teams.first

        // Index-decisive candidacy (tri-state, CLAUDE.md #91): `.decidedClear`
        // rows cost no I/O at all; `.unknown` rows (written before the mirrored
        // fields existed) pay ONE read and are converged below, so they decide
        // from the index on every later open.
        let resolvableTeamIDs = Set(teamsByID.keys)
        let activeTeamIsPlaceholder = effectiveActiveTeam.map { placeholderIDs.contains($0.id) } ?? false
        // Snapshot the indices first so the loop never mutates the array it iterates.
        let candidates = tasksIndex.tasks.indices.filter {
            tasksIndex.tasks[$0].placeholderChatCandidacy(
                placeholderTeamIDs: placeholderIDs,
                resolvableTeamIDs: resolvableTeamIDs,
                activeTeamIsPlaceholder: activeTeamIsPlaceholder
            ) != .decidedClear
        }
        guard !candidates.isEmpty else { return false }

        var changed = false
        // Same per-sweep hop map as `scanRunningTeamRoles` — see the comment there.
        let links = tasksIndex.parentLinks()
        for i in candidates {
            let entry = tasksIndex.tasks[i]
            let ancestors = tasksIndex.ancestorIDs(of: entry.id, links: links)
            let taskURL = paths.taskJSON(taskID: entry.id, ancestors: ancestors)
            guard fileManager.fileExists(atPath: taskURL.path) else { continue }

            let task: NTMSTask
            do {
                task = try store.read(NTMSTask.self, from: taskURL)
            } catch {
                // Fail OPEN, for BOTH decode and I/O failures — unlike the reconcile scan
                // there is nothing to protect by failing closed. Skipping leaves the entry
                // untouched, so the next open retries it.
                print("[NTMSRepository] WARNING: task \(entry.id) task.json unreadable — "
                    + "skipping the generated-placeholder chat-mode heal: \(error)")
                continue
            }

            guard task.isChatMode,
                  let resolved = TeamResolution.resolveTeamID(
                      task: task,
                      teamProvider: { teamsByID[$0] },
                      activeTeam: effectiveActiveTeam
                  ),
                  placeholderIDs.contains(resolved)
            else {
                // The read was PAID and the verdict is "not a candidate" — converge
                // the row so this task decides from the index on every later open
                // instead of re-paying the read forever (an `.unknown` legacy row
                // gains the mirrored fields here; a stale `.decidedCandidate` row
                // gains the facts that cleared it). Same expression `updateTaskOnly`
                // uses, so the surfaces can't drift.
                // The read was PAID and the verdict is "not a candidate" — converge
                // the row so this task decides from the index on every later open
                // instead of re-paying the read forever (an `.unknown` legacy row
                // gains the mirrored fields here; a stale `.decidedCandidate` row
                // gains the facts that cleared it). Same expression `updateTaskOnly`
                // uses, so the surfaces can't drift.
                var refreshed = task.toSummary()
                if !task.streamsHydrated {
                    // Raw read of a split task: its stream arrays are empty on
                    // disk, so the recomputed supervisor-wait facts would be a
                    // false NEGATIVE — and writing `false`/`0` over a true row
                    // wipes persisted seen-state (#91). Keep the row's answers.
                    //
                    // Which fields those are lives on `preserveSupervisorWaitFacts`, not
                    // spelled out at each of the two seams: the flag and the count are one
                    // fact in two shapes, and a seam that patched one would leave a row
                    // claiming "waiting" beside a count of zero.
                    //
                    // The list is per FIELD, not per row: `hasRolesAwaitingAcceptance`
                    // is deliberately absent because it reads `run.roleStatuses` and
                    // `step.effectiveRoleID`, which the split does not strip (it takes
                    // only the four per-step stream arrays), so it recomputes faithfully
                    // here. That is a property of what `splittingStreams` strips and can
                    // change, so it is pinned rather than trusted.
                    refreshed.preserveSupervisorWaitFacts(from: tasksIndex.tasks[i])
                }
                if tasksIndex.tasks[i] != refreshed {
                    tasksIndex.tasks[i] = refreshed
                    changed = true
                }
                continue
            }

            var healed = task
            healed.setStoredChatMode(false)
            do {
                try store.write(healed, to: taskURL)
            } catch {
                // Do NOT touch the index when the blob write failed — the two must never
                // disagree about which surface has been healed.
                print("[NTMSRepository] WARNING: could not rewrite task \(entry.id) task.json "
                    + "for the generated-placeholder chat-mode heal: \(error)")
                continue
            }
            // The same expression `updateTaskOnly` uses, so the two can't drift —
            // except the supervisor field on a raw-read split task (see the
            // convergence branch above for why `false` must not be recomputed).
            var refreshed = healed.toSummary()
            if !healed.streamsHydrated {
                refreshed.preserveSupervisorWaitFacts(from: tasksIndex.tasks[i])
            }
            tasksIndex.tasks[i] = refreshed
            changed = true
        }
        return changed
    }
}
