import SwiftUI

// MARK: - Role Node Runtime View

/// A role node in the runtime graph showing execution status.
struct RoleNodeRuntimeView: View {
    let roleID: String
    let roleName: String
    let roleIcon: String
    let status: RoleExecutionStatus
    let isSelected: Bool
    let position: CGPoint
    let onSelect: () -> Void
    var onRestart: (() -> Void)? = nil
    var onFinish: (() -> Void)? = nil
    var onCorrect: (() -> Void)? = nil
    var isAdvisory: Bool = false
    var isPaused: Bool = false
    var isEngineRunning: Bool = true
    var isInMeeting: Bool = false
    var isReviewNode: Bool = false
    var roleTintColor: Color = Colors.neutral

    @State private var isHovered = false

    private var canRestart: Bool { onRestart != nil && status.canRestart }
    /// Matches `NTMSOrchestrator.correctRole` acceptance: the orchestrator only
    /// requires engine `.paused` + a paused step. The role's own status can sit at
    /// `.working` (normal pause) or `.idle`/`.ready` (post-app-restart recovery),
    /// so allow any non-terminal role here — the orchestrator re-verifies and
    /// surfaces errors if the user picks a role that can't actually be corrected.
    private var canCorrect: Bool {
        guard onCorrect != nil, isPaused else { return false }
        switch status {
        case .idle, .ready, .working, .revisionRequested:
            return true
        case .needsAcceptance, .accepted, .done, .failed, .skipped:
            return false
        }
    }

    private static let nodeMaxWidth: CGFloat = GraphTokens.nodeMaxWidth

    private var statusDisplayName: String {
        if isReviewNode { return "Review" }
        return status.displayName(isInMeeting: isInMeeting, isPaused: isPaused)
    }
    private var statusDisplayColor: Color {
        if isReviewNode { return Colors.purple }
        return status.displayColor(isInMeeting: isInMeeting, isPaused: isPaused)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                // Role icon in subtle container
                ZStack {
                    Circle()
                        .fill(Colors.surfaceElevated)
                        .frame(width: 32, height: 32)
                    Image(systemName: roleIcon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status == .idle ? roleTintColor : statusDisplayColor)
                }

                // Role name
                Text(roleName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                // Status label
                Text(statusDisplayName)
                    .font(.caption2)
                    .foregroundStyle(statusDisplayColor)
            }
            .padding(8)
            .frame(minWidth: 80, maxWidth: Self.nodeMaxWidth, minHeight: 60)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous)
                    .fill(isHovered ? Colors.surfaceElevated : Colors.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous)
                    .stroke(nodeStyle.borderColor, lineWidth: nodeStyle.borderWidth)
            )
            
            .overlay(alignment: .topTrailing) {
                meetingBadge
            }
            .opacity(nodeStyle.opacity)
        }
        .buttonStyle(.plain)
        .trackHover($isHovered)
        .position(position)
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label("View Details", systemImage: "info.circle")
            }

            if canCorrect {
                Divider()

                Button {
                    onCorrect?()
                } label: {
                    Label("Correct Role…", systemImage: "arrow.uturn.backward.circle")
                }
            }

            if canRestart {
                if !canCorrect { Divider() }

                Button {
                    onRestart?()
                } label: {
                    Label("Restart Role", systemImage: "arrow.counterclockwise.circle")
                }
            }

            if isAdvisory && onFinish != nil && (status == .ready || status == .working) {
                Button {
                    onFinish?()
                } label: {
                    Label("Finish Role", systemImage: "checkmark.circle")
                }
            }

            Divider()

            Button {
                let info = "\(roleName) (\(roleID))\nStatus: \(status.displayName)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info, forType: .string)
            } label: {
                Label("Copy Role Info", systemImage: "doc.on.doc")
            }
        }
        .accessibilityLabel("\(roleName), \(statusDisplayName)")
        .accessibilityHint("Tap to view role details. Right-click for more actions.")
        .animationWithReduceMotion(.spring(response: 0.3), value: isSelected)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    // MARK: - Meeting Badge

    @ViewBuilder
    private var meetingBadge: some View {
        if isInMeeting {
            Circle()
                .fill(Colors.purple)
                .frame(width: 8, height: 8)
                .offset(x: 4, y: -4)
        }
    }

    // MARK: - Node Style

    private var nodeStyle: RoleNodeStyle {
        var style = status.nodeStyle

        // Supervisor node during task review — purple without glow
        if isReviewNode {
            return RoleNodeStyle(
                borderColor: Colors.purple,
                borderWidth: 2,
                backgroundColor: Colors.purpleTint,
                glowRadius: 0,
                shouldAnimate: false,
                opacity: 1.0
            )
        }

        // When paused and working, show paused style (no animation)
        if isPaused && status == .working {
            style = RoleNodeStyle(
                borderColor: Colors.warning,
                borderWidth: style.borderWidth,
                backgroundColor: Colors.warningTint,
                glowRadius: 0,
                shouldAnimate: false,
                opacity: 1.0
            )
        }

        // Override border if selected
        if isSelected {
            return RoleNodeStyle(
                borderColor: Colors.accent,
                borderWidth: 2,
                backgroundColor: style.backgroundColor,
                glowRadius: 0,
                shouldAnimate: false,
                opacity: 1.0
            )
        }

        return style
    }
}

