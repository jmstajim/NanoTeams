import XCTest

@testable import NanoTeams

/// Pins the hard rule from CLAUDE.md "LM Studio Authentication": the API
/// bearer token must NEVER live on a Codable surface.
///
/// `LLMOverride` ships in `teams.json` and team JSON exports. `EmbeddingConfig`
/// is persisted to UserDefaults as JSON. `LLMConfig` is `Hashable`, used in
/// `NetworkLogRecord` correlation, and freely passed across services. Adding a
/// token field to any of them silently re-introduces the leak vector this
/// architecture exists to prevent.
///
/// These tests fail fast if a contributor forgets the rule. Migration plan if
/// you genuinely need a per-config token: re-route through `LLMTokenResolver`
/// and the Keychain — do NOT add a stored property here.
final class LLMTokenLeakGuardTests: XCTestCase {

    private let bannedKeys: Set<String> = [
        "apiToken", "api_token", "authToken", "auth_token",
        "bearerToken", "bearer_token", "secret", "password",
        "Authorization", "authorization", "headers"
    ]

    func testLLMOverride_serialized_containsNoTokenLikeKeys() throws {
        let override = LLMOverride(
            baseURLString: "http://localhost:1234",
            modelName: "test",
            maxTokens: 1024,
            temperature: 0.7
        )
        try assertNoBannedKeys(in: override, type: "LLMOverride")
    }

    func testLLMOverride_emptyAndFullyPopulated_bothClean() throws {
        try assertNoBannedKeys(in: LLMOverride(), type: "LLMOverride (empty)")
        try assertNoBannedKeys(
            in: LLMOverride(baseURLString: "http://localhost:1234"),
            type: "LLMOverride (URL only)"
        )
    }

    func testEmbeddingConfig_serialized_containsNoTokenLikeKeys() throws {
        let config = EmbeddingConfig.defaultNomicLMStudio
        try assertNoBannedKeys(in: config, type: "EmbeddingConfig")
    }

    /// `LLMConfig` is not directly Codable in the persistence path, but it's
    /// freely copied and hashed — adding a token property here would let the
    /// secret leak via debug prints, NetworkLogRecord correlation IDs, etc.
    /// We guard the structural contract via reflection instead of JSON.
    func testLLMConfig_hasNoTokenLikeProperties() {
        let config = LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost:1234",
            modelName: "test"
        )
        let mirror = Mirror(reflecting: config)
        let propertyNames = mirror.children.compactMap(\.label)
        let leaks = bannedKeys.intersection(Set(propertyNames))
        XCTAssertTrue(
            leaks.isEmpty,
            "LLMConfig must not gain a token-like property — found: \(leaks). "
                + "Tokens flow via LLMTokenResolver, not as a stored field. "
                + "See CLAUDE.md 'LM Studio Authentication'."
        )
    }

    /// `NetworkLogRecord` ships to disk as `network_log.json` AND is read
    /// back / dumped during diagnostics. Adding a `headers` field here —
    /// even one that's `private` and excluded from the JSON encoder via
    /// `CodingKeys` — would still expose the token in memory dumps, debug
    /// prints, and any `Codable` encoder that doesn't honor `CodingKeys`
    /// (e.g. PropertyList, custom NSKeyedArchiver paths). The JSON-key
    /// guard in `NetworkLoggerHeadersGuardTests` catches the Codable
    /// surface; this guard catches structural additions.
    func testNetworkLogRecord_hasNoTokenLikeProperties() {
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "http://localhost:1234/api/v1/chat",
            statusCode: nil,
            body: nil,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil,
            inputTokens: nil,
            outputTokens: nil,
            roleName: nil
        )
        let mirror = Mirror(reflecting: record)
        let propertyNames = mirror.children.compactMap(\.label)
        let leaks = bannedKeys.intersection(Set(propertyNames))
        XCTAssertTrue(
            leaks.isEmpty,
            "NetworkLogRecord must not gain a token-like or `headers` property "
                + "— found: \(leaks). Adding one re-opens the leak vector "
                + "this architecture exists to prevent. See CLAUDE.md "
                + "'LM Studio Authentication' Hard Rule #4."
        )
    }

    // MARK: - Helper

    private func assertNoBannedKeys<T: Encodable>(
        in value: T, type: String, file: StaticString = #file, line: UInt = #line
    ) throws {
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let data = try encoder.encode(value)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let leaks = bannedKeys.intersection(Set(json.keys))
        XCTAssertTrue(
            leaks.isEmpty,
            "\(type) must not serialize a token-like field — found: \(leaks). "
                + "Tokens belong in Keychain via LLMTokenResolver. "
                + "See CLAUDE.md 'LM Studio Authentication'.",
            file: file, line: line
        )
    }
}
