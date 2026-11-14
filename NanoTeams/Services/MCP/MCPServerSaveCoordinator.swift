import Foundation

/// The three stores one edit of the server list writes — the Keychain, the approvals and the
/// list — and the one order that leaves no half-saved server behind. There is no transaction
/// across the three, so the ORDER is the design.
///
/// Writes only. What a write changes for the RUNNING servers — the reading, the snapshot, the
/// connections — is the manager's (`MCPServerManager.save`, `remove`), which applies whatever
/// landed, failure or not.
nonisolated struct MCPServerSaveCoordinator: Sendable {

    let catalogueStore: MCPServerCatalogueStore
    let trustStore: MCPTrustStore
    let secrets: MCPSecretStore

    /// Saves one server:
    ///
    /// 1. **The Keychain first** (`MCPSecretStore.apply`) — the plan's writes, moves and clears
    ///    (`MCPSecretChangePlan`), all or nothing. A refused write throws before the list is
    ///    touched: a server never runs with its credential missing (F41). A re-point first lists
    ///    what the server holds (`MCPSecretStore.heldAccounts(of:)`), so its plan clears every
    ///    account under the server's prefix, not only the ones the configs name.
    /// 2. **A re-pointed server's approvals next** (`MCPTrustStore.forget`): its pins and
    ///    always-allow grants were given to the old address and do not follow it to another
    ///    (F22). Before the list, because in this order a failure can only COST approvals,
    ///    never carry them to another host.
    /// 3. **The list last.** A refusal puts the Keychain back (`MCPSecretStore.restore`), so no
    ///    secret is left behind for a server that does not exist, and the old address runs on
    ///    with the values it was saved with (F28). Approvals already cleared stay cleared, and
    ///    the error says so.
    ///
    /// None typed for a new address reaches the old one, BY CONSTRUCTION rather than by this
    /// order: every account is spelled under the origin it was entered for
    /// (`MCPServerConfig.originAccountPrefix`), a re-point writes only the new origin's, and a
    /// connection reads only its own origin's. So a Keychain that refuses the undo too — which
    /// the order cannot prevent — leaves at worst the new address's values under the server's
    /// id and the old address's gone: nothing either address is sent that was typed for the
    /// other, the error says the token must be entered again, and the next re-point, removal or
    /// launch sweep clears the leftover.
    ///
    /// Throws `MCPServerEditError`, which says what state each store was left in.
    ///
    /// Synchronous on purpose: the Keychain and the list are written in ONE main-actor turn,
    /// which is what lets the launch sweep (`MCPServerManager`), deciding and deleting in a turn
    /// of its own, never see a server's accounts before the list names it.
    func save(_ config: MCPServerConfig, secrets edit: MCPServerSecretEdit) throws {
        let stored = catalogueStore.server(id: config.id)
        let held = MCPSecretChangePlan.isRepoint(stored: stored, saved: config)
            ? try secrets.heldAccounts(of: config) : []
        let plan = MCPSecretChangePlan.make(stored: stored, saved: config, edit: edit, held: held)
        let undo = try secrets.apply(plan)

        let clearsApprovals = plan.isRepoint && !trustStore.record(for: config.id).toolPins.isEmpty
        if plan.isRepoint {
            do {
                try trustStore.forget(serverID: config.id)
            } catch {
                throw MCPServerEditError.approvalsNotCleared(undone: secrets.restore(undo))
            }
        }

        do {
            try catalogueStore.upsert(config)
        } catch {
            throw MCPServerEditError.catalogueNotSaved(
                undone: secrets.restore(undo), approvalsCleared: clearsApprovals)
        }
    }

    /// Removes one server, then its secrets — every account under its prefix
    /// (`MCPSecretStore.clearAll(for:)`) — and its approvals, once the list no longer names
    /// it, and not before: a removal the list refused leaves a server that is still configured,
    /// and taking its token then left it saying "Needs a token" (review of 2026-09-23). A later
    /// server reusing the id would otherwise inherit a stranger's pins, and a token nothing in
    /// the UI can see any more is a credential left behind.
    ///
    /// Throws when the list refused the removal — nothing else was touched. Returns what the
    /// removal left behind, or `nil`, so the list pane can say which one could not be deleted
    /// instead of claiming the list itself was not saved.
    func remove(id: UUID) throws -> MCPServerEditError? {
        let config = catalogueStore.server(id: id)
        do {
            try catalogueStore.remove(id: id)
        } catch {
            throw MCPServerEditError.catalogueNotSaved(undone: true, approvalsCleared: false)
        }
        var tokenLeft = false
        var approvalsLeft = false
        if let config {
            do { try secrets.clearAll(for: config) } catch { tokenLeft = true }
        }
        do { try trustStore.forget(serverID: id) } catch { approvalsLeft = true }
        return tokenLeft || approvalsLeft
            ? .removedWithLeftovers(token: tokenLeft, approvals: approvalsLeft)
            : nil
    }
}
