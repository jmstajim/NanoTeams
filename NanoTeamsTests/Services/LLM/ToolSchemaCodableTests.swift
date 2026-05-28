import XCTest
@testable import NanoTeams

/// `ToolSchema: Codable` was added so `FirstPromptRenderer.makeRenderMeta` can
/// emit per-tool char sizes and full schemas into `render_meta`. The audit's
/// token-economy numbers depend on encode-stability — a future `JSONSchema`
/// encoder change could shift counts without any other test breaking.
final class ToolSchemaCodableTests: XCTestCase {

    func testToolSchema_codableRoundTrip_preservesNameDescriptionAndParams() throws {
        let original = ToolSchema(
            name: "read_file",
            description: "Read entire file content.",
            parameters: JSONSchema.object(
                properties: ["path": JSONSchema.string("Relative path to file")],
                required: ["path"]
            )
        )

        let encoder = JSONCoderFactory.makeWireEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONCoderFactory.makeWireDecoder()
        let roundTrip = try decoder.decode(ToolSchema.self, from: data)

        XCTAssertEqual(roundTrip.name, original.name)
        XCTAssertEqual(roundTrip.description, original.description)
        // Hashable conformance on ToolSchema gives us a cheap structural check.
        XCTAssertEqual(roundTrip, original)
    }

    func testToolSchema_jsonShape_isStableAcrossEncodes() throws {
        // Two encodes of the same schema must produce byte-identical JSON —
        // otherwise `render_meta.tools[i].chars` would drift run-to-run and
        // the audit's diff against a `--from-logs` baseline would be noisy.
        let schema = ToolSchema(
            name: "edit_file",
            description: "Replace exact text in a file.",
            parameters: JSONSchema.object(
                properties: [
                    "path": JSONSchema.string("Relative path to file"),
                    "old_text": JSONSchema.string("Text to find"),
                    "new_text": JSONSchema.string("Replacement text"),
                ],
                required: ["path", "old_text", "new_text"]
            )
        )

        let encoder = JSONCoderFactory.makeWireEncoder()
        let a = try encoder.encode(schema)
        let b = try encoder.encode(schema)
        XCTAssertEqual(a, b, "schema encoding must be byte-stable for audit reproducibility")
    }
}
