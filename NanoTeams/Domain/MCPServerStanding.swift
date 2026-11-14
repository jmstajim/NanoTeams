import Foundation

/// Where one configured server stands for a PERSON — the first thing in the way, in the order a
/// person repairs them: the power switch, the folder rule, the token, then whatever the server
/// itself is doing. The one reading the Settings list, the server page, the role editor's
/// section header and a held grant's hint all show, computed once by the manager — the only
/// owner of every fact it reads: the switch, the open folder's rule, the Keychain, whether it is
/// shut down, and the connection (`MCPServerManager.standing(of:connection:)`).
///
/// Finer than `MCPServerStatus`, which the runtime reads and which folds three causes into
/// `.disabled` on purpose — a person's switch, this folder's rule, a manager shut down between
/// folders — because to a run they are one fact: nothing runs the server. To a person they are
/// three repairs. Until 2026-10-28 the list and the page each re-derived the cause from the
/// row's fields, and the role editor, which had only the status, read every one of them "Off"
/// while a held grant said "switched off — turn it on" of a server whose switch was on.
nonisolated enum MCPServerStanding: Hashable, Sendable {
    /// The status of a running connection — every `MCPServerStatus` case except `.disabled`,
    /// which is not a running connection and therefore cannot sit inside `.running`.
    nonisolated enum RunningStatus: Hashable, Sendable {
        case connecting
        case connected(era: MCPProtocolEra)
        case needsAuth(reason: String)
        case failed(reason: String)
        case unsupportedTransport(reason: String)
        case incompatible(reason: String)

        init?(_ status: MCPServerStatus) {
            switch status {
            case .disabled: return nil
            case .connecting: self = .connecting
            case .connected(let era): self = .connected(era: era)
            case .needsAuth(let reason): self = .needsAuth(reason: reason)
            case .failed(let reason): self = .failed(reason: reason)
            case .unsupportedTransport(let reason): self = .unsupportedTransport(reason: reason)
            case .incompatible(let reason): self = .incompatible(reason: reason)
            }
        }

        var status: MCPServerStatus {
            switch self {
            case .connecting: .connecting
            case .connected(let era): .connected(era: era)
            case .needsAuth(let reason): .needsAuth(reason: reason)
            case .failed(let reason): .failed(reason: reason)
            case .unsupportedTransport(let reason): .unsupportedTransport(reason: reason)
            case .incompatible(let reason): .incompatible(reason: reason)
            }
        }
    }

    /// Switched off app-wide (`MCPServerConfig.isEnabled`).
    case switchedOff
    /// Switched on, and the open work folder's rule blocks it.
    case offInThisFolder
    /// Switched on and allowed, not connected, and a credential its configuration declares is
    /// not in the Keychain. A server that connects without it ships its tools, so it reads as
    /// connected.
    case needsToken
    /// Switched on and allowed, and nothing runs it: the manager is shut down — a folder being
    /// switched, one that failed to open, the app quitting — until the next folder opens.
    case notRunning
    /// Running, as the connection's own status says.
    case running(RunningStatus)

    /// The rule, first obstacle first. Pure so a hand-built value and the manager's agree.
    static func of(
        isSwitchedOn: Bool = true,
        isAllowedInThisFolder: Bool = true,
        hasRequiredSecrets: Bool = true,
        isShutDown: Bool = false,
        status: MCPServerStatus
    ) -> MCPServerStanding {
        if !isSwitchedOn { return .switchedOff }
        if !isAllowedInThisFolder { return .offInThisFolder }
        if !hasRequiredSecrets, !status.isConnected { return .needsToken }
        guard !isShutDown, let running = RunningStatus(status) else { return .notRunning }
        return .running(running)
    }

    /// What the list's subtitle, the server page and the role editor's section header say.
    var label: String {
        switch self {
        case .switchedOff: "Off"
        case .offInThisFolder: "Off in this folder"
        case .needsToken: "Needs a token"
        case .notRunning: "Not running"
        case .running(let running): running.status.displayLabel
        }
    }

    /// A live session with nothing in the way — the quiet case, which a section header draws no
    /// note for.
    var isQuietlyConnected: Bool {
        if case .running(let running) = self { return running.status.isConnected }
        return false
    }
}
