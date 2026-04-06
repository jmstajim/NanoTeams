import Foundation

// MARK: - Role Execution Status

/// Status of a role's work during a run
enum RoleExecutionStatus: String, Codable, Hashable, CaseIterable {
    /// Waiting for dependencies (required artifacts)
    case idle

    /// Dependencies satisfied, ready to start
    case ready

    /// Currently executing
    case working

    /// Completed work, waiting for Supervisor acceptance
    case needsAcceptance

    /// Work accepted by Supervisor
    case accepted

    /// Supervisor requested changes
    case revisionRequested

    /// Work completed successfully
    case done

    /// Execution failed
    case failed

    /// Role was skipped (due to error recovery)
    case skipped

    private struct StatusMetadata {
        let displayName: String
        let icon: String
        let isActive: Bool
        let isComplete: Bool
        let requiresSupervisorAttention: Bool
        let canStart: Bool
        let canRestart: Bool
    }

    private static let metadata: [RoleExecutionStatus: StatusMetadata] = [
        .idle:              StatusMetadata(displayName: "Standby",            icon: "circle",
                                          isActive: false, isComplete: false, requiresSupervisorAttention: false, canStart: false, canRestart: false),
        .ready:             StatusMetadata(displayName: "Ready",              icon: "circle.lefthalf.filled",
                                          isActive: false, isComplete: false, requiresSupervisorAttention: false, canStart: true,  canRestart: false),
        .working:           StatusMetadata(displayName: "Working",            icon: "arrow.triangle.2.circlepath",
                                          isActive: true,  isComplete: false, requiresSupervisorAttention: false, canStart: false, canRestart: true),
        .needsAcceptance:   StatusMetadata(displayName: "Needs Review",        icon: "hand.raised.circle.fill",
                                          isActive: true,  isComplete: false, requiresSupervisorAttention: true,  canStart: false, canRestart: true),
        .accepted:          StatusMetadata(displayName: "Accepted",           icon: "checkmark.circle",
                                          isActive: false, isComplete: true,  requiresSupervisorAttention: false, canStart: false, canRestart: true),
        .revisionRequested: StatusMetadata(displayName: "Revision Requested", icon: "arrow.counterclockwise",
                                          isActive: true,  isComplete: false, requiresSupervisorAttention: false, canStart: true,  canRestart: true),
        .done:              StatusMetadata(displayName: "Done",               icon: "checkmark.circle.fill",
                                          isActive: false, isComplete: true,  requiresSupervisorAttention: false, canStart: false, canRestart: true),
        .failed:            StatusMetadata(displayName: "Failed",             icon: "xmark.circle",
                                          isActive: false, isComplete: false, requiresSupervisorAttention: true,  canStart: false, canRestart: true),
        .skipped:           StatusMetadata(displayName: "Skipped",            icon: "forward.circle",
                                          isActive: false, isComplete: true,  requiresSupervisorAttention: false, canStart: false, canRestart: true),
    ]

    var displayName: String { Self.metadata[self]?.displayName ?? "" }
    var icon: String { Self.metadata[self]?.icon ?? "circle" }
    var isActive: Bool { Self.metadata[self]?.isActive ?? false }
    var isComplete: Bool { Self.metadata[self]?.isComplete ?? false }
    var requiresSupervisorAttention: Bool { Self.metadata[self]?.requiresSupervisorAttention ?? false }
    var canStart: Bool { Self.metadata[self]?.canStart ?? false }
    var canRestart: Bool { Self.metadata[self]?.canRestart ?? false }
}

// MARK: - Connection Status

/// Status of artifact connection between roles
enum ConnectionStatus: String, Codable, Hashable {
    /// Waiting for artifact to be produced
    case waiting

    /// Artifact has been produced and is available
    case satisfied

    /// Artifact is unavailable (producer failed or skipped)
    case error

    var isDashed: Bool {
        self != .satisfied
    }
}
