import Foundation

// MARK: - Slug

/// A server's short name, validated once at the boundary so nothing downstream has to
/// re-check it.
///
/// The slug is not decoration: it is half of every tool name the model sees
/// (`mcp__<slug>__<tool>`), the key of the server's trust record, AND a path component
/// (`internal/mcp/<slug>/rpc_log.jsonl`, `attachments/mcp/<slug>/`). A raw `String` in that
/// last role is a traversal waiting to happen — `../../../` satisfies no rule anyone
/// remembered to apply. Making the type unconstructible from an invalid string is what
/// removes the question from every call site.
nonisolated struct MCPServerSlug: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {

    let rawValue: String

    /// `nil` for anything `MCPToolNaming.isValidSlug` refuses — lowercase alphanumerics and
    /// single underscores, first character alphanumeric, at most 32 characters. Use
    /// `MCPToolNaming.rejection(forSlug:)` to tell the user which rule they broke.
    init?(_ rawValue: String) {
        guard MCPToolNaming.isValidSlug(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Decoding refuses an invalid slug rather than healing it. A catalogue row whose slug
    /// is unusable has no repair the app could pick: healing it would silently re-namespace
    /// every tool the user already approved, and the pins are keyed by the old name.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let slug = MCPServerSlug(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Server slug \"\(raw)\" is not lowercase letters, digits and single underscores.")
        }
        self = slug
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }

    static func < (lhs: MCPServerSlug, rhs: MCPServerSlug) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Approval mode

/// How much friction a server's calls get. Per server, because trust is per server: a
/// desktop app answering on loopback and a server that can place orders do not deserve
/// the same posture.
///
/// There is no `.off` case on purpose — it would be a second spelling of `isEnabled == false`,
/// and two ways to say "this server is not running" is how one of them ends up unchecked.
nonisolated enum MCPApprovalMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Every call is held for a human, read-only tools and previously approved ones included.
    /// The default for a newly added server, and the only posture under which an unreviewed
    /// annotation cannot loosen anything.
    case manual
    /// Calls the policy can clear without a person — an "always allow" the human granted, or
    /// a read-only tool on a server the human marked trusted — run straight through. Anything
    /// else is still held.
    case semiAutomatic
    /// Calls that clear `MCPPermissionService` (an "always allow" grant or a read-only tool on
    /// a trusted server) run straight through; every call that would ask a human under
    /// `.semiAutomatic` is evaluated by the LLM judge (`MCPJudgeService`) at the server's
    /// configured `MCPJudgeStrictness`. Never holds a card for a person.
    case auto

    /// Exhaustive `switch`es, no `default`: a mode added later fails to compile until every
    /// projection names and classifies it.
    var displayName: String {
        switch self {
        case .manual: "Manual"
        case .semiAutomatic: "Semi-automatic"
        case .auto: "Auto"
        }
    }

    /// Shown under the picker in the server editor — a human reader, not the model.
    var settingDescription: String {
        switch self {
        case .manual:
            "You approve every call to this server before it runs."
        case .semiAutomatic:
            "Calls you marked “always allow” run without asking, and so do read-only tools if you marked the server trusted. Everything else waits for you."
        case .auto:
            "Calls you marked “always allow” run without asking, and so do read-only tools if you marked the server trusted. Everything else is decided by the LLM judge at the strictness set below."
        }
    }

    /// Whether this mode reads the server's trust mark at all. Under `.manual` every call is held
    /// whatever the mark says (`MCPPermissionService.evaluate`, step 1), so the editor greys the
    /// switch out there and says under which modes it counts — keeping the stored value, which
    /// counts again the moment the mode changes.
    ///
    /// Exhaustive `switch`, no `default`.
    var readsTrustMark: Bool {
        switch self {
        case .manual: false
        case .semiAutomatic, .auto: true
        }
    }

    /// The caption under the trust switch when the selected mode ignores it — the modes that
    /// read it, named from the modes themselves, so a mode added later is named here without
    /// anyone remembering this sentence.
    static var trustMarkCaption: String {
        let names = allCases.filter(\.readsTrustMark).map(\.displayName)
        let list: String
        switch names.count {
        case 0, 1: list = names.first ?? ""
        default: list = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
        return "Counts under \(list) only."
    }

    /// Whether a standing grant — "Always allow" on one tool, at its approved text — may be
    /// offered and recorded for a server in this mode. Not under `.manual`, which holds every
    /// call for a person (`MCPPermissionService.evaluate`, step 1): a grant recorded there would
    /// count for nothing now and switch itself on, unreviewed, the moment the mode changed.
    ///
    /// The ONE rule: the gate reads it for the approval card's button, the server page for its
    /// tool rows' switch (`MCPToolRowStatus.offersAlwaysAllow`), and the write seam refuses a
    /// grant under a mode that answers `false` (`MCPServerConnection.setAlwaysAllow`). Until
    /// 2026-10-28 it was spelled at the first two, and the write took a grant under any mode.
    ///
    /// Exhaustive `switch`, no `default` — a mode added later must be classified by whoever adds it.
    var allowsStandingGrants: Bool {
        switch self {
        case .manual: false
        case .semiAutomatic, .auto: true
        }
    }
}

/// How strict the LLM judge (`MCPJudgeService`) is when a server in `.auto` mode hands it an
/// `.ask` call, or when a human clicks "Ask AI" on a held `MCPApprovalCard`.
nonisolated enum MCPJudgeStrictness: String, Codable, CaseIterable, Hashable, Sendable {
    case permissive
    case standard
    case strict

    var displayName: String {
        switch self {
        case .permissive: "Permissive"
        case .standard: "Standard"
        case .strict: "Strict"
        }
    }

    /// Shown under the strictness picker in the server editor when `.auto` is selected.
    var settingDescription: String {
        switch self {
        case .permissive:
            "The judge allows read-only calls and routine reversible writes on the server, and denies destructive actions, financial transactions, secrets in arguments, and bulk outreach."
        case .standard:
            "The judge allows read-only calls and scoped reversible writes (drafts, comments, local edits), and denies deletions, permission or schema changes, publishing, and secrets in arguments."
        case .strict:
            "The judge allows read-only calls with non-sensitive arguments only, and denies every call that creates, modifies, deletes, sends, or triggers an external side effect."
        }
    }

    /// The restriction block inlined into `MCPJudgeService.systemPrompt(strictness:)`.
    var judgeGuidance: String {
        switch self {
        case .permissive:
            """
            ALLOW read-only queries, lookups, searches, and routine reversible writes on the server \
            (such as creating or updating a work item, posting a team message, or saving a draft) \
            whose arguments carry no credentials or secrets.
            DENY destructive or irreversible actions (deletions, drops, purges, force-pushes, revocations), \
            financial or billing operations, permission or access-control changes, bulk external messaging, \
            and any call whose arguments contain secrets, tokens, keys, passwords, or private data.
            """
        case .standard:
            """
            ALLOW read-only queries, lookups, and searches, plus scoped reversible writes \
            (such as creating a draft, adding a comment, or updating a single non-production record) \
            whose arguments carry no credentials or secrets.
            DENY any deletion, overwrite, schema or configuration change, permission or access-control change, \
            financial or billing operation, external publication or message send, and any call whose arguments \
            contain secrets, tokens, keys, passwords, or private data.
            """
        case .strict:
            """
            ALLOW only read-only queries, lookups, and inspections whose arguments carry no credentials, \
            secrets, or sensitive personal data.
            DENY every call that creates, modifies, deletes, sends, publishes, charges, or triggers any \
            state change or external side effect on the server, as well as any call whose arguments contain \
            secrets, tokens, keys, passwords, or private data.
            """
        }
    }
}

/// What the static policy says about one call, before the gate decides what to do with it.
/// Precedence inside `MCPPermissionService` is deny > ask > allow, same as `bash`.
nonisolated enum MCPPermissionDecision: Hashable, Sendable {
    case allow
    case ask(reason: String)
    case deny(reason: String)
}

// MARK: - Authorization

/// How this client proves who it is. Two cases and no OAuth: an authorization code flow
/// means a browser round-trip, a refresh token at rest and a redirect listener — none of which
/// a server that takes no token or a static one needs.
nonisolated enum MCPAuthorizationMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Nothing is sent. Correct for a loopback server whose authority is the desktop session
    /// the user is already logged into (a desktop app serving on loopback).
    case none
    /// `Authorization: Bearer <secret>`, the secret read from the Keychain per request and
    /// never held on the connection actor.
    case staticBearer

    var displayName: String {
        switch self {
        case .none: "No authentication"
        case .staticBearer: "Bearer token"
        }
    }
}

