import XCTest

@testable import NanoTeams

/// `parseToolCallFromJSON` must recognize a FLAT `create_artifact` emission —
/// `{"content":…,"format":…,"name":"<Artifact Name>"}` with no `arguments`
/// wrapper — where the top-level `name` is the ARTIFACT name, not the tool name.
/// Without inference the artifact name was mis-bound as the tool name (observed
/// with `google/gemma-4-e4b`: `<|call|>{…,"name":"Production Readiness"}`).
///
/// The fix is gated on `create_artifact`'s exact signature (`name`+`content`, no
/// keys exclusive to other tools) AND the top-level `name` NOT already being
/// `create_artifact` — so it never over-reaches into other tools or the
/// canonical/flat-tool-name forms.
final class FlatCreateArtifactInferenceTests: XCTestCase {

    private func parse(_ json: String) -> StepToolCall? {
        ToolCallParsingHelpers.parseToolCallFromJSON(json)
    }

    // MARK: - The fix

    /// Flat artifact-shaped payload, `name` = artifact name → create_artifact,
    /// artifact name preserved in arguments.
    func testFlatArtifactPayload_infersCreateArtifact() {
        let call = parse("{\"content\":\"the spec body\",\"format\":\"markdown\",\"name\":\"Design Spec\"}")
        XCTAssertEqual(call?.name, ToolNames.createArtifact)
        XCTAssertTrue(call?.argumentsJSON.contains("\"name\":\"Design Spec\"") == true,
                      "Artifact name must survive in args; got \(call?.argumentsJSON ?? "nil")")
        XCTAssertTrue(call?.argumentsJSON.contains("\"content\":\"the spec body\"") == true)
    }

    /// `format` is optional for the inference — `name`+`content` is the minimum.
    func testFlatArtifactPayload_noFormat_stillInfers() {
        let call = parse("{\"content\":\"body\",\"name\":\"Research Report\"}")
        XCTAssertEqual(call?.name, ToolNames.createArtifact)
        XCTAssertTrue(call?.argumentsJSON.contains("\"name\":\"Research Report\"") == true)
    }

    // MARK: - Boundaries (must NOT change)

    /// Flat payload whose top-level `name` IS `create_artifact` (model used `name`
    /// for the tool, dropped the artifact name). Stays create_artifact — the
    /// inference must not fire and re-wrap it.
    func testFlatPayload_nameIsCreateArtifact_staysCreateArtifact() {
        let call = parse("{\"name\":\"create_artifact\",\"content\":\"body\"}")
        XCTAssertEqual(call?.name, ToolNames.createArtifact)
    }

    /// Canonical envelope is unchanged: nested `arguments` win, tool = create_artifact.
    func testCanonicalCreateArtifact_unchanged() {
        let call = parse("{\"name\":\"create_artifact\",\"arguments\":{\"name\":\"Design Spec\",\"content\":\"x\"}}")
        XCTAssertEqual(call?.name, ToolNames.createArtifact)
        XCTAssertTrue(call?.argumentsJSON.contains("\"name\":\"Design Spec\"") == true)
    }

    /// A canonical call to another tool is unchanged.
    func testCanonicalReadFile_unchanged() {
        let call = parse("{\"name\":\"read_file\",\"arguments\":{\"path\":\"a.txt\"}}")
        XCTAssertEqual(call?.name, "read_file")
    }

    /// Flat `read_file` (name=read_file, `path` present) — `path` is a key
    /// exclusive to other tools, so the create_artifact shape gate fails and the
    /// top-level `name` is used as the tool. Unchanged.
    func testFlatReadFile_withPath_staysReadFile() {
        let call = parse("{\"name\":\"read_file\",\"path\":\"a.txt\"}")
        XCTAssertEqual(call?.name, "read_file")
        XCTAssertTrue(call?.argumentsJSON.contains("\"path\":\"a.txt\"") == true)
    }

    /// Flat payload with `content` but ALSO a key exclusive to another tool
    /// (`query`): the create_artifact gate refuses (ambiguous), so the inference
    /// does NOT fire — `name` is taken as the tool name (pre-existing behavior,
    /// out of this fix's scope). Pins that the fix doesn't over-reach.
    func testFlatPayload_contentPlusExclusiveKey_doesNotInferCreateArtifact() {
        let call = parse("{\"name\":\"Mystery\",\"content\":\"x\",\"query\":\"q\"}")
        XCTAssertNotEqual(call?.name, ToolNames.createArtifact)
    }

    /// `arguments`-wrapped artifact shape with NO top-level name still infers
    /// create_artifact via the existing shape fallback (regression guard for the
    /// pre-existing `inferToolNameFromShape` path).
    func testWrappedArtifactShape_noTopLevelName_infersCreateArtifact() {
        let call = parse("{\"arguments\":{\"name\":\"Design Spec\",\"content\":\"x\"}}")
        XCTAssertEqual(call?.name, ToolNames.createArtifact)
    }
}
