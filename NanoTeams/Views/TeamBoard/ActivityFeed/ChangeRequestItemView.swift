import SwiftUI

/// Renders a single change request card with status badge.
struct ChangeRequestItemView: View {
    let request: ChangeRequest
    let targetRoleName: String

    private var requesterRole: Role {
        Role.builtInRole(for: request.requestingRoleID) ?? .custom(id: request.requestingRoleID)
    }

    private var requesterName: String {
        requesterRole.displayName
    }

    var body: some View {
        HStack(alignment: .top, spacing: ActivityCardTokens.cardPadding) {
            ActivityFeedIconAvatar(icon: "arrow.triangle.2.circlepath", color: Colors.warning)

            VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
                HStack(spacing: Spacing.s) {
                    Text(requesterName)
                        .font(Typography.captionSemibold)
                        .foregroundStyle(requesterRole.tintColor)
                    Image(systemName: "arrow.right").font(Typography.term2xs).foregroundStyle(Colors.textSecondary)
                    Text(targetRoleName).font(Typography.captionSemibold).foregroundStyle(Colors.textSecondary)
                    statusBadge(request.status)
                    Spacer()
                    Text(request.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(Typography.term2xs).foregroundStyle(Colors.textTertiary)
                }

                contentCard
            }
        }
    }

    // MARK: - Content Card

    private var contentCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            MonoLabel(text: "Changes Requested", size: .xs)

            Text(request.changes)
                .font(Typography.termBase)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !request.reasoning.isEmpty {
                Text("Reasoning: \(request.reasoning)")
                    .font(Typography.termBase)
                    .foregroundStyle(Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.leading, Spacing.s)
        .overlay(alignment: .leading) {
            RoundedRectangle.squircle(CornerRadius.accent)
                .fill(Colors.warning)
                .frame(width: 2)
                .padding(.vertical, 4)
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private func statusBadge(_ status: ChangeRequestStatus) -> some View {
        Text(status.displayName)
            .font(Typography.term2xs.weight(.medium))
            .foregroundStyle(status.statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle.squircle(CornerRadius.micro).fill(status.statusTintColor))
    }
}

// MARK: - Equatable

/// See `MessageBubbleView`'s Equatable extension for full rationale.
/// `ChangeRequest` is `Hashable`; both props are value types.
extension ChangeRequestItemView: Equatable {
    static func == (lhs: ChangeRequestItemView, rhs: ChangeRequestItemView) -> Bool {
        lhs.request == rhs.request && lhs.targetRoleName == rhs.targetRoleName
    }
}

#Preview {
    VStack(spacing: 16) {
        ChangeRequestItemView(
            request: ChangeRequest(
                id: UUID(),
                createdAt: Date(),
                requestingRoleID: "code_reviewer",
                targetRoleID: "software_engineer",
                changes: "The error handling in fetchData() is incomplete. Add proper try/catch blocks around the network calls.",
                reasoning: "Unhandled errors will crash the app in production.",
                status: .pending
            ),
            targetRoleName: "Software Engineer"
        )
        ChangeRequestItemView(
            request: ChangeRequest(
                id: UUID(),
                createdAt: Date(),
                requestingRoleID: "sre",
                targetRoleID: "software_engineer",
                changes: "Add retry logic to the API client.",
                reasoning: "Production reliability requirement.",
                status: .approved
            ),
            targetRoleName: "Software Engineer"
        )
    }
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}
