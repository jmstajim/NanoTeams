import SwiftUI

/// Track-row style: thin colored status bar on the leading edge, bold title, metadata below.
struct SidebarTaskRow: View {
    let task: SidebarTaskItem
    let isActive: Bool
    var isSelected: Bool = false

    @State private var isHovered = false

    private var rowBackground: Color {
        if isSelected { return Colors.accentTint }
        if isHovered { return Colors.surfaceHover }
        return .clear
    }

    private var statusColor: Color {
        if task.hasUnreadInput { return Colors.info }
        return task.status.tintColor(isChatMode: task.isChatMode)
    }
    private var statusLabel: String { task.status.displayLabel(isChatMode: task.isChatMode) }
    private var statusIcon: String { task.status.systemImageName(isChatMode: task.isChatMode) }

    private var statusMetadataRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) {
                statusIconView
                statusLabelView
                timestampView
            }

            HStack(spacing: Spacing.xs) {
                statusIconView
                statusLabelView
            }

            HStack(spacing: Spacing.xs) {
                statusIconView
                timestampView
            }
        }
    }

    private var statusIconView: some View {
        Image(systemName: statusIcon)
            .font(Typography.caption2)
            .foregroundStyle(statusColor)
            .symbolEffect(.pulse, options: .repeating, isActive: task.isEngineRunning && !task.hasUnreadInput)
    }

    private var statusLabelView: some View {
        Text(statusLabel)
            .font(Typography.caption)
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.85)
    }

    private var timestampView: some View {
        Text(task.updatedAt.relativeTimestamp)
            .font(Typography.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(task.title)
                    .font(isActive ? Typography.subheadlineSemibold : Typography.subheadlineMedium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                statusMetadataRow
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.medium)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Relative Timestamp

private extension Date {
    var relativeTimestamp: String {
        let interval = -timeIntervalSinceNow
        switch interval {
        case ..<60:          return "just now"
        case ..<3600:        return "\(Int(interval / 60))m ago"
        case ..<86400:       return "\(Int(interval / 3600))h ago"
        case ..<604800:      return "\(Int(interval / 86400))d ago"
        default:
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            return formatter.string(from: self)
        }
    }
}

// MARK: - Previews

#Preview("Task Row — All States") {
    VStack(alignment: .leading, spacing: 0) {
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Implement sorting algorithms", status: .running, updatedAt: Date(), isEngineRunning: true),
            isActive: true
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Refactor auth module", status: .running, updatedAt: Date(), isEngineRunning: true),
            isActive: false
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Add dark mode support", status: .paused, updatedAt: Date()),
            isActive: false
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Database migration", status: .waiting, updatedAt: Date()),
            isActive: false
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Design API endpoints", status: .needsSupervisorInput, updatedAt: Date()),
            isActive: true
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Build notification system", status: .needsSupervisorAcceptance, updatedAt: Date()),
            isActive: false
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Fix login bug", status: .done, updatedAt: Date()),
            isActive: false
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Deploy to production", status: .failed, updatedAt: Date()),
            isActive: false
        )
    }
    .padding(.horizontal, Spacing.s)
    .padding(.vertical, Spacing.xs)
    .frame(width: 260)
    .background(Colors.surfaceBackground)
}

#Preview("Task Row — Selected vs Normal") {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Selected task (active)", status: .running, updatedAt: Date(), isEngineRunning: true),
            isActive: true,
            isSelected: true
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Selected task (not active)", status: .paused, updatedAt: Date()),
            isActive: false,
            isSelected: true
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Normal task", status: .running, updatedAt: Date(), isEngineRunning: true),
            isActive: false,
            isSelected: false
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Normal task (active)", status: .done, updatedAt: Date()),
            isActive: true,
            isSelected: false
        )
    }
    .padding(.horizontal, Spacing.s)
    .padding(.vertical, Spacing.xs)
    .frame(width: 260)
    .background(Colors.surfaceBackground)
}

#Preview("Task Row — Long Title") {
    VStack(alignment: .leading, spacing: 0) {
        SidebarTaskRow(
            task: SidebarTaskItem(
                id: 0,
                title: "Implement comprehensive user authentication system with OAuth2 and JWT token refresh",
                status: .running,
                updatedAt: Date(),
                isEngineRunning: true
            ),
            isActive: true,
            isSelected: true
        )
        SidebarTaskRow(
            task: SidebarTaskItem(
                id: 0,
                title: "A",
                status: .done,
                updatedAt: Date()
            ),
            isActive: false
        )
    }
    .padding(.horizontal, Spacing.s)
    .padding(.vertical, Spacing.xs)
    .frame(width: 260)
    .background(Colors.surfaceBackground)
}

#Preview("Task Row — Time Variations") {
    VStack(alignment: .leading, spacing: 0) {
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Just created", status: .running, updatedAt: Date(), isEngineRunning: true),
            isActive: false
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Updated 15 min ago", status: .paused, updatedAt: Date(timeIntervalSinceNow: -900)),
            isActive: false
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Updated 3 hours ago", status: .waiting, updatedAt: Date(timeIntervalSinceNow: -10800)),
            isActive: false
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Updated 2 days ago", status: .done, updatedAt: Date(timeIntervalSinceNow: -172800)),
            isActive: false
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Updated 2 weeks ago", status: .done, updatedAt: Date(timeIntervalSinceNow: -1_209_600)),
            isActive: false
        )
    }
    .padding(.horizontal, Spacing.s)
    .padding(.vertical, Spacing.xs)
    .frame(width: 260)
    .background(Colors.surfaceBackground)
}
