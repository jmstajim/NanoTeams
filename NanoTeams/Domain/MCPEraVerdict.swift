import Foundation

/// What the probe's answer says about a server's era — the one decision `MCPClient.connect`
/// reads, pure so every row of it is held by a table rather than by a socket.
///
/// The probe asks `server/discover` at this client's modern revision, and the 2026-07-28
/// revision says how to read what comes back (basic/versioning and streamable-http, "Backward
/// Compatibility"): "a recognized modern JSON-RPC error … identifies a modern server: the client
/// retries with a supported version rather than falling back. Anything else identifies a legacy
/// server." The recognized errors are that revision's own codes and no others (basic/index,
/// "Error Codes"): `-32020` HeaderMismatch, `-32021` MissingRequiredClientCapability, `-32022`
/// UnsupportedProtocolVersion — `-32042` sits in the reserved range and belonged to 2025-11-25
/// alone. A `DiscoverResult` names the revisions its server speaks (`supportedVersions`), and
/// "The client should choose one of these for subsequent requests" (server/discover).
///
/// The verdict, first match:
/// - a result naming `supportedVersions` is adopted BY that list: the asked revision (or another
///   modern one this client speaks) among them → `.modern`; else a handshake-era revision this
///   client accepts → `.legacy`, a dual-era server's advertisement; else `.fail(.unsupported)`,
///   naming the list — an empty one included;
/// - a result naming none: the asked revision, unless it names another (`protocolVersion`,
///   which only the legacy `initialize` defines), and then only one this client speaks;
/// - `-32022`: a modern revision this client speaks in its `supported` list — the asked one
///   first, a server contradicting itself while it starts up or rolls a config — → `.retry`,
///   once; else, or refused again, a handshake-era revision in common → `.legacy` ("The client
///   SHOULD select a mutually supported version from the `supported` list and retry", and the
///   mutual revision is reached through `initialize`); else `.fail(.unsupported)`;
/// - `-32020`, `-32021` → `.fail(.refused)`, in the server's words: nothing in this probe can
///   be corrected — its envelope is the spec's, its capabilities are empty on purpose — and a
///   fallback would hand a modern server's refusal to `initialize`, which a modern-only server
///   refuses for a reason that hides the real one and a dual-era one accepts, so the app runs
///   the legacy era and nobody learns why;
/// - every other refusal (a legacy server's `-32601` for a method it has never heard of,
///   `-32602`, `-32603`, an implementation's own code) and no answer at all → `.legacy`.
///
/// This follows the spec's SHOULD over the reference client: the python SDK falls back on every
/// error but a disjoint `-32022`. This client reports honest statuses, and a silent fallback is
/// what hid an envelope a conforming server refused.
nonisolated enum MCPEraVerdict: Hashable, Sendable {
    /// Speak the modern era at this revision; `result` is the answer that says so, whose
    /// identity and catalogue lifetime the connection reads.
    case modern(version: String, result: JSONValue)
    /// Ask `server/discover` again, at this revision.
    case retry(version: String)
    /// Take the `initialize` handshake.
    case legacy
    /// The server is modern and this client cannot speak to it.
    case fail(Failure)

    nonisolated enum Failure: Hashable, Sendable {
        /// It shares no revision with this client; the versions it named, cleaned
        /// (`MCPWire.supportedVersions`).
        case unsupported(serverSupports: [String])
        /// It refused the probe with one of its revision's own codes; `message` is its own words,
        /// already cleaned where the refusal entered the client.
        case refused(code: Int, message: String)
        /// It answered `server/discover` with `resultType: "input_required"`, which the revision
        /// allows only on `prompts/get`, `resources/read` and `tools/call`.
        case inputRequired
        /// It answered `server/discover` with a `resultType` this client does not recognize.
        case unknownResultType(String)
    }

    /// What `server/discover` came back with.
    nonisolated enum ProbeAnswer: Hashable, Sendable {
        /// A result.
        case result(JSONValue)
        /// A JSON-RPC error.
        case refused(code: Int, message: String, data: JSONValue?)
        /// Nothing this client can read: no answer in time, a transport failure, a reply it
        /// could not parse.
        case noAnswer
    }

    /// The verdict on `answer` to a probe that asked for `asked`. `retried` — the probe already
    /// asked once more after a `-32022` that named the asked revision.
    static func of(
        _ answer: ProbeAnswer,
        asked: String,
        retried: Bool,
        modernRevisions: Set<String> = [MCPConstants.modernProtocolVersion],
        handshakeRevisions: Set<String> = MCPConstants.acceptedLegacyProtocolVersions
    ) -> MCPEraVerdict {
        switch answer {
        case .result(let result):
            switch MCPWire.resultType(of: result) {
            case .complete:
                break
            case .inputRequired:
                return .fail(.inputRequired)
            case .unrecognized(let type):
                return .fail(.unknownResultType(type))
            }
            if let supported = MCPWire.supportedVersions(fromDiscoverResult: result, cappedForDisplay: false) {
                if supported.contains(asked), modernRevisions.contains(asked) {
                    return .modern(version: asked, result: result)
                }
                if let modern = supported.first(where: modernRevisions.contains) {
                    return .modern(version: modern, result: result)
                }
                if supported.contains(where: handshakeRevisions.contains) { return .legacy }
                return .fail(.unsupported(serverSupports: Array(supported.prefix(MCPWire.maxListedVersions))))
            }
            guard let named = MCPWire.negotiatedProtocolVersion(from: result) else {
                return .modern(version: asked, result: result)
            }
            return modernRevisions.contains(named)
                ? .modern(version: named, result: result)
                : .fail(.unsupported(serverSupports: [named]))

        case .refused(let code, _, let data) where code == MCPErrorCode.unsupportedProtocolVersion:
            let supported = MCPWire.supportedVersions(fromErrorData: data, cappedForDisplay: false)
            let modern = supported.contains(asked) && modernRevisions.contains(asked)
                ? asked : supported.first(where: modernRevisions.contains)
            if let modern, !retried { return .retry(version: modern) }
            if supported.contains(where: handshakeRevisions.contains) { return .legacy }
            return .fail(.unsupported(serverSupports: Array(supported.prefix(MCPWire.maxListedVersions))))

        case .refused(let code, let message, _)
            where code == MCPErrorCode.headerMismatch || code == MCPErrorCode.missingRequiredClientCapability:
            return .fail(.refused(code: code, message: message))

        case .refused, .noAnswer:
            return .legacy
        }
    }
}
