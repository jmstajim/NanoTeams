import Foundation

/// Every MCP secret, and the only place that knows where they live.
///
/// A thin type over `SecureTokenStorage` with the MCP service id baked in, and the four things
/// the app does to a server's accounts: a save changes them (`apply(_:)` — every write, move
/// and clear of a plan, all or nothing, with `restore(_:)` for a later failure), a removal
/// clears them (`clearAll(for:)`), the list asks which of them hold a value
/// (`storedKeys(of:)`), and the launch sweep clears what no configured server reads
/// (`orphanedAccounts(readBy:)`, `clear(_:)`). The thinness is the point: there is exactly one
/// spelling of a server's Keychain accounts (`MCPServerConfig.secretAccountPrefix`,
/// `originAccountPrefix`, `bearerSecretKey`, `secretKey(forHeader:)`), and a second one would
/// strand tokens on the next rename.
///
/// **An account names the address its value was entered for** — `<server id>/<origin>/bearer`,
/// `<server id>/<origin>/header/<name>` — so a value is read only by a connection to that
/// origin, whatever this type did or failed to do: no ordering and no clean-up is what keeps a
/// token off another host. `<server id>/` is what a removal and a re-point clear.
///
/// **Which values are read, by whom, and why** — the editor never shows a stored secret, so
/// none is read for display:
/// - **Sent values**, on their way out: the request path and the scrubs of what comes back
///   (`MCPAuthorizer.swift`), per request, held nowhere.
/// - **Touched values**, by `apply`: every account one save's plan writes, moves or clears, read
///   once before the first step — a move carries a value, and the undo (`Undo`) must know what
///   to put back. Held for the length of that save.
/// - **Presence only**, by `storedKeys(of:)`: whether each account a server READS holds
///   something, for "Needs a token" and "leave blank to keep" — the value is tested for
///   blankness and dropped.
/// - **Names only**, by `heldAccounts(of:)`, `clearAll(for:)` and `orphanedAccounts(readBy:)`:
///   the accounts listed under a server's prefix, or the whole service's, no value read — what a
///   re-point, a removal and the launch sweep clear.
nonisolated struct MCPSecretStore {

    let storage: any SecureTokenStorage

    init(storage: (any SecureTokenStorage)? = nil) {
        self.storage = storage ?? KeychainSecureTokenStorage(service: MCPConstants.keychainService)
    }

    // MARK: - Applying a save

    /// What the accounts a save changed held before it — what `restore(_:)` puts back. Holds
    /// secret values for the length of one save, no longer: `apply` makes it, and the save that
    /// asked for it drops it when it returns.
    struct Undo: Sendable {
        fileprivate let prior: [String: String?]
    }

    /// Performs a save's plan all or nothing, as far as the Keychain lets it.
    ///
    /// Every account the plan touches is READ first, and a Keychain that refuses a read — locked,
    /// an ACL — changes nothing (`.keychainUnreadable`): an undo needs to know what to put back.
    /// An entry that exists but is corrupt (`KeychainError.invalidUTF8`) is the exception: it
    /// counts as holding nothing, is overwritten or cleared as the plan says, and its undo
    /// clears it. A plan with no step reads nothing — a save of a server that reads no secret
    /// never asks the Keychain (`MCPSecretChangePlan`, rule 4). Then each step
    /// in order; a move takes what its source held when the save STARTED, so two headers that
    /// swap names each keep their own value. A step that would leave an account as it is
    /// writes nothing — reopening the sheet does not churn the Keychain. A refused write puts
    /// back every account already changed and throws (`.keychainNotSaved(undone:)`), so the
    /// caller never saves a server whose credential did not land.
    ///
    /// Returns the undo a LATER failure — the server list refusing its write — hands
    /// `restore(_:)`.
    func apply(_ plan: MCPSecretChangePlan) throws -> Undo {
        var prior: [String: String?] = [:]
        // Accounts that hold an entry whose bytes cannot be decoded. For the undo they hold
        // nothing — putting back bytes nobody can read restores nothing — and every step on
        // them runs, since holding nothing READABLE is not holding nothing.
        var corrupt = Set<String>()
        for key in plan.touchedKeys {
            do {
                prior[key] = .some(try storage.loadToken(forKey: key))
            } catch KeychainError.invalidUTF8 {
                // Its own message says to re-enter the token to overwrite the bad entry —
                // refusing the save here left no way to do that short of removing the server.
                prior[key] = .some(nil)
                corrupt.insert(key)
            } catch {
                throw MCPServerEditError.keychainUnreadable
            }
        }

        var current = prior
        var changed: [String: String?] = [:]
        for step in plan.steps {
            let (key, value) = Self.target(of: step, prior: prior)
            guard corrupt.contains(key) || Self.normalized(value) != Self.normalized(current[key] ?? nil)
            else { continue }
            do {
                try storage.setToken(value, forKey: key)
            } catch {
                let undone = restore(Undo(prior: changed))
                throw MCPServerEditError.keychainNotSaved(undone: undone)
            }
            corrupt.remove(key)
            if changed[key] == nil { changed[key] = .some(prior[key] ?? nil) }
            current[key] = .some(value)
        }
        return Undo(prior: changed)
    }

    /// Puts every account `undo` names back to what it held. Tries them all; `false` when the
    /// Keychain refused any.
    @discardableResult
    func restore(_ undo: Undo) -> Bool {
        var complete = true
        for key in undo.prior.keys.sorted() {
            do {
                try storage.setToken(undo.prior[key] ?? nil, forKey: key)
            } catch {
                complete = false
            }
        }
        return complete
    }

    /// The account a step writes and the value it leaves there — `nil` clears it.
    private static func target(
        of step: MCPSecretChangePlan.Step, prior: [String: String?]
    ) -> (key: String, value: String?) {
        switch step {
        case .write(let key, let value): (key, value)
        case .move(let from, let to): (to, prior[from] ?? nil)
        case .delete(let key): (key, nil)
        }
    }

    /// What the Keychain would hold after writing `value`: trimmed, and nothing for blank.
    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    // MARK: - Per-server lifecycle

    /// Every account the Keychain holds for the server — the names under its id
    /// (`MCPServerConfig.secretAccountPrefix`), whatever origin each was entered for, no value
    /// read. What a re-point clears first (`MCPSecretChangePlan`, rule 1). A Keychain that
    /// refuses the listing refuses the save (`.keychainUnreadable`) even when it still reads and
    /// writes values: a re-point that could not see what it must clear saves nothing.
    func heldAccounts(of config: MCPServerConfig) throws -> [String] {
        do {
            return try storage.accountNames(withPrefix: config.secretAccountPrefix)
        } catch {
            throw MCPServerEditError.keychainUnreadable
        }
    }

    /// Clears EVERY account under the server's prefix — the ones it reads, the ones another
    /// address it was pointed at read, a bearer an earlier mode left, a header account a rename
    /// before 2026-09-24 orphaned, whatever a failed Add wrote — and no other server's: the
    /// prefix ends at the id's `/`. Called when the server is
    /// removed, once the list no longer names it; a save clears what it drops or re-points
    /// through its plan (`apply(_:)`). A value left behind is a credential nothing in the UI can
    /// see any more.
    ///
    /// The accounts the config reads are cleared even when the Keychain refuses the LISTING.
    /// Every account is tried, then the first refusal — the listing's included — is thrown, so
    /// the removal can say a credential may have been left behind instead of claiming it was
    /// deleted.
    func clearAll(for config: MCPServerConfig) throws {
        var refusal: (any Error)?
        var accounts = Set(config.allSecretKeys)
        do {
            accounts.formUnion(try storage.accountNames(withPrefix: config.secretAccountPrefix))
        } catch {
            refusal = error
        }
        for key in accounts.sorted() {
            do {
                try storage.setToken(nil, forKey: key)
            } catch {
                refusal = refusal ?? error
            }
        }
        if let refusal { throw refusal }
    }

    // MARK: - The launch sweep

    /// Every account of the MCP service that is spelled under a server id
    /// (`MCPServerConfig.serverID(ofAccount:)`) and that no config in `catalogue` reads
    /// (`allSecretKeys` — switched on or off, whichever folder allows it): a failed Add's
    /// leftovers under an id no server has, what a removal whose clear the Keychain refused left
    /// behind, and a CURRENT server's accounts it no longer reads — another address's, a bearer
    /// its mode does not send, one spelled before an account named its origin. Names only, no
    /// value read.
    ///
    /// Nothing else, ever: an account whose first path segment is not a server id exactly as
    /// this client spells one is not this client's to judge. The LM Studio token lives under
    /// another Keychain service (`KeychainSecureTokenStorage.defaultService`), so this listing
    /// never sees it — and its account, a base URL, begins with a scheme, never an id.
    ///
    /// `catalogue` must be the server list as READ — a list that could not be read is not an
    /// empty one; the caller decides that (`MCPServerManager`). Throws when the Keychain refuses
    /// the listing: nothing is selected from a list nobody could read.
    func orphanedAccounts(readBy catalogue: [MCPServerConfig]) throws -> [String] {
        let read = Set(catalogue.flatMap(\.allSecretKeys))
        return try storage.accountNames(withPrefix: "").filter { account in
            MCPServerConfig.serverID(ofAccount: account) != nil && !read.contains(account)
        }
    }

    /// Clears every one of `accounts`, trying them all; returns how many the Keychain refused.
    /// Housekeeping, so a refusal is counted rather than thrown: what is left is tried again by
    /// the next sweep.
    func clear(_ accounts: [String]) -> Int {
        var refused = 0
        for account in accounts {
            do {
                try storage.setToken(nil, forKey: account)
            } catch {
                refused += 1
            }
        }
        return refused
    }

    /// Which of the accounts the server READS (`allSecretKeys`) hold a value — a blank value
    /// counts as none, as it does on the wire. What "Needs a token" and the editor's "leave
    /// blank to keep" are derived from; a server that reads no secret costs no query. A Keychain
    /// that refuses the read — or an entry it cannot decode — counts as holding nothing: the
    /// editor then asks for the value rather than promising to keep one it could not see.
    func storedKeys(of config: MCPServerConfig) -> Set<String> {
        Set(config.allSecretKeys.filter(holdsValue(forKey:)))
    }

    private func holdsValue(forKey key: String) -> Bool {
        guard let value = storage.token(forKey: key) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
