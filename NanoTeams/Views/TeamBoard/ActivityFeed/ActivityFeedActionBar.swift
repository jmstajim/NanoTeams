import SwiftUI

/// Sticky bottom bar showing acceptance and task completion actions.
/// Bold hierarchy, pill CTAs, generous spacing.
/// Uses callback injection instead of @Environment for low coupling (GRASP).
struct ActivityFeedActionBar: View {
    let isFinalReviewStage: Bool
    let rolesNeedingAcceptance: [(roleID: String, roleName: String)]
    var onSelectRole: ((String) -> Void)? = nil
    var onReviewTask: (() -> Void)? = nil
    var onAcceptRole: ((String) async -> Void)? = nil
    var onRequestChanges: ((String) -> Void)? = nil
    var filterRoleID: String? = nil
    var supervisorReviewArtifacts: [String] = []
    var producedArtifacts: Set<String> = []

    @State private var hoveredCardID: String? = nil

    var body: some View {
        VStack(spacing: Spacing.m) {
            if isFinalReviewStage { taskCompletedCard }

            ForEach(rolesNeedingAcceptance, id: \.roleID) { entry in
                acceptanceCard(roleID: entry.roleID, roleName: entry.roleName)
            }
        }
        .padding(Spacing.m)
    }

    // MARK: - Helpers

    private var normalizedArtifacts: [String] {
        supervisorReviewArtifacts.normalizedUnique()
    }

    private var readyCount: Int {
        normalizedArtifacts.filter { producedArtifacts.contains($0) }.count
    }

    private var allArtifactsReady: Bool {
        !normalizedArtifacts.isEmpty && readyCount == normalizedArtifacts.count
    }

    private var reviewSubtitle: String {
        if normalizedArtifacts.isEmpty { return "Review before accepting" }
        if allArtifactsReady { return "All deliverables complete" }
        return "Review deliverables before accepting"
    }

    // MARK: - Shared Card Chrome

    /// Applies hover-reactive chrome to a card view.
    private func cardChrome<Content: View>(
        id: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isHovered = hoveredCardID == id
        return content()
            .padding(Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous)
                    .fill(isHovered ? Colors.surfaceHover : Colors.surfaceCard)
            )
            .animation(Animations.quick, value: isHovered)
            .onHover { hovering in hoveredCardID = hovering ? id : nil }
    }

    // MARK: - Task Completed Card

    private var taskCompletedCard: some View {
        cardChrome(id: "task-review") {
            HStack(spacing: Spacing.m) {
                Image(systemName: allArtifactsReady ? "checkmark.seal.fill" : "clock.badge.checkmark")
                    .font(.title3)
                    .foregroundStyle(allArtifactsReady ? Colors.success : Colors.purple)
                    .accessibilityHidden(true)

                // Title + subtitle
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.xs) {
                        Text("Ready for Review")
                            .font(Typography.subheadlineSemibold)
                        if !normalizedArtifacts.isEmpty {
                            Text("\(readyCount)/\(normalizedArtifacts.count)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Colors.surfaceElevated)
                                )
                        }
                    }
                    Text(reviewSubtitle)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Review button — compact, right-aligned
                Button {
                    onReviewTask?()
                } label: {
                    Label("Review Task", systemImage: "eye.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Colors.purple)
                .clipShape(Capsule(style: .continuous))
                .controlSize(.small)
            }
        }
    }

    // MARK: - Acceptance Card

    private func acceptanceCard(roleID: String, roleName: String) -> some View {
        cardChrome(id: "accept-\(roleID)") {
            HStack(spacing: Spacing.m) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.title3)
                    .foregroundStyle(Colors.purple)
                    .accessibilityHidden(true)

                // Title + subtitle
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(roleName)
                        .font(Typography.subheadlineSemibold)
                    Text("Awaiting review")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Inline actions — compact row aligned right
                HStack(spacing: Spacing.s) {
                    if filterRoleID != roleID {
                        Button { onSelectRole?(roleID) } label: {
                            Image(systemName: "arrow.right.circle")
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("View role output")
                    }

                    Button { onRequestChanges?(roleID) } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Colors.warning)
                    .help("Request changes")

                    Button {
                        Task { await onAcceptRole?(roleID) }
                    } label: {
                        Label("Accept", systemImage: "checkmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Colors.success)
                    .clipShape(Capsule(style: .continuous))
                    .controlSize(.small)
                }
            }
        }
    }

}