// MARK: - Timeouts

/// Per-server overrides of the timeout constants. Stored so a slow server can be given room
/// without loosening the ceiling for every other one; clamped on the way in so a stored
/// value cannot disable a guard.
nonisolated struct MCPTimeouts: Codable, Hashable, Sendable {

    let connect: TimeInterval
    /// Reset by every `notifications/progress` for the request — a long call stays alive by
    /// REPORTING, not by being trusted.
    let requestInactivity: TimeInterval
    /// Hard ceiling regardless of progress.
    let requestAbsolute: TimeInterval

    static let standard = MCPTimeouts(
        connect: MCPConstants.connectTimeout,
        requestInactivity: MCPConstants.requestInactivityTimeout,
        requestAbsolute: MCPConstants.requestAbsoluteTimeout)

    /// Bounds, spelled here rather than at each clamp. No editor shows them: a server's
    /// timeouts are set in `servers.json` (or a headless config) and an edit carries them
    /// through untouched (`MCPServerEditorState.makeConfig`).
    static let connectRange: ClosedRange<TimeInterval> = 1...120
    static let inactivityRange: ClosedRange<TimeInterval> = 5...3600
    static let absoluteRange: ClosedRange<TimeInterval> = 5...7200

    init(connect: TimeInterval, requestInactivity: TimeInterval, requestAbsolute: TimeInterval) {
        self.connect = connect.clamped(to: Self.connectRange)
        let inactivity = requestInactivity.clamped(to: Self.inactivityRange)
        self.requestInactivity = inactivity
        // An absolute ceiling below the inactivity budget would fire first and make the
        // progress-resets meaningless, so the floor is the inactivity value itself.
        self.requestAbsolute = requestAbsolute.clamped(to: max(inactivity, Self.absoluteRange.lowerBound)...Self.absoluteRange.upperBound)
    }

    #if DEBUG
    /// The three budgets exactly as given — a TEST's way to run the real-socket scenarios at a
    /// tenth of the app's scale (`MCPClientOverHTTPTests`), below the floors the clamping init
    /// enforces. Not in a release build, and never reached by a stored value: `init(from:)` and
    /// every editor go through the clamping init, which is what keeps a hand-edited
    /// `servers.json` from disabling a guard.
    init(unclampedConnect connect: TimeInterval, requestInactivity: TimeInterval, requestAbsolute: TimeInterval) {
        self.connect = connect
        self.requestInactivity = requestInactivity
        self.requestAbsolute = requestAbsolute
    }
    #endif

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            connect: try c.decodeIfPresent(TimeInterval.self, forKey: .connect) ?? MCPConstants.connectTimeout,
            requestInactivity: try c.decodeIfPresent(TimeInterval.self, forKey: .requestInactivity)
                ?? MCPConstants.requestInactivityTimeout,
            requestAbsolute: try c.decodeIfPresent(TimeInterval.self, forKey: .requestAbsolute)
                ?? MCPConstants.requestAbsoluteTimeout)
    }
}

