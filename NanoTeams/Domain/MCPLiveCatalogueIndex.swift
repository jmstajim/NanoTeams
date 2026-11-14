import Foundation

// MARK: - Standing

/// Where one tool a step was set up with stands in the live catalogue.
///
/// The one rule the iteration's drift check (`MCPResolvedTools.drift(against:)`) and the MCP
/// gate both read, so the two cannot disagree about which refusal a call gets, or about whose
/// policy it runs under.
nonisolated enum MCPLiveStanding: Equatable, Sendable {
    /// The live catalogue publishes a tool under this name, for the SAME server. `current`
    /// carries the policy a call runs under now. Its text may still differ from the one the
    /// step froze; comparing the two is the reader's — the drift check compares the hashes,
    /// and the gate hands both to `MCPPermissionService`, whose step 0 denies a mismatch.
    case published(current: MCPToolsSnapshot.Entry)
    /// The live catalogue does not publish the called tool on terms a call may run under, for
    /// the reason the invoker gives the same fact at dispatch (`MCPDispatchRefusal`) — or, for a
    /// server waiting for a person, the one reason only this rule can give, because it reads
    /// the server's status.
    case refused(MCPDispatchRefusal)
}

// MARK: - Index

/// The live catalogue, indexed for a reader that looks up many calls against it — the
/// iteration's drift check once per iteration, the gate once per catalogue revision.
/// `MCPToolsSnapshot.entry(named:)` is a linear scan, and either reader in a loop would make
/// it quadratic.
nonisolated struct MCPLiveCatalogueIndex: Sendable {
    /// The revision of the snapshot this was built from — how a reader holding one knows, in
    /// one comparison, whether the manager has rebuilt since.
    let revision: Int
    private let entriesByName: [String: MCPToolsSnapshot.Entry]
    private let statusByServerID: [UUID: MCPServerStatus]
    private let lastCommittedApprovalsOfUnverifiedServers: [UUID: [String: String]]

    init(_ live: MCPToolsSnapshot) {
        revision = live.revision
        entriesByName = live.entriesByName
        statusByServerID = live.statusByServerID
        lastCommittedApprovalsOfUnverifiedServers = live.lastCommittedApprovalsOfUnverifiedServers
    }

    /// `called` is the step's frozen entry: the tool the model read, on the server the call
    /// will be routed to.
    func standing(of called: MCPToolsSnapshot.Entry) -> MCPLiveStanding {
        // First of all: a tool whose call is split differently in the two protocol eras — its
        // schema carries `x-mcp-header` (`MCPToolDescriptor.callShapeDependsOnEra`) — cannot be
        // called by this step once its server's session speaks another era than the one the
        // step froze: every call of it is assembled for the frozen era, and the approval card
        // shows that shape (`MCPToolCall.era`). Gone for the step, whatever the catalogue says or
        // is re-reading; dispatch answers it the same way (`MCPClientRegistry.callTool`). A tool
        // with no annotation is called the same in both, and is judged by the rules below.
        if called.descriptor.callShapeDependsOnEra,
           let era = statusByServerID[called.serverID]?.connectedEra, era != called.era {
            return .refused(.toolChanged)
        }
        // First, ahead of anything the catalogue publishes: the server's tool list is being
        // read again — a listing that should have read a change (its `list_changed`, or its
        // stated catalogue lifetime running out) failed — so nothing says which text it serves
        // now: no entry of it is a policy a call may run under, and no card may show one. The
        // manager ships none of its tools meanwhile, and the answer is the verdict the app last
        // COMMITTED for this server. A tool that listing approved at the very text the step
        // froze is being read again: a re-read that finds it unchanged brings it back within
        // the step, which the arms below would deny it by reading the absence as a withdrawal
        // (group C, 2026-09-24). Any other — withdrawn, rewritten out of its approval, revoked
        // by a person, or approved only on another server — was gone before the list went into
        // a re-read, and the step was told so; a re-read cannot make its call run in this step,
        // so it stays `toolChanged`, as dispatch answers it from the route's same hashes. Until
        // C-5 (same day) every tool of such a server read as being read again, and a tool
        // already withheld "for the rest of the step" was invited back for the length of the
        // re-read, then refused as changed once more.
        if let approved = lastCommittedApprovalsOfUnverifiedServers[called.serverID] {
            return approved[called.modelFacingName] == called.descriptor.pinHash
                ? .refused(.toolsBeingReread) : .refused(.toolChanged)
        }
        if let current = entriesByName[called.modelFacingName] {
            // The same name on another server is another tool — one server renamed away from
            // the slug and another took it. The call is routed by the FROZEN entry, so deciding
            // it under the new owner's policy would apply neither server's rules to it.
            guard current.serverID == called.serverID else { return .refused(.toolChanged) }
            return .published(current: current)
        }
        // Not published. Which refusal depends on whether the server could bring it back.
        switch statusByServerID[called.serverID] {
        case nil:
            // Removed from the list: its id never comes back — a server added later is another
            // one — so the tool is gone for the rest of the step, which is what "changed" says.
            // "Not connected" would invite a later call that cannot succeed.
            return .refused(.toolChanged)
        case .connected?:
            // Connected, and not offering it as approved: withdrawn by the server, rewritten
            // out of its approval, revoked by a person. (A server whose tool list is being read
            // again is answered above, from its last committed listing, before its absence can
            // reach this arm.)
            return .refused(.toolChanged)
        case .connecting?, .failed?:
            // Between sessions, or failed and retrying on its backoff — which `.failed` always
            // is: a failure the connection does not retry has a case of its own. Every tool of
            // such a server comes back at the same hash when it has a session again.
            return .refused(.serverNotConnected)
        case .needsAuth?, .unsupportedTransport?, .incompatible?, .disabled?:
            // A refused credential, a refused address, a server this client cannot speak to, a
            // server a person switched off: nothing retries any of them
            // (`MCPServerConnection.recordFailure(_:)`; `.disabled` is a person's switch, or a
            // manager shut down with nothing left to run — a restarting connection reads
            // `.connecting`, `MCPServerManager`), so nothing in the step brings the tool back.
            // "Not connected — call it again later" would invite a call that cannot succeed;
            // only a person changing the server's settings clears it.
            return .refused(.serverNeedsAttention)
        }
    }
}
