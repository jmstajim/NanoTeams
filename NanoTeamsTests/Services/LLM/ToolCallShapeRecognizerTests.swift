import XCTest

@testable import NanoTeams

/// Corner / boundary coverage for the pure shape-recognition enum extracted
/// from `ToolCallParsingHelpers.parseToolCallFromJSON`. Each envelope variant,
/// the reserved-name guard, top-level argument synthesis, and shape inference
/// are exercised directly against a clean `[String: Any]` — no bytes, no repair
/// layer in the way. The full byte→call pipeline stays pinned by
/// `HarmonyToolCallParserTests` / `ToolCallParsingHelpersTests`; this file
/// isolates the dispatch so each variant is independently testable.
final class ToolCallShapeRecognizerTests: XCTestCase {

    /// Serialize resolved arguments with the same stable (sorted-keys) encoder
    /// the parser uses, so expectations are deterministic.
    private func argsJSON(_ resolved: (name: String, arguments: Any?)?) -> String? {
        guard let args = resolved?.arguments else { return nil }
        return ToolCallParsingHelpers.stableJSONString(from: args)
    }

    // MARK: - Variant recognition

    func testResolve_nameField_withArgumentsWrapper() {
        let r = ToolCallShapeRecognizer.resolve(from: ["name": "read_file", "arguments": ["path": "a.txt"]])
        XCTAssertEqual(r?.name, "read_file")
        XCTAssertEqual(argsJSON(r), #"{"path":"a.txt"}"#)
    }

    func testResolve_toolNameField() {
        let r = ToolCallShapeRecognizer.resolve(from: ["tool_name": "search", "arguments": ["query": "x"]])
        XCTAssertEqual(r?.name, "search")
        XCTAssertEqual(argsJSON(r), #"{"query":"x"}"#)
    }

    func testResolve_toolField_noArgs_nilArguments() {
        let r = ToolCallShapeRecognizer.resolve(from: ["tool": "git_status"])
        XCTAssertEqual(r?.name, "git_status")
        XCTAssertNil(r?.arguments, "No promotable keys → nil args (serialises to \"\")")
    }

    func testResolve_functionNameField() {
        let r = ToolCallShapeRecognizer.resolve(from: ["function_name": "list_files"])
        XCTAssertEqual(r?.name, "list_files")
    }

    func testResolve_functionObject_nameAndArgs() {
        let r = ToolCallShapeRecognizer.resolve(from: [
            "function": ["name": "read_file", "arguments": ["path": "x"]],
        ])
        XCTAssertEqual(r?.name, "read_file")
        XCTAssertEqual(argsJSON(r), #"{"path":"x"}"#)
    }

    // MARK: - Flat create_artifact (gemma-4-e4b mis-binding guard)

    func testResolve_flatCreateArtifact_wholeDictBecomesArgs() {
        // No args wrapper, top-level `name` is the ARTIFACT name (not a tool),
        // and the payload matches create_artifact's signature.
        let r = ToolCallShapeRecognizer.resolve(from: [
            "name": "My Doc", "content": "hello", "format": "md",
        ])
        XCTAssertEqual(r?.name, ToolNames.createArtifact, "Must NOT bind tool name to the artifact name")
        XCTAssertEqual(argsJSON(r), #"{"content":"hello","format":"md","name":"My Doc"}"#)
    }

    func testResolve_flatPayloadWhoseNameIsAKnownTool_staysThatTool() {
        // Gate condition 2: a flat `{name: update_scratchpad, content: …}` must
        // resolve to update_scratchpad (synthesized args), NOT create_artifact.
        let r = ToolCallShapeRecognizer.resolve(from: [
            "name": "update_scratchpad", "content": "note",
        ])
        XCTAssertEqual(r?.name, "update_scratchpad")
        XCTAssertEqual(argsJSON(r), #"{"content":"note"}"#)
    }

    // MARK: - Shape inference (no top-level name)

    func testResolve_shapeInferred_createArtifact() {
        let r = ToolCallShapeRecognizer.resolve(from: ["arguments": ["name": "Doc", "content": "x"]])
        XCTAssertEqual(r?.name, ToolNames.createArtifact)
        XCTAssertEqual(argsJSON(r), #"{"content":"x","name":"Doc"}"#)
    }

    // MARK: - Precedence

    func testResolve_nameField_winsOverToolName() {
        let r = ToolCallShapeRecognizer.resolve(from: ["name": "read_file", "tool_name": "search"])
        XCTAssertEqual(r?.name, "read_file")
    }

    func testResolve_argsWrapperAliases_paramsAndArgs() {
        XCTAssertEqual(
            argsJSON(ToolCallShapeRecognizer.resolve(from: ["name": "read_file", "params": ["path": "a"]])),
            #"{"path":"a"}"#)
        XCTAssertEqual(
            argsJSON(ToolCallShapeRecognizer.resolve(from: ["name": "read_file", "args": ["path": "b"]])),
            #"{"path":"b"}"#)
    }

    // MARK: - Reserved-name guard

    func testResolve_reservedNames_rejected() {
        for reserved in ["commentary", "analysis", "final", "thinking"] {
            XCTAssertNil(
                ToolCallShapeRecognizer.resolve(from: ["name": reserved, "arguments": [:]]),
                "Reserved channel name \(reserved) must never resolve to a tool")
        }
    }

    func testResolve_reservedName_caseInsensitive() {
        XCTAssertNil(ToolCallShapeRecognizer.resolve(from: ["name": "COMMENTARY"]))
        XCTAssertNil(ToolCallShapeRecognizer.resolve(from: ["tool_name": "Analysis"]))
    }

    // MARK: - Degenerate / boundary

    func testResolve_emptyDict_returnsNil() {
        XCTAssertNil(ToolCallShapeRecognizer.resolve(from: [:]))
    }

    func testResolve_emptyNameString_returnsNil() {
        // stringValue rejects empty strings → no shape matches.
        XCTAssertNil(ToolCallShapeRecognizer.resolve(from: ["name": ""]))
    }

    func testResolve_unknownShape_returnsNil() {
        // No name field, arguments don't match any inferable signature.
        XCTAssertNil(ToolCallShapeRecognizer.resolve(from: ["arguments": ["foo": "bar"]]))
    }

    // MARK: - synthesizeArgumentsFromTopLevel

    func testSynthesize_promotesNonReservedKeys() {
        let out = ToolCallShapeRecognizer.synthesizeArgumentsFromTopLevel([
            "name": "write_file", "path": "a.txt", "content": "x",
        ])
        XCTAssertEqual(ToolCallParsingHelpers.stableJSONString(from: out!), #"{"content":"x","path":"a.txt"}"#)
    }

    func testSynthesize_stripsEnvelopeAndFramingFields() {
        let out = ToolCallShapeRecognizer.synthesizeArgumentsFromTopLevel([
            "name": "x", "tool": "y", "id": "1", "call_id": "2",
            "type": "function", "channel": "commentary", "recipient": "z", "constrain": "json",
            "arguments": "ignored", "args": "ignored", "parameters": "ignored", "params": "ignored",
            "content": "keep",
        ])
        XCTAssertEqual(ToolCallParsingHelpers.stableJSONString(from: out!), #"{"content":"keep"}"#)
    }

    func testSynthesize_noPromotableKeys_returnsNil() {
        XCTAssertNil(ToolCallShapeRecognizer.synthesizeArgumentsFromTopLevel(["name": "x", "id": "1"]))
        XCTAssertNil(ToolCallShapeRecognizer.synthesizeArgumentsFromTopLevel([:]))
    }

    // MARK: - Promotion reads the tool's vocabulary (2026-11-09)
    //
    // A key written BESIDE the call is promoted into its arguments only when the tool reads it
    // (`ToolArgumentVocabulary.acceptedKeys`). Anything else — a `thought`, a `reasoning` — is
    // commentary: left out and reported, never promoted into a call the runtime would then
    // refuse for a key the model never put in its arguments.

    func testTopLevelSynthesis_promotesOnlyWhatTheToolReads() throws {
        let dict: [String: Any] = ["name": "read_file", "path": "a.txt", "thought": "look first"]
        let r = try XCTUnwrap(ToolCallShapeRecognizer.resolve(from: dict))
        XCTAssertEqual(argsJSON(r), #"{"path":"a.txt"}"#)
        XCTAssertEqual(ToolCallShapeRecognizer.strandedKeys(from: dict, delivered: r.arguments), ["thought"])
    }

    func testTopLevelSynthesis_promotesTheToolsOtherSpellingsToo() throws {
        let dict: [String: Any] = ["name": "search", "pattern": "x", "path": "a.js"]
        let r = try XCTUnwrap(ToolCallShapeRecognizer.resolve(from: dict))
        XCTAssertEqual(argsJSON(r), #"{"path":"a.js","pattern":"x"}"#, "renamed later, by the runtime's reading")
        XCTAssertTrue(ToolCallShapeRecognizer.strandedKeys(from: dict, delivered: r.arguments).isEmpty)
    }

    func testSpilledSiblings_mergeTheToolsArguments_andLeaveCommentaryOut() throws {
        let dict: [String: Any] = [
            "name": "edit_file", "arguments": ["new_text": "b"],
            "old_text": "a", "path": "p.swift", "reasoning": "fix the typo",
        ]
        let r = try XCTUnwrap(ToolCallShapeRecognizer.resolve(from: dict))
        XCTAssertEqual(argsJSON(r), #"{"new_text":"b","old_text":"a","path":"p.swift"}"#)
        XCTAssertEqual(ToolCallShapeRecognizer.spilledSiblingKeys(from: dict, forTool: r.name), ["old_text", "path"])
        XCTAssertEqual(ToolCallShapeRecognizer.strandedKeys(from: dict, delivered: r.arguments), ["reasoning"])
    }

    func testFlatCreateArtifact_keepsOnlyTheArtifactsOwnKeys() throws {
        let dict: [String: Any] = ["name": "Release Notes", "content": "# Notes", "type": "function", "id": "c1"]
        let r = try XCTUnwrap(ToolCallShapeRecognizer.resolve(from: dict))
        XCTAssertEqual(r.name, ToolNames.createArtifact)
        XCTAssertEqual(argsJSON(r), ##"{"content":"# Notes","name":"Release Notes"}"##,
                       "envelope framing never becomes an argument")
    }

    /// A tool the vocabulary does not describe (an MCP tool) is promoted as before: nothing may
    /// be assumed about what its server reads.
    func testAToolTheVocabularyDoesNotDescribe_promotesEverythingAsBefore() throws {
        let dict: [String: Any] = ["name": "mcp__srv__tool", "anything": 1, "else": "x"]
        let r = try XCTUnwrap(ToolCallShapeRecognizer.resolve(from: dict))
        XCTAssertEqual(argsJSON(r), #"{"anything":1,"else":"x"}"#)
        XCTAssertTrue(ToolCallShapeRecognizer.strandedKeys(from: dict, delivered: r.arguments).isEmpty)
    }

    /// A spill beside a tool the vocabulary does not describe merges every sibling, as before.
    func testASpillBesideAToolTheVocabularyDoesNotDescribe_mergesEverySibling() {
        let dict: [String: Any] = ["name": "mcp__srv__tool", "arguments": ["a": 1], "b": 2]
        XCTAssertEqual(ToolCallShapeRecognizer.spilledSiblingKeys(from: dict, forTool: "mcp__srv__tool"), ["b"])
        XCTAssertEqual(ToolHandlerRegistry.undeclaredArguments(named: "mcp__srv__tool").count, 0)
    }

    func testTheStrandedNote_namesTheKeysAndTheTool_orIsNil() {
        XCTAssertNil(ToolCallParsingHelpers.strandedArgumentsNote(keys: [], tool: ToolNames.readFile))
        let note = ToolCallParsingHelpers.strandedArgumentsNote(keys: ["thought"], tool: "functions.read_file")
        XCTAssertEqual(
            note, "`thought` stood outside `arguments`, so it was left out of the `read_file` call — put every argument inside `arguments`")
    }

    /// Which supervisor ask runs is decided by the ARGUMENTS, after this — so a `form` written
    /// beside a call misnamed `ask_supervisor` reaches the routing (the live shape of
    /// 2026-09-10), and a `question` beside one misnamed `ask_supervisor_form` does too.
    func testAMisnamedSupervisorAsk_keepsTheKeysThatDecideWhichAskRuns() throws {
        let flatForm: [String: Any] = ["name": "ask_supervisor", "headline": "Scheme", "form": ["questions": []]]
        let r1 = try XCTUnwrap(ToolCallShapeRecognizer.resolve(from: flatForm))
        XCTAssertNotNil((r1.arguments as? [String: Any])?["form"], "the form reaches the routing")
        XCTAssertTrue(ToolCallShapeRecognizer.strandedKeys(from: flatForm, delivered: r1.arguments).isEmpty)

        let spilled: [String: Any] = ["name": "ask_supervisor", "arguments": ["headline": "h"], "form": ["questions": []]]
        let r2 = try XCTUnwrap(ToolCallShapeRecognizer.resolve(from: spilled))
        XCTAssertNotNil((r2.arguments as? [String: Any])?["form"])

        let plain: [String: Any] = ["name": "ask_supervisor_form", "question": "Which?"]
        let r3 = try XCTUnwrap(ToolCallShapeRecognizer.resolve(from: plain))
        XCTAssertEqual((r3.arguments as? [String: Any])?["question"] as? String, "Which?")
    }

    /// A real argument beside a wrapper written as a STRING cannot be merged into text — it is
    /// reported as left out, never dropped in silence.
    func testASiblingBesideAStringWrapper_isReportedAsLeftOut() throws {
        let dict: [String: Any] = ["name": "read_lines", "arguments": #"{"path":"a"}"#, "start_line": 40]
        let r = try XCTUnwrap(ToolCallShapeRecognizer.resolve(from: dict))
        XCTAssertEqual(ToolCallShapeRecognizer.strandedKeys(from: dict, delivered: r.arguments), ["start_line"])
    }

    /// An envelope nested a level too deep runs its INNER call; an outer sibling did not reach it.
    func testASiblingBesideANestedEnvelope_isReportedAsLeftOut() throws {
        let dict: [String: Any] = ["arguments": ["name": "read_lines", "arguments": ["path": "a"]], "start_line": 40]
        let r = try XCTUnwrap(ToolCallShapeRecognizer.resolve(from: dict))
        XCTAssertEqual(r.name, ToolNames.readLines)
        XCTAssertEqual(ToolCallShapeRecognizer.strandedKeys(from: dict, delivered: r.arguments), ["start_line"])
    }

    // MARK: - inferToolNameFromShape

    func testInfer_createArtifact_fromWrappedArgs() {
        let inferred = ToolCallShapeRecognizer.inferToolNameFromShape([
            "arguments": ["name": "D", "content": "c"],
        ])
        XCTAssertEqual(inferred?.name, ToolNames.createArtifact)
    }

    func testInfer_rejectsWhenExclusiveKeyPresent() {
        // `path` is exclusive to file tools → refuse to guess create_artifact.
        XCTAssertNil(ToolCallShapeRecognizer.inferToolNameFromShape([
            "arguments": ["name": "D", "content": "c", "path": "p"],
        ]))
    }

    func testInfer_requiresBothNameAndContent() {
        XCTAssertNil(ToolCallShapeRecognizer.inferToolNameFromShape(["arguments": ["name": "D"]]))
        XCTAssertNil(ToolCallShapeRecognizer.inferToolNameFromShape(["arguments": ["content": "c"]]))
    }

    func testInfer_noArgumentsKey_returnsNil() {
        XCTAssertNil(ToolCallShapeRecognizer.inferToolNameFromShape(["name": "x"]))
    }
}
