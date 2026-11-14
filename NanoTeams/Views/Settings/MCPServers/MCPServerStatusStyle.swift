import SwiftUI

/// How one server's standing is drawn — the glyph, the ink, and whether the row's dot is lit.
///
/// Shared by the master row's dot and the detail header's badge rather than switched twice: two
/// switches over the same enum drift, and a list that says "connected" beside a detail pane
/// that says "refused" is worse than either.
nonisolated enum MCPServerStatusStyle {

    /// The bare status, ignoring whether the user switched the server off. Used where the
    /// status itself is the subject.
    static func glyph(for status: MCPServerStatus) -> String {
        switch status {
        case .connected: TerminalGlyph.done
        case .connecting: TerminalGlyph.working
        case .disabled: TerminalGlyph.paused
        case .needsAuth, .unsupportedTransport, .failed, .incompatible: TerminalGlyph.failed
        }
    }

    static func color(for status: MCPServerStatus) -> Color {
        switch status {
        case .connected: Colors.success
        case .connecting: Colors.info
        case .disabled: Colors.textTertiary
        // Repaired by a person rather than by waiting, and none is the server failing now — an
        // address this client refuses never reached it at all, and an incompatible server is
        // answering, in a dialect this client does not read.
        case .needsAuth, .unsupportedTransport, .incompatible: Colors.warning
        case .failed: Colors.error
        }
    }

    /// One server's ink: its status's, except that a connected server with a rewrite of an
    /// approved tool waiting for a person reads in the warning ink — the rug pull is the one
    /// thing the list must not let pass unseen (F47). A connection that is failing speaks first.
    static func color(for row: MCPServerRow) -> Color {
        if row.status.isConnected, !row.catalogueUnverified, row.tools.hasUnreviewedRewrite {
            return Colors.warning
        }
        return color(for: row.status)
    }

    /// The master row's dot. A server switched off — globally or for this folder — reads as
    /// dim whatever its last status was, because nothing is being attempted.
    static func dotColor(for row: MCPServerRow) -> Color {
        row.isRunnable ? color(for: row) : Colors.textTertiary
    }
}
