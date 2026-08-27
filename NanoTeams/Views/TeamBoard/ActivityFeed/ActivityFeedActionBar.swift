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
        normalizedArtifacts.count { producedArtifacts.contains($0) }
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
                RoundedRectangle.squircle(CornerRadius.large)
                    .fill(isHovered ? Colors.surfaceHover : Colors.surfaceCard)
            )
            .animation(Animations.quick, value: isHovered)
            .onHover { hovering in hoveredCardID = hovering ? id : nil }
    }

    // MARK: - Task Completed Card

    private var taskCompletedCard: some View {
        cardChrome(id: "task-review") {
            HStack(spacing: Spacing.m) {
                StatusGlyph(
                    glyph: allArtifactsReady ? TerminalGlyph.done : TerminalGlyph.review,
                    color: allArtifactsReady ? Colors.success : Colors.purple,
                    font: Typography.termMd
                )
                .accessibilityHidden(true)

                // Title + subtitle
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.xs) {
                        MonoLabel(text: "Ready for Review")
                        if !normalizedArtifacts.isEmpty {
                            Text("\(readyCount)/\(normalizedArtifacts.count)")
                                .font(Typography.term2xs.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Colors.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle.squircle(CornerRadius.micro)
                                        .fill(Colors.surfaceElevated)
                                )
                        }
                    }
                    Text(reviewSubtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                }

                Spacer()

                // Review button — compact, right-aligned
                Button {
                    onReviewTask?()
                } label: {
                    Label("Review Task", systemImage: "eye.circle")
                        .font(Typography.captionSemibold)
                }
                .buttonStyle(.terminalPrimary)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Acceptance Card

    private func acceptanceCard(roleID: String, roleName: String) -> some View {
        cardChrome(id: "accept-\(roleID)") {
            HStack(spacing: Spacing.m) {
                StatusGlyph(glyph: TerminalGlyph.review, color: Colors.purple, font: Typography.termMd)
                    .accessibilityHidden(true)

                // Title + subtitle
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(roleName)
                        .font(Typography.subheadlineSemibold)
                        .foregroundStyle(Colors.textPrimary)
                    Text("Awaiting review")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                }

                Spacer()

                // Inline actions — compact row aligned right
                HStack(spacing: Spacing.s) {
                    if filterRoleID != roleID {
                        Button { onSelectRole?(roleID) } label: {
                            Image(systemName: "arrow.right.circle")
                                .font(Typography.termBase)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Colors.textSecondary)
                        .help("View role output")
                    }

                    Button { onRequestChanges?(roleID) } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(Typography.termBase)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Colors.warning)
                    .help("Request changes")

                    Button {
                        Task { await onAcceptRole?(roleID) }
                    } label: {
                        Label("Accept", systemImage: "checkmark")
                            .font(Typography.captionSemibold)
                    }
                    .buttonStyle(.terminalPrimary)
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
                    supervisorReviewArtifacts: ["Release Notes", "Engineering Notes"],
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
                    supervisorReviewArtifacts: ["Release Notes", "Engineering Notes", "Design Spec", "Code Review Summary", "Production Readiness"],
                    producedArtifacts: ["Release Notes", "Engineering Notes", "Design Spec"]
                )
            }
        }
        .padding()
    }
    .frame(width: 520, height: 900)
    .background(Colors.surfacePrimary)
}

// periphery:ignore - used in #Preview macros above
private func previewSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title)
            .font(Typography.term2xs.weight(.semibold))
            .foregroundStyle(Colors.textTertiary)
            .padding(.leading, Spacing.s)
        content()
    }
}

