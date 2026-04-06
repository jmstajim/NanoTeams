import Foundation

// MARK: - Acceptance Service

/// Handles Supervisor acceptance workflow for role work.
enum AcceptanceService {

    // MARK: - Acceptance Decision

    enum AcceptanceDecision: String, Codable {
        case accepted
        case revisionRequested
    }

    // MARK: - Supervisor Feedback

    struct SupervisorFeedback: Codable, Identifiable {
        var id: UUID
        var createdAt: Date
        var roleID: String
        var decision: AcceptanceDecision
        var comment: String?

        init(
            id: UUID = UUID(),
            createdAt: Date = MonotonicClock.shared.now(),
            roleID: String,
            decision: AcceptanceDecision,
            comment: String? = nil
        ) {
            self.id = id
            self.createdAt = createdAt
            self.roleID = roleID
            self.decision = decision
            self.comment = comment
        }
    }
}

// MARK: - SupervisorFeedback Hashable

extension AcceptanceService.SupervisorFeedback: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AcceptanceService.SupervisorFeedback, rhs: AcceptanceService.SupervisorFeedback) -> Bool {
        lhs.id == rhs.id
    }
}

extension AcceptanceService {

    // MARK: - Should Request Acceptance

    /// Determines whether Supervisor acceptance should be requested for a role.
    /// - Parameters:
    ///   - roleID: The role that completed work
    ///   - mode: The acceptance mode in effect
    ///   - checkpoints: Custom checkpoints (for customCheckpoints mode)
    ///   - isLastRole: Whether this is the final role in the execution
    /// - Returns: True if acceptance should be requested
    static func shouldRequestAcceptance(
        roleID: String,
        mode: AcceptanceMode,
        checkpoints: Set<String>,
        isLastRole: Bool
    ) -> Bool {
        switch mode {
        case .afterEachArtifact:
            // Always request after each artifact (handled at artifact level)
            return true

        case .afterEachRole:
            // Always request after each role completes
            return true

        case .finalOnly:
            // Only request after the final role
            return isLastRole

        case .customCheckpoints:
            // Request if this role is in the checkpoint list, or if it's the last role
            return checkpoints.contains(roleID) || isLastRole
        }
    }

    /// Determines whether Supervisor acceptance should be requested for an artifact.
    /// - Parameters:
    ///   - mode: The acceptance mode in effect
    /// - Returns: True if acceptance should be requested
    static func shouldRequestAcceptanceForArtifact(
        mode: AcceptanceMode
    ) -> Bool {
        switch mode {
        case .afterEachArtifact:
            return true
        case .afterEachRole, .finalOnly, .customCheckpoints:
            return false
        }
    }

    // MARK: - Effective Acceptance Mode

    /// Gets the effective acceptance mode for a task.
    /// - Parameters:
    ///   - task: The task (may have per-task override)
    ///   - teamSettings: The team settings (default mode)
    /// - Returns: The acceptance mode to use
    static func effectiveAcceptanceMode(
        for task: NTMSTask,
        teamSettings: TeamSettings
    ) -> AcceptanceMode {
        task.acceptanceMode ?? teamSettings.defaultAcceptanceMode
    }

    /// Gets the effective acceptance checkpoints for a task.
    /// - Parameters:
    ///   - task: The task (may have per-task override)
    ///   - teamSettings: The team settings (default checkpoints)
    /// - Returns: The checkpoints to use
    static func effectiveCheckpoints(
        for task: NTMSTask,
        teamSettings: TeamSettings
    ) -> Set<String> {
        task.acceptanceCheckpoints ?? teamSettings.acceptanceCheckpoints
    }

    // MARK: - Update Role Status After Acceptance

    /// Returns the new role status after an acceptance decision.
    /// - Parameter decision: The Supervisor's decision
    /// - Returns: The new role execution status
    static func statusAfterAcceptance(decision: AcceptanceDecision) -> RoleExecutionStatus {
        switch decision {
        case .accepted:
            return .accepted
        case .revisionRequested:
            return .revisionRequested
        }
    }

    // MARK: - Check If All Roles Accepted

    /// Checks if all roles have been accepted.
    /// - Parameters:
    ///   - roleStatuses: Current status of all roles
    ///   - requiredRoleIDs: Role IDs that must be accepted
    /// - Returns: True if all required roles are accepted
    static func allRolesAccepted(
        roleStatuses: [String: RoleExecutionStatus],
        requiredRoleIDs: Set<String>
    ) -> Bool {
        for roleID in requiredRoleIDs {
            guard let status = roleStatuses[roleID] else { return false }
            if status != .accepted && status != .done {
                return false
            }
        }
        return true
    }

    // MARK: - Get Pending Acceptances

    /// Gets all roles that are waiting for Supervisor acceptance.
    /// - Parameter roleStatuses: Current status of all roles
    /// - Returns: Array of role IDs pending acceptance
    static func getPendingAcceptances(
        roleStatuses: [String: RoleExecutionStatus]
    ) -> [String] {
        roleStatuses.compactMap { roleID, status in
            status == .needsAcceptance ? roleID : nil
        }
    }

    // MARK: - Acceptance Validation

    /// Error messages for statuses that cannot be accepted. Absent key (.needsAcceptance) = valid.
    private static let acceptanceErrors: [RoleExecutionStatus: String] = [
        .accepted: "Role already accepted",
        .done: "Role already completed",
        .working: "Role is still working",
        .idle: "Role has not started work yet",
        .ready: "Role has not started work yet",
        .revisionRequested: "Role is already in revision",
        .failed: "Cannot accept failed role",
        .skipped: "Cannot accept skipped role",
    ]

    // MARK: - Validate Acceptance Flow

    /// Validates that acceptance can proceed for a role.
    /// - Parameters:
    ///   - roleID: The role to accept
    ///   - roleStatuses: Current status of all roles
    /// - Returns: Nil if valid, or error message
    static func validateAcceptance(
        roleID: String,
        roleStatuses: [String: RoleExecutionStatus]
    ) -> String? {
        guard let status = roleStatuses[roleID] else {
            return "Role not found: \(roleID)"
        }

        return Self.acceptanceErrors[status]
    }
}
