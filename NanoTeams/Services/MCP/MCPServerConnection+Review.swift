import Foundation

// MARK: - Review actions

/// The decisions a person makes about one server's tools — approve, refuse, revoke, approve the
/// new ones in bulk, grant or withdraw "always allow".
///
/// Every one of them is bound to the text the person had on screen: the descriptor the review
/// sheet rendered, the list the confirmation named, the hash the approval card showed. A server
/// may rewrite a tool while the sheet is open (a `list_changed`, a reconnect, the stale sweep),
/// and a decision recorded against the text that arrived meanwhile would be a decision about
/// text nobody read — so it is refused with an `MCPReviewError` instead, and the person reads
/// the tool again. Each write is followed by `adoptTrustRecord()`, the one place the observed
/// trust state moves.
extension MCPServerConnection {

    /// Approves the text that was read. Refused when the server has since rewritten or
    /// withdrawn the tool.
    ///
    /// Approving a text that is already approved changes nothing — above all not its standing
    /// grant, which a fresh pin would reset.
    func approve(reviewed: MCPToolDescriptor) throws {
        let live = try liveDescriptor(matching: reviewed, in: liveIndex())
        guard !pinState(of: live).isApproved else { return }
        try trustStore.approve(
            serverID: config.id, tool: live.originalName,
            canonicalForm: MCPPinHasher.canonicalForm(rawTool: reviewed.rawTool))
        adoptTrustRecord()
        log?.notePin(tool: live.originalName, state: "approved")
        onChange()
    }

    /// Approves a reviewed prompt descriptor (`prompts/list`).
    func approvePrompt(reviewed: MCPPromptDescriptor) throws {
        try approve(reviewed: reviewed.asReviewDescriptor(slug: config.slug))
    }

    /// Approves exactly the tools a confirmation listed — each at its own text — or none of
    /// them: a list in which any tool has moved, or stopped being new, is not the list the
    /// person confirmed.
    func approveNewTools(_ listed: [MCPToolDescriptor]) throws {
        guard !listed.isEmpty else { return }
        let index = liveIndex()
        var forms: [String: String] = [:]
        for reviewed in listed {
            guard let live = index[reviewed.originalName], live.pinHash == reviewed.pinHash,
                  pinState(of: live) == .new, !isRejected(live) else {
                throw MCPReviewError.listChangedWhileReviewing
            }
            forms[live.originalName] = MCPPinHasher.canonicalForm(rawTool: reviewed.rawTool)
        }
        try trustStore.approveAll(serverID: config.id, canonicalFormsByTool: forms)
        adoptTrustRecord()
        for name in forms.keys.sorted() { log?.notePin(tool: name, state: "approved") }
        onChange()
    }

    /// Refuses the text that was read — a new tool, or the rewrite of an approved one. A
    /// refused rewrite keeps the old approval, so the tool stays "changed" against what was
    /// read instead of turning into an innocent-looking new one, and it loses its grant.
    func reject(reviewed: MCPToolDescriptor) throws {
        let live = try liveDescriptor(matching: reviewed, in: liveIndex())
        guard try trustStore.reject(serverID: config.id, tool: live.originalName, hash: live.pinHash) else {
            throw MCPReviewError.alreadyApproved
        }
        adoptTrustRecord()
        log?.notePin(tool: live.originalName, state: "rejected")
        onChange()
    }

    /// Revokes the approval that was on screen. The pin goes, and the tool comes back as new.
    func revoke(tool: String, reviewedHash: String) throws {
        guard try trustStore.revoke(serverID: config.id, tool: tool, expectedHash: reviewedHash) else {
            throw MCPReviewError.changedWhileReviewing
        }
        adoptTrustRecord()
        log?.notePin(tool: tool, state: "revoked")
        onChange()
    }

    /// Grants or withdraws "run this without asking". A grant needs the text on the screen
    /// that gave it (`expectedHash` — the approval card's `pinHash`, or the Settings row's
    /// tool) to be both what runs now and what was approved; either one moving since means the
    /// person granted it for a text that is not this one. And it needs a mode that allows one
    /// (`MCPApprovalMode.allowsStandingGrants`), read off `config` — the LIVE policy: an edit of
    /// the mode is taken in place, without a reconnect (`adopt(_:)`), so a server saved to
    /// Manual refuses a grant from that moment. Until 2026-10-28 the mode was not read
    /// here, and a Manual server's page could record a grant that counted for nothing until the
    /// server was made Semi-automatic — and then switched itself on, unreviewed. A connection
    /// stopped for good records no grant either: an edit that replaced it (a failed connection
    /// is replaced, not adopted) left its `config` behind the server's. A withdrawal is never
    /// refused.
    ///
    /// A refused grant THROWS, and says why — each reason its own `MCPReviewError`, which is what
    /// the server page puts on its banner: the connection was stopped (`.connectionStopped`), the
    /// mode allows none (`.standingGrantsNotAllowed`), the text moved (`.changedWhileReviewing`),
    /// asked in that order — a stopped connection's `config` is not the server's, so its mode
    /// says nothing. Until 2026-10-28 every refusal was one `false`, and the page read all
    /// three as "The tool changed while you were reading".
    func setAlwaysAllow(tool: String, allowed: Bool, expectedHash: String) throws {
        if allowed {
            guard !isStopped else { throw MCPReviewError.connectionStopped }
            guard config.approvalMode.allowsStandingGrants else { throw MCPReviewError.standingGrantsNotAllowed }
            guard liveIndex()[tool]?.pinHash == expectedHash else { throw MCPReviewError.changedWhileReviewing }
        }
        let done = try trustStore.setAlwaysAllow(
            serverID: config.id, tool: tool, expectedHash: expectedHash, allowed: allowed)
        adoptTrustRecord()
        onChange()
        // The approval on record is no longer the text on screen: nothing was granted.
        if allowed, !done { throw MCPReviewError.changedWhileReviewing }
    }

    /// The live catalogue by the server's own name — built once per action, so a bulk
    /// approval looks each listed tool up without rescanning the list per tool.
    private func liveIndex() -> [String: MCPToolDescriptor] {
        var index = Dictionary(descriptors.map { ($0.originalName, $0) }, uniquingKeysWith: { first, _ in first })
        for prompt in promptDescriptors where index[prompt.pinKey] == nil {
            index[prompt.pinKey] = prompt.asReviewDescriptor(slug: config.slug)
        }
        return index
    }

    /// The live descriptor the person's decision applies to, or the reason there is none.
    private func liveDescriptor(
        matching reviewed: MCPToolDescriptor, in index: [String: MCPToolDescriptor]
    ) throws -> MCPToolDescriptor {
        guard let live = index[reviewed.originalName] else { throw MCPReviewError.withdrawn }
        guard live.pinHash == reviewed.pinHash else { throw MCPReviewError.changedWhileReviewing }
        return live
    }
}
