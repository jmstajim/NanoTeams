import XCTest

@testable import NanoTeams

/// The tool id written INSIDE `arguments` — S2 format mixing under R4.4.2, three turns of
/// one `ornith-1.0-35b` step (`/Users/alex/CastleSurvivors`, task 1 run 0, 2026-09-08,
/// 07:21:47 / 07:21:50 / 07:22:37). All three were dropped, each costing a round trip and
/// an `unknown_tool` card.
///
/// R4.3.4 sends a rule broken on 2+ turns of one step to a runtime check rather than to the
/// prompt, and R3.8.7 says which one: make the parser accept the form the model emits. The
/// system prompt is untouched — it already carries the correct rule ("The top-level `name`
/// is the tool id; a tool parameter named `name` goes inside `arguments`"), and R3.3.2
/// allows exactly one worked example.
final class NestedToolNameEnvelopeTests: XCTestCase {

    private func calls(_ buffer: String) -> [StepToolCall] {
        HarmonyToolCallParser().extractAllToolCalls(from: buffer)
    }

    private func resolve(_ json: String) -> StepToolCall? {
        ToolCallParsingHelpers.parseToolCallFromJSON(json)
    }

    // MARK: - The three production payloads, verbatim

    func testOrnith_readFileWithNameInsideArguments_resolvesWithItsPath() {
        let call = resolve(
            #"{"arguments":{"path": "scripts/core/anim_lab_puppet.gd", "name": "read_file"}, "type": "tool_call"}"#)
        XCTAssertEqual(call?.name, ToolNames.readFile)
        XCTAssertEqual(call?.argumentsJSON, #"{"path":"scripts/core/anim_lab_puppet.gd"}"#)
    }

    func testOrnith_readLinesDoubleWrappedEnvelope_resolvesWithAllFourArguments() {
        let call = resolve(
            #"{"arguments":{"name":"read_lines","arguments":{"end_line":500,"include_line_numbers":true,"path":"scripts/nodes/unit.gd","start_line":1}}}"#)
        XCTAssertEqual(call?.name, ToolNames.readLines)
        XCTAssertEqual(
            call?.argumentsJSON,
            #"{"end_line":500,"include_line_numbers":true,"path":"scripts/nodes/unit.gd","start_line":1}"#)
    }

    /// `git_show` is neither a tool nor an alias, so the gate refuses. The model gets a
    /// nudge about the POSITION — which is the fault it repeats — instead of a
    /// `tool_not_found` that would name only the id.
    func testOrnith_gitShowInsideArguments_isNotDispatched() {
        XCTAssertNil(
            resolve(
                #"{"arguments":{"name": "git_show", "path": "scripts/core/anim_lab_puppet.gd", "rev": "dbce2bb"}, "type": "tool_call"}"#))
    }

    /// The envelope framing field must never reach the tool's arguments.
    func testTypeToolCallSibling_neverReachesTheArguments() {
        let call = resolve(#"{"arguments":{"path":"a.md","name":"read_file"},"type":"tool_call"}"#)
        XCTAssertEqual(call?.argumentsJSON.contains("tool_call"), false)
    }

    func testFullHarmonyBuffer_nestedNameEnvelope_dispatches() {
        let buffer =
            #"<|call|>{"arguments":{"path": "scripts/core/anim_lab_puppet.gd", "name": "read_file"}, "type": "tool_call"}<|end|>"#
        XCTAssertEqual(calls(buffer).map(\.name), [ToolNames.readFile])
    }

    // MARK: - Ordering and the gate

    /// The branch runs AFTER shape inference, which makes the change purely additive: every
    /// payload that resolved before still resolves to the same bytes. `{name, content}` is
    /// `create_artifact`'s exact required signature and matches no other tool, while
    /// `search` has no `content` parameter at all — so inference is the better answer here.
    /// RED if the branch is moved ahead of `inferToolNameFromShape`.
    func testNestedName_losesToShapeInference() {
        let call = resolve(#"{"arguments":{"name":"search","content":"x"}}"#)
        XCTAssertEqual(call?.name, ToolNames.createArtifact)
    }

    /// RED if the gate ever gains `ToolRegistry.resolveToolName`: `test` is an alias for
    /// `run_xcodetests`, so that would launch a test run from a payload whose id position is
    /// already provably wrong.
    func testNestedName_aliasIsNotAccepted() {
        XCTAssertNil(resolve(#"{"arguments":{"name":"test","path":"scripts/"}}"#))
        XCTAssertNil(resolve(#"{"arguments":{"name":"build"}}"#))
        XCTAssertNil(resolve(#"{"arguments":{"name":"exec","command":"ls"}}"#))
    }

    func testNestedName_reservedChannelName_isNotDispatched() {
        XCTAssertNil(resolve(#"{"arguments":{"name":"commentary","path":"a.md"}}"#))
    }

    func testNestedName_artifactTitleInsideArguments_staysCreateArtifact() {
        let call = resolve(#"{"arguments":{"name":"Design Spec","content":"x"}}"#)
        XCTAssertEqual(call?.name, ToolNames.createArtifact)
    }

    /// An inner name that is neither a tool nor a create_artifact signature stays refused —
    /// the conservative answer this branch deliberately keeps.
    func testNestedName_unknownNameWithNoInferableShape_returnsNil() {
        XCTAssertNil(resolve(#"{"arguments":{"name":"My Report","summary":"x"}}"#))
    }

    // MARK: - Wrapper spellings and degenerate inputs

    func testNestedName_allFourWrapperAliases() {
        for key in ["arguments", "args", "parameters", "params"] {
            let call = resolve(#"{"\#(key)":{"name":"read_file","path":"a.md"}}"#)
            XCTAssertEqual(call?.name, ToolNames.readFile, "wrapper key \(key)")
            XCTAssertEqual(call?.argumentsJSON, #"{"path":"a.md"}"#, "wrapper key \(key)")
        }
    }

    func testNestedName_argumentsSerializedAsAString_failsClosed() {
        XCTAssertNil(resolve(#"{"arguments":"{\"name\":\"read_file\",\"path\":\"a.md\"}"}"#))
    }

    func testNestedName_nonDictWrapper_array_isNotUnwrapped() {
        XCTAssertNil(resolve(#"{"arguments":[{"name":"read_file"}]}"#))
    }

    func testNestedName_emptyInnerDict_isNotDispatched() {
        XCTAssertNil(resolve(#"{"arguments":{}}"#))
    }

    func testNestedName_emptyNameString_isNotDispatched() {
        XCTAssertNil(resolve(#"{"arguments":{"name":"","path":"a.md"}}"#))
    }

    func testNestedName_nameOnly_dispatchesWithEmptyArguments() {
        let call = resolve(#"{"arguments":{"name":"git_status"}}"#)
        XCTAssertEqual(call?.name, ToolNames.gitStatus)
    }

    /// A plain `resolve`-recursion would have emptied this one: `function` is a reserved
    /// envelope key, so top-level synthesis strips it. Reusing `resolveExplicitName` keeps
    /// the `function` branch identical at both levels.
    func testNestedName_functionSubObjectInsideArguments_keepsItsArguments() {
        let call = resolve(
            #"{"arguments":{"function":{"name":"read_file","arguments":{"path":"a.md"}}}}"#)
        XCTAssertEqual(call?.name, ToolNames.readFile)
        XCTAssertEqual(call?.argumentsJSON, #"{"path":"a.md"}"#)
    }

    func testNestedName_outerNameWins() {
        let call = resolve(#"{"name":"read_file","arguments":{"name":"write_file","path":"a.md"}}"#)
        XCTAssertEqual(call?.name, ToolNames.readFile)
    }

    // MARK: - Item C: the `function` branch reads all four wrapper keys

    func testFunctionObject_parametersWrapper_keepsItsArguments() {
        let call = resolve(#"{"function":{"name":"read_file","parameters":{"path":"a.md"}}}"#)
        XCTAssertEqual(call?.name, ToolNames.readFile)
        XCTAssertEqual(call?.argumentsJSON, #"{"path":"a.md"}"#)
    }

    func testFunctionObject_paramsWrapper_keepsItsArguments() {
        let call = resolve(#"{"function":{"name":"read_file","params":{"path":"a.md"}}}"#)
        XCTAssertEqual(call?.name, ToolNames.readFile)
        XCTAssertEqual(call?.argumentsJSON, #"{"path":"a.md"}"#)
    }

    // MARK: - `resolveExplicitName` preserves the grouping it was extracted with

    func testExplicitName_reservedFirstKey_fallsThroughToTheNextGroup() {
        let r = ToolCallShapeRecognizer.resolveExplicitName(
            in: ["name": "commentary", "tool_name": "read_file"])
        XCTAssertEqual(r?.name, ToolNames.readFile)
    }

    func testExplicitName_reservedInsideTheChain_refusesRatherThanFallingThrough() {
        XCTAssertNil(
            ToolCallShapeRecognizer.resolveExplicitName(
                in: ["tool_name": "commentary", "tool": "read_file"]),
            "the `??` chain picks the first PRESENT key; flattening would change this")
    }

    func testExplicitToolName_doesNotApplyTheReservedGuard() {
        XCTAssertEqual(
            ToolCallShapeRecognizer.explicitToolName(in: ["name": "commentary"]), "commentary",
            "the classifier must see this as name-BEARING, not as a missing name")
    }

    func testExplicitToolName_readsTheFunctionObject() {
        XCTAssertEqual(
            ToolCallShapeRecognizer.explicitToolName(in: ["function": ["name": "read_file"]]),
            ToolNames.readFile)
    }

    func testExplicitToolName_absent() {
        XCTAssertNil(ToolCallShapeRecognizer.explicitToolName(in: ["arguments": ["path": "a"]]))
    }
}
