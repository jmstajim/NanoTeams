import SwiftUI

// MARK: - Role Node Visual Styling

/// Visual styling for a role node based on its execution status.
struct RoleNodeStyle {
    let borderColor: Color
    let borderWidth: CGFloat
    let backgroundColor: Color
    let glowRadius: CGFloat
    let shouldAnimate: Bool
    let opacity: Double
}

extension RoleExecutionStatus {
    /// Each status has a unique, visually distinct color.
    private static let colorMap: [RoleExecutionStatus: Color] = [
        .idle: Colors.neutral,          // gray — not started
        .ready: Colors.cyan,             // cyan — deps met, can start
        .working: Colors.info,           // blue — LLM executing
        .needsAcceptance: Colors.purple, // purple — Supervisor review
        .accepted: Colors.emerald,       // emerald — Supervisor approved
        .revisionRequested: Colors.yellow, // yellow — changes requested
        .done: Colors.success,           // green — completed
        .failed: Colors.error,           // red — error
        .skipped: Colors.dim,            // dim — observer
    ]
    var color: Color { Self.colorMap[self] ?? Colors.neutral }

    /// Contextual display name with meeting/paused overrides.
    func displayName(isInMeeting: Bool, isPaused: Bool) -> String {
        if isInMeeting { return "In Meeting" }
        if isPaused && self == .working { return "Paused" }
        return displayName
    }

    /// Contextual display color with meeting/paused overrides.
    func displayColor(isInMeeting: Bool, isPaused: Bool) -> Color {
        if isInMeeting { return Colors.purple }
        if isPaused && self == .working { return Colors.warning }
        return color
    }

    var nodeStyle: RoleNodeStyle {
        Self.nodeStyleMap[self] ?? RoleNodeStyle(
            borderColor: Colors.neutral,
            borderWidth: 1,
            backgroundColor: Colors.neutralTint,
            glowRadius: 0,
            shouldAnimate: false,
            opacity: 0.6
        )
    }

    private static let nodeStyleMap: [RoleExecutionStatus: RoleNodeStyle] = [
        .idle: RoleNodeStyle(borderColor: Colors.neutral, borderWidth: 0.5, backgroundColor: Colors.neutralTint, glowRadius: 0, shouldAnimate: false, opacity: 0.8),
        .ready: RoleNodeStyle(borderColor: Colors.cyan, borderWidth: 1, backgroundColor: Colors.cyanTint, glowRadius: 0, shouldAnimate: false, opacity: 1.0),
        .working: RoleNodeStyle(borderColor: Colors.info, borderWidth: 1, backgroundColor: Colors.infoTint, glowRadius: 0, shouldAnimate: false, opacity: 1.0),
        .needsAcceptance: RoleNodeStyle(borderColor: Colors.purple, borderWidth: 1.5, backgroundColor: Colors.purpleTint, glowRadius: 0, shouldAnimate: false, opacity: 1.0),
        .accepted: RoleNodeStyle(borderColor: Colors.emerald, borderWidth: 1, backgroundColor: Colors.emeraldTint, glowRadius: 0, shouldAnimate: false, opacity: 1.0),
        .revisionRequested: RoleNodeStyle(borderColor: Colors.yellow, borderWidth: 1, backgroundColor: Colors.yellowTint, glowRadius: 0, shouldAnimate: false, opacity: 1.0),
        .done: RoleNodeStyle(borderColor: Colors.success, borderWidth: 1, backgroundColor: Colors.successTint, glowRadius: 0, shouldAnimate: false, opacity: 1.0),
        .failed: RoleNodeStyle(borderColor: Colors.error, borderWidth: 1, backgroundColor: Colors.errorTint, glowRadius: 0, shouldAnimate: false, opacity: 1.0),
        .skipped: RoleNodeStyle(borderColor: Colors.dim, borderWidth: 0, backgroundColor: Colors.dimTint, glowRadius: 0, shouldAnimate: false, opacity: 0.35),
    ]
}
