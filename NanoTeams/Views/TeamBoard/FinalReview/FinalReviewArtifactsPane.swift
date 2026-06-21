import SwiftUI

// MARK: - Final Review Artifacts Pane

/// Left sidebar pane listing required and additional artifacts with completion status.
///
/// Custom `LazyVStack` instead of the native `List(selection:).listStyle(.sidebar)` —
/// the system sidebar list uses the OS accent for selection (blue dark fill) and
/// brings its own bezel chrome, both of which fight the terminal palette. Same
/// approach as `ArtifactListView.artifactList` / `RoleListView.roleList`.
struct FinalReviewArtifactsPane: View {
    let reviewItems: [FinalReviewItem]
    let additionalItems: [FinalReviewItem]
    @Binding var selectedArtifactName: String?
    let roleDefinitions: [TeamRoleDefinition]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                MonoLabel(text: "Required Artifacts", marker: true)
                Spacer()
                Text("\(reviewItems.count)")
                    .font(Typography.term2xs.monospacedDigit())
                    .foregroundStyle(Colors.textTertiary)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(Colors.surfaceBackground)

            TerminalDivider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
                    ForEach(reviewItems) { item in
                        SelectableArtifactReviewRow(
                            item: item,
                            isSelected: selectedArtifactName == item.name,
                            roleDefinitions: roleDefinitions,
                            onSelect: { selectedArtifactName = item.name }
                        )
                    }

                    if !additionalItems.isEmpty {
                        HStack {
                            MonoLabel(text: "Additional Artifacts", rule: true)
                            Spacer()
                        }
                        .padding(.horizontal, Spacing.s)
                        .padding(.top, Spacing.s)
                        .padding(.bottom, Spacing.xxs)

                        ForEach(additionalItems) { item in
                            SelectableArtifactReviewRow(
                                item: item,
                                isSelected: selectedArtifactName == item.name,
                                roleDefinitions: roleDefinitions,
                                onSelect: { selectedArtifactName = item.name }
                            )
                        }
                    }
                }
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xs)
            }
        }
        .background(Colors.surfaceBackground)
    }
}

// MARK: - Selectable Row

/// DS-styled selectable row — terminal selection (`accentTint` fill +
/// `surfaceHover` on hover, `CornerRadius.small`). Replaces the native
/// `.sidebar` list row's system-blue pill highlight.
private struct SelectableArtifactReviewRow: View {
    let item: FinalReviewItem
    let isSelected: Bool
    let roleDefinitions: [TeamRoleDefinition]
    let onSelect: () -> Void

    @State private var isHovered = false

    private var rowBackground: Color {
        if isSelected { return Colors.accentTint }
        if isHovered { return Colors.surfaceHover }
        return .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs + 2) {
                StatusGlyph(
                    glyph: item.isReady ? TerminalGlyph.done : TerminalGlyph.idle,
                    color: item.isReady ? Colors.success : Colors.textTertiary
                )

                Text(item.name)
                    .font(Typography.termSm)
                    .foregroundStyle(Colors.textPrimary)
                    .lineLimit(1)
            }

            byline
                .padding(.leading, Spacing.m + Spacing.xs)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs + 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle.squircle(CornerRadius.small))
        .contentShape(RoundedRectangle.squircle(CornerRadius.small))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var byline: some View {
        if let produced = item.produced {
            Text("by \(roleDefinitions.roleName(for: produced.roleID))")
                .font(Typography.term2xs)
                .foregroundStyle(Colors.textTertiary)
                .lineLimit(1)
        } else if item.name == SystemTemplates.supervisorTaskArtifactName, item.isReady {
            Text("by Supervisor")
                .font(Typography.term2xs)
                .foregroundStyle(Colors.textTertiary)
                .lineLimit(1)
        } else {
            Text("not produced")
                .font(Typography.term2xs)
                .foregroundStyle(Colors.warning)
                .lineLimit(1)
        }
    }
}

#Preview("Selected Item") {
    @Previewable @State var selected: String? = "Product Requirements"
    let defs = [
        TeamRoleDefinition(id: "pm-1", name: "Product Manager", icon: "doc.text", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies()),
        TeamRoleDefinition(id: "tl-1", name: "Tech Lead", icon: "cpu", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies()),
        TeamRoleDefinition(id: "tpm-1", name: "TPM", icon: "calendar", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies()),
    ]
    FinalReviewArtifactsPane(
        reviewItems: [
            FinalReviewItem(
                name: "Product Requirements",
                produced: Run.ProducedArtifactRecord(artifact: Artifact(name: "Product Requirements"), roleID: "pm-1"),
                isReady: true
            ),
            FinalReviewItem(
                name: "Implementation Plan",
                produced: Run.ProducedArtifactRecord(artifact: Artifact(name: "Implementation Plan"), roleID: "tl-1"),
                isReady: true
            ),
            FinalReviewItem(name: "Release Notes", produced: nil, isReady: false),
            FinalReviewItem(
                name: "Engineering Notes",
                produced: Run.ProducedArtifactRecord(artifact: Artifact(name: "Engineering Notes"), roleID: "tpm-1"),
                isReady: true
            ),
        ],
        additionalItems: [
            FinalReviewItem(
                name: "Design Spec",
                produced: Run.ProducedArtifactRecord(artifact: Artifact(name: "Design Spec"), roleID: "tl-1"),
                isReady: true
            ),
        ],
        selectedArtifactName: $selected,
        roleDefinitions: defs
    )
    .frame(width: 280, height: 340)
    .background(Colors.surfacePrimary)
}

#Preview("No Selection") {
    @Previewable @State var selected: String? = nil
    FinalReviewArtifactsPane(
        reviewItems: [
            FinalReviewItem(
                name: "Product Requirements",
                produced: Run.ProducedArtifactRecord(artifact: Artifact(name: "Product Requirements"), roleID: "pm-1"),
                isReady: true
            ),
            FinalReviewItem(name: "Release Notes", produced: nil, isReady: false),
        ],
        additionalItems: [],
        selectedArtifactName: $selected,
        roleDefinitions: [
            TeamRoleDefinition(id: "pm-1", name: "Product Manager", icon: "doc.text", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies()),
        ]
    )
    .frame(width: 280, height: 200)
    .background(Colors.surfacePrimary)
}
