import XCTest

@testable import NanoTeams

/// Pins the legacy `description` / `descriptionPrompt` → `context` / `contextPrompt`
/// migration in `ProjectSettings.init(from:)`. Existing on-disk `settings.json`
/// files written before the rename use the old keys; loading them must populate
/// the new fields without data loss.
final class ProjectSettingsMigrationTests: XCTestCase {

    private let decoder = JSONCoderFactory.makeDateDecoder()
    private let encoder = JSONCoderFactory.makePersistenceEncoder()

    func testDecode_legacyKeys_populatesNewFields() throws {
        let json = #"""
        {
          "schemaVersion": 1,
          "description": "Legacy work folder description",
          "descriptionPrompt": "Legacy custom prompt"
        }
        """#

        let data = json.data(using: .utf8)!
        let settings = try decoder.decode(ProjectSettings.self, from: data)

        XCTAssertEqual(settings.context, "Legacy work folder description",
                       "legacy `description` key must hydrate `context`")
        XCTAssertEqual(settings.contextPrompt, "Legacy custom prompt",
                       "legacy `descriptionPrompt` key must hydrate `contextPrompt`")
    }

    func testDecode_newKeys_preferredOverLegacy() throws {
        // If both old and new keys are present (pathological mid-write state),
        // the new key wins so a partial migration cannot resurrect stale data.
        let json = #"""
        {
          "schemaVersion": 2,
          "context": "New context",
          "description": "Stale legacy text",
          "contextPrompt": "New prompt",
          "descriptionPrompt": "Stale legacy prompt"
        }
        """#

        let data = json.data(using: .utf8)!
        let settings = try decoder.decode(ProjectSettings.self, from: data)

        XCTAssertEqual(settings.context, "New context")
        XCTAssertEqual(settings.contextPrompt, "New prompt")
    }

    func testDecode_missingBothKeys_fallsBackToDefaults() throws {
        let json = #"""
        {
          "schemaVersion": 1
        }
        """#

        let data = json.data(using: .utf8)!
        let settings = try decoder.decode(ProjectSettings.self, from: data)

        XCTAssertEqual(settings.context, "")
        XCTAssertEqual(settings.contextPrompt, AppDefaults.workFolderContextPrompt)
    }

    func testEncode_writesOnlyNewKeys() throws {
        let settings = ProjectSettings(
            context: "Round-trip context",
            contextPrompt: "Round-trip prompt"
        )

        let data = try encoder.encode(settings)
        let json = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains("\"context\""), "must serialize new key")
        XCTAssertTrue(json.contains("\"contextPrompt\""), "must serialize new key")
        XCTAssertFalse(json.contains("\"description\""),
                       "must not write legacy key — stale on-disk data would " +
                       "shadow the new key during partial-migration reads")
        XCTAssertFalse(json.contains("\"descriptionPrompt\""),
                       "must not write legacy prompt key")
    }

    func testRoundTrip_legacyJSON_throughEncode_emitsNewSchema() throws {
        let legacyJSON = #"""
        {
          "schemaVersion": 1,
          "description": "RT context",
          "descriptionPrompt": "RT prompt"
        }
        """#

        // Decode legacy, re-encode, decode again — values must survive identically
        // and the second encoded form must be on the new schema.
        let firstDecode = try decoder.decode(
            ProjectSettings.self,
            from: legacyJSON.data(using: .utf8)!
        )
        let reencoded = try encoder.encode(firstDecode)
        let secondDecode = try decoder.decode(ProjectSettings.self, from: reencoded)

        XCTAssertEqual(secondDecode.context, "RT context")
        XCTAssertEqual(secondDecode.contextPrompt, "RT prompt")

        let json = String(data: reencoded, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"context\""))
        XCTAssertFalse(json.contains("\"description\""))
    }

    func testDecode_legacyKeys_bumpsSchemaVersionTo2() throws {
        // After a legacy decode the in-memory `schemaVersion` must be 2 so that the
        // next encode does not write a v1 payload that holds new-shape keys — the
        // on-disk version field would then lie about what's inside.
        let json = #"""
        {
          "schemaVersion": 1,
          "description": "Legacy",
          "descriptionPrompt": "Legacy prompt"
        }
        """#

        let settings = try decoder.decode(
            ProjectSettings.self,
            from: json.data(using: .utf8)!
        )

        XCTAssertEqual(settings.schemaVersion, 2,
                       "legacy decode must migrate schemaVersion in-memory")
    }

    func testRoundTrip_legacyJSON_emitsSchemaVersion2InOutput() throws {
        let legacyJSON = #"""
        {
          "schemaVersion": 1,
          "description": "ctx",
          "descriptionPrompt": "prompt"
        }
        """#

        let decoded = try decoder.decode(
            ProjectSettings.self,
            from: legacyJSON.data(using: .utf8)!
        )
        let reencoded = try encoder.encode(decoded)

        struct Envelope: Decodable { let schemaVersion: Int }
        let envelope = try decoder.decode(Envelope.self, from: reencoded)
        XCTAssertEqual(envelope.schemaVersion, 2,
                       "re-encoded legacy file must carry schemaVersion 2")
    }

    func testEncode_preservesSelectedScheme() throws {
        // Pinned by request from review: a future "skip-nil-encodeIfPresent"
        // refactor must not silently drop a real scheme.
        let original = ProjectSettings(
            context: "ctx",
            contextPrompt: "prompt",
            selectedScheme: "Demo"
        )
        let data = try encoder.encode(original)
        let roundTrip = try decoder.decode(ProjectSettings.self, from: data)

        XCTAssertEqual(roundTrip.selectedScheme, "Demo")
    }

    func testEncode_nilSelectedScheme_doesNotEmitKey() throws {
        // Round-trip when the optional is absent — must not materialize a `null`
        // that a third-party tool could mistake for a real value.
        let original = ProjectSettings(
            context: "ctx",
            contextPrompt: "prompt",
            selectedScheme: nil
        )
        let data = try encoder.encode(original)
        let roundTrip = try decoder.decode(ProjectSettings.self, from: data)

        XCTAssertNil(roundTrip.selectedScheme)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"selectedScheme\""),
                       "absent optional must not be serialized")
    }
}
