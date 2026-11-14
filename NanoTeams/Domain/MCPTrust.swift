import Foundation

// MARK: - Era

/// Which revision of the protocol a server speaks. The two are not dialects of one protocol —
/// the modern one has no `initialize`, no sessions and no server→client requests — so the
/// client picks once, at connect, and every layer above reads this answer rather than sniffing
/// again.
nonisolated enum MCPProtocolEra: String, Codable, Hashable, Sendable, CaseIterable {
    /// 2026-07-28: `server/discover`, capabilities in `params._meta`, POST only.
    case modern
    /// 2025-11-25 and earlier: `initialize` → `notifications/initialized`, `Mcp-Session-Id`,
    /// a GET stream the server pushes down.
    case legacy

    var displayName: String {
        switch self {
        case .modern: MCPConstants.modernProtocolVersion
        case .legacy: "2025-11-25 or earlier"
        }
    }

    /// Whether a session of this era has a header channel for a tool's parameters — the one
    /// fact the split of a call between body and headers rests on (`MCPArgumentCoercion.coerce`),
    /// and what the review sheet says of a tool's header parameters (`MCPHeaderParamsNote`).
    /// Only 2026-07-28 defines `x-mcp-header`; the legacy revisions send every argument in the
    /// body alone. Exhaustive, so an era added later answers it.
    var carriesHeaderParameters: Bool {
        switch self {
        case .modern: true
        case .legacy: false
        }
    }
}

// MARK: - Pins

/// One approved tool, frozen. `hash` is what the user actually read and said yes to, and every
/// call is checked against it twice: the gate refuses a call made against any other text
/// (`LLMExecutionService.mcpDecision` — the model's text is the step's frozen one, the pin is
/// the live one), and the invoker refuses it again at the instant it would go out, if the
/// server no longer publishes that text as approved (`MCPClientRegistry.callTool`). The second
/// check covers what the first cannot see: a card held for minutes, or an earlier call of the
/// same batch.
///
/// This is the answer to the rug pull: a server may publish an honest tool, wait for it to be
/// approved, and then change its description to something the model will obey. Re-hashing per
/// call means the swap surfaces as "changed — review" instead of as a tool the model quietly
/// starts using differently.
nonisolated struct MCPToolPin: Codable, Hashable, Sendable {

    /// The server's own name for the tool, not the folded model-facing one — the fold is
    /// lossy, so two distinct server tools can fold to the same name and must not share a pin.
    let toolName: String
    let hash: String
    var approvedAt: Date
    /// Set by the user on the approval card or in Settings. Bound to `hash`: a refresh that
    /// finds the live tool at another hash clears it and persists the clearing
    /// (`MCPTrustStore.reconcile`), so a server that reverts its text later does not get the
    /// grant back — the person has to give it again for the text they read again.
    var alwaysAllow: Bool
    /// When the tool stopped appearing in the server's catalogue. A restarting server drops
    /// its whole list for a moment, so a pin is kept for `removedPinRetention` before being
    /// pruned — otherwise every server restart would send the user back through the review
    /// sheet.
    var removedAt: Date?
    /// The exact bytes `hash` was taken over (`MCPPinHasher.canonicalForm`) — the text the
    /// person approved, kept so a later rewrite can be shown as a diff against it. `nil` on a
    /// pin written before 2026-09-23, which recorded only the hash; the review sheet says so
    /// rather than inventing a "before" side. Optional, so a file from either side of that
    /// date decodes on either side of it.
    let approvedCanonicalJSON: String?

    init(
        toolName: String,
        hash: String,
        approvedAt: Date,
        alwaysAllow: Bool = false,
        removedAt: Date? = nil,
        approvedCanonicalJSON: String? = nil
    ) {
        self.toolName = toolName
        self.hash = hash
        self.approvedAt = approvedAt
        self.alwaysAllow = alwaysAllow
        self.removedAt = removedAt
        self.approvedCanonicalJSON = approvedCanonicalJSON
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            toolName: try c.decode(String.self, forKey: .toolName),
            hash: try c.decode(String.self, forKey: .hash),
            approvedAt: try c.decodeIfPresent(Date.self, forKey: .approvedAt) ?? Date(timeIntervalSince1970: 0),
            alwaysAllow: try c.decodeIfPresent(Bool.self, forKey: .alwaysAllow) ?? false,
            removedAt: try c.decodeIfPresent(Date.self, forKey: .removedAt),
            approvedCanonicalJSON: try c.decodeIfPresent(String.self, forKey: .approvedCanonicalJSON))
    }

    /// A pin whose tool has been gone longer than the retention window. Not a property of the
    /// pin alone — it takes a clock — so it is a method and the caller supplies `now`.
    func isPrunable(now: Date, retention: TimeInterval = MCPConstants.removedPinRetention) -> Bool {
        guard let removedAt else { return false }
        return now.timeIntervalSince(removedAt) > retention
    }
}

