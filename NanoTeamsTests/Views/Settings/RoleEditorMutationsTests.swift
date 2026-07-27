import XCTest
@testable import NanoTeams

/// Pins the pure mutation semantics of `RoleEditorMutations.applyEdit` /
/// `applyCreate` — the helpers `RoleEditorSheet.saveRole` delegates to.
///
/// Motivation: the previous in-place `saveRole` issued two separate writes
/// to the team `Binding` (role-field update + hierarchy clear). Because the
/// `TeamEditorView.binding(for:)` getter captures a frozen snapshot, the
/// second write's read-modify-write cycle dropped the first write's
/// mutation. Symptom: unchecking a team in the Delegation tab whitelist
/// did not persist when `allowDelegationToGeneratedTeams = true` (or any
/// other whitelist entry was still selected) — exactly the conditions that
/// make `shouldClearReportsTo = true`.
///
/// The fix extracts both mutations into a single in-out helper so callers
/// can compose them on a local copy and ship one Binding write. These tests
/// pin that pure shape.
final class RoleEditorMutationsTests: XCTestCase {

    // MARK: - RoleEditorState.loaded(from:) — TDD: init-time vs onAppear-time

    /// `RoleEditorSheet` previously seeded `@State editorState` to its default
    /// value and then ran `editorState.load(from: role)` inside `.onAppear`.
    /// That leaves a window — between the first body evaluation and the
    /// onAppear firing — during which the view renders with an EMPTY
    /// `selectedDelegationTeamIDs`. Any user click landing in that window
    /// races against the load. The fix is a synchronous factory that builds
    /// a fully-loaded state at init time, so the very first render is
    /// already authoritative.
    func testLoadedFactory_seedsAllStateFromRole_synchronously() {
        let role = TeamRoleDefinition(
            id: "delegator",
            name: "Delegator",
            icon: "arrow.up.right",
            prompt: "Delegate.",
            toolIDs: [ToolNames.readFile],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Brief"],
                producesArtifacts: ["Report"]
            ),
            llmOverride: LLMOverride(modelName: "qwen-14b"),
            allowedDelegationTeamIDs: ["team-A", "team-B"],
            allowDelegationToGeneratedTeams: true,
            isSystemRole: false,
            systemRoleID: nil,
            iconColor: "#FFFFFF",
            iconBackground: "#FF00FF"
        )

        let state = RoleEditorState.loaded(from: role)

