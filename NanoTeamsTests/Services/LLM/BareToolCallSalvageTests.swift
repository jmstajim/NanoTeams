import XCTest

@testable import NanoTeams

/// The last-resort recovery for a reply that carries no Harmony sentinel.
///
/// Fixtures are verbatim from the production pass that wedged
/// (`openai/gpt-oss-20b`, Autovisor manager): the model tried three times to end its
/// review pass with `wait_for_events` and could not, because every shape it reached for
/// was rejected. The two this type covers are turn 10 (bare JSON) and turns 7/9 (bare
/// identifier); the third, an empty-bodied channel envelope, is handled in the parser.
///
/// Half of these tests assert what the salvage REFUSES. That is the substance of it:
/// without a marker there is no evidence of intent, so the guards stand in for one.
final class BareToolCallSalvageTests: XCTestCase {

    // MARK: - Fixtures

    private func schema(_ name: String, required: [String] = []) -> ToolSchema {
        ToolSchema(
            name: name, description: "",
            parameters: JSONSchema(type: "object", properties: [:], required: required))
    }

    private var waitForEvents: [ToolSchema] { [schema(ToolNames.waitForEvents)] }

    private func salvage(_ text: String, _ tools: [ToolSchema] = []) -> StepToolCall? {
        BareToolCallSalvage.salvage(from: text, advertised: tools)
    }

    // MARK: - Rule A: the whole reply is one JSON object

