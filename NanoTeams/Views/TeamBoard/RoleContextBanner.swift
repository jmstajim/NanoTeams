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

    private var roleDef: TeamRoleDefinition? {
        roleDefinitions.first { $0.id == roleID }
    }

    private var roleStatus: RoleExecutionStatus {
        if let status = run?.roleStatuses[roleID] { return status }
        // Fallback: find status by systemRoleID bridge (handles UUID mismatch)
        guard let def = roleDef, let sysID = def.systemRoleID else { return .idle }
        for (key, status) in run?.roleStatuses ?? [:] {
            if roleDefinitions.first(where: { $0.id == key })?.systemRoleID == sysID {
                #if DEBUG
                print("[RoleContextBanner] Status fallback: roleID \(roleID) matched via systemRoleID '\(sysID)' → \(status)")
                #endif
                return status
            }
        }
        return .idle
    }

    private var selectedStep: StepExecution? {
        if let step = run?.steps.last(where: { $0.effectiveRoleID == roleID }) {
            return step
        }
        // Fallback: match by role.baseID via systemRoleID bridge
        guard let def = roleDef, let sysID = def.systemRoleID else { return nil }
        let step = run?.steps.last(where: { $0.role.baseID == sysID })
        #if DEBUG
        if step != nil {
            print("[RoleContextBanner] Step fallback: roleID \(roleID) matched step via systemRoleID '\(sysID)'")
        }
        #endif
        return step
    }

    private var displayStatusName: String {
        roleStatus.displayName(isInMeeting: isInMeeting, isPaused: isPaused)
    }

    private var displayStatusColor: Color {
        roleStatus.displayColor(isInMeeting: isInMeeting, isPaused: isPaused)
    }

    private var consultations: [TeammateConsultation] {
        selectedStep?.consultations ?? []
    }

    private var scratchpad: String? {
        selectedStep?.scratchpad
    }

    private var resolvedRole: Role {
        if let step = selectedStep { return step.role }
        if let def = roleDef { return Role.fromDefinition(def) }
        return .custom(id: roleID)
    }

    private var hasSecondaryContent: Bool {
        let hasArtifacts = selectedStep.map { !$0.artifacts.isEmpty } ?? false
        let hasConsultationCount = !consultations.isEmpty
        let hasScratchpad = scratchpad.map { !$0.isEmpty } ?? false
        return hasArtifacts || hasConsultationCount || hasScratchpad
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            primaryRow
                .padding(.horizontal, Spacing.standard)
                .padding(.top, Spacing.s)
                .padding(.bottom, hasSecondaryContent ? Spacing.xs : Spacing.s)

            if let step = selectedStep, !step.artifacts.isEmpty {
                RoleArtifactBadges(artifacts: step.artifacts)
                    .padding(.horizontal, Spacing.standard)
                    .padding(.bottom, Spacing.s)
            }

            if !consultations.isEmpty {
                Divider().padding(.horizontal, Spacing.s)
                RoleConsultationsPanel(consultations: consultations, isExpanded: $showConsultations)
            }

            if let pad = scratchpad, !pad.isEmpty {
                Divider().padding(.horizontal, Spacing.s)
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

    /// True when a Correct action makes sense: task paused and the role's step is paused too.
    private var canCorrect: Bool {
        isPaused && selectedStep?.status == .paused
    }

    // MARK: - Primary Row

    private var primaryRow: some View {
        HStack(spacing: Spacing.s) {
            ActivityFeedRoleAvatar(role: resolvedRole, roleDefinition: roleDef, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(roleDefinitions.roleName(for: roleID))
                    .font(Typography.subheadlineSemibold)
                    .lineLimit(1)

                RoleStatusPill(
                    roleDefinition: roleDef,
                    statusName: displayStatusName,
                    statusColor: displayStatusColor
                )
            }

            Spacer()

            HStack(spacing: Spacing.xs) {
                if !isReadOnly, onCorrect != nil, canCorrect {
                    Button {
                        isShowingCorrectSheet = true
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Correct role")
                    .accessibilityLabel("Correct role")
                }

                if !isReadOnly, onRestart != nil, roleStatus.canRestart {
                    Button {
                        isShowingRestartSheet = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
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
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Deselect role (Escape)")
                .accessibilityLabel("Deselect role")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(roleDefinitions.roleName(for: roleID)), \(roleStatus.displayName)")
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
        artifacts: [Artifact(name: "Engineering Notes", icon: "doc.text.fill", description: "Implementation details")],
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
        artifacts: [Artifact(name: "Product Requirements", icon: "doc.text.fill", description: "PRD v1")]
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
        expectedArtifacts: ["Code Review"],
        status: .needsApproval,
        artifacts: [Artifact(name: "Code Review", icon: "checkmark.shield.fill", description: "Review report")]
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
        artifacts: [Artifact(name: "Product Requirements", icon: "doc.text.fill", description: "PRD")]
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
