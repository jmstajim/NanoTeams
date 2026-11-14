import Foundation

/// Every decision the server page makes about what to show and what to enable, as data — so a
/// test can hold each one without a window, and the page's `body` only draws what this says.
nonisolated struct MCPServerDetailPresentation: Hashable, Sendable {

    /// One switch on the Status card: what it is, what it reads, and what a flip of it attempts.
    nonisolated struct SwitchRow: Hashable, Sendable, Identifiable {
        nonisolated enum Kind: Hashable, Sendable {
            /// "Connect to this server" — `MCPServerConfig.isEnabled`, app-wide.
            case power
            /// "Allowed in this work folder" — the open folder's rule.
            case folderRule
        }

        let kind: Kind
        let title: String
        let icon: String
        /// What the switch shows: what the disk holds, never what was last pressed.
        let isOn: Bool
        /// What a flip attempts — the words its failure puts on the banner, and which banner its
        /// success clears (`MCPServerDetailView.ActionFailure`).
        let action: MCPServerDetailView.ActionFailure.Action
        /// Drawn indented under the switch above it, which it depends on.
        let isNested: Bool
        /// Set when a flip of it changes nothing yet: drawn dimmed, with this line under it.
        let waitingNote: String?

        var id: Kind { kind }
    }

    /// One tool the app could not offer to roles, as the Tools card prints it.
    nonisolated struct RejectionLine: Hashable, Sendable, Identifiable {
        /// The refusal itself: the factory never reports two equal ones, so it keys the row even
        /// where two print alike.
        let id: MCPToolDescriptorFactory.Rejection
        let text: String
    }

    /// The Status card's switches, in the order it draws them: the power switch — it decides
    /// whether anything below happens at all — then, only while a work folder is open, the
    /// folder rule under it. Without a folder there is no rule to change — every server is
    /// allowed — and the switch could only fail (`MCPServerEditError.noWorkFolder`). Under a
    /// server switched off app-wide the folder rule changes nothing until it is on, and says so.
    let switchRows: [SwitchRow]
    /// The Tools card's "Not offered to roles" lines, each the rejection's own `displayLine` —
    /// the server's text with every hidden character spelled out, which the page prints and
    /// nothing else.
    let rejectionLines: [RejectionLine]
    /// Reconnect is for a server that is switched on and not answering — any status of a
    /// server that runs. A server that is off has nothing to reconnect.
    let reconnectEnabled: Bool
    /// Refresh lists the tools over the live session, so only while there is one. Enabled
    /// under "Not connected" until F48, it listed on a client that never finished its handshake.
    let refreshEnabled: Bool
    /// What the server says about itself, marked as unverified once. `nil` when it said nothing.
    let selfReport: String?
    /// The protocol revision a live session settled on, as a line of its own — in the status it
    /// read as a date (F47). `nil` when there is no session.
    let protocolLine: String?
    /// The tools card's text when there are no tools to list — naming what would fill it: the
    /// switch on this page (F40), the token, the address, or nothing but time. It never promises
    /// an answer from a server that cannot give one (`emptyToolsText(for:)`).
    let emptyToolsText: String

    init(
        row: MCPServerRow,
        hasConnection: Bool,
        serverInfoLabel: String?,
        folderRuleAvailable: Bool,
        isRefreshing: Bool,
        rejections: [MCPToolDescriptorFactory.Rejection]
    ) {
        switchRows = Self.switchRows(for: row, folderRuleAvailable: folderRuleAvailable)
        rejectionLines = rejections.map { RejectionLine(id: $0, text: $0.displayLine) }
        reconnectEnabled = hasConnection && row.isRunnable
        refreshEnabled = hasConnection && row.status.isConnected && !isRefreshing
        selfReport = serverInfoLabel.map { "Server says it is \($0) (not verified)." }
        if case .connected(let era) = row.status {
            protocolLine = "Protocol: \(era.rawValue) (\(era.displayName))"
        } else {
            protocolLine = nil
        }
        emptyToolsText = Self.emptyToolsText(for: row)
    }

    private static func switchRows(for row: MCPServerRow, folderRuleAvailable: Bool) -> [SwitchRow] {
        let power = SwitchRow(
            kind: .power, title: "Connect to this server", icon: "power",
            isOn: row.config.isEnabled, action: .power, isNested: false, waitingNote: nil)
        guard folderRuleAvailable else { return [power] }
        let folderRule = SwitchRow(
            kind: .folderRule, title: "Allowed in this work folder", icon: "folder",
            isOn: row.isAllowedInThisFolder, action: .folderRule, isNested: true,
            waitingNote: row.config.isEnabled ? nil : "Takes effect once \(power.title) is on.")
        return [power, folderRule]
    }

    /// The first thing in the way, in the row's own standing (`MCPServerStanding`) — the order
    /// the list's subtitle reads them: the power switch, the folder rule, the token, a manager
    /// that runs nothing, then the status — a repair further down helps nothing until the one
    /// above it is made. Only a server that is still trying — connecting, or failed and retrying
    /// on its backoff — is waited for; every status no retry repairs (`MCPServerConnection`'s
    /// terminal statuses) names the repair. Until 2026-09-24 all of them fell through to "tools
    /// appear once the server answers", which none of them would ever do.
    private static func emptyToolsText(for row: MCPServerRow) -> String {
        switch row.standing {
        case .switchedOff:
            return "Turn on Connect to this server to see what it offers."
        case .offInThisFolder:
            return "Turn on Allowed in this work folder to see what it offers."
        case .needsToken:
            return "Add its token in Edit to see what it offers."
        case .notRunning:
            // Switched on and allowed, and nothing runs it: the manager is shut down — the
            // folder closed, or failed to open — until the next folder opens.
            return "Not running — it starts when a work folder opens."
        case .running(.connected):
            // It published tools and the app could offer none — the collision or the refusals
            // are printed under this line. Until 2026-10-28 it read "publishes no tools" there.
            return row.nothingItPublishesCanBeOffered
                ? "None of what it publishes can be offered — see below."
                : "The server publishes no tools."
        case .running(.connecting), .running(.failed):
            return "Nothing yet — tools appear once the server answers."
        case .running(.needsAuth):
            return row.config.allSecretKeys.isEmpty
                ? "The server asks for credentials — add a token in Edit to see what it offers."
                : "The server turned down its credentials — replace them in Edit to see what it offers."
        case .running(.unsupportedTransport):
            return "This address cannot be used — change it in Edit to see what it offers."
        case .running(.incompatible):
            return "This app cannot read what the server sends — use Reconnect once the server is updated."
        }
    }
}
