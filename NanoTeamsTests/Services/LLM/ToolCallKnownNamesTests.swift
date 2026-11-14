import XCTest

@testable import NanoTeams

/// Whether the parser can recognise a tool name it could not have been compiled against.
///
/// `ToolNames.allNames` is a compile-time list. An `mcp__<slug>__<tool>` name exists only on
/// the step that advertised it, so every gate along the parse chain that asks "is this string
/// a tool" has to be asked with the step's own union — and a gate that is not reaches the
/// worst outcome available: the call parses to nothing and is dropped silently, which the
/// model reads as a turn it never made.
final class ToolCallKnownNamesTests: XCTestCase {

    private let mcpName = "mcp__folio__get_metadata"

    private var advertised: [ToolSchema] {
        [ToolSchema(name: mcpName, description: "External.", parameters: JSONSchema(type: "object"))]
    }

    private var known: Set<String> { HarmonyToolCallParser.knownNames(advertising: advertised) }

    // MARK: - The union itself

    func testTheUnionIsTheRegistryPlusWhatWasAdvertised() {
        XCTAssertTrue(known.contains(mcpName))
        XCTAssertTrue(known.contains(ToolNames.readFile))
    }

    /// The common case — no MCP anywhere — must not allocate a second set, and must be the
    /// same answer the whole chain defaulted to before this parameter existed.
    func testWithNothingAdvertisedTheUnionIsTheRegistry() {
        XCTAssertEqual(HarmonyToolCallParser.knownNames(advertising: []), ToolNames.allNames)
    }

    // MARK: - `<|call|>` envelopes

