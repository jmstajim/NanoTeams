import Foundation

/// Why a review action — approve, reject, revoke, a bulk approval — was refused rather than
/// written.
///
/// Every one of them is bound to the text the person had on screen. A server may rewrite a
/// tool while its review sheet is open (a `list_changed`, a reconnect, the stale sweep), and a
/// decision recorded against the text that arrived meanwhile would be a decision about text
/// nobody read — the tool-poisoning route the pinning exists to close. So the action is
/// refused, the sheet stays open, and the person reads the tool again.
nonisolated enum MCPReviewError: Error, Hashable, LocalizedError {
    /// The live tool is no longer the text the person read.
    case changedWhileReviewing
    /// A bulk approval's list is no longer what the confirmation named: a tool in it was
    /// rewritten, withdrawn, approved or refused since.
    case listChangedWhileReviewing
    /// The server stopped publishing the tool, or the connection that held it is gone.
    case withdrawn
    /// A rejection of the text that is approved. An approval is revoked, never "rejected" —
    /// the sheet does not offer it, and the seam refuses it anyway.
    case alreadyApproved
    /// A standing grant on a server whose approval mode allows none — Manual asks about every
    /// call (`MCPApprovalMode.allowsStandingGrants`).
    case standingGrantsNotAllowed
    /// A standing grant through a connection stopped for good — replaced by an edit and still
    /// closing, removed, or switched off.
    case connectionStopped

    var errorDescription: String? { message }

    /// Read by the person who pressed the button, in the sheet or the detail view that
    /// offered it.
    var message: String {
        switch self {
        case .changedWhileReviewing:
            return "The tool changed while you were reading. Review it again."
        case .listChangedWhileReviewing:
            return "A tool in that list changed since the list was shown, so nothing was approved. "
                + "Open the list again."
        case .withdrawn:
            return "The server no longer offers this tool, so there is nothing to decide."
        case .alreadyApproved:
            return "This text is already approved. Revoke the approval instead."
        case .standingGrantsNotAllowed:
            return "This server asks about every call — its approval mode is Manual — so nothing was "
                + "recorded. Make it Semi-automatic or Auto to let a tool run without asking."
        case .connectionStopped:
            return "The server's connection was stopped a moment ago, so nothing was recorded. "
                + "Try again once it has reconnected."
        }
    }
}
