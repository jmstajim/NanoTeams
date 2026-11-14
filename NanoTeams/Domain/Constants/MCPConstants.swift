import Foundation

/// Tunables for the MCP client: protocol versions, timeouts, and the guards that keep a
/// misbehaving server from costing the app more than the connection it is on.
nonisolated enum MCPConstants {

    // MARK: - Protocol versions

    /// The revision the era probe names first. A server that knows it answers
    /// `server/discover`; one that does not answers something else, and that difference
    /// IS the probe (see `MCPProtocolEra`).
    static let modernProtocolVersion = "2026-07-28"

    /// The legacy revision this client offers in `initialize`.
    static let legacyProtocolVersion = "2025-11-25"

    /// Legacy revisions whose `initialize` result this client accepts. A server answering
    /// with a revision outside this set is disconnected rather than guessed at: the
    /// 2024-11-05 HTTP+SSE transport is a different transport, not a dialect.
    static let acceptedLegacyProtocolVersions: Set<String> = ["2025-11-25", "2025-06-18", "2025-03-26"]

    /// The header both eras carry on every HTTP request.
    static let protocolVersionHeader = "MCP-Protocol-Version"

    /// Standard SSE resumption header sent on a follow-up `GET` when a request's event stream
    /// closes cleanly after delivering an event `id:` but before delivering the JSON-RPC reply.
    static let lastEventIDHeader = "Last-Event-ID"

    /// Maximum number of `GET` stream-resumption attempts (`Last-Event-ID`) for one request
    /// before reporting `.streamEnded`.
    static let maxStreamResumptionAttempts = 3

    // MARK: - Secrets

    /// Keychain service scoping every MCP secret. Separate from the LM Studio service so a
    /// future schema break on either side cannot strand the other's entries.
    static let keychainService = "com.nanoteams.mcp.secret.v1"

    // MARK: - Timeouts (seconds)

    /// Era probe. Short on purpose: a legacy server has to be given up on quickly, because
    /// the probe is pure overhead on the path that actually works.
    static let probeTimeout: TimeInterval = 10

    /// Default of `MCPTimeouts.connect`: the handshake, and each page of `tools/list`. The
    /// probe gets the smaller of this and `probeTimeout`.
    static let connectTimeout: TimeInterval = 20

    /// Per-request inactivity budget. Reset by every `notifications/progress` the server
    /// sends for the request, so a genuinely long tool call stays alive by REPORTING, not
    /// by being trusted.
    static let requestInactivityTimeout: TimeInterval = 120

    /// Hard ceiling on one request regardless of progress. A server that reports progress
    /// forever is still a hung call from the role's point of view.
    static let requestAbsoluteTimeout: TimeInterval = 600

    /// Budget for a graceful close (legacy `DELETE`, stream cancellation) at app quit. The
    /// termination delegate has ~5 s in total and the search index shares it.
    static let shutdownBudget: TimeInterval = 2

    /// How much longer the HTTP layer waits than the client's own request budgets
    /// (`MCPTimeouts.httpIdleTimeout`): the client's watchdog owns both budgets, and the HTTP
    /// layer only ends what nothing watches.
    static let httpTimeoutMargin: TimeInterval = 5

    /// A frame the server is owed but nobody waits on — the legacy `notifications/cancelled`,
    /// the reply to a server's `ping` — gets this long to be taken. A server too busy to take it
    /// does not get it: a courtesy must never hold a caller, nor the stream behind it.
    static let courtesyBudget: TimeInterval = 2

    /// How many replies to the SERVER'S requests — a `ping`, or anything else a legacy server
    /// asks — may be in flight at once; one past it is dropped. A server sends a `ping` now and
    /// then; one that streams requests down the push channel would otherwise have this client
    /// open one POST per request, each living up to `courtesyBudget`, with nothing to slow it.
    /// This client's own `notifications/cancelled` is not counted and never dropped: each
    /// follows a call this client abandoned, so its own calls bound them (`MCPClient`).
    static let maxServerRequestRepliesInFlight = 8

    /// Reconnect delays, in order; the last value repeats — for as long as the server keeps
    /// failing, never stopping. Bounded so a server that is simply switched off (a desktop
    /// app that was quit) costs one attempt per thirty seconds, and still connects on its own
    /// once it is back.
    static let reconnectBackoff: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    /// A legacy push stream that stayed open this long was healthy, so its end restarts the
    /// reopen delays from the first step. One that ends sooner walks further down
    /// `reconnectBackoff`, so a server that refuses the GET at once is not asked every second.
    static let pushStreamHealthyAfter: TimeInterval = 30

    /// A connection that fails this many times inside `crashLoopWindow` — refused connects and
    /// sessions lost right after connecting alike — skips to the last step of
    /// `reconnectBackoff` and stays there, and says so. It does NOT stop: until 2026-09-23 it
    /// did, and a server that failed instantly (a local server whose app was launched after
    /// this one) used only the first two steps of the table and then waited for a click that
    /// nothing told the user to make. A session that outlives the window was healthy, and its
    /// end starts the count afresh.
    static let crashLoopFailureCount = 3
    static let crashLoopWindow: TimeInterval = 5

    /// Floor on the refresh interval a server can ask for through `ttlMs`. A server naming
    /// 100 ms would otherwise re-list its catalogue between every tool call.
    static let minimumCatalogueTTL: TimeInterval = 60

    // MARK: - Guards

    /// Ceiling on a single SSE frame or JSON body. Crossing it fails the CONNECTION loudly
    /// rather than truncating the frame: a truncated JSON-RPC frame is indistinguishable
    /// from a malformed one, and silently dropping half a tool result would hand the model
    /// a plausible-looking partial answer.
    static let maxFrameBytes = 64 * 1024 * 1024

    /// Ceiling on `tools/list` pagination. A server cycling its `nextCursor` forever is a
    /// denial of service against the connect path.
    static let maxToolsListPages = 100

    /// Longest `$ref` chain `MCPSchemaProjection` will follow before refusing the schema.
    static let maxSchemaRefDepth = 8

    /// How long a pin for a tool that vanished from a server's catalogue is kept, so a
    /// tool that comes back after a server restart is still approved.
    static let removedPinRetention: TimeInterval = 30 * 24 * 60 * 60
}
