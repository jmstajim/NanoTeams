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
        .background(Colors.surfacePrimary)
    }

    private func artifactDetail(_ item: FinalReviewItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                headerRow(for: item)

                if item.isReady {
                    if let produced = item.produced {
                        producerByline(roleID: produced.roleID)
                        contentPane(
                            title: item.name,
                            content: contentCache[item.name],
                            artifact: produced.artifact
                        )
                    } else if item.name == SystemTemplates.supervisorTaskArtifactName {
                        producerByline(roleID: nil)
                        contentPane(
                            title: item.name,
                            content: supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines),
                            artifact: nil
                        )
                    }
                } else {
                    missingArtifactBanner
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private func headerRow(for item: FinalReviewItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 0) {
                Text("artifact/")
                    .font(Typography.termLg)
                    .foregroundStyle(Colors.textTertiary)
                Text(item.name)
                    .font(Typography.termLg)
                    .foregroundStyle(Colors.textPrimary)
            }
            .lineLimit(1)

            Spacer()

            statusBadge(isReady: item.isReady)
        }
        .accessibilityElement(children: .combine)
    }

    private func statusBadge(isReady: Bool) -> some View {
        let color = isReady ? Colors.success : Colors.warning
        let label = isReady ? "Ready" : "Missing"
        let glyph = isReady ? TerminalGlyph.done : TerminalGlyph.failed

        return HStack(spacing: Spacing.xxs) {
            Text(glyph)
                .font(Typography.termSm)
                .foregroundStyle(color)
            Text(label.uppercased())
                .font(Typography.term2xs)
                .tracking(Typography.labelTracking)
                .foregroundStyle(color)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(
            RoundedRectangle.squircle(CornerRadius.micro)
                .fill(color.opacity(DynamicTintOpacity.background))
        )
        .overlay(
            RoundedRectangle.squircle(CornerRadius.micro)
                .strokeBorder(color.opacity(DynamicTintOpacity.stroke), lineWidth: 1)
        )
        .fixedSize()
    }

    // MARK: - Producer byline

    @ViewBuilder
    private func producerByline(roleID: String?) -> some View {
        HStack(spacing: Spacing.xs) {
            Text("produced by")
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
            Text(roleID.map { roleDefinitions.roleName(for: $0) } ?? "Supervisor")
                .font(Typography.captionSemibold)
                .foregroundStyle(Colors.textSecondary)
        }
    }

    // MARK: - Content pane

    private func contentPane(title: String, content: String?, artifact: Artifact?) -> some View {
        TerminalPane(
            title: title,
            fill: Colors.surfaceCard,
            contentPadding: Spacing.m
        ) {
            Group {
                if let content {
                    if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("(no content)")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textTertiary)
                    } else if isMarkdown(artifact: artifact) {
                        Text(.init(content))
                            .font(Typography.termBase)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(content)
                            .font(Typography.termBase)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(spacing: Spacing.s) {
                        NTMSLoader(.small)
                        Text("Loading artifact content…")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Missing banner

    private var missingArtifactBanner: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                Text(TerminalGlyph.failed)
                    .font(Typography.termSm)
                    .foregroundStyle(Colors.warning)
                Text("Artifact not available")
                    .font(Typography.subheadlineSemibold)
                    .foregroundStyle(Colors.warning)
            }

            Text("This artifact is required by Supervisor review settings but was not produced in the run.")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.warningTint)
        )
        .overlay(
            RoundedRectangle.squircle(CornerRadius.small)
                .strokeBorder(Colors.warning.opacity(DynamicTintOpacity.stroke), lineWidth: 1)
        )
    }

    // MARK: - Empty

    private var emptyDetail: some View {
        NTMSEmptyState(
            title: "No Artifact Selected",
            message: "Pick an artifact on the left to review its content.",
            systemImage: "doc.text"
        )
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
            TeamRoleDefinition(id: "pm-1", name: "Product Manager", icon: "doc.text", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies()),
        ]
    )
    .frame(width: 600, height: 500)
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
    .frame(width: 600, height: 300)
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
    .frame(width: 600, height: 300)
    .background(Colors.surfacePrimary)
}
