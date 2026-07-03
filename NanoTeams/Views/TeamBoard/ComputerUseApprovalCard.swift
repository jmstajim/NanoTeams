import AppKit
import SwiftUI

// MARK: - Computer-use approval card list

/// The held computer-use action approval cards for `taskID`. Rendered at the activity-feed
/// level (like the bash approval cards) so the gate's in-loop await always has reachable
/// Allow/Deny buttons. Self-hides when nothing is held.
struct ComputerUseApprovalCardList: View {
    let taskID: Int
    let roleDefinitions: [TeamRoleDefinition]

    @Environment(NTMSOrchestrator.self) private var store

    nonisolated static func sortedRequests(
        for taskID: Int, from all: [TaskStepKey: ComputerUseApprovalRequest]
    ) -> [ComputerUseApprovalRequest] {
        all.filter { $0.key.taskID == taskID }
            .map(\.value)
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ForEach(Self.sortedRequests(for: taskID, from: store.computerUseApprovalRequests)) { request in
            ComputerUseApprovalCard(
                taskID: taskID,
                request: request,
                roleName: roleDefinitions.first(where: { $0.id == request.stepID })?.name ?? request.stepID)
        }
    }
}

// MARK: - Computer-use approval card

/// A computer-use action HELD by the gate awaiting the human's decision. Shows a preview of the
/// last screenshot so the Supervisor can see what the model is about to touch. Allow / Deny
/// resolve the gate's await directly (bypassing the model); "Always allow in <app>" also records
/// a per-run grant.
private struct ComputerUseApprovalCard: View {
    let taskID: Int
    let request: ComputerUseApprovalRequest
    let roleName: String

    @Environment(NTMSOrchestrator.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "cursorarrow.rays")
                    .accessibilityHidden(true)
                Text("\(roleName) wants to control the screen")
            }
            .font(Typography.caption.weight(.medium))
            .foregroundStyle(Colors.textSecondary)

            Text(request.actionSummary)
                .font(Typography.monoCaption)
                .foregroundStyle(Colors.textPrimary)
                .textSelection(.enabled)
                .lineLimit(3)
                .padding(Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle.squircle(CornerRadius.micro).fill(Colors.surfaceOverlay))

            if let preview = previewImage {
                preview
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle.squircle(CornerRadius.micro))
                    .overlay(
                        RoundedRectangle.squircle(CornerRadius.micro).strokeBorder(Colors.borderSubtle, lineWidth: 1))
            }

            HStack(spacing: Spacing.xs) {
                Button("Allow") { resolve(.allow) }
                    .buttonStyle(.terminalPrimary)
                Button("Deny") { resolve(.deny) }
                    .buttonStyle(.terminalDanger)
                if request.offerAlways, let app = request.targetApp {
                    Button("Always allow in \(app)") { resolve(.alwaysAllowApp) }
                        .buttonStyle(.terminalGhost)
                }
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.surfaceElevated))
    }

    private var previewImage: Image? {
        guard let b64 = request.screenshotBase64,
              let data = Data(base64Encoded: b64),
              let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
    }

    private func resolve(_ choice: ComputerUseApprovalChoice) {
        store.resolveComputerUseApproval(
            taskID: taskID, stepID: request.stepID, actionKey: request.actionKey, choice: choice)
    }
}
