import XCTest
@testable import NanoTeams

/// Tests for `LLMOverride` — per-role configuration override struct.
///
/// Pinned behavior:
/// - `isEmpty` is true iff ALL four fields are nil.
/// - Any single field populated flips `isEmpty` to false.
/// - Codable round-trip preserves every field (including Double precision).
/// - Decoding with missing keys yields nil fields (graceful upgrade path).
/// - Decoding empty JSON `{}` yields a fully-empty override.
/// - Codable is additive-safe: decoder won't reject unknown keys.
final class LLMOverrideTests: XCTestCase {

    // MARK: - isEmpty

    func testIsEmpty_allNil_returnsTrue() {
        let o = LLMOverride()
        XCTAssertTrue(o.isEmpty)
    }

    func testIsEmpty_baseURLSet_returnsFalse() {
        let o = LLMOverride(baseURLString: "http://example.com")
        XCTAssertFalse(o.isEmpty)
    }

    func testIsEmpty_modelNameSet_returnsFalse() {
        let o = LLMOverride(modelName: "gpt-4")
        XCTAssertFalse(o.isEmpty)
    }

    func testIsEmpty_maxTokensSet_returnsFalse() {
        let o = LLMOverride(maxTokens: 4096)
        XCTAssertFalse(o.isEmpty)
    }

    func testIsEmpty_temperatureSet_returnsFalse() {
        let o = LLMOverride(temperature: 0.7)
        XCTAssertFalse(o.isEmpty)
    }

    /// Empty-string baseURL still counts as "set" (non-nil) — the struct is
    /// a nullability marker, not a validity check. Callers are responsible
    /// for validating content.
    func testIsEmpty_emptyStringBaseURL_returnsFalse() {
        let o = LLMOverride(baseURLString: "")
        XCTAssertFalse(o.isEmpty,
                       "An empty string is still non-nil — isEmpty is a nullability check")
    }

    func testIsEmpty_zeroTemperature_returnsFalse() {
        let o = LLMOverride(temperature: 0.0)
        XCTAssertFalse(o.isEmpty,
                       "Temperature = 0.0 is valid (deterministic) and must not be treated as absent")
    }

    func testIsEmpty_zeroMaxTokens_returnsFalse() {
        let o = LLMOverride(maxTokens: 0)
        XCTAssertFalse(o.isEmpty)
    }

    // MARK: - Codable round-trip

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testCodable_roundTrip_allFieldsPreserved() throws {
        let original = LLMOverride(
            baseURLString: "http://192.168.1.10:1234",
            modelName: "custom-model-v2",
            maxTokens: 8192,
            temperature: 0.42
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(LLMOverride.self, from: data)

        XCTAssertEqual(decoded.baseURLString, "http://192.168.1.10:1234")
        XCTAssertEqual(decoded.modelName, "custom-model-v2")
        XCTAssertEqual(decoded.maxTokens, 8192)
        XCTAssertEqual(decoded.temperature ?? .nan, 0.42, accuracy: 1e-9)
    }

    func testCodable_roundTrip_emptyOverride() throws {
        let original = LLMOverride()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(LLMOverride.self, from: data)

        XCTAssertTrue(decoded.isEmpty)
        XCTAssertNil(decoded.baseURLString)
        XCTAssertNil(decoded.modelName)
        XCTAssertNil(decoded.maxTokens)
        XCTAssertNil(decoded.temperature)
    }

    func testDecode_emptyJSONObject_yieldsEmptyOverride() throws {
        let data = "{}".data(using: .utf8)!
        let decoded = try decoder.decode(LLMOverride.self, from: data)
        XCTAssertTrue(decoded.isEmpty,
                      "`{}` must decode as all-nil — graceful default for legacy JSON")
    }

    func testDecode_partialJSON_onlyNamedFieldsPopulated() throws {
        let json = #"{"modelName":"qwen-14b","temperature":0.1}"#
        let data = json.data(using: .utf8)!
        let decoded = try decoder.decode(LLMOverride.self, from: data)

        XCTAssertEqual(decoded.modelName, "qwen-14b")
        XCTAssertEqual(decoded.temperature ?? .nan, 0.1, accuracy: 1e-9)
        XCTAssertNil(decoded.baseURLString)
        XCTAssertNil(decoded.maxTokens)
    }

    /// Unknown keys in the JSON payload must NOT cause decode to fail —
    /// future compatibility with downgraded apps.
    func testDecode_unknownKeys_ignored() throws {
        let json = #"{"modelName":"m1","futureField":"irrelevant","nested":{"x":1}}"#
        let data = json.data(using: .utf8)!
        XCTAssertNoThrow(try decoder.decode(LLMOverride.self, from: data),
                         "Unknown keys must be ignored by the custom decoder")
        let decoded = try decoder.decode(LLMOverride.self, from: data)
        XCTAssertEqual(decoded.modelName, "m1")
    }

    // MARK: - Hashable

    func testHashable_sameValues_equalAndSameHash() {
        let a = LLMOverride(baseURLString: "u", modelName: "m", maxTokens: 1, temperature: 0.1)
        let b = LLMOverride(baseURLString: "u", modelName: "m", maxTokens: 1, temperature: 0.1)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testHashable_differentTemperature_notEqual() {
        let a = LLMOverride(temperature: 0.1)
        let b = LLMOverride(temperature: 0.2)
        XCTAssertNotEqual(a, b)
    }
}
