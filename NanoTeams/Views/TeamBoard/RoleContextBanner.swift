import SwiftUI

// MARK: - Role Context Banner

/// Contextual banner shown at the top of the activity panel when a role is selected.
/// Composes status pill, artifact badges, consultations disclosure, and scratchpad disclosure.
struct RoleContextBanner: View {
    let roleID: String
    let run: Run?
    let roleDefinitions: [TeamRoleDefinition]
    var isInMeeting: Bool = false
    var isPaused: Bool = false
    let onDeselect: () -> Void
    var onRestart: ((String, String) -> Void)? = nil
    var onCorrect: ((String, String) -> Void)? = nil
    let isReadOnly: Bool

    @State private var showConsultations = false
    @State private var showScratchpad = false
    @State private var isShowingRestartSheet = false
    @State private var restartComment = ""
    @State private var isShowingCorrectSheet = false
    @State private var correctComment = ""

    // MARK: - Derived State

    /// The role's execution status, with the `systemRoleID` bridge for the UUID-mismatch
    /// case (a run whose `roleStatuses` are keyed by a previous generation of role ids).
    ///
    /// Iterates the ROSTER and indexes into `roleStatuses`, rather than iterating
    /// `roleStatuses` and scanning the roster for each key. Two things change:
    ///
    ///  - **Cost**: Θ(roles) with O(1) dictionary hits, not Θ(roles²).
    ///  - **Determinism, which is a fix rather than a speedup.** `Dictionary` iteration
    ///    order is not a function of its contents, so the old loop returned whichever
    ///    match it happened to reach first. With two roles sharing a `systemRoleID` —
    ///    reachable, since ids are name-derived, and the same hazard `RoleRosterIndex`
    ///    and `Run.stepsByRoleBaseID` both call out — the banner could show a different
    ///    status on different launches from identical data. Roster order now decides.
    ///
    /// Identical to the old answer whenever at most one role carries the `systemRoleID`.
    nonisolated static func resolveStatus(
        roleID: String,
        run: Run?,
        roleDefinitions: [TeamRoleDefinition],
        roleDef: TeamRoleDefinition?
    ) -> RoleExecutionStatus {
        if let status = run?.roleStatuses[roleID] { return status }
        guard let sysID = roleDef?.systemRoleID, let statuses = run?.roleStatuses else {
            return .idle
        }
        for candidate in roleDefinitions where candidate.systemRoleID == sysID {
            if let status = statuses[candidate.id] { return status }
        }
        return .idle
    }

    /// The role's most recent step, with the same `systemRoleID` bridge.
    nonisolated static func resolveStep(
        roleID: String,
        run: Run?,
        roleDef: TeamRoleDefinition?
    ) -> StepExecution? {
        if let step = run?.steps.last(where: { $0.effectiveRoleID == roleID }) {
            return step
        }
        guard let sysID = roleDef?.systemRoleID else { return nil }
        return run?.steps.last(where: { $0.role.baseID == sysID })
    }

    nonisolated static func hasSecondaryContent(
        artifacts: [Artifact],
        consultations: [TeammateConsultation],
        scratchpad: String?
    ) -> Bool {
        !artifacts.isEmpty || !consultations.isEmpty || (scratchpad.map { !$0.isEmpty } ?? false)
    }

    // MARK: - Body