nonisolated extension TimeInterval {
    func clamped(to range: ClosedRange<TimeInterval>) -> TimeInterval {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Transport

/// Everything needed to reach a Streamable HTTP server, minus the secrets.
///
/// **What is NOT here is the point.** `headers` carries values that are safe in a JSON file
/// on disk; a header whose value is a credential is named in `secretHeaderNames` and its
/// value lives in the Keychain, keyed by the server's id and its origin
/// (`MCPServerConfig.originAccountPrefix`). The two lists are disjoint by
/// construction (the initializer strips any overlap), so there is no state in which the same
/// header name means both "here is the value" and "look it up".
nonisolated struct MCPHTTPConfig: Codable, Hashable, Sendable {

    let urlString: String
    /// Extra request headers whose values are not secret — a version pin, a tenant id.
    let headers: [String: String]
    /// Names of headers whose values are in the Keychain. Order-insensitive; stored sorted.
    let secretHeaderNames: [String]
    let authorization: MCPAuthorizationMode

    /// Headers the transport owns. A user-supplied value here would either be overwritten
    /// silently (`Accept`) or would smuggle a credential into a plaintext JSON file
    /// (`Authorization` — which is what `authorization`/`secretHeaderNames` are for).
    static let reservedHeaderNames: Set<String> = [
        "authorization", "mcp-session-id", "mcp-protocol-version",
        "content-type", "content-length", "accept", "host",
    ]

    init(
        urlString: String,
        headers: [String: String] = [:],
        secretHeaderNames: [String] = [],
        authorization: MCPAuthorizationMode = .none
    ) {
        self.urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let secrets = Self.normalizedHeaderNames(secretHeaderNames)
        self.secretHeaderNames = secrets
        let secretKeys = Set(secrets.map { $0.lowercased() })
        self.headers = headers.filter { name, _ in
            let folded = name.lowercased()
            return !Self.reservedHeaderNames.contains(folded) && !secretKeys.contains(folded)
        }
        self.authorization = authorization
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawAuth = try c.decodeIfPresent(String.self, forKey: .authorization)
        self.init(
            urlString: try c.decodeIfPresent(String.self, forKey: .urlString) ?? "",
            headers: try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
            secretHeaderNames: try c.decodeIfPresent([String].self, forKey: .secretHeaderNames) ?? [],
            // An unknown mode (e.g. a future `"oauth"` value after a downgrade) falls back to
            // `.none` so the catalogue is not quarantined and no credential is sent blindly.
            authorization: rawAuth.flatMap(MCPAuthorizationMode.init(rawValue:)) ?? .none)
    }

    var url: URL? { URL(string: urlString) }

    /// Whether two addresses reach the same server — the same `URLOrigin`, the redirect
    /// policy's rule: a new path is the same server; a new scheme, host or port is not, and a
    /// credential entered for one is not the other's (`MCPServerConfig.isRepointed(from:)`).
    /// One that names no server reaches the same one as another only when the two are spelled
    /// identically — anything looser would let an address the policy cannot read keep a
    /// credential it cannot place.
    ///
    /// Compared AS the two addresses' account segments (`secretAccountSegment(for:)`), which
    /// are equal exactly when the origins are — so "this edit re-points the server" and "this
    /// edit gives every secret account a new name" are one fact, not two rules that must agree.
    static func reachSameServer(_ first: String, _ second: String) -> Bool {
        secretAccountSegment(for: first) == secretAccountSegment(for: second)
    }

    /// The segment every Keychain account of this address is spelled under
    /// (`MCPServerConfig.originAccountPrefix`).
    var secretAccountSegment: String { Self.secretAccountSegment(for: urlString) }

    /// `URLOrigin.accountSegment` for an address that names a server. For one that does not —
    /// no scheme or no host — the address itself, trimmed, with its `%`, `/` and `:` escaped:
    /// one path segment that holds no `:`, so it can never be an origin's, which always holds
    /// two, and that two such addresses share only when spelled identically.
    static func secretAccountSegment(for urlString: String) -> String {
        if let origin = URLOrigin(urlString) { return origin.accountSegment }
        return URLOrigin.percentEscaping(urlString.trimmingCharacters(in: .whitespacesAndNewlines), ["/", ":"])
    }

    /// Deduplicated, blank-free and sorted, so two configs differing only in the order the
    /// user typed the header names compare equal and hash alike.
    private static func normalizedHeaderNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted()
    }
}

/// Streamable HTTP is the only implemented transport today. It is an enum rather than a bare
/// `MCPHTTPConfig` because the decision — no local processes, so no stdio — is a SECURITY
/// decision, and an enum is where a future second transport has to be declared, reviewed and
/// gated rather than slipped in as an optional field.
///
/// A row whose `kind` names a transport this build does not implement (e.g. a future `"stdio"`
/// entry after a downgrade) decodes as `.unsupported`, preserving its raw JSON payload across
/// saves instead of failing decoding and quarantining the whole `servers.json`. Its `http`
/// projection is empty and `MCPServerConnection` refuses it immediately as `.unsupportedTransport`.
nonisolated enum MCPTransportConfig: Codable, Hashable, Sendable {
    case http(MCPHTTPConfig)
    case unsupported(kind: String, raw: [String: JSONValue])

    var http: MCPHTTPConfig {
        switch self {
        case .http(let config): return config
        case .unsupported: return MCPHTTPConfig(urlString: "")
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, http }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "http"
        guard kind == "http" else {
            let raw = try [String: JSONValue](from: decoder)
            self = .unsupported(kind: kind, raw: raw)
            return
        }
        self = .http(try c.decode(MCPHTTPConfig.self, forKey: .http))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .http(let config):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("http", forKey: .kind)
            try c.encode(config, forKey: .http)
        case .unsupported(let kind, var raw):
            raw["kind"] = .string(kind)
            try raw.encode(to: encoder)
        }
    }
}

