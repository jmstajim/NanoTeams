import SwiftUI

/// Slim full-width band that marks a transition between team contexts in the
/// interleaved activity feed (parent ↔ delegated child team).
///
/// Renders just above the first item of the new team's run, so the user has a
/// clear visual handoff. The band shows direction (↳ into child, ↰ back to
/// parent), the team name, and (for `.intoChild`) the delegating role's name.
struct TeamBoundaryBandView: View {
    let boundary: ActivityFeedBuilder.TeamBoundary

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: directionIcon)
                .font(.caption)
                .foregroundStyle(Colors.purple)
                .accessibilityHidden(true)

            Text(label)
                .font(Typography.captionSemibold)
                .foregroundStyle(Colors.textPrimary)

            if let role = boundary.delegatedFromRoleName, boundary.direction == .intoChild {
                Text(verbatim: "by \(role)")
                    .font(.caption)
                    .foregroundStyle(Colors.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(Colors.purpleTint, in: RoundedRectangle.squircle(CornerRadius.small))
        .padding(.vertical, Spacing.xs)
    }

    private var directionIcon: String {
        switch boundary.direction {
        case .intoChild:    return "arrow.turn.down.right"
        case .backToParent: return "arrow.turn.up.left"
        }
    }

    private var label: String {
        switch boundary.direction {
        case .intoChild:    return "Delegated to \(boundary.teamName)"
        case .backToParent: return "Back from \(boundary.teamName)"
        }
    }
}
