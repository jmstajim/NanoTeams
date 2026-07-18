import Foundation

// MARK: - Acceptance Service

/// Handles Supervisor acceptance workflow for role work.
nonisolated enum AcceptanceService {

    // MARK: - Acceptance Decision

    enum AcceptanceDecision: String, Codable {
        case accepted
        case revisionRequested
    }

    // MARK: - Supervisor Feedback

    nonisolated struct SupervisorFeedback: Codable, Identifiable {
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

nonisolated extension AcceptanceService.SupervisorFeedback: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AcceptanceService.SupervisorFeedback, rhs: AcceptanceService.SupervisorFeedback) -> Bool {
        lhs.id == rhs.id
    }
}

extension AcceptanceService {

    // MARK: - Should Request Acceptance

    /// Determines whether per-role Supervisor acceptance should be requested when a role
    /// completes. This is the *intermediate* per-role gate only — the final deliverable is
    /// always approved by the task-level review (`derivedStatusFromActiveRun` →
    /// `.needsSupervisorAcceptance` once all steps are `.done` and all roles `.isComplete`).
    /// So no mode needs to gate the terminal role here: doing so would hold the terminal role
    /// at `.needsAcceptance` (not `.isComplete`), which suppresses the real final-review window.
    /// - Parameters:
    ///   - roleID: The role that completed work
    ///   - mode: The acceptance mode in effect
    ///   - checkpoints: Custom checkpoints (for customCheckpoints mode)
    /// - Returns: True if a per-role acceptance gate should be requested
    static func shouldRequestAcceptance(
        roleID: String,
        mode: AcceptanceMode,
        checkpoints: Set<String>
    ) -> Bool {
        switch mode {
        case .afterEachArtifact:
            // Always request after each artifact (handled at artifact level)
            return true

        case .afterEachRole:
            // Always request after each role completes
            return true

        case .finalOnly:
            // No per-role gate — the task-level final review IS the "final only" approval.
            return false

        case .customCheckpoints:
            // Gate only Supervisor-selected checkpoints; the last role is covered by the
            // task-level final review.
            return checkpoints.contains(roleID)
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

    // MARK: - Accept Routing (Autovisor manage_role accept)

    /// How the Autovisor's `manage_role accept` should be handled for a role.
    /// `.accept` = ordinary acceptance of a role awaiting review; `.finishChatRole` =
    /// the chat-mode exit (a chat advisory role never reaches acceptance, so accept
    /// finishes it — and the caller closes the task when nothing else is active —
    /// instead of failing "still working"); `.reject` carries the unchanged validation
    /// message for cases where neither applies.
    nonisolated enum AcceptRoute: Hashable {
        case accept
        case finishChatRole
        case reject(reason: String)
    }

    /// Statuses for which the chat-finish exit is appropriate: a live advisory role
    /// (`.working`) or the auto-finished-but-task-not-closed zombie (`.done`, from
    /// `attemptAdvisoryAutoFinish`). Every OTHER validation-failing status keeps the
    /// ordinary reject — accept must never force-convert a role to `.done` when that would
    /// erase state: `.failed` (a failure `finalizeRoleStatusesForClose` deliberately
    /// preserves; restart it instead), `.skipped`, `.revisionRequested` (don't abandon the
    /// revision), `.accepted`, or `.idle`/`.ready` (work that never ran — plus a step-less
    /// idle role has nothing to finish, which would spuriously fail).
    private static let chatFinishableStatuses: Set<RoleExecutionStatus> = [.working, .done]

    /// Routes `accept`, layered on top of `validateAcceptance` so the error table stays
    /// the single source of the reject messages.
    /// - `.needsAcceptance` (validation passes) → `.accept`, checked **first**: a
    ///   chat-mode team can still hold a producing role legitimately at `.needsAcceptance`
    ///   (Quest Party), a genuine mid-pipeline gate that must go through untouched.
    /// - a chat-mode task's non-producing (advisory) role in a `chatFinishableStatuses`
    ///   state → `.finishChatRole`.
    /// - otherwise → `.reject` with the ordinary message.
    static func routeAccept(
        roleID: String,
        roleStatuses: [String: RoleExecutionStatus],
        isChatModeTask: Bool,
        roleIsProducing: Bool
    ) -> AcceptRoute {
        guard let reason = validateAcceptance(roleID: roleID, roleStatuses: roleStatuses) else {
            return .accept
        }
        if isChatModeTask, !roleIsProducing,
           let status = roleStatuses[roleID], chatFinishableStatuses.contains(status) {
            return .finishChatRole
        }
        return .reject(reason: reason)
    }
}
