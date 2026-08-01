import SwiftUI

// MARK: - Dependencies Tab

struct RoleEditorDependenciesTab: View {
    @Binding var editorState: RoleEditorState
    let isEditingSupervisor: Bool
    @Binding var team: Team

    @State private var showingNewArtifact = false
    @State private var newArtifactTargetIsProduced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                MonoLabel(text: "Artifact Dependencies", marker: true)
                    .padding(.horizontal, Spacing.standard)
                    .padding(.top, Spacing.m)

                if isEditingSupervisor {
                    supervisorDependenciesView
                        .padding(.horizontal, Spacing.standard)
                } else {
                    ArtifactDependencyEditor(
                        requiredArtifacts: $editorState.requiredArtifacts,
                        producedArtifacts: $editorState.producedArtifacts,
                        availableArtifacts: team.artifactNames,
                        excludeFromProduced: [SystemTemplates.supervisorTaskArtifactName],
                        onCreateNewForRequired: { showNewArtifactSheet(forProduced: false) },
                        onCreateNewForProduced: { showNewArtifactSheet(forProduced: true) }
                    )
                    .padding(.horizontal, Spacing.standard)
                }

                Text("Required artifacts must be produced by upstream roles before this role can start. Produced artifacts become available to downstream roles.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .padding(.horizontal, Spacing.standard)

                roleTypeBanner
                    .padding(.horizontal, Spacing.standard)
                    .padding(.bottom, Spacing.m)
            }
        }
        .sheet(isPresented: $showingNewArtifact) {
            ArtifactEditorSheet(team: $team, mode: .create) { artifact in
                autoAssignNewArtifact(artifact)
            }
        }
    }

    // MARK: - New Artifact

    private func showNewArtifactSheet(forProduced: Bool) {
        newArtifactTargetIsProduced = forProduced
        showingNewArtifact = true
    }

    /// Assign the artifact the sheet just created to whichever list the user
    /// opened it from.
    ///
    /// Takes the artifact from the callback rather than diffing
    /// `team.artifactNames` against a pre-sheet snapshot, which could never
    /// work: `onSave` fires in the same synchronous turn as the sheet's `team`
    /// Binding write, and that setter is async (`Task { await
    /// store.mutateWorkFolder … }`), so `team` here is still the pre-write
    /// snapshot and the diff was always empty — the auto-assign silently never
    /// fired.
    private func autoAssignNewArtifact(_ artifact: TeamArtifact) {
        let name = artifact.name
        if newArtifactTargetIsProduced {
            guard !editorState.producedArtifacts.contains(name) else { return }
            editorState.producedArtifacts.append(name)
        } else {
            guard !editorState.requiredArtifacts.contains(name) else { return }
            editorState.requiredArtifacts.append(name)
        }
    }

    // MARK: - Supervisor Layout

    private var supervisorDependenciesView: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.xs) {
                    Text("↓").font(Typography.termSm).foregroundStyle(Colors.info)
                    MonoLabel(text: "Required Artifacts")
                }

                ArtifactSelectorView(
                    selected: $editorState.requiredArtifacts,
                    availableArtifacts: team.artifactNames,
                    placeholder: "This role doesn't require any artifacts",
                    onCreateNew: { showNewArtifactSheet(forProduced: false) }
                )
            }

            TerminalDivider()

            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Text("↑").font(Typography.termSm).foregroundStyle(Colors.artifact)
                    MonoLabel(text: "Produced Artifacts")
                    Text("(locked)")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                }

                Text(SystemTemplates.supervisorTaskArtifactName)
                    .font(Typography.caption)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xs)
                    .background(
                        RoundedRectangle.squircle(CornerRadius.small)
                            .fill(Colors.surfaceCard)
                    )

                    .padding(Spacing.m)
            }
        }
    }

    // MARK: - Role Type Banner

    @ViewBuilder
    private var roleTypeBanner: some View {
        if !isEditingSupervisor {
            if !editorState.producedArtifacts.isEmpty {
                roleTypeRow(
                    glyph: TerminalGlyph.bullet,
                    color: Colors.artifact,
                    text: "Producing role \u{2014} completes when all deliverables are submitted via create_artifact."
                )
            } else if !editorState.requiredArtifacts.isEmpty {
                roleTypeRow(
                    glyph: TerminalGlyph.bullet,
                    color: Colors.teal,
                    text: "Chat role \u{2014} responds continuously; no deliverables."
                )
            } else {
                roleTypeRow(
                    glyph: TerminalGlyph.skipped,
                    color: Colors.textTertiary,
                    text: "Observer role \u{2014} participates only via consultations and meetings."
                )
            }
        }
    }

    private func roleTypeRow(glyph: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            StatusGlyph(glyph: glyph, color: color)
            Text(text)
                .font(Typography.caption)
                .foregroundStyle(color)
        }
    }
}

#Preview("Producing Role") {
    @Previewable @State var state = RoleEditorState(
        roleName: "Software Engineer",
        requiredArtifacts: ["Implementation Plan", "Design Spec"],
        producedArtifacts: ["Engineering Notes"]
    )
    @Previewable @State var team = Team.default
    RoleEditorDependenciesTab(
        editorState: $state,
        isEditingSupervisor: false,
        team: $team
    )
    .frame(width: 500, height: 400)
    .background(Colors.surfacePrimary)
}

#Preview("Supervisor") {
    @Previewable @State var state = RoleEditorState(
        roleName: "Supervisor",
        requiredArtifacts: ["Release Notes"],
        producedArtifacts: ["Supervisor Task"]
    )
    @Previewable @State var team = Team.default
    RoleEditorDependenciesTab(
        editorState: $state,
        isEditingSupervisor: true,
        team: $team
    )
    .frame(width: 500, height: 400)
    .background(Colors.surfacePrimary)
}
