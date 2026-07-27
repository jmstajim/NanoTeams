import XCTest
@testable import NanoTeams

/// Tests for `LLMOverride` — per-role configuration override struct.
///
/// Pinned behavior:
/// - `isEmpty` is true iff both fields are nil.
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

    /// Empty-string baseURL still counts as "set" (non-nil) — the struct is
    /// a nullability marker, not a validity check. Callers are responsible
    /// for validating content.
    func testIsEmpty_emptyStringBaseURL_returnsFalse() {
        let o = LLMOverride(baseURLString: "")
        XCTAssertFalse(o.isEmpty,
                       "An empty string is still non-nil — isEmpty is a nullability check")
    }

    // MARK: - Codable round-trip

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testCodable_roundTrip_allFieldsPreserved() throws {
        let original = LLMOverride(
            baseURLString: "http://192.168.1.10:1234",
            modelName: "custom-model-v2"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(LLMOverride.self, from: data)

        XCTAssertEqual(decoded.baseURLString, "http://192.168.1.10:1234")
        XCTAssertEqual(decoded.modelName, "custom-model-v2")
    }

    func testCodable_roundTrip_emptyOverride() throws {
        let original = LLMOverride()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(LLMOverride.self, from: data)

        XCTAssertTrue(decoded.isEmpty)
        XCTAssertNil(decoded.baseURLString)
        XCTAssertNil(decoded.modelName)
    }

    func testDecode_emptyJSONObject_yieldsEmptyOverride() throws {
        let data = "{}".data(using: .utf8)!
        let decoded = try decoder.decode(LLMOverride.self, from: data)
        XCTAssertTrue(decoded.isEmpty,
                      "`{}` must decode as all-nil — graceful default for legacy JSON")
    }

    /// Legacy JSON written when sampling params still lived on the override
    /// carries `maxTokens`/`temperature` keys — decode must ignore them,
    /// not reject.
    func testDecode_legacyJSON_withSamplingKeys_decodesIgnoringThem() throws {
        let json = #"{"modelName":"qwen-14b","maxTokens":8192,"temperature":0.1}"#
        let data = json.data(using: .utf8)!
        let decoded = try decoder.decode(LLMOverride.self, from: data)

        XCTAssertEqual(decoded.modelName, "qwen-14b")
        XCTAssertNil(decoded.baseURLString)
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

    // MARK: - hasServerOverride / hasModelOverride

    func testHasServerOverride_nil_returnsFalse() {
        XCTAssertFalse(LLMOverride().hasServerOverride)
    }

    func testHasServerOverride_emptyString_returnsFalse() {
        XCTAssertFalse(LLMOverride(baseURLString: "").hasServerOverride)
    }

    func testHasServerOverride_whitespaceOnly_returnsFalse() {
        XCTAssertFalse(LLMOverride(baseURLString: "   \n\t  ").hasServerOverride,
                       "Whitespace-only URLs are visually empty — must not seed the toggle on")
    }

    func testHasServerOverride_validURL_returnsTrue() {
        XCTAssertTrue(LLMOverride(baseURLString: "http://192.168.1.10:1234").hasServerOverride)
    }

    func testHasModelOverride_nil_returnsFalse() {
        XCTAssertFalse(LLMOverride().hasModelOverride)
    }

    func testHasModelOverride_emptyString_returnsFalse() {
        XCTAssertFalse(LLMOverride(modelName: "").hasModelOverride)
    }

    func testHasModelOverride_whitespaceOnly_returnsFalse() {
        XCTAssertFalse(LLMOverride(modelName: "  \t  ").hasModelOverride)
    }

    func testHasModelOverride_validName_returnsTrue() {
        XCTAssertTrue(LLMOverride(modelName: "qwen-14b").hasModelOverride)
    }

    /// The two predicates are independent — server and model can be
    /// overridden independently per CLAUDE.md "Per-role architecture".
    func testHasOverrides_independent() {
        let serverOnly = LLMOverride(baseURLString: "http://x:1234")
        XCTAssertTrue(serverOnly.hasServerOverride)
        XCTAssertFalse(serverOnly.hasModelOverride)

        let modelOnly = LLMOverride(modelName: "m")
        XCTAssertFalse(modelOnly.hasServerOverride)
        XCTAssertTrue(modelOnly.hasModelOverride)
    }

    // MARK: - Hashable

    func testHashable_sameValues_equalAndSameHash() {
        let a = LLMOverride(baseURLString: "u", modelName: "m")
        let b = LLMOverride(baseURLString: "u", modelName: "m")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testHashable_differentModelName_notEqual() {
        let a = LLMOverride(modelName: "m1")
        let b = LLMOverride(modelName: "m2")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Provider override

    func testIsEmpty_providerSet_returnsFalse() {
        // A provider-only override is meaningful: "this URL speaks Ollama".
        let override = LLMOverride(provider: .ollama)
        XCTAssertFalse(override.isEmpty)
    }

    func testCodable_roundTrip_providerPreserved() throws {
        let original = LLMOverride(
            baseURLString: "http://127.0.0.1:11434",
            modelName: "gpt-oss:20b",
            provider: .ollama
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMOverride.self, from: data)
        XCTAssertEqual(decoded.provider, .ollama)
        XCTAssertEqual(decoded, original)
    }

    func testDecode_legacyJSONWithoutProvider_yieldsNilProvider() throws {
        // Every teams.json written before provider overrides existed.
        let json = #"{"baseURLString":"http://x:1234","modelName":"m"}"#
        let decoded = try JSONDecoder().decode(LLMOverride.self, from: Data(json.utf8))
        XCTAssertNil(decoded.provider)
        XCTAssertEqual(decoded.baseURLString, "http://x:1234")
    }

    func testDecode_providerAsWrongType_tolerantlyNil() throws {
        // Hand-edited / corrupted teams.json: a NUMBER under `provider` must
        // not fail the whole team decode (the three-file store treats any
        // decode failure as corruption → wipe + re-bootstrap, far too harsh
        // for one garbage field). Type garbage collapses to "inherit global",
        // same as an unknown raw value.
        let json = #"{"modelName":"m","provider":42}"#
        let decoded = try JSONDecoder().decode(LLMOverride.self, from: Data(json.utf8))
        XCTAssertNil(decoded.provider)
        XCTAssertEqual(decoded.modelName, "m")
    }

    func testDecode_providerAsNullLiteral_nil() throws {
        let json = #"{"modelName":"m","provider":null}"#
        let decoded = try JSONDecoder().decode(LLMOverride.self, from: Data(json.utf8))
        XCTAssertNil(decoded.provider)
    }

    func testDecode_unknownProviderRawValue_tolerantlyNil() throws {
        // A future provider in a newer export must not fail the whole team —
        // unknown raw values collapse to "inherit global".
        let json = #"{"modelName":"m","provider":"futureProvider"}"#
        let decoded = try JSONDecoder().decode(LLMOverride.self, from: Data(json.utf8))
        XCTAssertNil(decoded.provider)
        XCTAssertEqual(decoded.modelName, "m")
    }
}
