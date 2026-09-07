import Foundation

/// What a run can do with a tool family whose actions need approval — `bash` (per command)
/// and computer-use (per action) — given the family's execution mode and whether a human is
/// there to approve (`ApprovalPresence`).
///
/// The shape is the same for both families because their modes are: Off / Manual /
/// Semi-automatic / Auto. What differs is what a READER does with `.readOnlyUnattended`,
/// because the families differ in granularity: `bash` is one tool whose commands are
/// classified one by one (the read-only ones run, the rest are refused), so the schema keeps
/// the tool; computer-use is five tools whose read-only tier is two of them
/// (`screen_capture`, `ui_scroll`), so the schema keeps those and withholds the mutating trio
/// (`ToolHandlerRegistry.computerUseMutatingTools`).
///
/// `.withheld` means no call of the family could ever run in this run — the schema resolver
/// strips it (advertising a tool every call of which is refused burns a model turn per
/// attempt, KNOWN_ISSUES B3), the badge names why, and a call the model still makes is
/// answered by the classifier with the same reason.
nonisolated enum ApprovalGatedAvailability: Hashable, Sendable {
    enum Reason: Hashable, Sendable {
        /// The family's mode is Off.
        case switchedOff
        /// Every action would need a human's approval, and this run has no human.
        case noApprover
    }

    /// Every action can be attempted: either approvals are unneeded (Auto), or a human is
    /// there to give them.
    case available
    /// A human is absent and only the read-only tier runs; anything else is refused with
    /// `ToolErrorCode.approvalUnavailable`.
    case readOnlyUnattended
    /// Nothing can run.
    case withheld(Reason)

    var isWithheld: Bool {
        if case .withheld = self { return true }
        return false
    }

    static func forBash(mode: BashExecutionMode, humanPresent: Bool) -> ApprovalGatedAvailability {
        switch mode {
        case .off: return .withheld(.switchedOff)
        // Step 1b of `BashPermissionService.evaluate` asks ABOVE the read-only bypass: the user
        // opted into confirming every command, so with no one to confirm, nothing runs.
        case .manual: return humanPresent ? .available : .withheld(.noApprover)
        case .semiAutomatic: return humanPresent ? .available : .readOnlyUnattended
        case .auto: return .available
        }
    }

    static func forComputerUse(mode: ComputerUseMode, humanPresent: Bool) -> ApprovalGatedAvailability {
        switch mode {
        case .off: return .withheld(.switchedOff)
        // Manual confirms the FIRST capture with the human (`ComputerUsePermissionService`
        // step 7), and a refused capture never counts as having occurred — so with no human
        // there is never a screenshot, and a scroll without one errors out on its own.
        case .manual: return humanPresent ? .available : .withheld(.noApprover)
        case .semiAutomatic: return humanPresent ? .available : .readOnlyUnattended
        case .auto: return .available
        }
    }
}

/// Both families' availabilities for one run, computed from the two execution modes and one
/// `ApprovalPresence` answer. Threaded, never defaulted: a caller that passes nothing here is
/// a caller that did not decide, and an implicit "feature off" once hid a preview↔wire
/// divergence (`FirstPromptRendererConfig`'s post-mortem on `computerUseEnabled`).
nonisolated struct ToolApprovalAvailability: Hashable, Sendable {
    let bash: ApprovalGatedAvailability
    let computerUse: ApprovalGatedAvailability

    init(bash: ApprovalGatedAvailability, computerUse: ApprovalGatedAvailability) {
        self.bash = bash
        self.computerUse = computerUse
    }

    init(bashMode: BashExecutionMode, computerUseMode: ComputerUseMode, humanPresent: Bool) {
        self.bash = .forBash(mode: bashMode, humanPresent: humanPresent)
        self.computerUse = .forComputerUse(mode: computerUseMode, humanPresent: humanPresent)
    }

    /// A human is present and neither family is Off — what a role editor, a preview or a test
    /// means by "nothing is withheld for want of approval". Spelled out at every site; not a
    /// parameter default.
    static let available = ToolApprovalAvailability(bash: .available, computerUse: .available)

    /// The folder-level reading for surfaces that hold a TEAM but no task: the role editor,
    /// the wire preview, the role-list badge. `humanPresent` comes from the team's Supervisor
    /// mode (a missing team reads as `.manual`, the fresh-team default) and from whether the
    /// Autovisor supervises this folder's top-level tasks — the same two facts the gates read
    /// for a running task, minus the task-specific "is a delegation child / is the manager".
    static func forTeam(
        bashMode: BashExecutionMode,
        computerUseMode: ComputerUseMode,
        team: Team?,
        workFolderSettings: ProjectSettings?
    ) -> ToolApprovalAvailability {
        let underAutovisor = workFolderSettings.map {
            AutovisorPolicy.supervisesTopLevelTasks(
                autovisorEnabled: $0.autovisorEnabled, activation: $0.autovisorActivation)
        } ?? false
        return ToolApprovalAvailability(
            bashMode: bashMode,
            computerUseMode: computerUseMode,
            humanPresent: ApprovalPresence.humanPresent(
                supervisorMode: team?.settings.supervisorMode ?? .manual,
                underAutovisor: underAutovisor))
    }
}