        XCTAssertEqual(state.roleName, "Delegator")
        XCTAssertEqual(state.roleIcon, "arrow.up.right")
        XCTAssertEqual(state.rolePrompt, "Delegate.")
        XCTAssertEqual(state.selectedTools, [ToolNames.readFile])
        XCTAssertEqual(state.requiredArtifacts, ["Brief"])
        XCTAssertEqual(state.producedArtifacts, ["Report"])
        XCTAssertEqual(state.llmModelName, "qwen-14b")
        XCTAssertEqual(state.selectedDelegationTeamIDs, ["team-A", "team-B"])
        XCTAssertTrue(state.allowDelegationToGeneratedTeams)
        XCTAssertEqual(state.roleIconColor, "#FFFFFF")
        XCTAssertEqual(state.roleIconBackground, "#FF00FF")
    }

    /// The factory must be a pure value constructor (not call MainActor
    /// APIs / @Observable singletons), so `RoleEditorSheet.init` can call it
    /// synchronously in a `State(initialValue:)` expression.
    func testLoadedFactory_isPureValue_noSideEffects() {
        let role = TeamRoleDefinition(
            id: "x", name: "X", prompt: "", toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let a = RoleEditorState.loaded(from: role)
        let b = RoleEditorState.loaded(from: role)
        // Identical inputs → identical outputs across two calls (no
        // hidden timestamp / id / counter mutation).
        XCTAssertEqual(a.roleName, b.roleName)
        XCTAssertEqual(a.selectedDelegationTeamIDs, b.selectedDelegationTeamIDs)
    }


    // MARK: - Fixtures

    private static let supervisorID = "supervisor-role"
    private static let teamID: NTMSID = "test-team"
    private static let teamA_ID: NTMSID = "team-A"
    private static let teamB_ID: NTMSID = "team-B"

    /// Non-Supervisor LLM-driven role with custom defaults overridable by tests.
    private func makeWorkerRole(
        id: String = "worker-role",
        name: String = "Worker",
        toolIDs: [String] = [],
        allowedDelegationTeamIDs: [NTMSID] = [],
        allowDelegationToGeneratedTeams: Bool = false
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: name,
            prompt: "Do the work.",
            toolIDs: toolIDs,
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: allowedDelegationTeamIDs,
            allowDelegationToGeneratedTeams: allowDelegationToGeneratedTeams,
            isSystemRole: false,
            systemRoleID: nil
        )
    }

    /// Supervisor sentinel (user-driven, not LLM). Marked via `systemRoleID = "supervisor"`
    /// per `TeamRoleDefinition.isSupervisor`.
    private func makeSupervisorRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: Self.supervisorID,
            name: "Supervisor",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: [SystemTemplates.supervisorTaskArtifactName]
            ),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )
    }

    /// Build a team containing the given roles, with an explicit `reportsTo` map.
    /// `reportsTo` lets tests seed an upstream link the helper may need to clear.
    private func makeTeam(
        roles: [TeamRoleDefinition],
        reportsTo: [String: String] = [:]
    ) -> Team {
        Team(
            id: Self.teamID,
            name: "Test Team",
            roles: roles,
            artifacts: [],
            settings: TeamSettings(hierarchy: TeamHierarchy(reportsTo: reportsTo)),
            graphLayout: TeamGraphLayout()
        )
    }

    /// Build a `RoleEditorState` that round-trips the role first via `load`,
    /// then applies the per-test mutations.
    private func makeState(
        for role: TeamRoleDefinition,
        mutate: (inout RoleEditorState) -> Void = { _ in }
    ) -> RoleEditorState {
        var s = RoleEditorState()
        s.load(from: role)
        mutate(&s)
        return s
    }

    // MARK: - .edit: whitelist persistence (regression core)

    /// Core regression. Unchecking one of two whitelisted teams while the
    /// generated-teams flag stays ON: both the whitelist removal AND the
    /// hierarchy clear must land in a single mutation, with no
    /// captured-snapshot lost-update.
    func testApplyEdit_persistsLLMProviderOverride() {
        let role = makeWorkerRole()
        var team = makeTeam(roles: [role], reportsTo: [role.id: Self.supervisorID])

        let state = makeState(for: role) {
            $0.llmBaseURL = "http://127.0.0.1:11434"
            $0.llmProviderOverride = .ollama
        }

        XCTAssertTrue(RoleEditorMutations.applyEdit(
            to: &team, editorState: state, existingRoleID: role.id))
        XCTAssertEqual(team.roles[0].llmOverride?.provider, .ollama,
                       "Dropping provider from makeLLMOverride would compile (default param) and silently lose the pin")
        XCTAssertEqual(team.roles[0].llmOverride?.baseURLString, "http://127.0.0.1:11434")
    }

    func testApplyEdit_providerOnlyOverride_persistsNonNil() {
        let role = makeWorkerRole()
        var team = makeTeam(roles: [role], reportsTo: [role.id: Self.supervisorID])

        let state = makeState(for: role) {
            $0.llmProviderOverride = .ollama
        }

        XCTAssertTrue(RoleEditorMutations.applyEdit(
            to: &team, editorState: state, existingRoleID: role.id))
        XCTAssertEqual(team.roles[0].llmOverride?.provider, .ollama,
                       "A provider-only override is meaningful (\"this role's inherited URL speaks Ollama\") and must survive the empty-collapse")
    }

    func testApplyEdit_uncheckingTeamFromWhitelist_persistsRemoval() {
        let role = makeWorkerRole(
            allowedDelegationTeamIDs: [Self.teamA_ID, Self.teamB_ID],
            allowDelegationToGeneratedTeams: true
        )
        var team = makeTeam(roles: [role], reportsTo: [role.id: Self.supervisorID])

        // Uncheck teamB; keep teamA + generated ON.
        let state = makeState(for: role) {
            $0.selectedDelegationTeamIDs = [Self.teamA_ID]
        }

        let didApply = RoleEditorMutations.applyEdit(
            to: &team,
            editorState: state,
            existingRoleID: role.id
        )

        XCTAssertTrue(didApply, "Helper must report a matching role was found.")
        XCTAssertEqual(
            team.roles[0].allowedDelegationTeamIDs, [Self.teamA_ID],
            "Whitelist removal must persist."
        )
        XCTAssertTrue(
            team.roles[0].allowDelegationToGeneratedTeams,
            "Generated-teams flag must persist."
        )
        XCTAssertNil(
            team.settings.hierarchy.reportsTo[role.id],
            "Delegation is configured → role must be peer-with-Supervisor (no reportsTo entry)."
        )
    }

    /// Wiping the whitelist AND disabling generated teams flips
    /// `shouldClearReportsTo` to false — the helper must leave any
    /// pre-existing `reportsTo` entry intact (changing one's delegation
    /// policy should not silently re-parent the role).
    func testApplyEdit_emptyingWhitelistAndDisablingGenerated_persistsBoth_andDoesNotTouchReportsTo() {
        let role = makeWorkerRole(
            allowedDelegationTeamIDs: [Self.teamA_ID],
            allowDelegationToGeneratedTeams: true
        )
        var team = makeTeam(roles: [role], reportsTo: [role.id: Self.supervisorID])

        let state = makeState(for: role) {
            $0.selectedDelegationTeamIDs = []
            $0.allowDelegationToGeneratedTeams = false
        }

        _ = RoleEditorMutations.applyEdit(
            to: &team,
            editorState: state,
            existingRoleID: role.id
        )

        XCTAssertEqual(team.roles[0].allowedDelegationTeamIDs, [])
        XCTAssertFalse(team.roles[0].allowDelegationToGeneratedTeams)
        XCTAssertEqual(
            team.settings.hierarchy.reportsTo[role.id], Self.supervisorID,
            "reportsTo must be preserved when shouldClearReportsTo == false."
        )
    }

    /// When the user FIRST enables delegation on a previously-subordinate
    /// role (`reportsTo` had an entry), the helper clears that entry so the
    /// auto-injection / peer-status invariant holds.
    func testApplyEdit_clearsReportsTo_whenWhitelistFirstBecomesNonEmpty() {
        let role = makeWorkerRole(allowedDelegationTeamIDs: [])
        var team = makeTeam(roles: [role], reportsTo: [role.id: Self.supervisorID])

        let state = makeState(for: role) {
            $0.selectedDelegationTeamIDs = [Self.teamA_ID]
        }

        _ = RoleEditorMutations.applyEdit(
            to: &team,
            editorState: state,
            existingRoleID: role.id
        )

        XCTAssertEqual(team.roles[0].allowedDelegationTeamIDs, [Self.teamA_ID])
        XCTAssertNil(team.settings.hierarchy.reportsTo[role.id])
    }

    // MARK: - .edit: Supervisor lock

    /// Editing the Supervisor row must lock delegation fields to zero AND
    /// never touch `reportsTo`, regardless of what the editorState carries
    /// (the Delegation tab is hidden for Supervisor, so any value there is
    /// stale and must not poison the save).
    func testApplyEdit_supervisor_locksDelegationFields_and_ignoresHierarchyEdit() {
        let supervisor = makeSupervisorRole()
        var team = makeTeam(
            roles: [supervisor],
            // Pre-seed a stale entry to prove the helper never writes
            // hierarchy edits for Supervisor.
            reportsTo: [Self.supervisorID: "stale-supervisor"]
        )

        let state = makeState(for: supervisor) {
            $0.selectedDelegationTeamIDs = [Self.teamA_ID]
            $0.allowDelegationToGeneratedTeams = true
            $0.requiredArtifacts = ["Custom Artifact"]
        }

        _ = RoleEditorMutations.applyEdit(
            to: &team,
            editorState: state,
            existingRoleID: supervisor.id
        )

        let saved = team.roles[0]
        XCTAssertTrue(
            saved.allowedDelegationTeamIDs.isEmpty,
            "Supervisor cannot delegate — whitelist must be forced empty."
        )
        XCTAssertFalse(
            saved.allowDelegationToGeneratedTeams,
            "Supervisor cannot delegate to generated teams."
        )
        XCTAssertEqual(
            saved.dependencies.producesArtifacts,
            [SystemTemplates.supervisorTaskArtifactName],
            "Supervisor's produced artifact is locked to the canonical Supervisor Task."
        )
        XCTAssertEqual(
            team.settings.hierarchy.reportsTo[Self.supervisorID], "stale-supervisor",
            "Hierarchy clear path must be skipped for Supervisor."
        )
    }

    // MARK: - .edit: delegation-tool stripping

    /// Delegation tools auto-inject from settings (`allowedDelegationTeamIDs` /
    /// `allowDelegationToGeneratedTeams`). They MUST NOT round-trip through
    /// `toolIDs`. Legacy `"list_teams"` literal is also scrubbed.
    func testApplyEdit_stripsDelegationToolsFromToolIDs() {
        let role = makeWorkerRole()
        var team = makeTeam(roles: [role])

        let state = makeState(for: role) {
            $0.selectedTools = [
                ToolNames.readFile,
                ToolNames.delegateToTeam,
                ToolNames.cancelDelegation,
                ToolNames.resumeDelegation,
                ToolNames.forwardToTeam,
                "list_teams",
            ]
        }

        _ = RoleEditorMutations.applyEdit(
            to: &team,
            editorState: state,
            existingRoleID: role.id
        )

        XCTAssertEqual(
            team.roles[0].toolIDs.sorted(),
            [ToolNames.readFile].sorted(),
            "Only non-delegation tools may persist in toolIDs."
        )
    }

    // MARK: - .edit: team.updatedAt bump (SwiftUI observer-trigger contract)

    /// Per CLAUDE.md #42, `Team.==` is an id-only shortcut (matches by id +
    /// `updatedAt`, NOT structural). When SwiftUI's `ForEach` over
    /// `team.roles` diffs the binding, an unchanged `updatedAt` makes the
    /// team compare equal even after a role's nested fields changed — the
    /// View tree skips re-render, ForEach row closures stay bound to the
    /// PRE-edit role, and the tap handler `showingEditRole = role` then
    /// stamps the stale role into state. Symptom (the user-reported bug):
    /// after Save, reopening the role editor in the SAME session shows the
    /// pre-edit whitelist. A full app reload reads fresh data from disk,
    /// so the disk persisted correctly — only the in-memory observer chain
    /// was broken. The fix is to bump `team.updatedAt` whenever the helper
    /// mutates a role's fields, mirroring what `Team.addRole(_:)` /
    /// `removeRole(_:)` already do for collection-level changes.
    func testApplyEdit_bumpsTeamUpdatedAt_soObserversReRender() {
        let role = makeWorkerRole(
            allowedDelegationTeamIDs: [Self.teamA_ID, Self.teamB_ID]
        )
        var team = makeTeam(roles: [role])
        let originalUpdatedAt = team.updatedAt

        let state = makeState(for: role) {
            $0.selectedDelegationTeamIDs = [Self.teamA_ID]
        }
        _ = RoleEditorMutations.applyEdit(
            to: &team,
            editorState: state,
            existingRoleID: role.id
        )

        XCTAssertGreaterThan(
            team.updatedAt, originalUpdatedAt,
            "team.updatedAt must bump on role-field edits so SwiftUI's id+timestamp Team.== shortcut treats the team as changed and downstream views re-render."
        )
    }

    /// Pre-refactor, the delegation-configured `applyCreate` path bumped
    /// `team.updatedAt` once via `Team.addRole` and ONCE MORE via a
    /// trailing `team.updatedAt = MonotonicClock.shared.now()` after the
    /// hierarchy clear. Without that second tick (or, post-refactor,
    /// without `Team.detachFromHierarchy`'s own bump), the final
    /// `team.updatedAt` would reflect "team grew a role" but not "team's
    /// hierarchy also changed" — a future post-`addRole` mutation that
    /// landed between addRole and return would silently degrade observer
    /// re-render. This test pins that a delegation-configured create
    /// produces a STRICTLY LATER `team.updatedAt` than the no-delegation
    /// control, proving the post-hierarchy bump actually fires.
    func testApplyCreate_withDelegation_stampsTimestampAfterAddRoleBump() {
        var control = makeTeam(roles: [])
        var controlState = RoleEditorState()
        controlState.roleName = "Plain"
        controlState.rolePrompt = "."
        _ = RoleEditorMutations.applyCreate(
            to: &control, editorState: controlState, teamID: control.id
        )

        var experiment = makeTeam(roles: [])
        var expState = RoleEditorState()
        expState.roleName = "Delegator"
        expState.rolePrompt = "."
        expState.selectedDelegationTeamIDs = [Self.teamA_ID]
        _ = RoleEditorMutations.applyCreate(
            to: &experiment, editorState: expState, teamID: experiment.id
        )

        XCTAssertGreaterThan(
            experiment.updatedAt, control.updatedAt,
            "Delegation-configured create must stamp a later monotonic tick than addRole's bump alone — pinning the post-hierarchy bump."
        )
    }

    /// `applyCreate` already bumps via `Team.addRole(_:)`. Pin it so that
    /// invariant doesn't silently regress when the helper is refactored.
    func testApplyCreate_bumpsTeamUpdatedAt() {
        var team = makeTeam(roles: [])
        let originalUpdatedAt = team.updatedAt

        var state = RoleEditorState()
        state.roleName = "Worker"
        state.rolePrompt = "."
        _ = RoleEditorMutations.applyCreate(
            to: &team,
            editorState: state,
            teamID: team.id
        )

        XCTAssertGreaterThan(
            team.updatedAt, originalUpdatedAt,
            "applyCreate must yield a team with bumped updatedAt (already provided by Team.addRole, pinned here against regression)."
        )
    }

    // MARK: - .edit: stale-id guard

    /// If the UI somehow drove a save against a deleted role (race against
    /// `handleDeleteRole`), the helper must report "no match" without
    /// mutating anything. This pins the new return-value contract.
    func testApplyEdit_returnsFalseForUnknownRoleID() {
        let role = makeWorkerRole(id: "real-role")
        var team = makeTeam(roles: [role])
        let snapshotBefore = team

        let state = makeState(for: role)
        let didApply = RoleEditorMutations.applyEdit(
            to: &team,
            editorState: state,
            existingRoleID: "ghost-role"
        )

        XCTAssertFalse(didApply, "No matching role → must return false.")
        XCTAssertEqual(team.roles, snapshotBefore.roles, "Team must be untouched.")
        XCTAssertEqual(team.settings, snapshotBefore.settings, "Settings must be untouched.")
        // No-op path must NOT bump `team.updatedAt`. Otherwise SwiftUI
        // observers re-render on every stale Save click, and a future
        // refactor that moves the bump above the role-existence guard
        // (RoleEditorMutations.swift) wouldn't be caught by the role/
        // settings assertions above. Pin the timestamp explicitly.
        XCTAssertEqual(
            team.updatedAt, snapshotBefore.updatedAt,
            "No-op apply must leave team.updatedAt untouched."
        )
    }

    // MARK: - .create: delegation peer-status auto-derivation

    /// A freshly-created role with delegation enabled must end up peer-level
    /// with Supervisor (no `reportsTo` entry).
    func testApplyCreate_clearsReportsTo_whenDelegationConfigured() {
        var team = makeTeam(roles: [])

        var state = RoleEditorState()
        state.roleName = "Delegator"
        state.rolePrompt = "Delegate work."
        state.selectedDelegationTeamIDs = [Self.teamA_ID]

        let newID = RoleEditorMutations.applyCreate(
            to: &team,
            editorState: state,
            teamID: team.id
        )

        XCTAssertEqual(team.roles.count, 1)
        XCTAssertEqual(team.roles[0].id, newID)
        XCTAssertEqual(team.roles[0].allowedDelegationTeamIDs, [Self.teamA_ID])
        XCTAssertNil(
            team.settings.hierarchy.reportsTo[newID],
            "Delegator role must be peer-with-Supervisor from creation."
        )
    }

    /// Control case: no delegation configured → `reportsTo` is not touched.
    /// `addRole` does not auto-insert any entry today, so absence is
    /// expected; the test pins that the helper does not invent one either.
    func testApplyCreate_noDelegation_leavesReportsToAlone() {
        var team = makeTeam(roles: [])

        var state = RoleEditorState()
        state.roleName = "Plain Worker"
        state.rolePrompt = "Just work."

        let newID = RoleEditorMutations.applyCreate(
            to: &team,
            editorState: state,
            teamID: team.id
        )

        XCTAssertEqual(team.roles.count, 1)
        XCTAssertTrue(team.roles[0].allowedDelegationTeamIDs.isEmpty)
        XCTAssertFalse(team.roles[0].allowDelegationToGeneratedTeams)
        // No write must have happened for this id either way.
        XCTAssertNil(team.settings.hierarchy.reportsTo[newID])
    }

    /// `SystemTemplates.supervisorTaskArtifactName` is reserved for Supervisor.
    /// Any non-Supervisor role that tries to declare it as a produced artifact
    /// must have it filtered out at save time.
    func testApplyCreate_sanitizesSupervisorTaskArtifact_outOfProducedArtifacts() {
        var team = makeTeam(roles: [])

        var state = RoleEditorState()
        state.roleName = "Sneaky"
        state.rolePrompt = "."
        state.producedArtifacts = [
            "Custom Artifact",
            SystemTemplates.supervisorTaskArtifactName,
        ]

        _ = RoleEditorMutations.applyCreate(
            to: &team,
            editorState: state,
            teamID: team.id
        )

        XCTAssertEqual(
            team.roles[0].dependencies.producesArtifacts,
            ["Custom Artifact"],
            "Supervisor Task must be filtered out of any non-Supervisor's produced list."
        )
    }
}
