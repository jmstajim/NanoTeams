import XCTest

@testable import NanoTeams

/// `BashPolicy` is `Codable` and round-trips through nowhere that carries a
/// credential. These pin the tolerant decoder (legacy / partial JSON), the full
/// round-trip, and the no-credential invariant the type's doc comment promises.
final class BashPolicyCodableTests: XCTestCase {

    func testFullRoundTrip() throws {
        let p = BashPolicy(
            mode: .auto,
            restrictionLevel: .strict,
            allowRules: ["git status"],
            askRules: ["npm"],
            denyRules: ["rm -rf *"],
            sandboxEnabled: false,
            sandboxPermissions: BashSandboxPermissions(workFolderWrite: false, everythingElseWrite: true),
            allowUnsandboxedFallback: true,
            judgeOverride: LLMOverride(baseURLString: "http://127.0.0.1:1", modelName: "judge"))
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(BashPolicy.self, from: data)
        XCTAssertEqual(p, decoded)
    }

    func testLegacyJSON_decodesWithDefaults() throws {
        // A pre-split blob (only `mode`) must fill every newer field with safe
        // defaults via the tolerant decoder instead of throwing.
        let decoded = try JSONDecoder().decode(BashPolicy.self, from: Data(#"{"mode":"auto"}"#.utf8))
        XCTAssertEqual(decoded.mode, .auto)
        XCTAssertEqual(decoded.restrictionLevel, BashConstants.defaultRestrictionLevel)
        XCTAssertTrue(decoded.allowRules.isEmpty)
        XCTAssertTrue(decoded.askRules.isEmpty)
        XCTAssertTrue(decoded.denyRules.isEmpty)
        XCTAssertTrue(decoded.sandboxEnabled, "sandbox defaults ON when absent from legacy JSON")
        XCTAssertEqual(decoded.sandboxPermissions, BashSandboxPermissions())
        XCTAssertFalse(decoded.allowUnsandboxedFallback)
        XCTAssertNil(decoded.judgeOverride)
    }

    func testEmptyJSON_decodesAllDefaults() throws {
        let decoded = try JSONDecoder().decode(BashPolicy.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, BashPolicy())
    }

    func testUnknownKeysIgnored() throws {
        let decoded = try JSONDecoder().decode(
            BashPolicy.self, from: Data(#"{"mode":"auto","unknownFutureKey":42}"#.utf8))
        XCTAssertEqual(decoded.mode, .auto)
    }

    func testLegacyManualRawValue_decodesToSemiAutomatic() throws {
        // The legacy `.manual` mode (read-only auto-allow + rule-driven) was renamed
        // to `.semiAutomatic`; the new `.manual` means "always confirm". The legacy
        // raw value `"manual"` therefore maps to `.semiAutomatic` so existing configs
        // keep their exact behavior with no migration, and the NEW always-confirm
        // mode carries a distinct raw value.
        XCTAssertEqual(BashExecutionMode(rawValue: "manual"), .semiAutomatic)
        XCTAssertEqual(BashExecutionMode.manual.rawValue, "alwaysConfirm")
        let decoded = try JSONDecoder().decode(BashPolicy.self, from: Data(#"{"mode":"manual"}"#.utf8))
        XCTAssertEqual(decoded.mode, .semiAutomatic)
    }

    func testEncodedJSON_carriesNoCredential() throws {
        // The bearer token lives only in the Keychain; an encoded policy (even with a
        // judge override) must never serialize a credential key. (We avoid the bare
        // "token" probe because `LLMOverride.maxTokens` legitimately contains it.)
        // maxTokens is set so the encoded JSON actually contains the `maxTokens` key —
        // that makes the "token" exclusion below genuinely necessary (a naive `token`
        // probe would false-trip on `maxtokens`) rather than vacuous.
        let p = BashPolicy(judgeOverride: LLMOverride(baseURLString: "http://h", modelName: "j", maxTokens: 256))
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self).lowercased()
        XCTAssertTrue(json.contains("maxtokens"), "sanity: maxTokens is present so the 'token' exclusion is real")
        // Not "token" (collides with `maxTokens`) nor "credential" (collides with the
        // `credentialRead` sandbox grant) — probe the actual bearer-token leak keys.
        for forbidden in ["bearer", "authorization", "apitoken", "api_token", "secret", "password"] {
            XCTAssertFalse(json.contains(forbidden), "encoded BashPolicy must not contain '\(forbidden)'")
        }
    }
}
