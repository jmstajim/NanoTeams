import SwiftUI

// MARK: - Final Review Artifacts Pane

/// Left sidebar pane listing required and additional artifacts with completion status.
struct FinalReviewArtifactsPane: View {
    let reviewItems: [FinalReviewItem]
    let additionalItems: [FinalReviewItem]
    @Binding var selectedArtifactName: String?
    let roleDefinitions: [TeamRoleDefinition]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Required Artifacts")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding()
            .background(Colors.surfaceCard)

            Divider()

            List(selection: $selectedArtifactName) {
                Section {
                    ForEach(reviewItems) { item in
                        artifactRow(item)
                            .tag(Optional(item.name))
                    }
                }

                if !additionalItems.isEmpty {
                    Section {
                        ForEach(additionalItems) { item in
                            artifactRow(item)
                                .tag(Optional(item.name))
                        }
                    } header: {
                        Text("Additional Artifacts")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private func artifactRow(_ item: FinalReviewItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs + 2) {
                Image(systemName: item.isReady ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isReady ? Colors.success : .secondary)
                    .font(.caption)

                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(1)
            }

            if let produced = item.produced {
                Text("By \(roleDefinitions.roleName(for: produced.roleID))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if item.name == SystemTemplates.supervisorTaskArtifactName, item.isReady {
                Text("By Supervisor")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Not produced")
                    .font(.caption2)
                    .foregroundStyle(Colors.warning)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview("Selected Item") {
    @Previewable @State var selected: String? = "Product Requirements"
    let defs = [
        TeamRoleDefinition(id: "pm-1", name: "Product Manager", icon: "doc.text.fill", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies()),
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
            TeamRoleDefinition(id: "pm-1", name: "Product Manager", icon: "doc.text.fill", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies()),
        ]
    )
    .frame(width: 280, height: 200)
    .background(Colors.surfacePrimary)
}
