import Foundation

/// Routes a tool call to the connection that owns it — and is the last place a call can still
/// be stopped before it leaves the machine.
///
/// **Why this is not the manager itself.** The manager is `@MainActor` — it is observable UI
/// state — while a tool call runs from the tool runtime, off the main actor, inside a role's
/// step. Making the manager the invoker would put a main-actor hop in the middle of every
/// tool call, and would make the snapshot's invoker reference a main-actor object that
/// non-isolated code has to await just to ask which server a call belongs to.
///
/// **Why it checks the text as well as the route.** A step decides from a catalogue it froze
/// at entry, and re-checks it once per iteration — before a generation that can take minutes,
/// a card a person can leave open for longer, and the batch's earlier calls (a long `bash`, an
/// `xcodebuild`). Any of those is time enough for a server to rewrite a tool, and the one
/// component that sees every call at the moment it goes out is this one. So each connection
/// publishes, with its session, the hash of every tool a call may reach — the APPROVED ones,
/// at the text approved — and a call made against any other text is refused
/// (`MCPDispatchRefusal`). The same check is what will tie an automatic approver's verdict to
/// the text that actually runs.
///
/// **Why a route can refuse every call while it stands.** A server whose tool list is being read
/// again — a listing asked after its `list_changed`, or once its stated catalogue lifetime ran
/// out, failed — still has a live session, but nothing says which text it serves now, so no
/// approved hash may be trusted to reach it. The connection marks its route unverified
/// (`MCPServerConnection.catalogueUnverified`) in the same write as its hashes — which it keeps,
/// its last committed listing's — and the route refuses every call until a listing commits: as
/// `toolChanged` when the call's text is not one those hashes approve, the verdict the app had
/// already committed, and otherwise as `toolsBeingReread` — the same answers, in the same order,
/// the live catalogue gives (`MCPLiveCatalogueIndex.standing(of:)`).
///
/// Holds only what a call needs: server id → session, approved hashes, that mark. Each connection
/// keeps its own entry in step (`MCPServerConnection`), and every write after the route opens
/// is bound to the SESSION, not to the server id: a connection opens its route only once its
/// session is live, and a write from a session that is not the route's own — a connection
/// replaced by an edit, a listing that landed late, a stop that finished after its successor
/// connected — changes nothing. That holds for withdrawing too: removing a route only ever
/// refuses calls, but refusing every call to a healthy server is its own failure.
nonisolated final class MCPClientRegistry: MCPToolInvoking, @unchecked Sendable {

    /// One server's route: its live session, and the text of every tool a call may reach
    /// through it — the server's own tool name → the hash of the approved text — unless its
    /// tool list is being read again, when it reaches none and the hashes are the verdict of
    /// the listing it last committed.
    private struct Route {
        let client: MCPClient
        var approvedHashes: [String: String]
        var catalogueUnverified: Bool
        /// The protocol revision `client`'s session negotiated — what a call's split between
        /// body and headers must have been decided for (`MCPToolCall.era`).
        let era: MCPProtocolEra
        /// What the connection does when the server answers a call `HeaderMismatch` — read its
        /// tool list again (`callTool`).
        let onHeaderMismatch: (@Sendable () -> Void)?
    }

    private let lock = NSLock()
    private var routes: [UUID: Route] = [:]

    init() {}

    /// A session that has connected, in `era`, and listed its catalogue: calls may now reach it,
    /// for exactly the tools in `approvedHashes`, each at its hash — or none, while
    /// `catalogueUnverified` (a listing asked after the connect's failed before this one
    /// committed), when `approvedHashes` still tells a text that listing approved from one it
    /// did not. `onHeaderMismatch` is how the session's connection is told a call came back
    /// `HeaderMismatch` (`callTool`).
    func publish(
        _ client: MCPClient, approvedHashes: [String: String], catalogueUnverified: Bool = false,
        era: MCPProtocolEra, for serverID: UUID, onHeaderMismatch: (@Sendable () -> Void)? = nil
    ) {
        lock.withLock {
            routes[serverID] = Route(
                client: client, approvedHashes: approvedHashes, catalogueUnverified: catalogueUnverified,
                era: era, onHeaderMismatch: onHeaderMismatch)
        }
    }

    /// The approvals moved — a person approved, revoked or refused a tool, or a listing changed
    /// what the pins cover — or the catalogue became unverified, or verified again. Both in
    /// ONE write, so no call meets a listing's new hashes without its mark or the reverse.
    /// Applied only to the route `session` itself opened: a no-op for a server with no route
    /// (approving never opens one, only a live session does), and for a route another session
    /// owns. The second is not hygiene: a replaced connection still holds the approvals of the
    /// text ITS session listed, and writing them over its successor's route would put back a
    /// text the server has since rewritten.
    func updateApprovedHashes(
        _ approvedHashes: [String: String], catalogueUnverified: Bool = false,
        for serverID: UUID, through session: MCPClient
    ) {
        lock.withLock {
            guard routes[serverID]?.client === session else { return }
            routes[serverID]?.approvedHashes = approvedHashes
            routes[serverID]?.catalogueUnverified = catalogueUnverified
        }
    }

    /// `session` ended or failed. Calls are refused as "not connected" until the next session
    /// has listed its catalogue. A no-op when the route belongs to another session: a
    /// connection replaced by an edit ends its session LATE — after its successor published —
    /// and until 2026-09-23 its withdrawal, keyed by server id alone, wiped the successor's
    /// route (A2 verification, item 12).
    func withdraw(serverID: UUID, through session: MCPClient) {
        lock.withLock {
            guard routes[serverID]?.client === session else { return }
            routes.removeValue(forKey: serverID)
        }
    }

    func removeAll() {
        lock.withLock { routes.removeAll() }
    }

    var connectedServerIDs: Set<UUID> { lock.withLock { Set(routes.keys) } }

    /// Refused rather than crashing when the server went away between the snapshot being
    /// frozen and the call being made — which is exactly what a disabled server, a folder
    /// switch or a reconnect looks like from here — refused when the text the call was made
    /// against is no longer an approved one, and refused while the server's tool list is being
    /// read again even when the text is approved. All decided under the lock, against the route
    /// as it stands at this instant.
    ///
    /// Refused, too, when the call was assembled for another protocol revision than the one the
    /// route's session negotiated (`MCPToolCall.era`, set only for a tool whose schema carries
    /// `x-mcp-header` — `callShapeDependsOnEra` — header parameters or not): the card showed the
    /// call split for that era, and sending it on this session
    /// would send another shape — or the frozen shape, over a channel that cannot carry it. A
    /// reconnect between the card and the send is what produces it. `toolChanged`, as the live
    /// catalogue answers it (`MCPLiveCatalogueIndex.standing(of:)`): the step's calls of that
    /// tool are assembled for an era its server no longer speaks, for the rest of the step.
    ///
    /// The text is checked BEFORE the mark: while the list is being read again the route keeps
    /// the hashes its last committed listing approved, so a call at any other text is refused
    /// as changed — the verdict already committed, which a re-read cannot undo within the step
    /// — and only a call at an approved text is told the list is being read again. The live
    /// catalogue answers in the same order (`MCPLiveCatalogueIndex.standing(of:)`), so the gate
    /// and dispatch give one call one refusal (group C, C-5, 2026-09-24).
    func callTool(_ call: MCPToolCall) async throws -> MCPCallToolResult {
        let (client, onHeaderMismatch) = try lock.withLock { () throws -> (MCPClient, (@Sendable () -> Void)?) in
            guard let route = routes[call.serverID] else { throw MCPDispatchRefusal.serverNotConnected }
            guard route.approvedHashes[call.toolName] == call.expectedHash else {
                throw MCPDispatchRefusal.toolChanged
            }
            if let era = call.era, era != route.era { throw MCPDispatchRefusal.toolChanged }
            guard !route.catalogueUnverified else { throw MCPDispatchRefusal.toolsBeingReread }
            return (route.client, route.onHeaderMismatch)
        }
        do {
            if let resourceURI = call.resourceURI {
                return try await client.readResource(uri: resourceURI)
            }
            return try await client.callTool(
                originalName: call.toolName,
                arguments: call.arguments,
                headerParameters: call.headerParameters)
        } catch MCPClientError.rpc(let code, let message, let data) where code == MCPErrorCode.headerMismatch {
            onHeaderMismatch?()
            throw MCPClientError.rpc(code: code, message: message, data: data)
        }
    }

    /// Dispatches `prompts/get` for a prompt whose pin (`"prompt:<promptName>"` == `expectedHash`)
    /// is currently approved on the live route for `serverID`.
    func getPrompt(
        serverID: UUID,
        promptName: String,
        expectedHash: String,
        arguments: [String: String] = [:]
    ) async throws -> MCPPromptGetResult {
        let pinKey = "prompt:\(promptName)"
        let client = try lock.withLock { () throws -> MCPClient in
            guard let route = routes[serverID] else { throw MCPDispatchRefusal.serverNotConnected }
            guard route.approvedHashes[pinKey] == expectedHash else {
                throw MCPDispatchRefusal.toolChanged
            }
            guard !route.catalogueUnverified else { throw MCPDispatchRefusal.toolsBeingReread }
            return route.client
        }
        return try await client.getPrompt(name: promptName, arguments: arguments)
    }
}
