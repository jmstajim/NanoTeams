import Foundation

/// Why an edit to the server list did not land — or landed only in part. Every message is read
/// by the person who pressed the button, on the surface they pressed it on: the editor's banner,
/// the server page's banner, the list's error line.
///
/// Each one says what state things were left in, not just that something failed: a save spans
/// the Keychain and two files, and "could not be saved" alone leaves the person guessing which
/// half of it happened.
nonisolated enum MCPServerEditError: Error, Equatable, Sendable {
    /// The Keychain refused a READ before anything was written: nothing changed.
    case keychainUnreadable
    /// A Keychain write failed part-way. `undone`: whether what the save had already written
    /// was put back.
    case keychainNotSaved(undone: Bool)
    /// A save that re-points the server could not clear the old address's tool approvals, so
    /// it stopped before saving the new address.
    case approvalsNotCleared(undone: Bool)
    /// The server list could not be written. `undone`: whether every secret the save had
    /// written was put back — true when it wrote none, as a removal does. `approvalsCleared`:
    /// whether a re-point had already cleared the old address's approvals — which stay cleared.
    case catalogueNotSaved(undone: Bool, approvalsCleared: Bool)
    /// A removal that landed, with a credential or the approvals left behind.
    case removedWithLeftovers(token: Bool, approvals: Bool)
    /// This folder's opt-out file could not be written.
    case folderRuleNotSaved
    /// No work folder is open, so there is no folder rule to change.
    case noWorkFolder
    /// The server list is not loaded yet — nothing has opened a folder since launch.
    case serversNotLoaded
    /// The server a switch was pressed for is no longer in the list — removed meanwhile.
    case serverNotFound

    var message: String {
        switch self {
        case .keychainUnreadable:
            return "The Keychain could not be read, so nothing was saved. Unlock it and try again."
        case .keychainNotSaved(let undone):
            return "A secret could not be written to the Keychain, so the server was not saved."
                + Self.undoNote(undone)
        case .approvalsNotCleared(let undone):
            return "The new address could not be saved: the old address's tool approvals could not "
                + "be cleared. Check that the app can write to its support folder." + Self.undoNote(undone)
        case .catalogueNotSaved(let undone, let approvalsCleared):
            return "The server list could not be saved. Check that the app can write to its support folder."
                + Self.undoNote(undone)
                + (approvalsCleared
                    ? " The tool approvals given to the old address were already cleared and must be given again."
                    : "")
        case .removedWithLeftovers(let token, let approvals):
            switch (token, approvals) {
            case (true, true):
                return "The server was removed, but its token and its tool approvals could not be deleted."
            case (true, false):
                return "The server was removed, but its token could not be deleted from the Keychain."
            default:
                return "The server was removed, but its tool approvals could not be deleted. "
                    + "Check that the app can write to its support folder."
            }
        case .folderRuleNotSaved:
            return "This folder's server settings could not be saved. Check that the app can write to the work folder."
        case .noWorkFolder:
            return "Open a work folder to allow or block this server there."
        case .serversNotLoaded:
            return "The server list is not loaded yet. Open a work folder and try again."
        case .serverNotFound:
            return "This server is no longer in the list, so there is nothing to switch."
        }
    }

    /// What a save the Keychain could not undo leaves: the token this server is saved with may
    /// be gone — a re-point clears the old address's before it writes the new one's — so the
    /// person is told to enter it again, not only to check it. Never another address's token:
    /// each account names the origin it was entered for (`MCPServerConfig.originAccountPrefix`).
    private static func undoNote(_ undone: Bool) -> String {
        undone
            ? ""
            : " Some of the secrets it had already written could not be put back, so this server's "
                + "saved token may be missing — enter it again before using the server."
    }
}
