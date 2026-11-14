import XCTest

@testable import NanoTeams

/// Pin the rule that no MCP secret ever reaches a file on disk.
///
/// Everything MCP persists is `Codable` and lands in plain JSON: `servers.json`, `trust.json`,
/// `mcp_folder.json`. A bearer token in any of them would defeat the Keychain entirely, and
/// the failure mode is quiet — a token added as an "extra header" looks like configuration
/// right up until someone reads the file.
///
/// The scan is by VALUE, not by key name. A guard that only checked for a key called
/// `token` would pass a config that stored the secret under `headers["X-Tenant"]`.
final class MCPConfigSecretLeakGuardTests: XCTestCase {

    /// Distinctive enough that a substring hit anywhere is a real leak.
    private let secret = "t.SECRET-BEARER-VALUE-9f3a1c"

    private func encode<T: Encodable>(_ value: T) throws -> (json: String, leaves: [String]) {
        let data = try JSONEncoder().encode(value)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return (json, Self.stringLeaves(of: any))
    }

    /// Every string that survives encoding, keys included — a secret smuggled into a KEY is
    /// still a secret on disk.
    private static func stringLeaves(of any: Any) -> [String] {
        switch any {
        case let string as String: return [string]
        case let array as [Any]: return array.flatMap(stringLeaves(of:))
        case let object as [String: Any]: return object.flatMap { [$0.key] + stringLeaves(of: $0.value) }
        default: return []
        }
    }

    private func makeConfig() throws -> MCPServerConfig {
        MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("trade_room")),
            displayName: "Trade-Room",
            transport: .http(MCPHTTPConfig(
                urlString: "https://trade-room.example/mcp",
                headers: ["X-Tenant": "acme"],
                secretHeaderNames: ["X-Api-Key"],
                authorization: .staticBearer)),
            isEnabled: true)
    }

    // MARK: - The config the user typed

    /// The config names the HEADER; the Keychain holds the value. There is no field the
    /// secret could occupy, which is what this asserts rather than assumes.
    func testAnEncodedServerConfigNamesHeadersAndHoldsNoValues() throws {
        let config = try makeConfig()
        let encoded = try encode(config)
        XCTAssertFalse(encoded.json.contains(secret))
        XCTAssertTrue(encoded.leaves.contains("X-Api-Key"), "the NAME is what the file is for")
        XCTAssertTrue(encoded.leaves.contains("staticBearer"))
        for leaf in encoded.leaves {
            XCTAssertFalse(leaf.contains(secret), leaf)
        }
    }

    /// The likeliest accident: a user pastes the token into the extra-headers table instead of
    /// the secure field. The config type strips it before anything can write it out.
    func testATokenTypedIntoTheExtraHeadersTableNeverReachesTheFile() throws {
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("trade_room")),
            displayName: "Trade-Room",
            transport: .http(MCPHTTPConfig(
                urlString: "https://x/mcp",
                headers: ["Authorization": "Bearer \(secret)"],
                authorization: .staticBearer)))
        let encoded = try encode(config)
        XCTAssertFalse(encoded.json.contains(secret), encoded.json)
        // `staticBearer` is the stored authorization MODE and is expected; a header VALUE
        // spelling a credential scheme is not.
        XCTAssertFalse(encoded.leaves.contains { $0.hasPrefix("Bearer ") }, encoded.json)
    }

    /// The same, one name over: a header the user invents for the same purpose. Listing it as
    /// secret moves the value to the Keychain; leaving it in `headers` would not, so the two
    /// lists are disjoint and the secret-named one wins.
    func testAHeaderDeclaredSecretCannotAlsoCarryItsValue() throws {
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("s")),
            displayName: "S",
            transport: .http(MCPHTTPConfig(
                urlString: "https://x/mcp",
                headers: ["X-Api-Key": secret],
                secretHeaderNames: ["X-Api-Key"])))
        XCTAssertFalse(try encode(config).json.contains(secret))
    }

    func testTheWholeCatalogueFileIsSecretFree() throws {
        let file = MCPServerCatalogueFile(servers: [try makeConfig(), try makeConfig()])
        let encoded = try encode(file)
        XCTAssertFalse(encoded.json.contains(secret))
        XCTAssertGreaterThan(encoded.leaves.count, 5, "anti-vacuum: the file must actually have encoded")
    }

    // MARK: - What the app remembers

    /// The trust file holds hashes and dates. A hash is not a secret, but the file is the
    /// other thing that gets copied out of Application Support, so it is scanned too.
    func testTheTrustFileHoldsNoSecretsEither() throws {
        let file = MCPTrustFile(records: [UUID().uuidString: MCPServerTrustRecord(
            approvedAt: Date(timeIntervalSince1970: 0), cachedEra: .legacy,
            toolPins: ["GetPortfolio": MCPToolPin(
                toolName: "GetPortfolio", hash: "deadbeef", approvedAt: Date(timeIntervalSince1970: 0))])])
        let encoded = try encode(file)
        XCTAssertFalse(encoded.json.contains(secret))
        XCTAssertTrue(encoded.leaves.contains("deadbeef"))
    }

    // MARK: - No MCP secrets in UserDefaults

    /// `UserDefaults` is a plist anyone with the container can read. The MCP server catalogue
    /// lives in `servers.json` and every MCP secret in the Keychain; the only MCP setting in
    /// `UserDefaults` is `mcpJudgeLLMOverride` (model name and endpoint URL for the Auto judge,
    /// whose bearer token is Keychain-keyed by URL).
    ///
    /// Scanned from the SOURCE of `UserDefaultsKeys` rather than from a hand-kept list: any
    /// second MCP key fails this pin immediately.
    func testOnlyTheNonSecretJudgeOverrideKeyBelongsToMCPInUserDefaults() throws {
        XCTAssertEqual(
            UserDefaultsKeys.mcpJudgeLLMOverride,
            "NanoTeams.mcp.judgeLLMOverride.v1")

        let path = "NanoTeams/Domain/Constants/UserDefaultsKeys.swift"
        let source = try String(
            contentsOf: RatchetSourceScan.repoRoot.appendingPathComponent(path), encoding: .utf8)
        XCTAssertTrue(source.contains("static let"), "anti-vacuum: \(path) did not read as constants")

        let allowedLine = #"static let mcpJudgeLLMOverride = "NanoTeams.mcp.judgeLLMOverride.v1""#
        let body = RatchetSourceScan.strippingLineComments(source)
        var matchedAllowed = 0
        for (index, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.lowercased().contains("mcp") {
            if line.trimmingCharacters(in: .whitespaces) == allowedLine {
                matchedAllowed += 1
                continue
            }
            XCTFail("\(path):\(index + 1) declares unexpected MCP state in UserDefaults — the catalogue "
                + "belongs in servers.json and its secrets in the Keychain")
        }
        XCTAssertEqual(matchedAllowed, 1, "expected exactly one mcpJudgeLLMOverride declaration")
    }
}
