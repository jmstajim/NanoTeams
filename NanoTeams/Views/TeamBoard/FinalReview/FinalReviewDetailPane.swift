import SwiftUI

// MARK: - Final Review Detail Pane

/// Right-side detail pane showing selected artifact content for Supervisor review.
struct FinalReviewDetailPane: View {
    let selectedItem: FinalReviewItem?
    let selectedArtifactName: String?
    let contentCache: [String: String]
    let supervisorTask: String
    let roleDefinitions: [TeamRoleDefinition]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let item = selectedItem {
                    artifactDetail(item)
                } else {
                    emptyDetail
                }
            }
            .transition(.opacity)
            .animationWithReduceMotion(.easeInOut(duration: 0.2), value: selectedArtifactName)
        }
    }

    private func artifactDetail(_ item: FinalReviewItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack {
                    Text(item.name)
                        .font(.title3.weight(.semibold))

                    Spacer()

                    Label(
                        item.isReady ? "Ready" : "Missing",
                        systemImage: item.isReady ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(item.isReady ? Colors.success : Colors.warning)
                }

                Divider()

                if item.isReady {
                    if let produced = item.produced {
                        Text("Produced by \(roleDefinitions.roleName(for: produced.roleID))")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let content = contentCache[item.name] {
                            contentView(content: content, artifact: produced.artifact)
                        } else {
                            HStack(spacing: Spacing.s) {
                                NTMSLoader(.small)
                                Text("Loading artifact content...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                        }
                    } else if item.name == SystemTemplates.supervisorTaskArtifactName {
                        contentView(
                            content: supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines),
                            artifact: nil
                        )
                    }
                } else {
                    missingArtifactBanner
                }
            }
            .padding()
        }
    }

    private func contentView(content: String, artifact: Artifact?) -> some View {
        Group {
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("(No content)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isMarkdown(artifact: artifact) {
                Text(.init(content))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(content)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                .fill(Colors.surfaceOverlay)
        )
    }

    private var missingArtifactBanner: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("Artifact not available", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(Colors.warning)

            Text("This artifact is required by Supervisor review settings but was not produced in the run.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                .fill(Colors.warningTint)
        )
    }

    private var emptyDetail: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Select an artifact to review")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isMarkdown(artifact: Artifact?) -> Bool {
        if let artifact {
            return artifact.mimeType == "text/markdown" || artifact.name.lowercased().hasSuffix(".md")
        }
        return true
    }
}

#Preview("With Content") {
    FinalReviewDetailPane(
        selectedItem: FinalReviewItem(
            name: "Product Requirements",
            produced: Run.ProducedArtifactRecord(
                artifact: Artifact(name: "Product Requirements"),
                roleID: "pm-1"
            ),
            isReady: true
        ),
        selectedArtifactName: "Product Requirements",
        contentCache: [
            "Product Requirements": """
            # Product Requirements

            ## Overview
            Build a **notification system** for real-time alerts across the platform.

            ## Goals
            1. Push notification support (APNs + FCM)
            2. Email fallback for offline users
            3. User preferences per notification channel

            ## Acceptance Criteria
            - Users can toggle notification types in Settings
            - Delivery latency < 500ms for push notifications
            - Rate limiting: max 10 notifications/minute per user
            """
        ],
        supervisorTask: "",
        roleDefinitions: [
            TeamRoleDefinition(id: "pm-1", name: "Product Manager", icon: "doc.text.fill", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies()),
        ]
    )
    .frame(width: 500, height: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Missing Artifact") {
    FinalReviewDetailPane(
        selectedItem: FinalReviewItem(name: "Release Notes", produced: nil, isReady: false),
        selectedArtifactName: "Release Notes",
        contentCache: [:],
        supervisorTask: "",
        roleDefinitions: []
    )
    .frame(width: 500, height: 300)
    .background(Colors.surfacePrimary)
}

#Preview("No Selection") {
    FinalReviewDetailPane(
        selectedItem: nil,
        selectedArtifactName: nil,
        contentCache: [:],
        supervisorTask: "",
        roleDefinitions: []
    )
    .frame(width: 500, height: 300)
    .background(Colors.surfacePrimary)
}
