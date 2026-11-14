import Foundation

// MARK: - Status

/// Where one server stands. Read by the Settings list, the role-editor badge and the
/// server-detail header.
///
/// Every reason string here has already been through redaction — a 401 body can echo the
/// token that failed, and a transport error can carry the URL with its userinfo intact.
///
/// **Whether it will come back on its own is the case, not a guess.** `.connecting` and
/// `.failed` retry by themselves; `.disabled`, `.needsAuth`, `.unsupportedTransport` and
/// `.incompatible` wait for a person. The gate and the drift check read exactly that
/// (`MCPLiveCatalogueIndex.standing(of:)`) to tell a step's call "try again later" from "this
/// server needs its settings changed".
nonisolated enum MCPServerStatus: Hashable, Sendable {
    /// Nothing runs it, and nothing will until something changes: a person switched it off,
    /// app-wide or for this work folder, or the manager is shut down with no reload since (a
    /// folder that failed to open, the app quitting). Not a failure. A connection between
    /// lifecycles — a restart, a replacement — reads `.connecting` instead, which means a
    /// lifecycle is about to run (`MCPServerManager`).
    case disabled
    case connecting
    /// A live session, in the protocol revision the handshake settled on. It carries no count of
    /// tools: how they stand is the catalogue's business (`MCPToolTally`), and a count frozen
    /// into the status — the approved tools alone, until F47 — told a person with five tools to
    /// review that the server had "0 tools".
    case connected(era: MCPProtocolEra)
    /// 401 or 403. Separated from `.failed` because the repair is a credential, not a retry.
    case needsAuth(reason: String)
    /// It could not connect, or its session ended, and it is trying again on its backoff — for
    /// as long as it keeps failing, slowed to the backoff's last step when failures bunch up
    /// but never stopped (`MCPServerConnection`). A failure retrying cannot repair has its own
    /// case, because its repair is a person's.
    case failed(reason: String)
    /// The endpoint is not one this client will talk to at all — plain HTTP off loopback,
    /// a URL with userinfo, a private-range address. Separated from `.failed` because
    /// retrying cannot help and the repair is the URL.
    case unsupportedTransport(reason: String)
    /// The server speaks nothing this client can read — a protocol revision it does not
    /// support, a catalogue past the frame ceiling, a catalogue that never stops paging.
    /// Separated from `.failed` because retrying cannot help and the repair is the server (or
    /// this app).
    case incompatible(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// The protocol revision a live session settled on; `nil` when there is no session. What a
    /// connected server's tools are listed under (`MCPToolsSnapshot.Entry.era`), and what the
    /// live catalogue compares a step's frozen entry against (`MCPLiveCatalogueIndex`).
    var connectedEra: MCPProtocolEra? {
        if case .connected(let era) = self { return era }
        return nil
    }

    /// It tried and could not. Not `.disabled` — nothing is running it, nor asked to — and not
    /// `.connecting`, which is still trying (a restart reads `.connecting`, never `.disabled`).
    var hasFailed: Bool {
        switch self {
        case .needsAuth, .failed, .unsupportedTransport, .incompatible: true
        case .disabled, .connecting, .connected: false
        }
    }

    /// Short label for a status row. The reason, when there is one, is shown beside it rather
    /// than folded in — it can be long and it is server-controlled. A connected server's tool
    /// counts are the row's to add (`MCPServerRow.subtitle`), and its protocol revision is a line
    /// of its own on the server's page: in a status line "2025-11-25 or earlier" read as a date
    /// the server had connected, and it pushed the counts out of a one-line row (F47).
    var displayLabel: String {
        switch self {
        case .disabled: "Off"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .needsAuth: "Needs authentication"
        case .failed: "Not connected — retrying"
        case .unsupportedTransport: "Address refused"
        case .incompatible: "Incompatible server"
        }
    }

    var reason: String? {
        switch self {
        case .needsAuth(let reason), .failed(let reason), .unsupportedTransport(let reason),
             .incompatible(let reason): reason
        case .disabled, .connecting, .connected: nil
        }
    }
}

// MARK: - Invocation seam

/// One call, already authorized and already type-checked. Built by the dynamic tool, executed
/// by whoever owns the connection.
nonisolated struct MCPToolCall: Hashable, Sendable {
    let serverID: UUID
    /// The server's own name — the folded model-facing one never goes on the wire.
    let toolName: String
    /// The hash of the text the call was made against: the tool as the step's frozen
    /// catalogue carried it, which is what the model read. The invoker refuses the call unless
    /// the server still publishes exactly that text as approved (`MCPDispatchRefusal`) — the
    /// iteration's drift check runs before a long generation, a held card and the batch's
    /// earlier calls, and any of them is time enough for a server to rewrite the tool.
    let expectedHash: String
    /// Always an object; the empty object for a tool with no parameters.
    let arguments: JSONValue
    /// Values the tool's schema asked to be mirrored into `Mcp-Param-*` headers — beside the
    /// same values in `arguments`, modern era only — already name-checked.
    let headerParameters: [String: String]
    /// The protocol revision the call's split between body and headers was decided for
    /// (`MCPArgumentCoercion.Coerced.era`) — the step's frozen entry's, which the approval card
    /// was built against — or `nil` when its call is the same in both: a tool whose schema
    /// carries no `x-mcp-header`. One whose schema carries it (`callShapeDependsOnEra`) names its
    /// era header parameters or not — a legacy listing admits none, and its call is still body
    /// only, which a modern session must not send. The invoker refuses the call
    /// (`MCPDispatchRefusal.toolChanged`) when the
    /// session it would go out on negotiated another era: a reconnect between the card and the
    /// send must not turn the call into one nobody saw.
    let era: MCPProtocolEra?
    /// Non-nil when this call invokes a synthesized resource tool (`resources/read`) for the
    /// resolved `resourceURI` rather than `tools/call`.
    let resourceURI: String?

    init(
        serverID: UUID,
        toolName: String,
        expectedHash: String,
        arguments: JSONValue,
        headerParameters: [String: String],
        era: MCPProtocolEra?,
        resourceURI: String? = nil
    ) {
        self.serverID = serverID
        self.toolName = toolName
        self.expectedHash = expectedHash
        self.arguments = arguments
        self.headerParameters = headerParameters
        self.era = era
        self.resourceURI = resourceURI
    }
}

nonisolated struct MCPCallToolResult: Hashable, Sendable {
    /// The wire's `content` array verbatim: text, image, audio, resource and resource_link
    /// blocks, plus anything this client does not recognise (which the mapper reports rather
    /// than drops). Named `contentBlocks` rather than `content` because a bare `content` is
    /// already a `String` on three other types in this module.
    let contentBlocks: [JSONValue]
    let structuredContent: JSONValue?
    /// The server's own "this call failed" flag. A protocol-level error is thrown instead —
    /// the two are different things and collapsing them would tell a role its arguments were
    /// wrong when the server was simply down.
    let isError: Bool

    init(contentBlocks: [JSONValue], structuredContent: JSONValue? = nil, isError: Bool = false) {
        self.contentBlocks = contentBlocks
        self.structuredContent = structuredContent
        self.isError = isError
    }
}

/// The seam between a tool call in the runtime and the actor that owns the connection. A
/// protocol so the runtime can be driven by a scripted invoker in tests without a socket, and
/// so `Domain` states the contract that `Services/MCP` implements.
nonisolated protocol MCPToolInvoking: Sendable {
    /// Throws `MCPDispatchRefusal` for a call it refused before anything was sent.
    func callTool(_ call: MCPToolCall) async throws -> MCPCallToolResult
}

/// Why a call is refused BEFORE it is sent: the terms it was made on no longer hold.
///
/// Not an `MCPClientError`, because no server was asked: what moved is what the step was set
/// up with. The facts are found at three points — the iteration's drift check, the gate
/// reading the live catalogue (both through `MCPLiveCatalogueIndex.standing(of:)`), and the
/// invoker at the instant of dispatch (`MCPClientRegistry.callTool`), the last component that
/// can still stop the call — and each point answers a fact with the same
/// `ToolUnavailabilityReason`.
///
/// Who produces which: `toolChanged`, `serverNotConnected` and `toolsBeingReread` come from
/// all three points — the last from the snapshot's `lastCommittedApprovalsOfUnverifiedServers`
/// at the first two, and from the route's own mark at the invoker (`MCPClientRegistry`); at
/// every point a server whose list is being read again answers a text its last committed
/// listing did not approve as `toolChanged`, and only an approved one as `toolsBeingReread`.
/// `serverNeedsAttention` comes from `standing(of:)` alone — it is read off the server's STATUS,
/// which the invoker does not hold: to the invoker such a server simply has no route, and it
/// answers `serverNotConnected`.
nonisolated enum MCPDispatchRefusal: Error, Hashable, Sendable {
    /// The called tool is gone for the rest of the step: its connected server rewrote it,
    /// withdrew it or no longer has it approved, the name now belongs to another server, the
    /// server was removed, or — for a tool whose schema carries `x-mcp-header`
    /// (`callShapeDependsOnEra`), header parameters or not — its session now speaks another
    /// protocol revision than the one the step's calls are assembled for, which
    /// sends them in another shape (`MCPToolCall.era`). That holds while the server's tool list is being read again,
    /// when it is answered from the listing the app last committed. A tool that listing still
    /// approved at the called text is not this — `toolsBeingReread` — because a re-read that
    /// finds it unchanged brings it back within the step.
    case toolChanged
    /// The server has no live session and is getting one back on its own: connecting, or
    /// failed and retrying on its backoff (`MCPServerStatus.connecting`, `.failed`). The
    /// refusal leaves a later call open — it is not promised to work, only allowed. The
    /// invoker answers a removed server, one switched off and one that needs a person this way
    /// too: it holds routes, not statuses, and to it they all simply have none. The drift check
    /// and the gate read the statuses and answer those first.
    case serverNotConnected
    /// The server cannot be used until a person changes its settings: its credential was
    /// refused (`MCPServerStatus.needsAuth`), its address is one this client will not talk to
    /// (`.unsupportedTransport`), it speaks nothing this client can read (`.incompatible`), or
    /// a person switched it off (`.disabled`). The connection retries none of these, so no
    /// later call in the step can succeed — unlike `serverNotConnected`, nothing is left open.
    case serverNeedsAttention
    /// The server's tool list is being read again: a listing that should have read a change —
    /// asked after its `list_changed`, or once its stated catalogue lifetime ran out — failed,
    /// and none asked since has committed (`MCPServerConnection.catalogueUnverified`). Nothing
    /// says which text the server serves now, so no call reaches any of its tools — but the
    /// connection lists again on its own, and the first listing that commits brings back, at
    /// the same hash and within the step, every tool it did not change. So the refusal leaves
    /// a later call open, as `serverNotConnected` does; it is given only for a tool the last
    /// committed listing approved at the called text — any other is `toolChanged` throughout —
    /// and a tool the committed re-read DID change is `toolChanged` from then on. Until
    /// 2026-09-24 (group C) this state was refused as `toolChanged`, whose text withholds the
    /// tool for the rest of the step — false the moment the retry commits (R1.8.5).
    case toolsBeingReread
}

// MARK: - Snapshot

/// Every approved tool of every reachable server, frozen at one instant.
///
/// A step reads this ONCE, at entry, and works from the copy for its whole life. That is not
/// caching — it is the reason a mid-step catalogue change is detectable at all: the wire is
/// append-only and the tool list is rendered into the prompt, so narrowing it mid-step would
/// re-prefill every remaining request. Drift is reported to the model as a refusal on the one
/// call that hit it (`mcp_tool_changed`; `mcp_server_not_connected` while the server has no
/// session; `mcp_server_needs_attention` while it waits for a person to change its settings;
/// `mcp_tools_being_reread` while its tool list is being read again after a listing failed),
/// and the NEXT step sees the new catalogue.
///
/// Not `Hashable` — it carries the invoker. `revision` is the change token instead: it is
/// bumped by the manager on every rebuild, so memoised views can compare it.
nonisolated struct MCPToolsSnapshot: Sendable {

    /// One tool, with the server facts the gate needs so it never has to look the server up
    /// again mid-call.
    nonisolated struct Entry: Hashable, Sendable, Identifiable {
        let serverID: UUID
        let slug: MCPServerSlug
        let serverDisplayName: String
        let approvalMode: MCPApprovalMode
        let judgeStrictness: MCPJudgeStrictness
        let serverTrusted: Bool
        /// The user marked this exact tool, at this exact hash, always-allowed.
        let alwaysAllowed: Bool
        /// Whether a call of this tool could clear the policy with nobody watching. Computed
        /// by the manager through `MCPPermissionService` when the snapshot is built, because
        /// the policy lives in `Services` and this type does not reach across that line.
        let runsUnattended: Bool
        let descriptor: MCPToolDescriptor
        /// The protocol revision of the session whose listing published this entry — which
        /// decides how a call of it carries a header parameter (`MCPArgumentCoercion.coerce`).
        /// A step's frozen entry keeps the era it was set up with; a call of a tool whose split
        /// depends on it is refused once the server's session speaks another
        /// (`MCPLiveCatalogueIndex.standing(of:)`, `MCPToolCall.era`).
        let era: MCPProtocolEra

        init(
            serverID: UUID,
            slug: MCPServerSlug,
            serverDisplayName: String,
            approvalMode: MCPApprovalMode,
            judgeStrictness: MCPJudgeStrictness = .standard,
            serverTrusted: Bool,
            alwaysAllowed: Bool,
            runsUnattended: Bool,
            descriptor: MCPToolDescriptor,
            era: MCPProtocolEra
        ) {
            self.serverID = serverID
            self.slug = slug
            self.serverDisplayName = serverDisplayName
            self.approvalMode = approvalMode
            self.judgeStrictness = judgeStrictness
            self.serverTrusted = serverTrusted
            self.alwaysAllowed = alwaysAllowed
            self.runsUnattended = runsUnattended
            self.descriptor = descriptor
            self.era = era
        }

        var modelFacingName: String { descriptor.modelFacingName }
        var id: String { modelFacingName }
        /// The grant that holds this tool's whole server.
        var serverGrantName: String { MCPToolNaming.serverGrant(slug: slug.rawValue) }
    }

    /// Sorted by (slug, model-facing name) so the prompt's tool list is stable across
    /// launches — an unstable order would miss the server's prefix cache on every run.
    let entries: [Entry]
    let statusByServerID: [UUID: MCPServerStatus]
    /// Connected servers whose catalogue is unverified, each with what its LAST COMMITTED
    /// listing approved — model-facing name → pin hash of the approved text
    /// (`MCPGrantCatalogue.lastCommittedApprovalsOfUnverifiedServers`). The keys are the
    /// unverified set; a server whose last commit approved nothing maps to an empty table.
    /// None of their tools is in `entries`, and this is how `MCPLiveCatalogueIndex.standing(of:)`
    /// tells an absence a listing may end — a tool that commit approved at the frozen text —
    /// from a withdrawal the app had already committed. Never shipped: nothing that reads
    /// `entries` reads this.
    let lastCommittedApprovalsOfUnverifiedServers: [UUID: [String: String]]
    /// Bumped by the manager on every rebuild. The only equality anyone needs here.
    let revision: Int
    let invoker: (any MCPToolInvoking)?

    init(
        entries: [Entry] = [],
        statusByServerID: [UUID: MCPServerStatus] = [:],
        lastCommittedApprovalsOfUnverifiedServers: [UUID: [String: String]] = [:],
        revision: Int = 0,
        invoker: (any MCPToolInvoking)? = nil
    ) {
        self.entries = entries.sorted {
            ($0.slug, $0.modelFacingName) < ($1.slug, $1.modelFacingName)
        }
        self.statusByServerID = statusByServerID
        self.lastCommittedApprovalsOfUnverifiedServers = lastCommittedApprovalsOfUnverifiedServers
        self.revision = revision
        self.invoker = invoker
    }

    /// What a run with no MCP at all sees — and what every existing caller gets by default, so
    /// a prompt built without MCP stays byte-identical to the one built before this feature
    /// existed.
    static let empty = MCPToolsSnapshot()

    var isEmpty: Bool { entries.isEmpty }

    func entry(named modelFacingName: String) -> Entry? {
        entries.first { $0.modelFacingName == modelFacingName }
    }

    /// Every entry by its model-facing name — for a caller that looks several names up, which
    /// `entry(named:)`'s scan would make quadratic. Names are unique by construction (the fold
    /// is namespaced by slug and the factory refuses a repeat), so the first of a collision
    /// can only be a caller's fixture.
    var entriesByName: [String: Entry] {
        Dictionary(entries.map { ($0.modelFacingName, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var modelFacingNames: Set<String> { Set(entries.map(\.modelFacingName)) }

    /// The entries a role's `toolIDs` grants: a whole-server grant (`mcp__<slug>`) brings
    /// every approved tool of that server, an exact name brings one.
    ///
    /// Order follows `entries`, not the grant list — a role that lists its grants in a
    /// different order must still produce a byte-identical prompt.
    func entries(grantedBy grants: some Sequence<String>) -> [Entry] {
        var grantedSlugs = Set<String>()
        var grantedNames = Set<String>()
        for id in grants {
            guard MCPToolNaming.isMCPName(id) else { continue }
            if MCPToolNaming.isServerGrant(id), let slug = MCPToolNaming.slug(ofName: id) {
                grantedSlugs.insert(slug)
            } else {
                grantedNames.insert(id)
            }
        }
        guard !grantedSlugs.isEmpty || !grantedNames.isEmpty else { return [] }
        return entries.filter { grantedSlugs.contains($0.slug.rawValue) || grantedNames.contains($0.modelFacingName) }
    }

    /// Splits the catalogue by whether a call could reach a decision in THIS run.
    ///
    /// With a human present nothing is withheld — every held call has someone to answer it.
    /// Without one, a tool whose every call would sit waiting is withheld from the schema
    /// rather than advertised: advertising it costs a model turn per attempt and teaches
    /// nothing (KNOWN_ISSUES B3). The split is per TOOL, not per server, because one server's
    /// read-only tools can run unattended while its mutating ones cannot.
    func resolved(humanPresent: Bool) -> MCPResolvedTools {
        guard !humanPresent else {
            return MCPResolvedTools(
                shipped: entries, withheld: [], invoker: invoker, revision: revision)
        }
        var shipped: [Entry] = []
        var withheld: [Entry] = []
        for entry in entries {
            if entry.runsUnattended { shipped.append(entry) } else { withheld.append(entry) }
        }
        return MCPResolvedTools(
            shipped: shipped, withheld: withheld, invoker: invoker, revision: revision)
    }
}

// MARK: - Resolved

/// The snapshot split for one run. `withheld` has exactly one cause — nobody is there to
/// approve a call of it — so the classifier answers a call of a withheld name with
/// `approval_unavailable` and no further discrimination is needed.
nonisolated struct MCPResolvedTools: Sendable {

    let shipped: [MCPToolsSnapshot.Entry]
    let withheld: [MCPToolsSnapshot.Entry]
    let invoker: (any MCPToolInvoking)?
    /// The snapshot revision this was split from. Carried so a step that froze it can tell,
    /// in one comparison, whether the catalogue has moved at all since — which is the
    /// answer on every iteration but the rare one.
    let revision: Int

    init(
        shipped: [MCPToolsSnapshot.Entry] = [],
        withheld: [MCPToolsSnapshot.Entry] = [],
        invoker: (any MCPToolInvoking)? = nil,
        revision: Int = 0
    ) {
        self.shipped = shipped
        self.withheld = withheld
        self.invoker = invoker
        self.revision = revision
    }

    static let empty = MCPResolvedTools()

    var isEmpty: Bool { shipped.isEmpty && withheld.isEmpty }

    var shippedNames: Set<String> { Set(shipped.map(\.modelFacingName)) }
    var withheldNames: Set<String> { Set(withheld.map(\.modelFacingName)) }

    func entry(named modelFacingName: String) -> MCPToolsSnapshot.Entry? {
        shipped.first { $0.modelFacingName == modelFacingName }
    }

    /// The shipped entries by model-facing name — built once by a caller that looks up every
    /// call of a batch.
    var shippedByName: [String: MCPToolsSnapshot.Entry] {
        Dictionary(shipped.map { ($0.modelFacingName, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Narrows to what one role was granted, keeping the shipped/withheld split — the step
    /// needs BOTH: the shipped half goes into the schema and the registry, and the withheld
    /// half is what the classifier recognises when the model calls one anyway.
    func granted(by grants: some Sequence<String>) -> MCPResolvedTools {
        let ids = Set(grants)
        func keep(_ entry: MCPToolsSnapshot.Entry) -> Bool {
            ids.contains(entry.modelFacingName) || ids.contains(entry.serverGrantName)
        }
        return MCPResolvedTools(
            shipped: shipped.filter(keep), withheld: withheld.filter(keep),
            invoker: invoker, revision: revision)
    }

    /// Which of the tools this step SHIPPED the live catalogue no longer answers for on the
    /// same terms, split by why: the tool is gone for the rest of the step (its server rewrote
    /// its description or schema after the user approved it, withdrew it or lost its approval;
    /// the name now belongs to another server; the server was removed), its server has no
    /// live session at the moment, its server cannot be used until a person changes its
    /// settings, or its server's tool list is being read again and its last committed listing
    /// approved the tool at the frozen text.
    ///
    /// This is the drift half of the freeze. A step reads the catalogue once and keeps the
    /// copy, because the tool list is rendered into segment 0 of the prompt and the wire is
    /// append-only — narrowing it mid-step would re-prefill every remaining request. So the
    /// SCHEMA keeps promising the tool, and the promise is kept honest here instead: the one
    /// call that hits a drifted tool is refused (`mcp_tool_changed`; `mcp_server_not_connected`
    /// for a server between sessions; `mcp_server_needs_attention` for one that waits for a
    /// person; `mcp_tools_being_reread` for one whose tool list is being read again), and the
    /// next step resolves against the new catalogue. Exactly the shape `workSuperseded` uses
    /// for the build runners, and for the same reason.
    ///
    /// The hash is what makes "changed" decidable rather than guessed: it is taken over what
    /// the server SENT, so a rewritten description — the rug pull this whole design is
    /// pinned against — moves it even when the name and the arguments do not. The server's
    /// status is what keeps a reconnect from reading as a change: every tool of a server leaves
    /// the live catalogue while it has no session, and comes back with the same hash when it
    /// has one. Which of the two a missing tool is, is `MCPLiveCatalogueIndex.standing(of:)`'s
    /// call — the rule the gate reads too.
    func drift(against live: MCPToolsSnapshot) -> MCPToolDrift {
        // The common answer, in one integer comparison: the manager bumps `revision` on
        // every rebuild, so an unchanged revision means an unchanged catalogue.
        guard live.revision != revision, !shipped.isEmpty else { return .none }
        let index = MCPLiveCatalogueIndex(live)
        var changed: Set<String> = []
        var serverNotConnected: Set<String> = []
        var serverNeedsAttention: Set<String> = []
        var toolsBeingReread: Set<String> = []
        for entry in shipped {
            switch index.standing(of: entry) {
            case .published(let current):
                if current.descriptor.pinHash != entry.descriptor.pinHash {
                    changed.insert(entry.modelFacingName)
                }
            case .refused(.toolChanged):
                changed.insert(entry.modelFacingName)
            case .refused(.serverNotConnected):
                serverNotConnected.insert(entry.modelFacingName)
            case .refused(.serverNeedsAttention):
                serverNeedsAttention.insert(entry.modelFacingName)
            case .refused(.toolsBeingReread):
                toolsBeingReread.insert(entry.modelFacingName)
            }
        }
        return MCPToolDrift(
            changed: changed, serverNotConnected: serverNotConnected,
            serverNeedsAttention: serverNeedsAttention, toolsBeingReread: toolsBeingReread)
    }
}

// MARK: - Drift

/// Why tools a step shipped no longer answer on the terms the step was set up with — split by
/// what the model can do about each, because the four have different repairs.
nonisolated struct MCPToolDrift: Equatable, Sendable {
    /// Gone for the rest of the step: the connected server publishes the tool at another hash
    /// or not at all, the name now belongs to another server, the server was removed, or — for a
    /// tool whose schema carries `x-mcp-header` (`callShapeDependsOnEra`), header parameters or
    /// not — its session now speaks another protocol revision than the one the step's calls are
    /// assembled for.
    /// Nothing in the step can bring the approved text back, so the tool is withheld. While a
    /// server's tool list is being read again this is answered from its last committed
    /// listing: a tool that listing had not approved at the frozen text stays here, and one it
    /// had is not — a re-read that finds it unchanged brings it back within the step
    /// (`toolsBeingReread`).
    let changed: Set<String>
    /// The server has no live session right now and is reconnecting on its own — connecting,
    /// or failed and retrying on its backoff. When it reconnects its tools come back at the
    /// same hash, often seconds later, so the refusal leaves a later call open.
    let serverNotConnected: Set<String>
    /// The server cannot be used until a person changes its settings — a refused credential, a
    /// refused address, a server this client cannot speak to, or one switched off. Nothing
    /// retries it, so nothing in the step brings the tool back and no later call is invited;
    /// unlike `changed`, the tool itself is untouched.
    let serverNeedsAttention: Set<String>
    /// The server's tool list is being read again — a listing asked after its `list_changed`,
    /// or once its stated catalogue lifetime ran out, failed, and it is being listed again on
    /// its own — and its last committed listing approved the tool at the frozen text. Not
    /// `changed`: nothing says the tool changed, and the first listing that commits brings
    /// back, at the same hash, every tool it did not change — nothing latches, so the next
    /// iteration's drift is read afresh and the tool is simply not in it. A tool that listing
    /// DID change moves to `changed` then.
    let toolsBeingReread: Set<String>

    init(
        changed: Set<String>, serverNotConnected: Set<String>,
        serverNeedsAttention: Set<String> = [], toolsBeingReread: Set<String> = []
    ) {
        self.changed = changed
        self.serverNotConnected = serverNotConnected
        self.serverNeedsAttention = serverNeedsAttention
        self.toolsBeingReread = toolsBeingReread
    }

    /// Every drifted name — what the iteration withholds from the executor's allowed set.
    var names: Set<String> {
        changed.union(serverNotConnected).union(serverNeedsAttention).union(toolsBeingReread)
    }

    static let none = MCPToolDrift(changed: [], serverNotConnected: [])
}

/// Immutable value snapshot of all currently approved MCP prompts across connected, enabled
/// servers (`DEBTS.md` D-M3). Consumed by the `/` skills picker (`SkillsPickerButton`) to
/// surface reviewed MCP prompts without touching the connection actors directly.
nonisolated struct MCPPromptsSnapshot: Hashable, Sendable {

    nonisolated struct Entry: Hashable, Sendable {
        let serverID: UUID
        let slug: MCPServerSlug
        let serverDisplayName: String
        let descriptor: MCPPromptDescriptor
    }

    static let empty = MCPPromptsSnapshot(entries: [], folderAllowedServerIDs: nil)

    let entries: [Entry]
    let folderAllowedServerIDs: Set<UUID>?
}