    func testAnEnvelopeNamingAnExternalToolParses() {
        let text = "<|call|>{\"name\":\"\(mcpName)\",\"arguments\":{\"node\":\"1:2\"}}<|end|>"
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: text, knownNames: known)
        XCTAssertEqual(calls.map(\.name), [mcpName])
    }

    /// A top-level `name` the recognizer does not know, beside a `content` key, is read as a
    /// flat `create_artifact` payload — which for an unrecognised MCP name would dispatch
    /// the WRONG TOOL and write an artifact the role never asked for.
    func testAnExternalToolIsNotMistakenForAFlatArtifactWrite() {
        let text = "<|call|>{\"name\":\"\(mcpName)\",\"content\":\"x\"}<|end|>"
        let withUnion = HarmonyToolCallParser().extractAllToolCalls(from: text, knownNames: known)
        XCTAssertEqual(withUnion.map(\.name), [mcpName])

        let withoutUnion = HarmonyToolCallParser().extractAllToolCalls(from: text)
        XCTAssertEqual(
            withoutUnion.map(\.name), [ToolNames.createArtifact],
            "the registry-only reading is what the union exists to correct")
    }

    /// The nested-wrapper recovery is gated on the name being a real tool, so an external
    /// one has to be in the set or the shape is not recovered at all.
    func testTheNestedWrapperRecoveryReachesAnExternalTool() {
        let dict: [String: Any] = ["arguments": ["name": mcpName, "node": "1:2"]]
        XCTAssertEqual(ToolCallShapeRecognizer.resolve(from: dict, knownNames: known)?.name, mcpName)
        XCTAssertNil(ToolCallShapeRecognizer.resolve(from: dict)?.name)
    }

    func testTheNamePositionReportIsTruthfulAboutAnExternalTool() {
        let dict: [String: Any] = ["arguments": ["name": mcpName]]
        guard case .insideArguments(_, let isRegistered) =
            ToolCallShapeRecognizer.toolNamePosition(in: dict, knownNames: known)
        else { return XCTFail("expected the nested position") }
        XCTAssertTrue(isRegistered)
    }

    // MARK: - Bare salvage, rule A

    func testAnUnframedEnvelopeNamingAnExternalToolIsSalvaged() throws {
        let text = "{\"name\":\"\(mcpName)\",\"arguments\":{\"node\":\"1:2\"}}"
        let salvaged = try XCTUnwrap(BareToolCallSalvage.salvage(from: text, advertised: advertised))
        XCTAssertEqual(salvaged.name, mcpName)
    }

    func testTheSameTextIsNotSalvagedWhenTheRoleAdvertisedNothing() {
        let text = "{\"name\":\"\(mcpName)\",\"arguments\":{\"node\":\"1:2\"}}"
        XCTAssertNil(BareToolCallSalvage.salvage(from: text, advertised: []))
    }

    /// Recognition and dispatch must not be able to disagree about what counts as an
    /// attempt — that is the contract `looksLikeToolCallAttempt` states about itself.
    func testRecognitionAgreesWithDispatchForAnExternalTool() {
        let text = "{\"name\":\"\(mcpName)\",\"arguments\":{}}"
        XCTAssertTrue(BareToolCallSalvage.looksLikeToolCallAttempt(text, knownNames: known))
        XCTAssertFalse(BareToolCallSalvage.looksLikeToolCallAttempt(text))
    }

    // MARK: - A spliced sentinel

    /// The debris run can CARRY the call's identity — `<|tool_call>call:edit_file{…}` is a
    /// shape a shipping model writes — and the hoist DROPS a run whose trailing identifier
    /// it does not recognise. So an unrecognised external name is not merely unhelped: it
    /// is taken out with the debris, leaving a nameless payload that resolves to nothing.
    func testAMangledSentinelKeepsAnExternalToolsName() {
        let short = "mcp__fg__meta"
        let known = HarmonyToolCallParser.knownNames(advertising: [
            ToolSchema(name: short, description: "External.", parameters: JSONSchema(type: "object")),
        ])
        let text = "<|tool_call>call:\(short){\"node\":\"1:2\"}<|end|>"
        XCTAssertTrue(
            HarmonySentinelNormalizer.normalize(text, knownNames: known).contains(short))
        XCTAssertFalse(HarmonySentinelNormalizer.normalize(text).contains(short))
        XCTAssertEqual(
            HarmonyToolCallParser().extractAllToolCalls(
                from: text, knownNames: known).map(\.name),
            [short])
    }

    /// Where the hoist stops, and it is not the registry: the debris budget is 20
    /// characters, so `>call:mcp__folio__get_metadata` is refused as debris whatever the
    /// name means. Nothing is LOST there — the whole token is emitted verbatim — so the
    /// boundary is a missed repair rather than a dropped call, and this records which of
    /// the two limits a long external name meets first.
    func testALongExternalNamePastTheDebrisBudgetIsLeftVerbatim() {
        let text = "<|tool_call>call:\(mcpName){\"node\":\"1:2\"}<|end|>"
        XCTAssertEqual(HarmonySentinelNormalizer.normalize(text, knownNames: known), text)
    }

    /// Nothing about a built-in tool may change because the parameter exists.
    func testABuiltInToolParsesIdenticallyWithAndWithoutTheUnion() {
        let text = "<|call|>{\"name\":\"read_file\",\"arguments\":{\"path\":\"a.txt\"}}<|end|>"
        let withUnion = HarmonyToolCallParser().extractAllToolCalls(from: text, knownNames: known)
        let withoutUnion = HarmonyToolCallParser().extractAllToolCalls(from: text)
        XCTAssertEqual(withUnion.map(\.name), withoutUnion.map(\.name))
        XCTAssertEqual(withUnion.map(\.argumentsJSON), withoutUnion.map(\.argumentsJSON))
    }

    /// The classifier is what turns a failed attempt into a nudge, so it has to read the
    /// same set — otherwise a broken MCP envelope is diagnosed as naming no tool.
    func testTheFailureClassifierSeesAnExternalToolAsNamed() {
        let text = "<|call|>{\"name\":\"\(mcpName)\",\"arguments\":{\"node\":}}<|end|>"
        XCTAssertEqual(
            ToolCallParsingHelpers.classifyHarmonyCallIssue(in: text, knownNames: known),
            .malformedJSON)
    }
}
