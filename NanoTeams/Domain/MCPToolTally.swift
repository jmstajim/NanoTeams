import Foundation

/// How one server's published tools stand against the approvals on record — counted for the
/// one line the Settings list shows under the server's name, the badge on its page, and the
/// state of a whole-server grant of it.
///
/// Counted by this one rule, from a server's published tools and its trust record: the
/// connection's (`MCPServerConnection.toolTally`) for the list and the page, and the grant
/// catalogue's copy of the same tools (`MCPGrantCatalogue.Server.toolTally`) for the role
/// editor — so the list's "to review" and a grant's "waiting for review" cannot disagree, which
/// they did until 2026-10-28 about a refused text. Never carried inside the connection status. The status
/// used to carry the APPROVED count alone (`.connected(era:toolCount:)`), so a server that had
/// just published five tools nobody had read said "0 tools", and an approved tool the server
/// rewrote only made the number go down — the review queue and the rug pull were both invisible
/// from the list (F47). What a person has to act on is the number to review, and a rewrite of an
/// approved tool is the one they must not miss.
nonisolated struct MCPToolTally: Hashable, Sendable {
    /// Approved at the text the server publishes now: the tools that can reach a prompt.
    let approved: Int
    /// Published and never approved, and not refused.
    let new: Int
    /// Approved once and rewritten since, and the rewrite not refused — the rug pull the
    /// pinning exists to catch.
    let changed: Int
    /// Texts the person refused. Decided, so not waiting for anyone — whatever the pin says: a
    /// refused rewrite stays "changed" to the policy (`MCPToolRowStatus`).
    let rejected: Int

    init(approved: Int, new: Int, changed: Int, rejected: Int) {
        self.approved = approved
        self.new = new
        self.changed = changed
        self.rejected = rejected
    }

    /// Counts one catalogue: each tool's state against its pin, and whether the person refused
    /// exactly its text.
    init(_ tools: some Sequence<(state: MCPPinState, isRejected: Bool)>) {
        var approved = 0, new = 0, changed = 0, rejected = 0
        for tool in tools {
            if tool.isRejected {
                rejected += 1
                continue
            }
            switch tool.state {
            case .approved: approved += 1
            case .new: new += 1
            case .changed: changed += 1
            }
        }
        self.init(approved: approved, new: new, changed: changed, rejected: rejected)
    }

    /// A server with no catalogue to count — switched off, or not connected yet.
    static let none = MCPToolTally(approved: 0, new: 0, changed: 0, rejected: 0)

    /// Waiting for a person to read them: new, or rewritten since they were approved.
    var toReview: Int { new + changed }

    /// Everything the server publishes.
    var total: Int { approved + new + changed + rejected }

    /// Whether an approved tool was rewritten and nobody has decided about the new text yet —
    /// what tints the server's dot and badge.
    var hasUnreviewedRewrite: Bool { changed > 0 }

    /// The counts as the row reads them: "3 to review · 2 approved", the review clause only
    /// when there is something to review — the list is scanned for it, and a "0 to review" on
    /// every quiet row would bury the one that matters. It comes FIRST because the list's
    /// one-line subtitle truncates at its tail, and at the master pane's width the tail is what
    /// goes: the review count is the part a person acts on.
    var summary: String {
        guard total > 0 else { return "no tools" }
        var parts: [String] = []
        if toReview > 0 { parts.append("\(toReview) to review") }
        parts.append("\(approved) approved")
        return parts.joined(separator: " · ")
    }
}