/// Where one live tool stands against the pins.
nonisolated enum MCPPinState: Hashable, Sendable {
    /// Pinned, and the live hash matches. The only state in which a tool reaches a prompt.
    case approved
    /// The server publishes it; nobody has approved it. Withheld from every prompt until
    /// someone reads it.
    case new
    /// Approved once, but the server has since changed the text or the schema. Withheld; the
    /// review sheet shows the new text beside a diff against the approved one when the pin
    /// recorded it (`MCPToolPin.approvedCanonicalJSON`).
    case changed(approvedHash: String)

    /// The one rule, for ONE descriptor at ITS OWN hash. Every reader — the diff, the
    /// connection's rows, the manager's catalogue — derives the state here, so a tool can
    /// never read as approved on the strength of another entry's hash.
    init(liveHash: String, pin: MCPToolPin?) {
        guard let pin else {
            self = .new
            return
        }
        self = pin.hash == liveHash ? .approved : .changed(approvedHash: pin.hash)
    }

    var isApproved: Bool {
        if case .approved = self { return true }
        return false
    }

    /// The hash of the approval on record for a tool published at `liveHash` — what a revoke
    /// is bound to. For a rewrite that is the OLD text's hash: the live one was never approved,
    /// and the approval a person withdraws from a rewrite's sheet is the one it is compared to.
    /// `nil` for a tool nobody approved.
    func approvedHash(liveHash: String) -> String? {
        switch self {
        case .approved: liveHash
        case .new: nil
        case .changed(let approvedHash): approvedHash
        }
    }
}

/// The whole comparison between what a server publishes now and what the user approved. Pure —
/// no I/O, no clock beyond the one passed in — so the store that persists pins and the view
/// that renders them read the same answer.
nonisolated struct MCPPinDiff: Hashable, Sendable {

    /// Live tool name → its state.
    let states: [String: MCPPinState]
    /// Pinned tools that are no longer published. Kept (not dropped) until the retention
    /// window closes.
    let removed: [String]

    var approvedNames: [String] { states.filter { $0.value.isApproved }.keys.sorted() }
    var newNames: [String] { states.compactMap { if case .new = $0.value { return $0.key } else { return nil } }.sorted() }
    var changedNames: [String] { states.compactMap { if case .changed = $0.value { return $0.key } else { return nil } }.sorted() }

    /// `liveHashes` is the server's current catalogue, tool name → freshly computed hash.
    static func between(liveHashes: [String: String], pins: [String: MCPToolPin]) -> MCPPinDiff {
        var states: [String: MCPPinState] = [:]
        for (name, hash) in liveHashes {
            states[name] = MCPPinState(liveHash: hash, pin: pins[name])
        }
        let removed = pins.keys.filter { liveHashes[$0] == nil }.sorted()
        return MCPPinDiff(states: states, removed: removed)
    }
}

// MARK: - Trust record

