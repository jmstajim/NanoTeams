import SwiftUI

// MARK: - Timeline Event Type

/// Type of timeline event (step started or completed)
nonisolated enum TimelineEventType {
    case started
    case completed
    case failed
}

// MARK: - Timeline Event

/// Model for a timeline event
nonisolated struct TimelineEvent: Identifiable {
    let id: UUID
    let taskID: Int
    let taskTitle: String
    let role: Role
    let roleDefinition: TeamRoleDefinition?
    let stepTitle: String
    let eventType: TimelineEventType
    let isChatMode: Bool
    let timestamp: Date

    /// Derive a deterministic UUID from stepID + event type so that the same
    /// logical event always gets the same identity across SwiftUI re-renders.
    /// This enables proper diffing instead of recreating every cell.
    private static let suffixMap: [TimelineEventType: UInt8] = [
        .started: 0x01, .completed: 0x02, .failed: 0x03,
    ]

    static func stableID(taskID: Int, runID: Int, stepID: String, eventType: TimelineEventType) -> UUID {
        // Deterministic UUID from (taskID, runID, stepID, eventType) — stable
        // across app launches. Uses FNV-1a hash (not Hasher, which is randomized
        // per process). Including taskID + runID is LOAD-BEARING: `stepID` is the
        // ROLE id, which recurs in EVERY run of a task, so hashing the step alone
        // makes two runs of the same role collide on one UUID → SwiftUI ForEach
        // "ID occurs multiple times within the collection" (undefined results).
        let suffix = suffixMap[eventType] ?? 0x00
        let composite = "\(taskID):\(runID):\(stepID)"
        var h: UInt64 = 14695981039346656037 // FNV offset basis
        for byte in composite.utf8 {
            h ^= UInt64(byte)
            h &*= 1099511628211 // FNV prime
        }
        h ^= UInt64(suffix)
        h &*= 1099511628211
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: h >> 0), UInt8(truncatingIfNeeded: h >> 8),
            UInt8(truncatingIfNeeded: h >> 16), UInt8(truncatingIfNeeded: h >> 24),
            UInt8(truncatingIfNeeded: h >> 32), UInt8(truncatingIfNeeded: h >> 40),
            UInt8(truncatingIfNeeded: h >> 48), UInt8(truncatingIfNeeded: h >> 56),
            suffix, 0, 0, 0, 0, 0, 0, 0
        ))
    }

    private static let displayFormatMap: [TimelineEventType: @Sendable (String, String) -> String] = [
        .started: { "\($0) started working on \($1)" },
        .completed: { "\($0) finished working on \($1)" },
        .failed: { "\($0) failed on \($1)" },
    ]

    private static let chatModeFormatMap: [TimelineEventType: @Sendable (String) -> String] = [
        .started: { "Chat with \($0) started" },
        .completed: { "Chat with \($0) ended" },
        .failed: { "Chat with \($0) failed" },
    ]

    var displayText: String {
        if isChatMode, let format = Self.chatModeFormatMap[eventType] {
            return format(role.displayName)
        }
        return Self.displayFormatMap[eventType]?(role.displayName, stepTitle) ?? "\(role.displayName) — \(stepTitle)"
    }
}

// MARK: - Watchtower Timeline Item

/// Single item in the watchtower timeline showing role activity
struct WatchtowerTimelineItem: View {
    let event: TimelineEvent
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    /// Terminal status glyph + color for the event type (the design's per-row
    /// status marker). Reuses the documented status palette by event kind.
    /// Timeline events are historical — never animated. Chat-mode `.started`
    /// uses the prompt chevron `›` to match `TaskStatus.glyph(isChatMode:)`
    /// and the prompt-marker rail discipline shared across chat surfaces;
    /// non-chat `.started` keeps the static work-arrow `▸`. Symbol shape
    /// alone distinguishes the three event kinds (`▸ / ✓ / ✗`).
    private var statusGlyph: (glyph: String, color: Color, animates: Bool) {
        switch event.eventType {
        case .started:
            let glyph = event.isChatMode ? TerminalGlyph.prompt : TerminalGlyph.working
            return (glyph, Colors.accent, false)
        case .completed: return (TerminalGlyph.done, Colors.success, false)
        case .failed: return (TerminalGlyph.failed, Colors.error, false)
        }
    }

    /// Role name in bold + the action text in secondary — the design's
    /// `ActivityRow` two-tone label. Falls back to a single secondary run when
    /// the text doesn't lead with the role name (chat-mode phrasing).
    @ViewBuilder
    private var activityText: some View {
        let name = event.role.displayName
        let full = event.displayText
        if full.hasPrefix(name) {
            Text(name).fontWeight(.semibold).foregroundStyle(Colors.textPrimary)
                + Text(String(full.dropFirst(name.count))).foregroundStyle(Colors.textSecondary)
        } else {
            Text(full).foregroundStyle(Colors.textSecondary)
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Spacing.s) {
                StatusGlyph(
                    glyph: statusGlyph.glyph,
                    color: statusGlyph.color,
                    animatesWork: statusGlyph.animates,
                    font: Typography.termSm
                )
                .padding(.top, 1)

                ActivityFeedRoleAvatar(
                    role: event.role,
                    roleDefinition: event.roleDefinition,
                    size: 20
                )
                .padding(.top, 1)

                // Event text — role name bold, action text secondary (1:1 ActivityRow).
                VStack(alignment: .leading, spacing: 2) {
                    activityText
                        .font(Typography.termSm)
                        .lineLimit(2)

                    Text(event.taskTitle)
                        .font(Typography.term2xs)
                        .foregroundStyle(Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: Spacing.s)

                // Timestamp
                Text(event.timestamp.formatted(.relative(presentation: .named)))
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.textTertiary)
                    .padding(.top, 1)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(isHovered ? Colors.surfaceHover : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? .none : Animations.quick) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.displayText) in \(event.taskTitle), \(event.timestamp.formatted(.relative(presentation: .named)))")
        .accessibilityHint("Double-click to open task")
    }
}


// MARK: - Preview

#Preview {
    VStack(spacing: Spacing.s) {
        WatchtowerTimelineItem(
            event: TimelineEvent(
                id: UUID(),
                taskID: Int(),
                taskTitle: "Implement authentication",
                role: .productManager,
                roleDefinition: nil,
                stepTitle: "Product Requirements",
                eventType: .started,
                isChatMode: false,
                timestamp: Date().addingTimeInterval(-120)
            ),
            onTap: {}
        )

        WatchtowerTimelineItem(
            event: TimelineEvent(
                id: UUID(),
                taskID: Int(),
                taskTitle: "Implement authentication",
                role: .techLead,
                roleDefinition: nil,
                stepTitle: "Implementation Plan",
                eventType: .completed,
                isChatMode: false,
                timestamp: Date().addingTimeInterval(-300)
            ),
            onTap: {}
        )

        WatchtowerTimelineItem(
            event: TimelineEvent(
                id: UUID(),
                taskID: Int(),
                taskTitle: "Fix navigation bug",
                role: .softwareEngineer,
                roleDefinition: nil,
                stepTitle: "Engineering Notes",
                eventType: .failed,
                isChatMode: false,
                timestamp: Date().addingTimeInterval(-600)
            ),
            onTap: {}
        )
    }
    .padding()
    .frame(width: 400)
    .background(NTMSBackground())
}
