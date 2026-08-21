import Foundation

/// Which teams the Autovisor manager may create new tasks on, and whether it may assemble a
/// fresh one. The single authority behind `create_managed_task` — consulted by the schema
/// builder (`CreateManagedTaskTool.buildSchema`), by the runtime classifier, and by the
/// Settings card, so those three can never disagree about what is allowed.
///
/// **Block list, not allow list.** An empty `blockedTeamIDs` — the default and the shape every
/// existing `settings.json` decodes to — means every team is allowed, byte-identical to the
/// behaviour before this type existed. A team added to the folder later is therefore usable at
/// once, without the user revisiting Settings. Blocking everything is legal; the Settings card
/// warns rather than forbidding it.
///
/// **Creation only.** `control_task start` and `manage_role restart` re-run tasks that already
/// exist, and a started `Run` is pinned to its `teamID`, so neither consults this policy. The
/// Settings copy says "create new tasks on" for that reason.
nonisolated struct AutovisorTeamPolicy: Hashable, Sendable {

    /// Whether `team_id: "generated"` is a valid value.
    let allowGeneration: Bool

    /// Team ids the manager may NOT create tasks on — sorted and deduped.
    ///
    /// An ARRAY rather than a `Set` because `ProjectSettings` is `Hashable` and
    /// `mutateWorkFolder` diffs it structurally: `["a","b"]` and `["b","a"]` would compare
    /// unequal and rewrite `settings.json` on a no-op. (It is NOT for schema stability —
    /// `selectableTeams(from:)` filters `allTeams` and preserves ITS order, so no ordering
    /// here can change a byte of the rendered catalog.)
    ///
    /// Ids are **name-slug-scoped**: `NTMSID.from(name:)` is lossy, so "My Team", "my team"
    /// and "My-Team!" all collapse to `my_team` and share one entry.
    let blockedTeamIDs: [NTMSID]

    /// Membership set, derived once in `init` — `buildSchema` runs on every LLM iteration.
    /// Every stored property is `let` on purpose: a `var` array beside a cached set could be
    /// mutated out of step with it, and the synthesized `==` compares both.
    private let blocked: Set<NTMSID>

    init(blockedTeamIDs: [NTMSID] = [], allowGeneration: Bool = true) {
        self.blockedTeamIDs = Self.normalizedBlockList(blockedTeamIDs)
        self.allowGeneration = allowGeneration
        self.blocked = Set(self.blockedTeamIDs)
    }

    /// The ONE place the two persisted keys become a policy.
    init(settings: ProjectSettings) {
        self.init(blockedTeamIDs: settings.autovisorBlockedTeamIDs,
                  allowGeneration: settings.autovisorAllowTeamGeneration)
    }

    /// Every team allowed, generation on — the behaviour before this type existed, and the
    /// deliberate fallback for callers with no work folder (offline preview, renderer).
    static let unrestricted = AutovisorTeamPolicy()

    /// Trim → drop empties → dedupe → sort. Applied at BOTH persistence boundaries
    /// (`ProjectSettings.init(from:)` and the orchestrator setters) so a hand-edited
    /// `settings.json` self-heals and the stored array can never disagree with this type.
    static func normalizedBlockList(_ ids: [NTMSID]) -> [NTMSID] {
        Array(Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })).sorted()
    }

    // MARK: - Predicates

    /// USER POLICY only — "did the supervisor block this id?".
    ///
    /// Deliberately distinct from `allows(_:)`, which also excludes structurally hidden teams.
    /// The explicit-`team_id` arm must ask THIS question: the manager naming its own team id
    /// would otherwise be told the team is "blocked", announcing a decision the user never made
    /// (and confirming the hidden team's existence).
    func blocks(id: NTMSID) -> Bool { blocked.contains(id) }

    /// May the manager create a task on this team? Excludes infrastructure teams (its own, and
    /// the generated placeholder) as well as blocked ones.
    func allows(_ team: Team) -> Bool { !team.isHiddenFromPickers && !blocks(id: team.id) }

    /// The teams the catalog lists and the Settings card shows checked — one function so the
    /// two surfaces cannot drift. Preserves `allTeams` order.
    func selectableTeams(from allTeams: [Team]) -> [Team] { allTeams.filter(allows) }

    /// True when the manager has no existing team to create a task on.
    func hasNoSelectableTeam(in allTeams: [Team]) -> Bool { selectableTeams(from: allTeams).isEmpty }

    /// True when the manager can create a task at all — an existing team OR generation.
    func hasAnyUsableTarget(in allTeams: [Team]) -> Bool {
        allowGeneration || !hasNoSelectableTeam(in: allTeams)
    }

    /// True when blocking is what emptied the catalog (as opposed to a folder that simply has
    /// no non-infrastructure teams). Gates the empty-catalog note so prompt bytes stay
    /// byte-identical in the no-blocking case.
    func blockingNarrowedCatalog(in allTeams: [Team]) -> Bool {
        !blockedTeamIDs.isEmpty
            && allTeams.contains { !$0.isHiddenFromPickers && blocks(id: $0.id) }
    }

    /// Blocked ids with no surviving team — surfaced by the Settings card as dimmed, clearable
    /// rows. Deliberately NOT auto-pruned: pruning an ALLOW list is fail-closed, but pruning a
    /// BLOCK list is fail-OPEN, so a transient short `allTeams` (a corrupt-read re-bootstrap, a
    /// deferred reconcile) would silently restore a permission the supervisor revoked.
    func orphanBlockedTeamIDs(in allTeams: [Team]) -> [NTMSID] {
        let live = Set(allTeams.map(\.id))
        return blockedTeamIDs.filter { !live.contains($0) }
    }
}

