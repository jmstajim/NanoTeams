import SwiftUI

// MARK: - Delegation Policy (pure, testable)

/// Pure-logic backing for the Delegation tab's "Allowed Teams" list — a static
/// helper namespace in the same testable-namespace style as
/// `RoleEditorSkillsPolicy` (top of `RoleEditorSkillsTab.swift`). Marked
/// `nonisolated` so the unit tests, which don't inherit the app target's
/// `@MainActor` default, can call it without a `@MainActor` hop.
///
/// Delegatability is owned by `Team.isValidDelegationTarget` (chat-mode teams are never
/// valid targets — they never auto-complete). The runtime catalog
/// (`DelegateToTeamTool.buildSchema`) routes through the same predicate, so the
/// picker stays in lock-step with what the LLM can actually delegate to. The
/// prune keeps a role's whitelist honest: any id that somehow became
/// non-delegatable (a team converted to chat-mode after being selected, or
/// imported JSON) is stripped from the in-memory selection so it can't persist
/// as an invisible stuck entry.
nonisolated enum RoleEditorDelegationPolicy {

    /// Project teams this role may delegate to: every team except the role's own
    /// and excluding non-delegatable (chat-mode) teams. Sorted by name for stable rendering.
    static func delegatableTeams(allTeams: [Team], excludingTeamID: NTMSID) -> [Team] {
        allTeams
            .filter { $0.id != excludingTeamID && $0.isValidDelegationTarget }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Drops any selected delegation id whose resolved team is not a valid
    /// delegation target (`!Team.isValidDelegationTarget`), keeping the in-memory selection
    /// in lock-step with what `delegatableTeams` shows in the picker. Scope is
    /// strictly the delegatability rule — unknown / own-team ids are left to their
    /// existing validation surfaces (`unknownDelegationTeam`, `delegationToSelf`).
    static func pruneNonDelegatableTeams(from selection: Set<NTMSID>, allTeams: [Team]) -> Set<NTMSID> {
        let nonDelegatableIDs = Set(allTeams.filter { !$0.isValidDelegationTarget }.map(\.id))
        return selection.subtracting(nonDelegatableIDs)
    }
}

// MARK: - Delegation Tab

/// Editor tab for configuring `delegate_to_team` policy on a role.
/// Visible for any non-Supervisor role. Picking any team checkbox or enabling
/// "generated" auto-injects the 4-tool delegation pack into the role's LLM
/// schema (see `LLMExecutionService+ToolResolution`); the save handler also
/// clears any `reportsTo[role.id]` entry so the role becomes peer-level with
/// Supervisor (required for delegation).
struct RoleEditorDelegationTab: View {
    @Binding var editorState: RoleEditorState
    let team: Team
    let allTeams: [Team]

    /// Project teams this role may delegate to: every team except the role's own
    /// and excluding chat-mode teams. See `RoleEditorDelegationPolicy`.
    private var delegatableTeams: [Team] {
        RoleEditorDelegationPolicy.delegatableTeams(allTeams: allTeams, excludingTeamID: team.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                MonoLabel(text: "Delegation", marker: true)
                    .padding(.horizontal, Spacing.standard)
                    .padding(.top, Spacing.m)

                Text("Pick the teams this role may delegate sub-tasks to via the `delegate_to_team` tool. The role's tool loop blocks until the delegated team finishes; final artifacts are returned to the role. Selecting any target (or enabling generated teams) auto-injects the 4-tool delegation pack into the role's LLM schema.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .padding(.horizontal, Spacing.standard)
                    .fixedSize(horizontal: false, vertical: true)

                TerminalDivider()
                    .padding(.horizontal, Spacing.standard)

                Toggle("Allow generating new teams on the fly", isOn: $editorState.allowDelegationToGeneratedTeams)
                    .toggleStyle(.terminal)
                    .padding(.horizontal, Spacing.standard)

                Text("When enabled, the role can pass `team_id: \"generated\"` to spawn a fresh team tailored to the task brief. Otherwise only whitelisted existing teams are valid targets.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .padding(.horizontal, Spacing.standard)
                    .fixedSize(horizontal: false, vertical: true)

                TerminalDivider()
                    .padding(.horizontal, Spacing.standard)

                teamWhitelistSection

                constraintsBanner
                    .padding(.horizontal, Spacing.standard)
                    .padding(.bottom, Spacing.m)
            }
        }
        .task {
            // Strip any id whose team is no longer a valid delegation target
            // (chat-mode) before it persists as an invisible stuck entry — the
            // row was just removed from the picker, so the user can't unstick it
            // (it still flips `hasDelegationConfigured`). Keeps the selection in
            // lock-step with `delegatableTeams`. Purely in-memory editor state;
            // persisted on next Save, discarded on Cancel, so the
            // `RoleEditorMutations` Binding race doesn't apply.
            editorState.selectedDelegationTeamIDs = RoleEditorDelegationPolicy.pruneNonDelegatableTeams(
                from: editorState.selectedDelegationTeamIDs,
                allTeams: allTeams
            )
        }
    }

    // MARK: - Whitelist

    @ViewBuilder
    private var teamWhitelistSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            MonoLabel(text: "Allowed Teams")

            if delegatableTeams.isEmpty {
                Text("No other delegatable teams in this project. Chat-mode teams can't be delegation targets — create a non-chat team, or enable generated teams above.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(delegatableTeams, id: \.id) { otherTeam in
                    Toggle(isOn: bindingForTeam(otherTeam.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(otherTeam.name)
                                .font(Typography.termBase)
                                .foregroundStyle(Colors.textPrimary)
                            if !otherTeam.description.isEmpty {
                                Text(otherTeam.description)
                                    .font(Typography.caption)
                                    .foregroundStyle(Colors.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .toggleStyle(.terminal)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, Spacing.standard)
    }

    private func bindingForTeam(_ id: NTMSID) -> Binding<Bool> {
        Binding(
            get: { editorState.selectedDelegationTeamIDs.contains(id) },
            set: { isOn in
                if isOn {
                    editorState.selectedDelegationTeamIDs.insert(id)
                } else {
                    editorState.selectedDelegationTeamIDs.remove(id)
                }
            }
        )
    }

    // MARK: - Constraints Banner

    private var constraintsBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            MonoLabel(text: "Constraints")
            Text("• Chat-mode teams cannot be delegated to (they never auto-complete).")
                .font(Typography.caption2)
                .foregroundStyle(Colors.textSecondary)
            Text("• Per-delegation timeout: \(Int(DelegationConstants.delegationTimeoutSeconds / 60)) minutes.")
                .font(Typography.caption2)
                .foregroundStyle(Colors.textSecondary)
        }
        .padding(Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceCard)
        )
    }
}