/// Everything the app remembers about one server across launches, apart from its configuration
/// and its secret.
nonisolated struct MCPServerTrustRecord: Codable, Hashable, Sendable {

    /// When the user first approved anything on this server. `nil` for a server nobody has
    /// reviewed yet.
    var approvedAt: Date?
    /// The era the probe settled on last time. A cache, never a belief: one failed connect on
    /// the cached era re-probes, because a server can be upgraded under the app.
    var cachedEra: MCPProtocolEra?
    /// Keyed by the server's own tool name.
    var toolPins: [String: MCPToolPin]
    /// Tool name → the hash of a text the person read and REFUSED. Display only: it keeps a
    /// refused text flagged as refused — out of the review count and out of bulk approval —
    /// and decides nothing about what reaches a prompt, which is the pins' business alone.
    ///
    /// Kept beside the pins rather than on them because a tool that was never approved has no
    /// pin, and refusing a NEW tool is as much a decision as refusing a rewrite.
    ///
    /// **Never equal to the same tool's pinned hash** (`normalize()`): a rejection AT the
    /// approved hash would read as "refused" here and as "approved" to a build that predates
    /// this field — one text, two answers. Both mutators keep the rule, and a decode repairs
    /// a file that breaks it.
    private(set) var rejectedHashes: [String: String]

    init(
        approvedAt: Date? = nil,
        cachedEra: MCPProtocolEra? = nil,
        toolPins: [String: MCPToolPin] = [:],
        rejectedHashes: [String: String] = [:]
    ) {
        self.approvedAt = approvedAt
        self.cachedEra = cachedEra
        self.toolPins = toolPins
        self.rejectedHashes = rejectedHashes
        normalize()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            approvedAt: try c.decodeIfPresent(Date.self, forKey: .approvedAt),
            cachedEra: try c.decodeIfPresent(MCPProtocolEra.self, forKey: .cachedEra),
            toolPins: try c.decodeIfPresent([String: MCPToolPin].self, forKey: .toolPins) ?? [:],
            rejectedHashes: try c.decodeIfPresent([String: String].self, forKey: .rejectedHashes) ?? [:])
    }

    static let empty = MCPServerTrustRecord()

    /// Pins a tool, dropping a rejection of the very text being approved.
    mutating func setPin(_ pin: MCPToolPin) {
        toolPins[pin.toolName] = pin
        normalize()
    }

    /// Records that the person refused `tool` at `hash`. `false` — and nothing written — when
    /// that hash is the one approved: an approved text is revoked, never "rejected".
    @discardableResult
    mutating func reject(tool: String, hash: String) -> Bool {
        guard toolPins[tool]?.hash != hash else { return false }
        rejectedHashes[tool] = hash
        return true
    }

    /// The text the person refused for `tool` — `nil` when they refused nothing, or refused a
    /// text the server no longer publishes (`isRejected(_:)` compares it against the live hash).
    func rejectedHash(of tool: String) -> String? { rejectedHashes[tool] }

    /// Whether the person refused exactly the text `descriptor` carries. A refusal is of one
    /// text: the server's next rewrite is not covered by it. The one reading of a refusal — the
    /// connection's rows and its tally (`MCPServerConnection.isRejected`) and the grant
    /// catalogue's tools (`MCPServerManager.tools(of:under:)`) all ask it here, so the Settings
    /// list's "to review" and a role's "waiting for review" cannot count a refused text apart.
    func isRejected(_ descriptor: MCPToolDescriptor) -> Bool {
        rejectedHash(of: descriptor.originalName) == descriptor.pinHash
    }

    private mutating func normalize() {
        for (tool, hash) in rejectedHashes where toolPins[tool]?.hash == hash {
            rejectedHashes[tool] = nil
        }
    }
}

// MARK: - Files on disk

/// `~/Library/Application Support/NanoTeams/mcp/trust.json`. Keyed by the server's UUID
/// string — not by slug, so renaming a server keeps its approvals, and not by URL, so
/// re-pointing one does NOT: an edit that points a server at another scheme, host or port
/// forgets its record before the new address is saved (`MCPServerManager.save`). Pins and
/// always-allow grants never follow a server to a host nobody reviewed.
nonisolated struct MCPTrustFile: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var records: [String: MCPServerTrustRecord]

    init(schemaVersion: Int = MCPTrustFile.currentSchemaVersion, records: [String: MCPServerTrustRecord] = [:]) {
        self.schemaVersion = schemaVersion
        self.records = records
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        self.init(
            // Bumped on read so a legacy decode cannot re-persist the old version forever
            // (CLAUDE.md #48).
            schemaVersion: max(stored, Self.currentSchemaVersion),
            records: try c.decodeIfPresent([String: MCPServerTrustRecord].self, forKey: .records) ?? [:])
    }

    static let empty = MCPTrustFile()
}

/// `~/Library/Application Support/NanoTeams/mcp/servers.json`. App-wide, not per work folder:
/// a server is a thing the user connected, and re-approving it per folder would train them to
/// click through the review sheet.
nonisolated struct MCPServerCatalogueFile: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var servers: [MCPServerConfig]

    init(schemaVersion: Int = MCPServerCatalogueFile.currentSchemaVersion, servers: [MCPServerConfig] = []) {
        self.schemaVersion = schemaVersion
        self.servers = servers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        self.init(
            schemaVersion: max(stored, Self.currentSchemaVersion),
            servers: try c.decodeIfPresent([MCPServerConfig].self, forKey: .servers) ?? [])
    }

    static let empty = MCPServerCatalogueFile()
}

/// `.nanoteams/internal/mcp/mcp_folder.json` — the per-folder half of the switch.
///
/// Servers are configured once, app-wide, but which of them a given work folder may reach is
/// that folder's business: the cross-server shadowing mitigation is partly just not having
/// every server present everywhere. Stored as a DISABLED list so a newly added server is not
/// silently absent from folders that predate it.
nonisolated struct MCPFolderOverrides: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var disabledServerIDs: Set<UUID>

    init(schemaVersion: Int = MCPFolderOverrides.currentSchemaVersion, disabledServerIDs: Set<UUID> = []) {
        self.schemaVersion = schemaVersion
        self.disabledServerIDs = disabledServerIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        self.init(
            schemaVersion: max(stored, Self.currentSchemaVersion),
            disabledServerIDs: try c.decodeIfPresent(Set<UUID>.self, forKey: .disabledServerIDs) ?? [])
    }

    static let empty = MCPFolderOverrides()

    func allows(_ serverID: UUID) -> Bool { !disabledServerIDs.contains(serverID) }
}
