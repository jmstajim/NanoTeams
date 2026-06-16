import XCTest

@testable import NanoTeams

/// Regression tests pinned to the verbatim model emission captured in
/// `.nanoteams/internal/tasks/0/subtasks/1/runs/0/network_log.json` lines 14
/// and 170 (Engineering Team Tech Lead and Software Engineer steps, planning
/// phase). `openai/gpt-oss-20b` emits `to=repo_browser.list_files` instead of
/// the canonical `list_files`; this exercises the three layers that compose to
/// produce the activity-feed cell:
///
/// 1. `HarmonyToolCallParser` preserves the namespaced name as-emitted.
/// 2. `ToolRegistry.resolveToolName` strips the prefix at every dispatch
///    boundary so the actual handler / authorization layer matches against
///    the canonical name.
/// 3. `LLMExecutionService.makeToolNotAuthorizedResult` keeps the as-emitted
///    name in the human-readable message (so the LLM can correlate with what
///    it just emitted) and omits the structured `tool` field — echoing the
///    name back as `"tool":"X"` framed an invented name as a real tool and
///    confused weaker models.
final class RepoBrowserNamespaceRejectionTests: XCTestCase {

    // MARK: - Test A — parser preserves namespace on real captured input

    /// Verbatim from `network_log.json` line 14 (Tech Lead step). The inner
    /// JSON is NOT a canonical envelope (no top-level `name`+`arguments`),
    /// so `resolveDispatch` keeps the channel `to=` value as the dispatch
    /// name.
    func testParser_realCapture_techLead_preservesRepoBrowserNamespace() {
        let raw = "[reasoning]\nWe need to plan: list files, edit them. Let's inspect repo.\n[/reasoning]\n\n<|channel|>commentary to=repo_browser.list_files <|constrain|>json<|message|>{\"path\": \"\", \"depth\": 2}\n"

        let calls = HarmonyToolCallParser().extractAllToolCalls(from: raw)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "repo_browser.list_files")
        // `normalizeArgumentsJSONString` re-serialises with `.sortedKeys`, so
        // the captured input order (`path` first, `depth` second) becomes
        // `depth`-first alphabetically.
        XCTAssertEqual(calls.first?.argumentsJSON, "{\"depth\":2,\"path\":\"\"}")
    }

    /// Verbatim from `network_log.json` line 170 (Software Engineer step,
    /// after Tech Lead handed off the Implementation Plan). Same channel /
    /// constrain shape as the Tech Lead emission but a different reasoning
    /// preamble — the model deterministically reaches for `repo_browser.*`
    /// during planning phase across both engineering roles, so we pin both.
    func testParser_realCapture_softwareEngineer_preservesRepoBrowserNamespace() {
        let raw = "[reasoning]\nWe need to implement. First list files. Let's read index.html.\n[/reasoning]\n\n<|channel|>commentary to=repo_browser.list_files <|constrain|>json<|message|>{\"path\": \"\", \"depth\": 2}\n"

        let calls = HarmonyToolCallParser().extractAllToolCalls(from: raw)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "repo_browser.list_files")
        XCTAssertEqual(calls.first?.argumentsJSON, "{\"depth\":2,\"path\":\"\"}")
    }

    // MARK: - Test B — resolveToolName strips known provider prefixes

    func testResolveToolName_repoBrowserPrefix_stripsToCanonical() {
        XCTAssertEqual(ToolRegistry.resolveToolName("repo_browser.list_files"), "list_files")
        XCTAssertEqual(ToolRegistry.resolveToolName("repo_browser.read_file"), "read_file")
    }

    func testResolveToolName_functionsPrefix_stripsToCanonical() {
        XCTAssertEqual(ToolRegistry.resolveToolName("functions.search"), "search")
        XCTAssertEqual(ToolRegistry.resolveToolName("functions.create_artifact"), "create_artifact")
    }

    func testResolveToolName_noPrefix_unchanged() {
        XCTAssertEqual(ToolRegistry.resolveToolName("list_files"), "list_files")
        XCTAssertEqual(ToolRegistry.resolveToolName("create_artifact"), "create_artifact")
    }

    /// Strip-then-alias path: `repo_browser.ls` strips to `ls`, which is in
    /// `defaultAliases` mapping to `list_files`. Same load-bearing path the
    /// runtime uses — without it, a namespaced alias would land in the
    /// rejected-tools envelope as `ls` instead of resolving to a real handler.
    func testResolveToolName_repoBrowserPrefixedAlias_resolvesToCanonical() {
        XCTAssertEqual(ToolRegistry.resolveToolName("repo_browser.ls"), "list_files")
        XCTAssertEqual(ToolRegistry.resolveToolName("functions.cat"), "read_file")
        XCTAssertEqual(ToolRegistry.resolveToolName("functions.grep"), "search")
    }

    /// Prefix detection is case-insensitive (uses `lower.hasPrefix(...)`); the
    /// returned name preserves the original casing of the suffix, then alias
    /// lookup lowercases internally. Pin both behaviors together so a future
    /// change can't accidentally make matching case-sensitive.
    func testResolveToolName_uppercasedPrefix_stillStripsAndAliases() {
        XCTAssertEqual(ToolRegistry.resolveToolName("REPO_BROWSER.LIST_FILES"), "LIST_FILES")
        // After strip the suffix `LS` lowercases for alias lookup → `list_files`.
        XCTAssertEqual(ToolRegistry.resolveToolName("REPO_BROWSER.LS"), "list_files")
    }

    /// Surrounding whitespace is trimmed before prefix detection — without
    /// this, a stray newline from an SSE chunk boundary would defeat the
    /// strip and surface the namespaced name to the UI.
    func testResolveToolName_surroundingWhitespace_isTrimmed() {
        XCTAssertEqual(ToolRegistry.resolveToolName(" repo_browser.list_files "), "list_files")
        XCTAssertEqual(ToolRegistry.resolveToolName("\nrepo_browser.search\t"), "search")
    }

    // MARK: - Test C — planning-phase rejection envelope shape

    /// Reproduces the rejection that produced the `tool_not_authorized` envelope
    /// captured in the network log's `[Tool Result]` for both Tech Lead and SWE
    /// during the Engineering Team's planning phase (when `allowedToolNames`
    /// contains only `update_scratchpad`).
    func testMakeToolNotAuthorizedResult_repoBrowserCall_envelopeShape() {
        let call = StepToolCall(
            name: "repo_browser.list_files",
            argumentsJSON: "{\"depth\":2,\"path\":\"\"}"
        )

        let result = LLMExecutionService.makeToolNotAuthorizedResult(
            call: call,
            canonicalName: "list_files",
            scope: "for this role"
        )

        XCTAssertTrue(result.isError)
        // As-emitted name preserved on the result so step.toolCalls history
        // matches what the LLM actually said. UI normalises at render time
        // (see `ToolCallItemView.canonicalName`).
        XCTAssertEqual(result.toolName, "repo_browser.list_files")
        // The `tool_not_authorized` (hallucination) envelope deliberately omits
        // the structured `tool` field — echoing the model's invented name back
        // as `"tool":"X"` framed it as a real-but-unauthorized tool and confused
        // weaker models (the name is often an artifact name, not a tool).
        XCTAssertFalse(
            result.outputJSON.contains("\"tool\":"),
            "tool_not_authorized envelope must not carry a 'tool' field, got: \(result.outputJSON)"
        )
        // The human-readable message echoes the as-emitted name so the LLM
        // can correlate with what it just emitted.
        XCTAssertTrue(
            result.outputJSON.contains("Tool 'repo_browser.list_files' is not available"),
            "expected as-emitted name in error message, got: \(result.outputJSON)"
        )
    }

    // MARK: - Test D — summariser dispatches on canonical names only

    /// `ToolCallSummarizer.argumentSummarizers` is keyed by canonical
    /// `ToolNames.*` constants. Passing the as-emitted namespaced name
    /// returns an empty summary — that's the bug the UI fix avoids by
    /// normalising via `ToolRegistry.resolveToolName` before invoking the
    /// summariser. If a future change broadens the dictionary keys, this
    /// test catches it.
    func testToolCallSummarizer_namespacedName_returnsEmptySummary() {
        let argsJSON = "{\"path\":\"index.html\"}"

        // Empty: dictionary has no key `repo_browser.read_file`.
        XCTAssertEqual(
            ToolCallSummarizer.summarizeArguments(
                toolName: "repo_browser.read_file", json: argsJSON, resolveRoleName: nil),
            ""
        )
    }

    /// Counterpart to the test above: the canonical name DOES dispatch and
    /// returns a non-empty summary. Together the two tests pin the contract
    /// "callers must normalise namespaced names before invoking the
    /// summariser" and demonstrate why the UI fix in `ToolCallItemView` is
    /// load-bearing for display correctness.
    func testToolCallSummarizer_canonicalName_returnsNonEmptySummary() {
        let argsJSON = "{\"path\":\"index.html\"}"

        XCTAssertEqual(
            ToolCallSummarizer.summarizeArguments(
                toolName: ToolNames.readFile, json: argsJSON, resolveRoleName: nil),
            "index.html"
        )
    }
}
