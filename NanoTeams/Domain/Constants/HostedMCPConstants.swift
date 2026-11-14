import Foundation

/// Constants for the hosted loopback MCP server (`Services/HostedMCP/*`).
///
/// Kept in one `nonisolated` namespace so the HTTP parser, request guard, dual-era
/// dispatcher, agent store, and UI surfaces quote the same limits, headers, and protocol
/// revision strings without reaching across actors.
nonisolated enum HostedMCPConstants {
    /// The External Agents symbol — the Settings tab's icon, the switch's, and the origin mark on a
    /// task an external agent created (`SidebarTaskRow`). One literal, three readers.
    static let symbolName = "antenna.radiowaves.left.and.right"

    // MARK: - Network & Endpoint

    /// Default loopback TCP port for the hosted MCP server (§7.1).
    static let defaultPort: UInt16 = 47321

    /// Primary MCP Streamable HTTP endpoint path (§7.2).
    static let mcpPath = "/mcp"

    /// Pre-authentication server identity proof endpoint for the native stdio bridge (§7.2).
    static let identifyPath = "/identify"

    /// Domain separator prepended to the hex nonce in `/identify` HMAC-SHA256 (§7.2).
    static let identifyDomainSeparator = "nanoteams-identify-v1:"

    /// Maximum simultaneous TCP connections accepted by the listener (§7.2).
    static let maxConnections = 32

    /// Connection slots reserved for short-lived non-wait requests so concurrent
    /// `wait_for_events` calls cannot starve `folder_status` or `answer_task_question` (§7.2).
    static let reservedNonWaitConnections = 8

    // MARK: - HTTP/1.1 Limits & Deadlines (§7.2)

    /// Maximum total bytes in the HTTP request line + header block (`16 KiB`).
    static let maxHeaderBytes = 16 * 1024

    /// Maximum bytes in a single HTTP request line or header line (`8 KiB`).
    static let maxHeaderLineBytes = 8 * 1024

    /// Maximum number of HTTP header fields in one request (`64`).
    static let maxHeaderCount = 64

    /// Maximum decoded HTTP request body size (`4 MiB`).
    static let maxBodyBytes = 4 * 1024 * 1024

    /// Default deadline to finish receiving the HTTP request head (`10 s`).
    static let defaultHeadDeadline: Duration = .seconds(10)

    /// Default deadline to finish receiving the HTTP request body (`30 s`).
    static let defaultBodyDeadline: Duration = .seconds(30)

    /// `WWW-Authenticate` header sent on `401 Unauthorized` — deliberately omits
    /// `resource_metadata` so MCP clients do not enter an OAuth discovery flow (§7.2).
    static let wwwAuthenticateBearerRealm = #"Bearer realm="nanoteams""#

    // MARK: - Protocol Eras & Metadata (§7.3)

    static let serverName = "nanoteams"
    static let serverTitle = "NanoTeams"

    /// Legacy revisions supported by the hosted server (`2025-03-26` is excluded because
    /// it required JSON-RPC batch support).
    static let supportedLegacyProtocolVersions: [String] = ["2025-11-25", "2025-06-18"]

    /// All protocol versions the hosted server speaks across both eras.
    static let allSupportedProtocolVersions: [String] = [
        "2026-07-28",
        "2025-11-25",
        "2025-06-18",
    ]

    /// `_meta` key carrying the fingerprint of `.externalAgent` runtime prompts (§7.3).
    static let agentTextVersionMetaKey = "io.nanoteams/agentTextVersion"

    /// Cache TTL advertised on modern `server/discover` and `tools/list` (`1 hour`).
    static let discoveryCacheTTLMs = 3_600_000
    static let catalogueCacheScope = "private"
    static let defaultServerVersion = "2.0.0"

    /// `_meta["anthropic/maxResultSizeChars"]` value attached exclusively to `read_artifact` (§8.1).
    static let readArtifactMaxResultSizeChars = 500_000

    /// `_meta["anthropic/maxResultSizeChars"]` value attached to `task_changes` (§3.11).
    static let taskChangesMaxResultSizeChars = 250_000

    // MARK: - Rate Limiting (§7.2)

    static let rateLimitBucketCapacity = 60
    static let rateLimitRefillPerSecond: Double = 10.0

    // MARK: - SSE & Wait Limits (§7.3, §9)

    /// Default interval between SSE `: keep-alive` comments and `notifications/progress` frames.
    static let sseKeepAliveIntervalSeconds: TimeInterval = 15.0

    /// `wait_for_events` calls with `timeout_seconds` above this threshold promote to SSE.
    static let ssePromotionWaitThresholdSeconds = 30

    /// The longest `wait_for_events` the server holds — the `maximum` its schema advertises for
    /// `timeout_seconds`, the bound the argument check enforces and the clamp the event feed applies.
    static let maxWaitSeconds = 3600

    /// The `timeout_seconds` of a `wait_for_events` that names none.
    static let defaultWaitSeconds = 50

    /// How long a client must let one call run: the longest wait plus a margin. A wait's reply
    /// leaves after its deadline — measured 2026-11-07, 3600 s → 3601 s and 35 s → 36.9 s — so a
    /// client that cuts a call at exactly `maxWaitSeconds` turns a full wait into a timeout error.
    /// The stdio relay's `POST /mcp` ceilings and every generated client configuration that sets a
    /// call timeout read this one value.
    static let clientCallTimeoutSeconds = maxWaitSeconds + 120

    // MARK: - Credentials, Frame Log & Environment (§6, §7.1, §10.2)

    /// The agents' verifiers, under the tab's pre-2026-11-08 name (Agent Access): a new service
    /// would hold no verifier, and every token already issued would be refused.
    static let keychainService = "com.nanoteams.agentaccess.v1"
    static let tokenPrefix = "ntm_"
    static let tokenSecretByteCount = 32
    static let shortIDCharacterCount = 8

    /// What an issued agent token looks like in text, for the scrubbers that keep it out of
    /// anything written down: `MCPRedaction` (its credential patterns and `agentTokens`) and
    /// `HostedMCPFrameLog`. One spelling, at the issuer — there were two, and they disagreed.
    ///
    /// Looser than the issuer on purpose (a scrubber is tolerant of what it is fed): the issued
    /// short id is `shortIDCharacterCount` lower-case hex and the secret 43 base64url characters,
    /// while this takes any 4+ alphanumerics and any 8+ base64url characters, so a token mangled
    /// in case or cut short is still taken out. It is the pattern `MCPRedaction` has always used.
    static let agentTokenPattern =
        NSRegularExpression.escapedPattern(for: tokenPrefix) + "[A-Za-z0-9]{4,}_[A-Za-z0-9_-]{8,}"
    static let minIdentifyNonceHexCharacters = 16
    static let maxIdentifyNonceHexCharacters = 64
    static let lastSeenPersistenceIntervalSeconds: TimeInterval = 60
    static let presenceConnectedWindowSeconds: TimeInterval = 120

    /// Under Application Support/NanoTeams; the old name for the same reason as `keychainService`
    /// (`agents.json` lives here).
    static let externalAgentsSubdirectory = "agent-access"
    static let agentsFileName = "agents.json"
    static let frameLogFileName = "hosted-mcp-frames.jsonl"
    static let frameLogRotatedFileName = "hosted-mcp-frames.1.jsonl"
    static let frameLogRingCapacity = 200
    static let frameLogMaxFileBytes = 2 * 1024 * 1024

    static let portEnvironmentVariable = "NANOTEAMS_MCP_PORT"
    static let tokenEnvironmentVariable = "NANOTEAMS_TOKEN"
    static let scrubbedEnvironmentPrefix = "NANOTEAMS_MCP_"

    static let minValidPort = 1024
    static let maxValidPort = 65535
    static let maxOpenConnections = maxConnections
    static let tokenSecretRandomByteCount = tokenSecretByteCount
    static let busyRetryAfterSeconds = 2
    static let folderTransitionRetryAfterSeconds = 1
    static let requestHeaderDeadlineSeconds = 10
    static let requestBodyDeadlineSeconds = 30
}
