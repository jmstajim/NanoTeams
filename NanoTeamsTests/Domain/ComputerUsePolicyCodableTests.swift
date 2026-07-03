import XCTest

@testable import NanoTeams

/// Tolerant-decode + no-credential-leak pins for `ComputerUsePolicy` (it's `Codable` and could
/// be logged or round-tripped).
final class ComputerUsePolicyCodableTests: XCTestCase {

    private func decode(_ json: String) throws -> ComputerUsePolicy {
        try JSONDecoder().decode(ComputerUsePolicy.self, from: Data(json.utf8))
    }

    func testEmptyJSON_decodesToSafeDefaults() throws {
        let p = try decode("{}")
        // Manual is the default: the feature is on but every action requires an
        // explicit human Allow — fail-safe without being unusable out of the box.
        XCTAssertEqual(p.mode, .manual)
        XCTAssertEqual(p.restrictionLevel, .standard)
        XCTAssertTrue(p.targetAppAllowlist.isEmpty)
        XCTAssertTrue(p.blockedTypingPatterns.isEmpty)
        XCTAssertTrue(p.blockedKeyCombos.isEmpty)
        XCTAssertTrue(p.raiseTargetWindowBeforeClick)
        XCTAssertTrue(p.gateFirstCaptureOnly)
        XCTAssertNil(p.judgeOverride)
    }

    func testPartialJSON_keepsDefaultsForMissingFields() throws {
        let p = try decode(#"{"mode":"manual"}"#)
        XCTAssertEqual(p.mode, .manual)
        XCTAssertTrue(p.raiseTargetWindowBeforeClick)   // default preserved
        XCTAssertTrue(p.gateFirstCaptureOnly)
    }

    func testRoundTrip_preservesValues() throws {
        let original = ComputerUsePolicy(
            mode: .auto, restrictionLevel: .strict,
            targetAppAllowlist: ["com.apple.Safari"],
            blockedTypingPatterns: ["password"], blockedKeyCombos: ["cmd\\+q"],
            raiseTargetWindowBeforeClick: false, gateFirstCaptureOnly: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ComputerUsePolicy.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// The policy must never carry a credential — probe the real leak keys (not "token",
    /// which would collide with `maxTokens` in a `judgeOverride`).
    func testEncodedJSON_carriesNoCredential() throws {
        let p = ComputerUsePolicy(mode: .auto, judgeOverride: LLMOverride(modelName: "vlm"))
        let json = String(data: try JSONEncoder().encode(p), encoding: .utf8)!.lowercased()
        for forbidden in ["bearer", "authorization", "api_token", "secret", "password"] {
            XCTAssertFalse(json.contains(forbidden), "policy JSON leaks '\(forbidden)'")
        }
    }

    func testModeRawValues_areFrozen() {
        // Persisted by rawValue — these must not drift or existing configs break.
        XCTAssertEqual(ComputerUseMode.off.rawValue, "off")
        XCTAssertEqual(ComputerUseMode.manual.rawValue, "manual")
        XCTAssertEqual(ComputerUseMode.auto.rawValue, "auto")
        XCTAssertEqual(ComputerUseRestrictionLevel.strict.rawValue, "strict")
        XCTAssertEqual(ComputerUseRestrictionLevel.standard.rawValue, "standard")
        XCTAssertEqual(ComputerUseRestrictionLevel.permissive.rawValue, "permissive")
        XCTAssertEqual(ComputerUseRestrictionLevel.off.rawValue, "off")
    }

    func testIsEnabled_truthTable() {
        // Single source of truth for "the feature is on at all" — schema strip,
        // classifier, and UI all key off this.
        XCTAssertFalse(ComputerUsePolicy(mode: .off).isEnabled)
        XCTAssertTrue(ComputerUsePolicy(mode: .manual).isEnabled)
        XCTAssertTrue(ComputerUsePolicy(mode: .auto).isEnabled)
    }

    func testRestrictionLevelOff_roundTrips() throws {
        let original = ComputerUsePolicy(mode: .auto, restrictionLevel: .off)
        let decoded = try JSONDecoder().decode(
            ComputerUsePolicy.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.restrictionLevel, .off)
        XCTAssertEqual(decoded, original)
    }

    func testRestrictionLevelOff_decodesFromRawJSON() throws {
        // The persisted shape a Safety=Off user's settings produce.
        let p = try decode(#"{"mode":"auto","restrictionLevel":"off"}"#)
        XCTAssertEqual(p.mode, .auto)
        XCTAssertEqual(p.restrictionLevel, .off)
        XCTAssertTrue(p.isEnabled)
    }

    func testMetadata_nonEmpty() {
        for mode in ComputerUseMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.settingDescription.isEmpty)
        }
        for level in ComputerUseRestrictionLevel.allCases {
            XCTAssertFalse(level.displayName.isEmpty)
            XCTAssertFalse(level.judgeGuidance.isEmpty)
        }
    }
}