// `nonisolated` again on the extension AND on the nested enum: neither inherits it from the
// struct under the app target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and the
// synthesized `Hashable` on a bare nested enum becomes main-actor-isolated — which makes
// `XCTAssertEqual(resolution, .teamBlocked("X"))` from a nonisolated `XCTestCase` fail to
// COMPILE. Same trap as `AcceptanceService.AcceptRoute`.
nonisolated extension AutovisorTeamPolicy {

    /// Outcome of classifying a `create_managed_task` `team_id`.
    nonisolated enum ManagedTeamResolution: Hashable {
        case useActiveTeam              // omitted/empty → the folder's active team
        case team(NTMSID)               // an existing, non-hidden, non-blocked team
        case generated                  // the `"generated"` sentinel
        case generationDisabled         // sentinel, but generation is off for this folder
        case teamBlocked(String)        // explicit id, real team, blocked          (name)
        case activeTeamBlocked(String)  // omitted, and the active team is blocked  (name)
        case activeTeamIsChat(String)   // omitted, and the active team is chat     (name)
        case activeTeamNotUsable        // omitted, and the active team is infrastructure
        case unknown(String)            // provided but unresolvable → must fail loudly
    }

    /// Resolves a `team_id` argument. Pure — `.generated` is materialised by the caller.
    ///
    /// Precedence, in this exact order:
    ///  1. **Omitted / empty** → the active-team branch. Within it, **blocked before chat**:
    ///     a block is explicit user policy, chat-mode is a heuristic about task shape, and
    ///     their remedies differ — telling the manager to "pass a pipeline team_id" for a
    ///     blocked chat team invites a retry that also fails.
    ///  2. **The `"generated"` sentinel** — an equality test kept ABOVE the catalog lookup so a
    ///     team literally named `generated` cannot shadow it (pre-existing behaviour).
    ///  3. **A known, non-hidden team** → blocked ? `.teamBlocked` : `.team`. The block test
    ///     lives HERE, after the existence check, never before it: a block entry can go stale
    ///     (the team was deleted while blocked), and testing it first would report a deleted id
    ///     as "blocked" instead of "unknown" — which is also what preserves the existing
    ///     `.unknown`-beats-`.generationDisabled` precedence for a bogus id.
    func classify(teamID raw: String?, allTeams: [Team], activeTeam: Team?) -> ManagedTeamResolution {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            guard let active = activeTeam else { return .useActiveTeam }
            // Omission means "use the default", not "pick anything". Every way the default can
            // be unusable fails loudly rather than silently creating the task somewhere the
            // supervisor did not sanction — otherwise the block list is one omitted argument
            // away from being bypassed.
            // HIDDEN first: infrastructure is not a user decision, so a blocked-AND-hidden
            // active team must not be reported as "blocked" — that would announce a decision
            // the UI cannot even express (hidden teams get no checkbox) and would put the
            // hidden team's NAME into a model-read message. Same reasoning as `blocks` vs
            // `allows` on the explicit-id arm, applied to the omit branch.
            if active.isHiddenFromPickers { return .activeTeamNotUsable }
            if blocks(id: active.id) { return .activeTeamBlocked(active.name) }
            if active.isChatMode { return .activeTeamIsChat(active.name) }
            return .useActiveTeam
        }
        if raw == DelegationConstants.generatedTeamSentinel {
            return allowGeneration ? .generated : .generationDisabled
        }
        guard let team = allTeams.first(where: { $0.id == raw }), !team.isHiddenFromPickers else {
            return .unknown(raw)
        }
        return blocks(id: team.id) ? .teamBlocked(team.name) : .team(team.id)
    }

    /// The model-read refusal for a failing resolution, or `nil` when the resolution succeeds.
    ///
    /// Lives here rather than in the orchestrator's dispatch so every one of these strings is a
    /// pure value surface the prompt-convention sweep can reach. Each remedy is DERIVED from
    /// the current state — the pre-existing messages advertised `'generated'` even with
    /// generation off, steered the model at `omit team_id` even when that path was closed, and
    /// pointed at "the catalog" even when the catalog was empty.
    func failureMessage(
        for resolution: ManagedTeamResolution,
        allTeams: [Team],
        omitPathIsViable: Bool
    ) -> String? {
        switch resolution {
        case .useActiveTeam, .team, .generated:
            return nil
        case .generationDisabled:
            return "Team generation is disabled for the Autovisor in this folder. " + remedy(allTeams, omitPathIsViable)
        case .teamBlocked(let name):
            return "Team \"\(name)\" is not one the Autovisor may create tasks on in this folder. " + remedy(allTeams, omitPathIsViable)
        case .activeTeamBlocked(let name):
            return "The folder's active team \"\(name)\" is not one the Autovisor may create tasks on, so omitting team_id is not an option here. " + remedy(allTeams, omitPathIsViable)
        case .activeTeamIsChat(let name):
            return "The folder's active team \"\(name)\" is a chat team — a managed task on it never finishes on its own. " + remedy(allTeams, omitPathIsViable)
        case .activeTeamNotUsable:
            return "The folder's active team is not one tasks can be created on. " + remedy(allTeams, omitPathIsViable)
        case .unknown(let raw):
            // "no-such-team"-style echo first: the pins assert the offending id appears, and
            // the word "disabled" must NOT (that is the sentinel case's signature).
            return "Unknown team_id '\(raw)'. " + remedy(allTeams, omitPathIsViable)
        }
    }

    /// What the manager can actually do next, given this folder's state. Never advertises a
    /// path that is currently closed.
    private func remedy(_ allTeams: [Team], _ omitPathIsViable: Bool) -> String {
        var options: [String] = []
        if !hasNoSelectableTeam(in: allTeams) {
            options.append("pick a team id from the catalog in create_managed_task's description")
        }
        if omitPathIsViable { options.append("omit team_id to use the folder's active team") }
        if allowGeneration { options.append("use 'generated' to assemble a new team") }
        guard !options.isEmpty else {
            return "No team is available for new tasks in this folder — report that to your Supervisor and carry on with the rest of the pass."
        }
        return options.count == 1
            ? "Instead, \(options[0])."
            : "Instead, " + options.dropLast().joined(separator: ", ") + ", or \(options.last!)."
    }
}
