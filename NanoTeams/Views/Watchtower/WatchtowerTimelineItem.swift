import SwiftUI

// MARK: - Timeline Event Type

/// Type of timeline event (step started or completed)
enum TimelineEventType {
    case started
    case completed
    case failed
}

// MARK: - Timeline Event

/// Model for a timeline event
struct TimelineEvent: Identifiable {
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

    static func stableID(stepID: String, eventType: TimelineEventType) -> UUID {
        // Deterministic UUID from (stepID, eventType) — stable across app launches.
        // Uses FNV-1a hash (not Hasher, which is randomized per process).
        let suffix = suffixMap[eventType] ?? 0x00
        var h: UInt64 = 14695981039346656037 // FNV offset basis
        for byte in stepID.utf8 {
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

    private static let displayFormatMap: [TimelineEventType: (String, String) -> String] = [
        .started: { "\($0) started working on \($1)" },
        .completed: { "\($0) finished working on \($1)" },
        .failed: { "\($0) failed on \($1)" },
    ]

    private static let chatModeFormatMap: [TimelineEventType: (String) -> String] = [
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

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.m) {
                ActivityFeedRoleAvatar(
                    role: event.role,
                    roleDefinition: event.roleDefinition,
                    size: 28
                )

                // Event text
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.displayText)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(event.taskTitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                // Timestamp
                Text(event.timestamp.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                    .fill(isHovered ? Colors.surfaceHover : Color.clear)
            )
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