// MARK: - Preview

#Preview("Core States") {
    ZStack {
        RoleNodeRuntimeView(
            roleID: "swe", roleName: "Software Engineer", roleIcon: "laptopcomputer",
            status: .working, isSelected: false, position: CGPoint(x: 100, y: 80),
            onSelect: {}
        )
        RoleNodeRuntimeView(
            roleID: "pm", roleName: "Product Manager", roleIcon: "chart.bar.doc.horizontal",
            status: .done, isSelected: true, position: CGPoint(x: 260, y: 80),
            onSelect: {}
        )
        RoleNodeRuntimeView(
            roleID: "cr", roleName: "Code Reviewer", roleIcon: "magnifyingglass",
            status: .idle, isSelected: false, position: CGPoint(x: 100, y: 200),
            onSelect: {}
        )
        RoleNodeRuntimeView(
            roleID: "tl", roleName: "Tech Lead", roleIcon: "wrench.and.screwdriver",
            status: .needsAcceptance, isSelected: false, position: CGPoint(x: 260, y: 200),
            onSelect: {}, isInMeeting: true
        )
    }
    .frame(width: 380, height: 300)
    .background(Colors.surfacePrimary)
}

#Preview("Paused · Failed · Skipped") {
    ZStack {
        RoleNodeRuntimeView(
            roleID: "swe", roleName: "Software Engineer", roleIcon: "laptopcomputer",
            status: .working, isSelected: false, position: CGPoint(x: 100, y: 80),
            onSelect: {}, isPaused: true
        )
        RoleNodeRuntimeView(
            roleID: "pm", roleName: "Product Manager", roleIcon: "chart.bar.doc.horizontal",
            status: .failed, isSelected: false, position: CGPoint(x: 260, y: 80),
            onSelect: {}
        )
        RoleNodeRuntimeView(
            roleID: "cr", roleName: "Code Reviewer", roleIcon: "magnifyingglass",
            status: .skipped, isSelected: false, position: CGPoint(x: 100, y: 200),
            onSelect: {}
        )
        RoleNodeRuntimeView(
            roleID: "tpm", roleName: "TPM", roleIcon: "list.clipboard",
            status: .revisionRequested, isSelected: false, position: CGPoint(x: 260, y: 200),
            onSelect: {}
        )
    }
    .frame(width: 380, height: 300)
    .background(Colors.surfacePrimary)
}

#Preview("Review · Ready") {
    ZStack {
        RoleNodeRuntimeView(
            roleID: "sre", roleName: "SRE", roleIcon: "server.rack",
            status: .working, isSelected: false, position: CGPoint(x: 100, y: 80),
            onSelect: {}
        )
        RoleNodeRuntimeView(
            roleID: "sup", roleName: "Supervisor", roleIcon: "person.circle",
            status: .needsAcceptance, isSelected: false, position: CGPoint(x: 260, y: 80),
            onSelect: {}, isReviewNode: true
        )
        RoleNodeRuntimeView(
            roleID: "tl", roleName: "Tech Lead", roleIcon: "wrench.and.screwdriver",
            status: .ready, isSelected: false, position: CGPoint(x: 100, y: 200),
            onSelect: {}
        )
        RoleNodeRuntimeView(
            roleID: "uxd", roleName: "UX Designer", roleIcon: "paintbrush",
            status: .accepted, isSelected: false, position: CGPoint(x: 260, y: 200),
            onSelect: {}
        )
    }
    .frame(width: 380, height: 300)
    .background(Colors.surfacePrimary)
}