    func testBareJSONEnvelope_resolves() {
        let out = salvage(#"{"name":"wait_for_events","arguments":{}}"#, waitForEvents)
        XCTAssertEqual(out?.name, ToolNames.waitForEvents)
        XCTAssertEqual(out?.argumentsJSON, "{}")
    }

    func testBareJSONEnvelope_withArguments_keepsThemSorted() {
        let out = salvage(#"{"name":"read_file","arguments":{"path":"a.swift"}}"#)
        XCTAssertEqual(out?.name, ToolNames.readFile)
        XCTAssertEqual(out?.argumentsJSON, #"{"path":"a.swift"}"#)
    }

    /// Registry membership, not role membership: a real tool the role lacks is promoted
    /// on purpose so `executeToolCalls` can answer `tool_not_authorized` + "do not retry".
    func testKnownToolTheRoleDoesNotHold_isStillPromoted() {
        XCTAssertEqual(salvage(#"{"name":"git_commit","arguments":{}}"#)?.name,
                       ToolNames.gitCommit)
    }

    /// …but a name outside the registry resolves to nothing. Without a marker there is no
    /// evidence this was a call attempt at all, and a one-object manifest is an ordinary
    /// thing to paste into a chat.
    func testUnknownToolName_doesNotResolve() {
        XCTAssertNil(salvage(#"{"name":"swift_build","arguments":{}}"#))
        XCTAssertNil(salvage(#"{"name":"my-app","version":"1.0.0"}"#))
    }

    /// `arguments` serialized as a JSON string is the OpenAI wire shape.
    func testArgumentsAsJSONString_isNormalized() {
        XCTAssertEqual(
            salvage(#"{"name":"read_file","arguments":"{\"path\":\"a\"}"}"#)?.argumentsJSON,
            #"{"path":"a"}"#)
    }

    /// Never `""` — an empty string splits `canonicalToolCallSignature`'s identity key, so
    /// a model alternating call shapes would slip past the repeated-tool-call detector.
    func testMissingArgumentsKey_yieldsEmptyObjectNotEmptyString() {
        XCTAssertEqual(salvage(#"{"name":"git_status"}"#)?.argumentsJSON, "{}")
    }

    func testFencedJSON_resolves() {
        XCTAssertEqual(
            salvage("```json\n{\"name\":\"git_status\",\"arguments\":{}}\n```")?.name,
            ToolNames.gitStatus)
        XCTAssertEqual(
            salvage("```\n{\"name\":\"git_status\",\"arguments\":{}}\n```")?.name,
            ToolNames.gitStatus)
    }

    // MARK: - Rule A: what it refuses

    /// Prose around the object means the model was writing ABOUT a call.
    func testProseAroundJSON_doesNotResolve() {
        XCTAssertNil(salvage(##"I'll call {"name":"git_status","arguments":{}} next."##))
        XCTAssertNil(salvage(##"{"name":"git_status","arguments":{}} — sound good?"##))
        XCTAssertNil(salvage(##"Sure: {"name":"git_status","arguments":{}}"##))
    }

    func testTwoObjects_doNotResolve() {
        XCTAssertNil(salvage(##"{"name":"git_status","arguments":{}}{"name":"git_log","arguments":{}}"##))
    }

    /// Strict parse only. The repair chain exists to rescue bytes whose intent a `<|call|>`
    /// already established; repairing unframed prose is how a quoted snippet becomes a
    /// dispatch.
    func testTruncatedJSON_doesNotResolve() {
        XCTAssertNil(salvage(##"{"name":"read_file","arguments":{"path":"##))
    }

    /// The flat-`create_artifact` inference and the argument-signature inference are the
    /// two branches of `ToolCallShapeRecognizer` this route must not inherit: `{name,
    /// content}` is the canonical shape of a DOCUMENT, and inferring an artifact write
    /// from it would let a chat reply persist a deliverable — and, via
    /// `resolveArtifactName`'s prefix matching, potentially complete the step with it.
    func testDocumentShapedObject_isNotAnArtifactWrite() {
        XCTAssertNil(salvage(##"{"name":"NPC Compendium entry: Grimwald","content":"A gruff smith."}"##))
        XCTAssertNil(salvage(##"{"arguments":{"name":"Plan","content":"1. read X"}}"##))
    }

    func testReservedChannelName_doesNotResolve() {
        for reserved in ["commentary", "analysis", "final", "thinking"] {
            XCTAssertNil(salvage(##"{"name":"\##(reserved)","arguments":{}}"##),
                         "`\(reserved)` is a channel, never a tool")
        }
    }

    func testNonObjectJSON_doesNotResolve() {
        XCTAssertNil(salvage(#"["wait_for_events"]"#))
        XCTAssertNil(salvage("42"))
        XCTAssertNil(salvage(#"{"status":"ok"}"#))
    }

    // MARK: - Rule B: the whole reply is one bare identifier

    func testBareToolName_resolves() {
        let out = salvage("wait_for_events", waitForEvents)
        XCTAssertEqual(out?.name, ToolNames.waitForEvents)
        XCTAssertEqual(out?.argumentsJSON, "{}")
    }

    func testBareToolName_surroundingWhitespace_isTolerated() {
        XCTAssertEqual(salvage("\n  wait_for_events \n", waitForEvents)?.name,
                       ToolNames.waitForEvents)
    }

    /// The load-bearing guard. `ToolRegistry.resolveToolName` maps the ordinary English
    /// words `test` and `build` onto the Xcode runners, both of which take no required
    /// parameters — so a schema-shape test would let a chat role replying with the single
    /// word "test" launch a build. The allowlist is why that cannot happen.
    func testAliasedEnglishWords_neverResolve() {
        let xcode = [schema(ToolNames.runXcodetests), schema(ToolNames.runXcodebuild)]
        for word in ["test", "build", "read", "find", "ls", "cat", "tree", "exec", "remove"] {
            XCTAssertNil(salvage(word, xcode), "the bare word `\(word)` must never dispatch")
        }
    }

    /// Everything else with no required parameters is off the allowlist too — `git_pull`
    /// is a network mutation, and the rest would silently default optional arguments to
    /// something other than what the model meant.
    func testOtherZeroRequiredArgTools_areNotOnTheAllowlist() {
        for name in [ToolNames.gitPull, ToolNames.gitStatus, ToolNames.listFiles,
                     ToolNames.gitLog, ToolNames.listTasks] {
            XCTAssertNil(salvage(name, [schema(name)]), "`\(name)` must not be bare-callable")
        }
    }

    /// The allowlist is necessary but not sufficient — the role must actually hold it.
    func testAllowlistedToolNotAdvertised_doesNotResolve() {
        XCTAssertNil(salvage("wait_for_events", []))
        XCTAssertNil(salvage("wait_for_events", [schema(ToolNames.readFile)]))
    }

    /// Talking about a tool is not calling it.
    func testDecoratedIdentifier_doesNotResolve() {
        for text in ["`wait_for_events`", "wait_for_events.", "wait_for_events!",
                     "Wait_for_events", "call wait_for_events", "wait for events",
                     "functions.wait_for_events", "\"wait_for_events\""] {
            XCTAssertNil(salvage(text, waitForEvents), "`\(text)` is prose, not a call")
        }
    }

    func testProse_doesNotResolve() {
        XCTAssertNil(salvage("Waiting for the M3 task to finish.", waitForEvents))
        XCTAssertNil(salvage("", waitForEvents))
        XCTAssertNil(salvage("   \n ", waitForEvents))
    }

    // MARK: - Identifier shape

    func testIsBareToolIdentifier_bounds() {
        XCTAssertFalse(BareToolCallSalvage.isBareToolIdentifier("ab"), "under 3 chars")
        XCTAssertTrue(BareToolCallSalvage.isBareToolIdentifier("abc"))
        XCTAssertTrue(BareToolCallSalvage.isBareToolIdentifier(String(repeating: "a", count: 40)))
        XCTAssertFalse(BareToolCallSalvage.isBareToolIdentifier(String(repeating: "a", count: 41)))
        XCTAssertFalse(BareToolCallSalvage.isBareToolIdentifier("_leading"), "must start with a letter")
        XCTAssertFalse(BareToolCallSalvage.isBareToolIdentifier("9lives"))
        XCTAssertFalse(BareToolCallSalvage.isBareToolIdentifier("has space"))
        XCTAssertFalse(BareToolCallSalvage.isBareToolIdentifier("привет_мир"), "ASCII only")
    }

    /// The allowlist is a deliberate one-tool special case; a silent growth would
    /// re-open the surface the guards above close.
    func testAllowlist_isExactlyWaitForEvents() {
        XCTAssertEqual(BareToolCallSalvage.zeroArgumentAllowlist, [ToolNames.waitForEvents])
    }

    // MARK: - Call-site pin

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
    }

    /// The sole expected call site — also the resolves-pin's marker, so the marker is a
    /// file every compiling checkout carries (the public mirror ships no CLAUDE.md).
    private static let expectedCallSitePath = "NanoTeams/Services/LLM/LLMExecutionService+Streaming.swift"

    /// Exactly one production call site: route 4 of `performStreamingCall`.
    ///
    /// A source pin because the property is about where this may NOT be used, and no
    /// behavioural test can observe a call site that doesn't exist yet. The step tool loop
    /// is the only place whose guards were reasoned through: it has a role's schema, a
    /// runtime that answers `tool_not_authorized`, and a ceiling that now counts an
    /// all-rejected batch. Meeting turns, consultations, the delegated-supervisor answer,
    /// team generation and vision analysis have none of that, and the last two are
    /// conversations where a model quoting a JSON object is ordinary.
    func testSalvageHasExactlyOneProductionCallSite() throws {
        let needle = "BareToolCallSalvage" + ".salvage("
        let enumerator = FileManager.default.enumerator(
            at: repoRoot.appendingPathComponent("NanoTeams"),
            includingPropertiesForKeys: nil)
        var sites: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  source.contains(needle) else { continue }
            // The declaration itself lives in the type; only USES count.
            guard url.lastPathComponent != "BareToolCallSalvage.swift" else { continue }
            sites.append(url.lastPathComponent)
        }
        XCTAssertEqual(
            sites, [URL(fileURLWithPath: Self.expectedCallSitePath).lastPathComponent],
            "the salvage is scoped to the step tool loop; adding a caller means re-arguing "
            + "its guards for that surface, not reusing them")
    }

    /// A broken `#filePath`→repoRoot derivation would enumerate nothing and pass vacuously.
    func testRepoRootResolves() {
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent(Self.expectedCallSitePath).path))
    }
}