// MARK: - Previews

#Preview("All States") {
    ScrollView {
        VStack(spacing: 24) {
            // Empty — no cards
            previewSection("Empty") {
                ActivityFeedActionBar(
                    isFinalReviewStage: false,
                    rolesNeedingAcceptance: []
                )
            }

            // Task review — no artifacts
            previewSection("Task Review — No Artifacts") {
                ActivityFeedActionBar(
                    isFinalReviewStage: true,
                    rolesNeedingAcceptance: []
                )
            }

            // Task review — partial artifacts
            previewSection("Task Review — Partial Artifacts") {
                ActivityFeedActionBar(
                    isFinalReviewStage: true,
                    rolesNeedingAcceptance: [],
                    supervisorReviewArtifacts: ["Release Notes", "Engineering Notes", "Build Diagnostics"],
                    producedArtifacts: ["Release Notes", "Engineering Notes"]
                )
            }

            // Task review — all artifacts ready
            previewSection("Task Review — All Ready") {
                ActivityFeedActionBar(
                    isFinalReviewStage: true,
                    rolesNeedingAcceptance: [],
                    supervisorReviewArtifacts: ["Release Notes", "Engineering Notes"],
                    producedArtifacts: ["Release Notes", "Engineering Notes"]
                )
            }

            // Acceptance — single role
            previewSection("Acceptance — Single Role") {
                ActivityFeedActionBar(
                    isFinalReviewStage: false,
                    rolesNeedingAcceptance: [
                        (roleID: "swe-1", roleName: "Software Engineer")
                    ]
                )
            }

            // Acceptance — multiple roles
            previewSection("Acceptance — Multiple Roles") {
                ActivityFeedActionBar(
                    isFinalReviewStage: false,
                    rolesNeedingAcceptance: [
                        (roleID: "pm-1", roleName: "Product Manager"),
                        (roleID: "tl-1", roleName: "Tech Lead")
                    ]
                )
            }

            // Acceptance — filtered (navigate button hidden)
            previewSection("Acceptance — Filtered") {
                ActivityFeedActionBar(
                    isFinalReviewStage: false,
                    rolesNeedingAcceptance: [
                        (roleID: "pm-1", roleName: "Product Manager")
                    ],
                    filterRoleID: "pm-1"
                )
            }

            // Mixed — review + acceptance
            previewSection("Mixed — Review + Acceptance") {
                ActivityFeedActionBar(
                    isFinalReviewStage: true,
                    rolesNeedingAcceptance: [(roleID: "swe-1", roleName: "Software Engineer")],
                    supervisorReviewArtifacts: ["Release Notes"],
                    producedArtifacts: ["Release Notes"]
                )
            }

            // Mixed — full house
            previewSection("Mixed — Full House") {
                ActivityFeedActionBar(
                    isFinalReviewStage: true,
                    rolesNeedingAcceptance: [
                        (roleID: "pm-1", roleName: "Product Manager"),
                        (roleID: "tl-1", roleName: "Tech Lead"),
                        (roleID: "swe-1", roleName: "Software Engineer")
                    ],
                    supervisorReviewArtifacts: ["Release Notes", "Engineering Notes", "Design Spec", "Code Review", "Production Readiness"],
                    producedArtifacts: ["Release Notes", "Engineering Notes", "Design Spec"]
                )
            }
        }
        .padding()
    }
    .frame(width: 520, height: 900)
    .background(Colors.surfacePrimary)
}

private func previewSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.leading, Spacing.s)
        content()
    }
}

