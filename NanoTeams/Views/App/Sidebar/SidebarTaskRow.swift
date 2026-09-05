import SwiftUI

/// Track-row style: thin colored status bar on the leading edge, bold title, metadata below.
struct SidebarTaskRow: View {
    let task: SidebarTaskItem
    /// The row's live stamp, read by the caller from `TaskFactsProjection.updatedAtByTaskID`
    /// rather than carried inside `task` — a cached item must not freeze "just now".
    let updatedAt: Date
    var isSelected: Bool = false
    /// 1-based row index in the filtered list — rendered as a `01`/`02` mono
    /// prefix per the design's tmux task ledger. `nil` hides the gutter (back
    /// compat for previews / contexts that don't number rows).
    var displayIndex: Int? = nil

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
    private var statusGlyph: String { task.status.glyph(isChatMode: task.isChatMode) }

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
        // Terminal status glyph (braille spinner when the engine is live),
        // consistent with the role-node status row.
        StatusGlyph(
            glyph: statusGlyph,
            color: statusColor,
            animatesWork: (task.isEngineRunning || task.isInitializing) && !task.hasUnreadInput,
            font: Typography.term2xs
        )
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
        Text(updatedAt.relativeTimestamp)
            .font(Typography.caption)
            .foregroundStyle(Colors.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            if let displayIndex {
                Text(String(format: "%02d", displayIndex))
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.textQuaternary)
                    .monospacedDigit()
                    .frame(width: 18, alignment: .leading)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xxs) {
                    Text(task.title)
                        // Fixed weight across active / inactive so the row
                        // height + glyph metrics don't reflow on selection —
                        // DS signals active state through the row background
                        // fill, not type-weight emphasis.
                        .font(Typography.subheadlineMedium)
                        .foregroundStyle(Colors.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if task.isRecurring {
                        Image(systemName: "repeat")
                            .font(Typography.caption2)
                            .foregroundStyle(Colors.textSecondary)
                            .accessibilityLabel("Recurring")
                    }
                    if task.hasPendingBashApproval {
                        Image(systemName: "terminal")
                            .font(Typography.caption2)
                            .foregroundStyle(Colors.warning)
                            .accessibilityLabel("Awaiting command approval")
                    }
                }
                statusMetadataRow
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.s)
        .padding(.horizontal, Spacing.m)
        // Flat DS row — no rounded card; an edge-to-edge fill + a 2px left accent
        // bar. Both reflect the SELECTED nav item only, never the orchestrator's
        // loaded/active task — otherwise the strip lingers on the last-viewed
        // task's row after navigating away to Watchtower (which doesn't change
        // the active task). The running spinner already conveys "active".
        .background(rowBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? Colors.accent : Color.clear)
                .frame(width: 2)
        }
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
            task: SidebarTaskItem(id: 0, title: "Implement sorting algorithms", status: .running, isEngineRunning: true),
            updatedAt: Date()
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Refactor auth module", status: .running, isEngineRunning: true),
            updatedAt: Date()
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Add dark mode support", status: .paused),
            updatedAt: Date()
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Database migration", status: .waiting),
            updatedAt: Date()
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Design API endpoints", status: .needsSupervisorInput),
            updatedAt: Date()
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Build notification system", status: .needsSupervisorAcceptance),
            updatedAt: Date()
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Fix login bug", status: .done),
            updatedAt: Date()
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Deploy to production", status: .failed),
            updatedAt: Date()
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
            task: SidebarTaskItem(id: 0, title: "Selected task (active)", status: .running, isEngineRunning: true),
            updatedAt: Date(),
            isSelected: true
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Selected task (not active)", status: .paused),
            updatedAt: Date(),
            isSelected: true
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Normal task", status: .running, isEngineRunning: true),
            updatedAt: Date(),
            isSelected: false
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Normal task (active)", status: .done),
            updatedAt: Date(),
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
                isEngineRunning: true
            ),
            updatedAt: Date(),
            isSelected: true
        )
        SidebarTaskRow(
            task: SidebarTaskItem(
                id: 0,
                title: "A",
                status: .done
            ),
            updatedAt: Date()
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
            task: SidebarTaskItem(id: 0, title: "Just created", status: .running, isEngineRunning: true),
            updatedAt: Date()
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Updated 15 min ago", status: .paused),
            updatedAt: Date(timeIntervalSinceNow: -900)
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Updated 3 hours ago", status: .waiting),
            updatedAt: Date(timeIntervalSinceNow: -10800)
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Updated 2 days ago", status: .done),
            updatedAt: Date(timeIntervalSinceNow: -172800)
        )
        SidebarTaskRow(
            task: SidebarTaskItem(id: 0, title: "Updated 2 weeks ago", status: .done),
            updatedAt: Date(timeIntervalSinceNow: -1_209_600)
        )
    }
    .padding(.horizontal, Spacing.s)
    .padding(.vertical, Spacing.xs)
    .frame(width: 260)
    .background(Colors.surfaceBackground)
}