// MARK: - Server

/// One configured server, as it sits in `servers.json`.
///
/// The admission gate is the per-tool review, not a switch: a server's tools ship to no model
/// until a person has read each one's description and approved its pin. A server added in the
/// editor therefore connects at once (`MCPServerEditorState.isEnabled`) — connecting is what
/// lists its tools for that review, and the address and credential are ones the person just
/// typed. `isEnabled` is the server's run switch, not an approval: off, nothing connects and
/// nothing is listed. A row decoded without the field reads off, and so does this
/// initializer's default — a server written by anything but the editor runs only when it says
/// so.
nonisolated struct MCPServerConfig: Codable, Hashable, Identifiable, Sendable {

    let id: UUID
    var slug: MCPServerSlug
    var displayName: String
    var transport: MCPTransportConfig
    var isEnabled: Bool
    /// Set by the user after they have decided the server is honest about its own tools.
    /// The ONLY thing it buys: a `readOnlyHint` annotation starts counting under
    /// `.semiAutomatic`. On an untrusted server an annotation can raise friction and never
    /// lower it, because the annotation is the server's own claim about itself.
    var isTrusted: Bool
    var approvalMode: MCPApprovalMode
    var judgeStrictness: MCPJudgeStrictness
    var timeouts: MCPTimeouts

    init(
        id: UUID = UUID(),
        slug: MCPServerSlug,
        displayName: String,
        transport: MCPTransportConfig,
        isEnabled: Bool = false,
        isTrusted: Bool = false,
        approvalMode: MCPApprovalMode = .manual,
        judgeStrictness: MCPJudgeStrictness = .standard,
        timeouts: MCPTimeouts = .standard
    ) {
        self.id = id
        self.slug = slug
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
        self.isEnabled = isEnabled
        self.isTrusted = isTrusted
        self.approvalMode = approvalMode
        self.judgeStrictness = judgeStrictness
        self.timeouts = timeouts
    }

    /// Tolerant on every field a future version might add, strict on the two that carry
    /// meaning no default can supply: a row without an id or a usable slug is not a server.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedStrictness = try c.decodeIfPresent(String.self, forKey: .judgeStrictness)
            .map { MCPJudgeStrictness(rawValue: $0) ?? .strict } ?? .standard
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            slug: try c.decode(MCPServerSlug.self, forKey: .slug),
            displayName: try c.decodeIfPresent(String.self, forKey: .displayName) ?? "",
            transport: try c.decode(MCPTransportConfig.self, forKey: .transport),
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            isTrusted: try c.decodeIfPresent(Bool.self, forKey: .isTrusted) ?? false,
            approvalMode: try c.decodeIfPresent(String.self, forKey: .approvalMode)
                .flatMap(MCPApprovalMode.init(rawValue:)) ?? .manual,
            judgeStrictness: decodedStrictness,
            timeouts: try c.decodeIfPresent(MCPTimeouts.self, forKey: .timeouts) ?? .standard)
    }

    /// What a live connection is BUILT from: the address, headers and credential shape the
    /// transport is made with, the timeouts the client and the transport run on, and the slug
    /// every tool name and the frame log are spelled with. Changing any of them is a new
    /// connection.
    ///
    /// Everything else on the config is policy — the approval mode, the trust mark, the name
    /// on screen — read per call, and a kept connection takes it in place
    /// (`MCPServerConnection.adopt(_:)`). Until 2026-09-23 any inequality rebuilt the
    /// connection, so switching a server to Manual killed its in-flight calls and made every
    /// running step see its whole catalogue as drifted until the new session listed it again.
    ///
    /// A field added to `MCPServerConfig` is policy unless it is added HERE, and
    /// `MCPServerConfigTests.testEveryFieldIsFiledAsATermOrAsPolicy` stays red until the new
    /// field is filed on one side.
    struct ConnectionTerms: Hashable, Sendable {
        let slug: MCPServerSlug
        let transport: MCPTransportConfig
        let timeouts: MCPTimeouts
    }

    var connectionTerms: ConnectionTerms {
        ConnectionTerms(slug: slug, transport: transport, timeouts: timeouts)
    }

    /// What the user sees when they named the server nothing. Never empty, because a blank
    /// row in the servers list is indistinguishable from a rendering bug.
    var effectiveDisplayName: String {
        displayName.isEmpty ? slug.rawValue : displayName
    }

    /// The grant a role's `toolIDs` carries to hold every tool of this server.
    var serverGrantName: String { MCPToolNaming.serverGrant(slug: slug.rawValue) }

    /// What every Keychain account of this server starts with, whatever address it was entered
    /// for: its id, then `/`. So "everything this server holds" is one listing
    /// (`MCPSecretStore.heldAccounts(of:)`) — what a removal and a re-point clear, the accounts
    /// no config reads any more (another address's, a bearer from an earlier mode, a header
    /// renamed before 2026-09-24, what a failed Add left, one spelled before an account named
    /// its origin) included. The `/` ends the id, so no other server's accounts share it.
    var secretAccountPrefix: String { "\(id.uuidString)/" }

    /// What every account this server READS starts with: its id, then the segment of the
    /// origin it runs at (`MCPHTTPConfig.secretAccountSegment` — `URLOrigin.accountSegment`),
    /// then `/`. **A secret is bound to the address it was entered for by its account's name**:
    /// a connection reads only the accounts its own config spells, so a value typed for any
    /// other address — another scheme, host or port — is never read by it, in any order of
    /// events. An edit that re-points the server gives every account a new name (the segment
    /// changes exactly when `isRepointed(from:)` says so), and one that does not changes none: a
    /// new path, a rename, a policy edit keep every secret where it is.
    ///
    /// Until the third pass of group D's review (2026-09-24) the accounts were `<uuid>/bearer`
    /// and `<uuid>/header/<name>`, read by every address the server was ever pointed at, and
    /// only the ORDER of a re-point's steps kept the new host's token off the old one. MCP had
    /// not shipped, so there is no migration: an account spelled that way is no longer read,
    /// and the next re-point, removal or launch sweep clears it.
    var originAccountPrefix: String { "\(secretAccountPrefix)\(transport.http.secretAccountSegment)/" }

    /// Keychain account for the bearer token — under the server's id and its origin, never its
    /// slug, so a rename does not strand the secret and another address never reads it.
    var bearerSecretKey: String { "\(originAccountPrefix)bearer" }

    func secretKey(forHeader name: String) -> String { "\(originAccountPrefix)header/\(name)" }

    /// The server an MCP Keychain account belongs to, read back from its name: a server id
    /// spelled exactly as `secretAccountPrefix` spells one, then `/`. `nil` for anything else —
    /// a lowercase or partial id, an id with nothing after it, a name that is not an id at all.
    /// What the orphaned-secret sweep (`MCPSecretStore.orphanedAccounts(readBy:)`) keys on, so
    /// it never touches an account this client did not spell.
    static func serverID(ofAccount account: String) -> UUID? {
        guard let slash = account.firstIndex(of: "/") else { return nil }
        let head = String(account[..<slash])
        guard let id = UUID(uuidString: head), id.uuidString == head else { return nil }
        return id
    }

    /// Every Keychain account this server's requests read — what it needs to run, what
    /// "Needs a token" checks, the only accounts a save or a reload asks the Keychain about, and
    /// the only ones the launch sweep keeps. All under `originAccountPrefix`. The bearer's only
    /// under `.staticBearer`: a token an earlier mode left is never sent, so nothing reads it; a
    /// removal, a re-point or the sweep clears it with everything else under the prefix.
    var allSecretKeys: [String] {
        var keys = transport.http.secretHeaderNames.map(secretKey(forHeader:))
        if transport.http.authorization == .staticBearer { keys.append(bearerSecretKey) }
        return keys.sorted()
    }

    /// Whether `stored` — the accounts that hold a value — covers every one this server's
    /// requests read. The one spelling of "Needs a token".
    func hasRequiredSecrets(among stored: Set<String>) -> Bool {
        Set(allSecretKeys).isSubset(of: stored)
    }

    /// Whether saving `self` over `stored` points the server at a different one: another
    /// scheme, host or port. A new path is the same server. A re-pointed server keeps its id —
    /// its place in the list and in every folder's opt-outs — and loses everything that was
    /// given to the old address: its secrets (every account has a new name, `originAccountPrefix`)
    /// and its tool approvals.
    func isRepointed(from stored: MCPServerConfig) -> Bool {
        !MCPHTTPConfig.reachSameServer(stored.transport.http.urlString, transport.http.urlString)
    }
}
