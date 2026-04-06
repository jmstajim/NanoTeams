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
                HStack(spacing: 6) {
                    Text(requesterName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(requesterRole.tintColor)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    Text(targetRoleName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    statusBadge(request.status)
                    Spacer()
                    Text(request.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                contentCard
            }
        }
    }

    // MARK: - Content Card

    private var contentCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Changes Requested").font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            Text(request.changes)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !request.reasoning.isEmpty {
                Text("Reasoning: \(request.reasoning)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.leading, Spacing.s)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: CornerRadius.accent, style: .continuous)
                .fill(Colors.warning)
                .frame(width: 2)
                .padding(.vertical, 4)
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private func statusBadge(_ status: ChangeRequestStatus) -> some View {
        Text(status.displayName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(status.statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(status.statusColor.opacity(DynamicTintOpacity.badge)))
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
