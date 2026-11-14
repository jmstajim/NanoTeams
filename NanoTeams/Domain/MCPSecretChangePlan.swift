import Foundation

/// Which Keychain accounts one save writes, moves and clears — computed here, performed by
/// `MCPSecretStore.apply(_:)`, so every rule about a server's secrets on an edit is a pure
/// function a test can enumerate.
nonisolated struct MCPSecretChangePlan: Equatable, Sendable {

    nonisolated enum Step: Equatable, Sendable {
        case write(key: String, value: String)
        /// Whatever `from` holds when the save starts goes to `to`: a renamed header keeps the
        /// value it was sent with. Read when the plan is applied, never carried here.
        case move(from: String, to: String)
        case delete(key: String)

        /// Every account the step reads or changes — what an undo has to remember.
        var touchedKeys: [String] {
            switch self {
            case .write(let key, _), .delete(let key): [key]
            case .move(let from, let to): [from, to]
            }
        }
    }

    let steps: [Step]
    /// The saved address reaches a different server than the stored one did.
    let isRepoint: Bool

    /// Every account any step touches, once each, in first-touch order.
    var touchedKeys: [String] {
        var seen = Set<String>()
        return steps.flatMap(\.touchedKeys).filter { seen.insert($0).inserted }
    }

    /// Whether saving `saved` over `stored` points the server at another one — the one case
    /// whose plan needs `held`, so the only save that lists the Keychain.
    static func isRepoint(stored: MCPServerConfig?, saved: MCPServerConfig) -> Bool {
        stored.map { saved.isRepointed(from: $0) } ?? false
    }

    /// The rules, in the order they are applied:
    ///
    /// 1. **A different server** (`MCPServerConfig.isRepointed(from:)`): every account the saved
    ///    config names differs from every one the stored config named — each is spelled under
    ///    its origin (`MCPServerConfig.originAccountPrefix`) — so there is nothing to keep or
    ///    move: a value entered for one host is not the other's (F22), and a blank row stays
    ///    empty. Every account the server HOLDS is cleared FIRST — `held`, the Keychain's own list
    ///    of the accounts under its id, so the old address's and any account no config names any
    ///    more go too — and so is every account either config reads, whether or not the list
    ///    named it. Then what was typed is written.
    /// 2. **A value typed** is written, under the row's saved name.
    /// 3. **A row left blank** keeps what its ORIGINAL name held: in place when the name did not
    ///    change, moved to the new name when it did (a header's account is keyed by its name —
    ///    F42). A move never leaves its origin: rule 1 took every re-point, so the two accounts
    ///    share the one the value was entered for. A row the stored server did not have keeps
    ///    nothing, and neither does a bearer
    ///    the stored server did not send: whatever their accounts hold is left from an earlier
    ///    configuration, so they are cleared rather than sent.
    /// 4. **What the edit dropped** — a removed row, a renamed row's old name, the bearer of a
    ///    server switched to No authentication — is cleared: every account the stored server
    ///    READ (`allSecretKeys`) that the saved one does not. Nothing else: an account neither
    ///    reads is never sent, and a save of a server that reads no secret touches no account at
    ///    all — a locked Keychain cannot refuse it. What such an account holds (a bearer an
    ///    earlier mode left) goes when the server is removed or re-pointed, with the rest of its
    ///    prefix (`MCPSecretStore.clearAll(for:)`, rule 1).
    ///
    /// `stored` is `nil` for a server being added: nothing to keep, move or clear. `held` is read
    /// only on a re-point (`isRepoint(stored:saved:)`); every other save ignores it.
    static func make(
        stored: MCPServerConfig?, saved: MCPServerConfig, edit: MCPServerSecretEdit, held: [String] = []
    ) -> MCPSecretChangePlan {
        let http = saved.transport.http
        let rows = Dictionary(edit.headers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let isRepoint = Self.isRepoint(stored: stored, saved: saved)
        let storedHeaders = Set(stored?.transport.http.secretHeaderNames ?? [])
        var steps: [Step] = []

        if isRepoint, let stored {
            let purged = Set(held).union(stored.allSecretKeys).union(saved.allSecretKeys)
            steps += purged.sorted().map { Step.delete(key: $0) }
        }

        if http.authorization == .staticBearer {
            if !edit.bearer.isEmpty {
                steps.append(.write(key: saved.bearerSecretKey, value: edit.bearer))
            } else if !isRepoint, let stored, stored.transport.http.authorization != .staticBearer {
                steps.append(.delete(key: saved.bearerSecretKey))
            }
        }

        for name in http.secretHeaderNames {
            let key = saved.secretKey(forHeader: name)
            let row = rows[name]
            if let row, !row.value.isEmpty {
                steps.append(.write(key: key, value: row.value))
                continue
            }
            guard !isRepoint, let stored else { continue }
            // No row at all is a save with no editor behind it: the header is kept as it is.
            let original: String? = row.map(\.originalName) ?? name
            if let original, storedHeaders.contains(original) {
                if original != name {
                    steps.append(.move(from: stored.secretKey(forHeader: original), to: key))
                }
            } else {
                steps.append(.delete(key: key))
            }
        }

        if !isRepoint, let stored {
            let read = Set(saved.allSecretKeys)
            for key in stored.allSecretKeys where !read.contains(key) {
                steps.append(.delete(key: key))
            }
        }
        return MCPSecretChangePlan(steps: steps, isRepoint: isRepoint)
    }
}