    var body: some View {
        // Derived ONCE per body pass and threaded down. These were computed properties,
        // which SwiftUI re-evaluates at every reference: `selectedStep` ran 8-10 times a
        // pass (each an O(steps) reverse scan returning a whole `StepExecution` copy) and
        // `roleStatus` four (each capable of the Θ(roles²) fallback). `consultations` was
        // read twice on adjacent lines alone. The `let`s are only half the fix — the
        // computed properties are DELETED, because a property is what a sub-view reaches
        // back for.
        let roleDef = roleDefinitions.first { $0.id == roleID }
        let status = Self.resolveStatus(
            roleID: roleID, run: run, roleDefinitions: roleDefinitions, roleDef: roleDef)
        let step = Self.resolveStep(roleID: roleID, run: run, roleDef: roleDef)
        let roleName = roleDefinitions.roleName(for: roleID)
        let consultations = step?.consultations ?? []
        let scratchpad = step?.scratchpad
        let artifacts = step?.artifacts ?? []

        VStack(alignment: .leading, spacing: 0) {
            primaryRow(roleDef: roleDef, roleName: roleName, status: status, step: step)
                .padding(.horizontal, Spacing.standard)
                .padding(.top, Spacing.s)
                .padding(.bottom, Self.hasSecondaryContent(
                    artifacts: artifacts, consultations: consultations, scratchpad: scratchpad)
                    ? Spacing.xs : Spacing.s)

            if !artifacts.isEmpty {
                RoleArtifactBadges(artifacts: artifacts)
                    .padding(.horizontal, Spacing.standard)
                    .padding(.bottom, Spacing.s)
            }

            if !consultations.isEmpty {
                TerminalDivider().padding(.horizontal, Spacing.s)
                RoleConsultationsPanel(consultations: consultations, isExpanded: $showConsultations)
            }

            if let pad = scratchpad, !pad.isEmpty {
                TerminalDivider().padding(.horizontal, Spacing.s)
                RoleScratchpadPanel(content: pad, isExpanded: $showScratchpad)
            }
        }
        .background(Colors.surfaceCard)
        .sheet(isPresented: $isShowingRestartSheet) {
            RestartRoleSheet(
                roleName: roleDefinitions.roleName(for: roleID),
                comment: $restartComment,
                isPresented: $isShowingRestartSheet
            ) {
                onRestart?(roleID, restartComment)
            }
        }
        .sheet(isPresented: $isShowingCorrectSheet) {
            CorrectRoleSheet(
                roleName: roleDefinitions.roleName(for: roleID),
                comment: $correctComment,
                isPresented: $isShowingCorrectSheet
            ) {
                onCorrect?(roleID, correctComment)
            }
        }
    }

    // MARK: - Primary Row

    private func primaryRow(
        roleDef: TeamRoleDefinition?,
        roleName: String,
        status: RoleExecutionStatus,
        step: StepExecution?
    ) -> some View {
        // True when a Correct action makes sense: task paused and the role's step too.
        let canCorrect = isPaused && step?.status == .paused
        let resolvedRole: Role = step?.role ?? roleDef.map(Role.fromDefinition) ?? .custom(id: roleID)

        return HStack(spacing: Spacing.s) {
            ActivityFeedRoleAvatar(role: resolvedRole, roleDefinition: roleDef, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(roleName)
                    .font(Typography.subheadlineSemibold)
                    .lineLimit(1)

                RoleStatusPill(
                    roleDefinition: roleDef,
                    statusName: status.displayName(isInMeeting: isInMeeting, isPaused: isPaused),
                    statusColor: status.displayColor(isInMeeting: isInMeeting, isPaused: isPaused)
                )
            }

            Spacer()

            HStack(spacing: Spacing.xs) {
                if !isReadOnly, onCorrect != nil, canCorrect {
                    Button {
                        isShowingCorrectSheet = true
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(Typography.termXs)
                            .foregroundStyle(Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Correct role")
                    .accessibilityLabel("Correct role")
                }

                if !isReadOnly, onRestart != nil, status.canRestart {
                    Button {
                        isShowingRestartSheet = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(Typography.termXs)
                            .foregroundStyle(Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Restart role")
                    .accessibilityLabel("Restart role")
                }

                Button {
                    withAnimation {
                        onDeselect()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(Typography.termXs)
                        .foregroundStyle(Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Deselect role (Escape)")
                .accessibilityLabel("Deselect role")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(roleName), \(status.displayName)")
    }
}

// MARK: - Previews

#Preview("Banner — Working") {
    let team = Team.default
    let pmRole = team.roles.first(where: { $0.name == "Product Manager" })!
    RoleContextBanner(
        roleID: pmRole.id,
        run: Run(id: 0, roleStatuses: [pmRole.id: .working]),
        roleDefinitions: team.roles,
        onDeselect: {},
        isReadOnly: false
    )
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Banner — Done with Artifacts") {
    let team = Team.default
    let sweRole = team.roles.first(where: { $0.name == "Software Engineer" })!
    let step = StepExecution(
        id: "preview",
        role: .softwareEngineer,
        title: "Software Engineer",
        expectedArtifacts: ["Engineering Notes"],
        status: .done,
        artifacts: [Artifact(name: "Engineering Notes", icon: "doc.text", description: "Implementation details")],
        consultations: [
            TeammateConsultation(
                requestingRole: .softwareEngineer,
                consultedRole: .techLead,
                question: "Should I use async/await for the network layer?",
                response: "Yes, use async/await with structured concurrency.",
                status: .completed
            )
        ]
    )
    RoleContextBanner(
        roleID: sweRole.id,
        run: Run(id: 0, steps: [step], roleStatuses: [sweRole.id: .done]),
        roleDefinitions: team.roles,
        onDeselect: {},
        onRestart: { _, _ in },
        isReadOnly: false
    )
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Banner — In Meeting") {
    let team = Team.default
    let tlRole = team.roles.first(where: { $0.name == "Tech Lead" })!
    RoleContextBanner(
        roleID: tlRole.id,
        run: Run(id: 0, roleStatuses: [tlRole.id: .working]),
        roleDefinitions: team.roles,
        isInMeeting: true,
        onDeselect: {},
        isReadOnly: false
    )
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Banner — Failed") {
    let team = Team.default
    let sweRole = team.roles.first(where: { $0.name == "Software Engineer" })!
    let step = StepExecution(
        id: "preview",
        role: .softwareEngineer,
        title: "Software Engineer",
        expectedArtifacts: ["Engineering Notes"],
        status: .failed,
        messages: [
            StepMessage(role: .softwareEngineer, content: "Build failed with 5 errors in AuthenticationService.swift")
        ]
    )
    RoleContextBanner(
        roleID: sweRole.id,
        run: Run(id: 0, steps: [step], roleStatuses: [sweRole.id: .failed]),
        roleDefinitions: team.roles,
        onDeselect: {},
        onRestart: { _, _ in },
        isReadOnly: false
    )
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Banner — Revision Requested") {
    let team = Team.default
    let pmRole = team.roles.first(where: { $0.name == "Product Manager" })!
    let step = StepExecution(
        id: "preview",
        role: .productManager,
        title: "Product Manager",
        expectedArtifacts: ["Product Requirements"],
        status: .done,
        artifacts: [Artifact(name: "Product Requirements", icon: "doc.text", description: "PRD v1")]
    )
    RoleContextBanner(
        roleID: pmRole.id,
        run: Run(id: 0, steps: [step], roleStatuses: [pmRole.id: .revisionRequested]),
        roleDefinitions: team.roles,
        onDeselect: {},
        onRestart: { _, _ in },
        isReadOnly: false
    )
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Banner — Needs Acceptance") {
    let team = Team.default
    let crRole = team.roles.first(where: { $0.name == "Code Reviewer" })!
    let step = StepExecution(
        id: "preview",
        role: .codeReviewer,
        title: "Code Reviewer",
        expectedArtifacts: ["Code Review Summary"],
        status: .needsApproval,
        artifacts: [Artifact(name: "Code Review Summary", icon: "checkmark.shield", description: "Review summary")]
    )
    RoleContextBanner(
        roleID: crRole.id,
        run: Run(id: 0, steps: [step], roleStatuses: [crRole.id: .needsAcceptance]),
        roleDefinitions: team.roles,
        onDeselect: {},
        onRestart: { _, _ in },
        isReadOnly: false
    )
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Banner — Read-Only (Historical)") {
    let team = Team.default
    let pmRole = team.roles.first(where: { $0.name == "Product Manager" })!
    let step = StepExecution(
        id: "preview",
        role: .productManager,
        title: "Product Manager",
        expectedArtifacts: ["Product Requirements"],
        status: .done,
        artifacts: [Artifact(name: "Product Requirements", icon: "doc.text", description: "PRD")]
    )
    RoleContextBanner(
        roleID: pmRole.id,
        run: Run(id: 0, steps: [step], roleStatuses: [pmRole.id: .done]),
        roleDefinitions: team.roles,
        onDeselect: {},
        isReadOnly: true
    )
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}
