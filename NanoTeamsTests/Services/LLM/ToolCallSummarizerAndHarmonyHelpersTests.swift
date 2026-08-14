import XCTest

@testable import NanoTeams

/// Coverage for the two pure layers that sit either side of a Harmony tool call:
///
/// 1. `ToolCallSummarizer` — the OCP dictionary of per-tool argument summarizers.
///    Its output is not decoration: `ToolCallTracker.record` stores it as
///    `TrackedCall.argumentsSummary` as a DISPLAY label; repetition identity is
///    `TrackedCall.argumentsIdentity` (canonical arguments JSON), and
///    `ToolCallLoopDetector` fires `.repetitiveTool` on a trailing run of 3
///    identical keys among the last 6 successful calls. A summarizer that
///    collapses two genuinely different calls therefore turns honest work
///    (pagination, scrolling, retargeting a capture) into a false "identical
///    arguments" nudge — the exact regression CLAUDE.md documents for the
///    computer-use entries. Every entry added here is asserted BOTH for its
///    rendered text AND, where the argument is a paging/coordinate/target knob,
///    for DISTINCTNESS across two calls that differ only in it.
///
/// 2. `ToolCallParsingHelpers` / `HarmonyToolCallParser` — the remaining
///    salvage/repair arms: `extractJSONBracedValue`'s synthetic-closer salvage
///    across its whole `maxSalvageDepth` range and its three refusal guards, the
///    quoted-identifier reader, the shared `postCallJSON` walk, and the composite
///    parser's cross-strategy merge/dedup.
///
/// Complements (does not duplicate) `ToolCallSummarizerTests`,
/// `ToolCallParsingHelpersTests`, `HarmonyToolCallParserTests`,
/// `HarmonyToolCallParserFailureTests` and `HarmonyJSONDefectRepairTests`.
final class ToolCallSummarizerAndHarmonyHelpersTests: XCTestCase {

    private typealias TN = ToolNames

    private static func summarize(_ tool: String, _ json: String) -> String {
        ToolCallSummarizer.summarizeArguments(toolName: tool, json: json)
    }

    private static func result(_ tool: String, _ json: String) -> String {
        ToolCallSummarizer.summarizeResult(toolName: tool, json: json)
    }

    // MARK: - Path-shaped summarizers with no prior test

    func testSummarizeArguments_deleteFile_showsPath_andMissingPathIsQuestionMark() {
        XCTAssertEqual(Self.summarize(TN.deleteFile, #"{"path":"/src/stale.swift"}"#), "/src/stale.swift")
        XCTAssertEqual(Self.summarize(TN.deleteFile, "{}"), "?")
    }

    func testSummarizeArguments_analyzeImage_showsPath_andMissingPathIsQuestionMark() {
        XCTAssertEqual(Self.summarize(TN.analyzeImage, #"{"path":"shots/ui.png"}"#), "shots/ui.png")
        XCTAssertEqual(Self.summarize(TN.analyzeImage, "{}"), "?")
    }

    func testSummarizeArguments_deleteFile_distinctPerPath() {
        // Deleting two different files must not read as one repeated call.
        XCTAssertNotEqual(
            Self.summarize(TN.deleteFile, #"{"path":"a.swift"}"#),
            Self.summarize(TN.deleteFile, #"{"path":"b.swift"}"#))
    }

    // MARK: - Git branch-shaped summarizers

    func testSummarizeArguments_gitCheckout_showsBranch_andMissingIsQuestionMark() {
        XCTAssertEqual(Self.summarize(TN.gitCheckout, #"{"branch":"feature/login"}"#), "feature/login")
        XCTAssertEqual(Self.summarize(TN.gitCheckout, "{}"), "?")
    }

    func testSummarizeArguments_gitBranch_showsName_andMissingIsQuestionMark() {
        XCTAssertEqual(Self.summarize(TN.gitBranch, #"{"name":"release/1.2"}"#), "release/1.2")
        XCTAssertEqual(Self.summarize(TN.gitBranch, "{}"), "?")
    }

    func testSummarizeArguments_gitCheckout_distinctPerBranch() {
        XCTAssertNotEqual(
            Self.summarize(TN.gitCheckout, #"{"branch":"main"}"#),
            Self.summarize(TN.gitCheckout, #"{"branch":"develop"}"#))
    }

    // MARK: - Xcode scheme extractor (both consumers, incl. the empty arm)

    func testSummarizeArguments_runXcodetests_showsScheme() {
        XCTAssertEqual(Self.summarize(TN.runXcodetests, #"{"scheme":"NanoTeams"}"#), "scheme: NanoTeams")
    }

    func testSummarizeArguments_schemeExtractor_missingScheme_returnsEmptyForBothTools() {
        // The shared `schemeExtractor` closure's else-arm. Both Xcode tools use it, so a
        // regression in one is a regression in both.
        XCTAssertEqual(Self.summarize(TN.runXcodetests, "{}"), "")
        XCTAssertEqual(Self.summarize(TN.runXcodebuild, "{}"), "")
    }

    // MARK: - update_scratchpad (content resolution + truncation)

    func testSummarizeArguments_updateScratchpad_showsContent() {
        XCTAssertEqual(Self.summarize(TN.updateScratchpad, #"{"content":"Plan: add the query"}"#),
                       "Plan: add the query")
    }

    func testSummarizeArguments_updateScratchpad_resolvesAliasKey() {
        // Goes through `resolveContentString`, the same resolver the handler uses, so an
        // aliased emission (`plan`) still renders the note instead of an empty card.
        XCTAssertEqual(Self.summarize(TN.updateScratchpad, #"{"plan":"step one"}"#), "step one")
    }

    func testSummarizeArguments_updateScratchpad_truncatesAt40() {
        let long = String(repeating: "s", count: 45)
        let out = Self.summarize(TN.updateScratchpad, #"{"content":"\#(long)"}"#)
        XCTAssertEqual(out, String(repeating: "s", count: 40) + "...")
        XCTAssertEqual(out.count, 43)
    }

    func testSummarizeArguments_updateScratchpad_exactlyAtBoundary_isNotTruncated() {
        // `> 40` — a 40-char note is rendered verbatim.
        let exact = String(repeating: "s", count: 40)
        XCTAssertEqual(Self.summarize(TN.updateScratchpad, #"{"content":"\#(exact)"}"#), exact)
    }

    func testSummarizeArguments_updateScratchpad_noResolvableContent_returnsEmpty() {
        // Two candidate strings and no known content key → `resolveContentString` refuses to
        // guess. Empty is the honest answer, not "?" (which marks a malformed call).
        XCTAssertEqual(Self.summarize(TN.updateScratchpad, #"{"alpha":"a","beta":"b"}"#), "")
    }

    // MARK: - create_team

    func testSummarizeArguments_createTeam_showsTeamName() {
        let json = #"{"team_config":{"name":"Calc Team","roles":[]}}"#
        XCTAssertEqual(Self.summarize(TN.createTeam, json), "Calc Team")
    }

    func testSummarizeArguments_createTeam_configWithoutName_returnsEmpty() {
        XCTAssertEqual(Self.summarize(TN.createTeam, #"{"team_config":{"description":"x"}}"#), "")
    }

    func testSummarizeArguments_createTeam_noConfig_returnsEmpty() {
        XCTAssertEqual(Self.summarize(TN.createTeam, "{}"), "")
    }

    // MARK: - delegate_to_team

    func testSummarizeArguments_delegateToTeam_generatedSentinel_labelsGenerated() {
        let json = #"{"team_id":"\#(DelegationConstants.generatedTeamSentinel)","task_brief":"Build a calculator"}"#
        XCTAssertEqual(Self.summarize(TN.delegateToTeam, json), "Generated · Build a calculator")
    }

    func testSummarizeArguments_delegateToTeam_realID_showsTrailingEightChars() {
        let json = #"{"team_id":"0123456789abcdef","task_brief":"Ship it"}"#
        XCTAssertEqual(Self.summarize(TN.delegateToTeam, json), "89abcdef · Ship it")
    }

    func testSummarizeArguments_delegateToTeam_shortID_isNotPadded() {
        // `suffix(8)` on a shorter id yields the whole id, not a crash or padding.
        XCTAssertEqual(Self.summarize(TN.delegateToTeam, #"{"team_id":"abc","task_brief":"x"}"#),
                       "abc · x")
    }

    func testSummarizeArguments_delegateToTeam_missingTeamID_isQuestionMark() {
        // The handler defaults a missing/empty `team_id` to the generated sentinel, but the
        // SUMMARY must reflect what the model actually sent — otherwise two different
        // emissions (explicit "generated" vs omitted) would share one identity.
        XCTAssertEqual(Self.summarize(TN.delegateToTeam, #"{"task_brief":"x"}"#), "? · x")
        XCTAssertEqual(Self.summarize(TN.delegateToTeam, #"{"team_id":"","task_brief":"x"}"#), "? · x")
    }

    func testSummarizeArguments_delegateToTeam_noBrief_showsTeamLabelAlone() {
        XCTAssertEqual(Self.summarize(TN.delegateToTeam, #"{"team_id":"0123456789abcdef"}"#), "89abcdef")
        XCTAssertEqual(Self.summarize(TN.delegateToTeam, "{}"), "?")
    }

    func testSummarizeArguments_delegateToTeam_truncatesLongBriefAt60() {
        let long = String(repeating: "b", count: 70)
        let out = Self.summarize(TN.delegateToTeam, #"{"team_id":"generated","task_brief":"\#(long)"}"#)
        XCTAssertEqual(out, "Generated · " + String(repeating: "b", count: 60) + "…")
    }

    func testSummarizeArguments_delegateToTeam_sameTeamDifferentBriefs_areDistinct() {
        // Delegating twice to the same team with different briefs is legitimate fan-out, not a
        // loop — the briefs must reach the identity key.
        let a = Self.summarize(TN.delegateToTeam, #"{"team_id":"generated","task_brief":"write the parser"}"#)
        let b = Self.summarize(TN.delegateToTeam, #"{"team_id":"generated","task_brief":"write the tests"}"#)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - screen_capture (target / window_title arms)

    func testSummarizeArguments_screenCapture_targetWithoutTitle() {
        XCTAssertEqual(Self.summarize(TN.screenCapture, #"{"target":"Safari"}"#), "Safari")
    }

    func testSummarizeArguments_screenCapture_emptyTargetFallsBackToScreen() {
        // `flatMap { $0.isEmpty ? nil : $0 }` — an empty string is not a target.
        XCTAssertEqual(Self.summarize(TN.screenCapture, #"{"target":""}"#), "screen")
    }

    func testSummarizeArguments_screenCapture_emptyTitleIsIgnored() {
        XCTAssertEqual(Self.summarize(TN.screenCapture, #"{"target":"Safari","window_title":""}"#), "Safari")
    }

    func testSummarizeArguments_screenCapture_titleWithoutTarget() {
        XCTAssertEqual(Self.summarize(TN.screenCapture, #"{"window_title":"Docs"}"#), "screen · Docs")
    }

    func testSummarizeArguments_screenCapture_differentWindows_areDistinct() {
        // Two captures of the same app but different windows are two different observations.
        XCTAssertNotEqual(
            Self.summarize(TN.screenCapture, #"{"target":"Safari","window_title":"Feed"}"#),
            Self.summarize(TN.screenCapture, #"{"target":"Safari","window_title":"Inbox"}"#))
    }

    // MARK: - ui_type / ui_click / ui_scroll remaining arms

    func testSummarizeArguments_uiType_resolvesAliasKeyThroughContentResolver() {
        // `(dict["text"] as? String) ?? resolveContentString(dict)` — a model that spells the
        // typed string `body` must still produce a distinguishing summary.
        XCTAssertEqual(Self.summarize(TN.uiType, #"{"body":"hello world"}"#), "hello world")
        XCTAssertEqual(Self.summarize(TN.uiType, #"{"content":"hi"}"#), "hi")
    }

    func testSummarizeArguments_uiType_exactlyAtBoundary_isNotTruncated() {
        let exact = String(repeating: "t", count: 60)
        XCTAssertEqual(Self.summarize(TN.uiType, #"{"text":"\#(exact)"}"#), exact)
    }

    func testSummarizeArguments_uiClick_buttonMatchIsCaseInsensitive() {
        XCTAssertEqual(Self.summarize(TN.uiClick, #"{"x":1,"y":2,"button":"RIGHT"}"#), "(1, 2) right")
        // A left click carries no marker — the default needs no annotation.
        XCTAssertEqual(Self.summarize(TN.uiClick, #"{"x":1,"y":2,"button":"left"}"#), "(1, 2)")
    }

    func testSummarizeArguments_uiClick_emptyTargetIsOmitted() {
        XCTAssertEqual(Self.summarize(TN.uiClick, #"{"x":1,"y":2,"target":""}"#), "(1, 2)")
    }

    func testSummarizeArguments_uiScroll_stringEncodedDeltas_areCoerced() {
        // Same coercion the handler applies; a quoted delta must not collapse to 0.
        XCTAssertEqual(Self.summarize(TN.uiScroll, #"{"x":"5","y":"6","dx":"-3","dy":"7"}"#),
                       "(5, 6) d(-3, 7)")
    }

    func testSummarizeArguments_uiScroll_samePointDifferentDeltas_areDistinct() {
        // Scrolling a list is repeated same-point calls with a delta each time — the paging
        // analogue of `read_lines`. Collapsing them flags the prescribed workflow as a loop.
        let a = Self.summarize(TN.uiScroll, #"{"x":100,"y":200,"dy":-120}"#)
        let b = Self.summarize(TN.uiScroll, #"{"x":100,"y":200,"dy":-240}"#)
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.contains("?"))
    }

    func testSummarizeArguments_uiScroll_missingBothCoordinates_isQuestionMark() {
        XCTAssertEqual(Self.summarize(TN.uiScroll, "{}"), "?")
    }

    // MARK: - list_files depth paging

    func testSummarizeArguments_listFiles_depthTiers_areDistinct() {
        // `depth` is 0-indexed recursion depth: 0 / 1 / 2 are three different listings and must
        // be three different identities.
        let d0 = Self.summarize(TN.listFiles, #"{"path":"/src","depth":0}"#)
        let d1 = Self.summarize(TN.listFiles, #"{"path":"/src","depth":1}"#)
        let d2 = Self.summarize(TN.listFiles, #"{"path":"/src","depth":2}"#)
        XCTAssertEqual(d0, "/src depth:0")
        XCTAssertEqual(Set([d0, d1, d2]).count, 3, "each depth tier is its own listing")
    }

    func testSummarizeArguments_listFiles_differentPaths_areDistinct() {
        XCTAssertNotEqual(
            Self.summarize(TN.listFiles, #"{"path":"Sources"}"#),
            Self.summarize(TN.listFiles, #"{"path":"Tests"}"#))
    }

    // MARK: - Collection-shaped summarizers: empty / absent arms

    func testSummarizeArguments_search_emptyPathsArray_showsQueryOnly() {
        // An explicitly empty list narrows nothing, so it must render like an absent one.
        XCTAssertEqual(Self.summarize(TN.search, #"{"query":"TODO","paths":[]}"#), "\"TODO\"")
    }

    func testSummarizeArguments_search_missingQuery_isQuestionMark() {
        XCTAssertEqual(Self.summarize(TN.search, #"{"paths":["a"]}"#), "\"?\" in 1 paths")
    }

    func testSummarizeArguments_search_differentQueries_areDistinct() {
        XCTAssertNotEqual(
            Self.summarize(TN.search, #"{"query":"TODO"}"#),
            Self.summarize(TN.search, #"{"query":"FIXME"}"#))
    }

    func testSummarizeArguments_gitAdd_emptyOrMissingPaths_fallsBackToFiles() {
        XCTAssertEqual(Self.summarize(TN.gitAdd, #"{"paths":[]}"#), "files")
        XCTAssertEqual(Self.summarize(TN.gitAdd, "{}"), "files")
    }

    func testSummarizeArguments_gitCommit_emptyOrMissingMessage_returnsEmpty() {
        XCTAssertEqual(Self.summarize(TN.gitCommit, #"{"message":""}"#), "")
        XCTAssertEqual(Self.summarize(TN.gitCommit, "{}"), "")
    }

    func testSummarizeArguments_gitCommit_exactlyAtBoundary_isNotTruncated() {
        let exact = String(repeating: "m", count: 30)
        XCTAssertEqual(Self.summarize(TN.gitCommit, #"{"message":"\#(exact)"}"#), exact)
    }

    // MARK: - Role-bearing summarizers: absent key / resolver interaction

    func testSummarizeArguments_askTeammate_missingKey_returnsEmpty() {
        XCTAssertEqual(Self.summarize(TN.askTeammate, #"{"question":"how?"}"#), "")
    }

    func testSummarizeArguments_requestChanges_missingKey_returnsEmpty() {
        XCTAssertEqual(Self.summarize(TN.requestChanges, #"{"changes":"fix"}"#), "")
    }

    func testSummarizeArguments_roleResolver_isNotConsultedWhenTheKeyIsAbsent() {
        // The resolver arm is gated on the id actually being present; otherwise the resolver
        // would be handed a value it never received.
        var resolverCalls = 0
        let out = ToolCallSummarizer.summarizeArguments(
            toolName: TN.askTeammate, json: #"{"question":"how?"}"#,
            resolveRoleName: { _ in
                resolverCalls += 1
                return "SHOULD NOT APPEAR"
            })
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(out, "")
    }

    func testSummarizeArguments_roleResolver_receivesTheRawID() {
        var seen: String?
        _ = ToolCallSummarizer.summarizeArguments(
            toolName: TN.requestChanges, json: #"{"target_role":"faang_team_swe"}"#,
            resolveRoleName: { id in
                seen = id
                return "Backend Engineer"
            })
        XCTAssertEqual(seen, "faang_team_swe")
    }

    // MARK: - bash identity

    func testSummarizeArguments_bash_differentCommands_areDistinct() {
        // Whitespace collapsing must normalise layout, never merge two different commands.
        let a = Self.summarize(TN.bash, #"{"command":"swift  build"}"#)
        let b = Self.summarize(TN.bash, #"{"command":"swift test"}"#)
        XCTAssertEqual(a, "swift build")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Degenerate JSON inputs

    func testSummarizeArguments_nonObjectJSON_isQuestionMark() {
        // `ToolCallDataUtils.parseJSON` only accepts an object; an array or a bare scalar is
        // not a tool-argument payload.
        XCTAssertEqual(Self.summarize(TN.readFile, "[1,2,3]"), "?")
        XCTAssertEqual(Self.summarize(TN.readFile, ""), "?")
    }

    func testSummarizeResult_nonObjectJSON_isParseError() {
        XCTAssertEqual(Self.result(TN.readFile, "[1,2,3]"), "parse error")
        XCTAssertEqual(Self.result(TN.readFile, ""), "parse error")
    }

    // MARK: - summarizeResult: untested tool arms

    func testSummarizeResult_gitBranchList_isOK() {
        XCTAssertEqual(Self.result(TN.gitBranchList, #"{"ok":true,"data":{"branches":["main"]}}"#), "ok")
    }

    func testSummarizeResult_gitMerge_isMerged() {
        XCTAssertEqual(Self.result(TN.gitMerge, #"{"ok":true,"data":{}}"#), "merged")
    }

    func testSummarizeResult_gitStatus_noDataObject_fallsBackToOK() {
        XCTAssertEqual(Self.result(TN.gitStatus, #"{"ok":true}"#), "ok")
    }

    func testSummarizeResult_gitStatus_dataWithoutBranchOrCleanFlag() {
        // Defaults: unknown branch, not clean.
        XCTAssertEqual(Self.result(TN.gitStatus, #"{"data":{}}"#), "dirty on ?")
    }

    func testSummarizeResult_runXcodebuild_noDataObject_fallsBackToOK() {
        XCTAssertEqual(Self.result(TN.runXcodebuild, #"{"ok":true}"#), "ok")
    }

    func testSummarizeResult_runXcodebuild_dataWithoutFlags_reportsFailureWithZeroErrors() {
        XCTAssertEqual(Self.result(TN.runXcodebuild, #"{"data":{}}"#), "failed (0 errors)")
    }

    func testSummarizeResult_readFile_missingLineCounts_fallsBackToOK() {
        XCTAssertEqual(Self.result(TN.readFile, #"{"ok":true}"#), "ok")
        XCTAssertEqual(Self.result(TN.readFile, #"{"data":{"end_line":5}}"#), "ok")
        XCTAssertEqual(Self.result(TN.readFile, #"{"data":{"total_lines":5}}"#), "ok")
    }

    // MARK: - summarizeResult: error branch precedence and shape guards

    func testSummarizeResult_errorEnvelope_winsOverToolSpecificSummarizer() {
        // The error check runs BEFORE the per-tool dictionary, so a failed build reports the
        // reason rather than the summarizer's canned verdict.
        XCTAssertEqual(
            Self.result(TN.gitMerge, #"{"ok":false,"error":{"code":"COMMAND_FAILED","message":"conflict in a.swift"}}"#),
            "error: conflict in a.swift")
        XCTAssertEqual(
            Self.result(TN.runXcodebuild, #"{"ok":false,"error":{"message":"scheme not found"},"data":{"success":true}}"#),
            "error: scheme not found")
    }

    func testSummarizeResult_errorMessage_truncatedAt50() {
        let long = String(repeating: "e", count: 80)
        let out = Self.result(TN.readFile, #"{"error":{"message":"\#(long)"}}"#)
        XCTAssertEqual(out, "error: " + String(repeating: "e", count: 50))
        XCTAssertEqual(out.count, 57)
    }

    func testSummarizeResult_errorNotAnObject_fallsThrough() {
        // `dict["error"] as? [String: Any]` fails → the normal path runs. Guards against a
        // crash or a bogus "error: " prefix for a scalar `error` field.
        XCTAssertEqual(Self.result(TN.gitMerge, #"{"ok":true,"error":"a bare string"}"#), "merged")
    }

    func testSummarizeResult_errorObjectWithoutMessage_fallsThrough() {
        XCTAssertEqual(Self.result("unknown_tool", #"{"ok":false,"error":{"code":"X"}}"#), "failed")
    }

    // MARK: - extractJSONBracedValue: synthetic-closer salvage across the whole depth range
    //
    // The salvage exists because some models emit `<|call|>{…{…}<|end|>` — one or more outer
    // closers dropped. `maxSalvageDepth` bounds how much imbalance is plausibly a dropped
    // closer rather than genuinely garbled bytes. Existing suites cover depth 1 end-to-end;
    // these pin the ladder and, critically, the refusal ONE STEP past the cap with a valid
    // salvage anchor present — so the test fails if the cap silently widens.

    func testSalvage_depthOne_padsOneCloser() {
        let s: Substring = #"{"a":{"b":1}"#
        let out = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertEqual(out?.0, #"{"a":{"b":1}}"#)
        XCTAssertNotNil(out.flatMap { JSONUtilities.parseJSONDictionary($0.0) },
                        "a depth-1 salvage must produce parseable JSON")
    }

    func testSalvage_depthTwo_padsTwoClosers() {
        let s: Substring = #"{"a":{"b":{"c":1}"#
        let out = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertEqual(out?.0, #"{"a":{"b":{"c":1}}}"#)
        XCTAssertNotNil(out.flatMap { JSONUtilities.parseJSONDictionary($0.0) })
    }

    func testSalvage_depthThree_isTheLastAcceptedTier() {
        XCTAssertEqual(ToolCallParsingHelpers.maxSalvageDepth, 3,
                       "the ladder below is written against this bound")
        let s: Substring = #"{"a":{"b":{"c":{"d":1}"#
        let out = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertEqual(out?.0, #"{"a":{"b":{"c":{"d":1}}}}"#)
        XCTAssertNotNil(out.flatMap { JSONUtilities.parseJSONDictionary($0.0) })
    }

    func testSalvage_depthFour_isRefusedEvenWithAValidAnchor() {
        // One level past the cap, with `lastCloseEnd` non-nil — so the ONLY thing refusing is
        // the depth bound. (The existing garbage-input guard fails both conditions at once and
        // therefore cannot detect a widened cap.)
        let s: Substring = #"{"a":{"b":{"c":{"d":{"e":1}"#
        XCTAssertNil(ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex),
                     "imbalance beyond maxSalvageDepth is garbled input, not a dropped closer")
    }

    func testSalvage_cursorStopsAfterTheLastObservedClose() {
        // The salvage truncates at the last close: everything after it (here `<|end|>`) is junk
        // the caller still has to skip, so it must remain in front of the returned cursor.
        let s: Substring = #"{"a":{"b":1}<|end|>"#
        let out = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertEqual(out?.0, #"{"a":{"b":1}}"#)
        XCTAssertEqual(out.map { String(s[$0.1...]) }, "<|end|>")
    }

    func testSalvage_anchorMayBeAnArrayClose() {
        // `lastCloseEnd` tracks `]` as well as `}` — a dropped outer object brace after an
        // array value still salvages.
        let s: Substring = #"{"paths":["a","b"]"#
        let out = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertEqual(out?.0, #"{"paths":["a","b"]}"#)
        XCTAssertNotNil(out.flatMap { JSONUtilities.parseJSONDictionary($0.0) })
    }

    func testSalvage_unbalancedArrayContainer_padsBracesAndThereforeFailsClosed() {
        // The pad is `}`-only. A top-level ARRAY with a dropped `]` therefore yields text that
        // does NOT parse — which is the safe direction: every caller re-validates, so the call
        // is dropped rather than dispatched from a mis-repaired span. Tool-call envelopes are
        // objects, so this shape is not a production path; pinned so the fail-closed property
        // is deliberate rather than accidental.
        let s: Substring = #"[{"a":1}"#
        let out = ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex)
        XCTAssertEqual(out?.0, #"[{"a":1}}"#)
        let data = (out?.0 ?? "").data(using: .utf8)!
        XCTAssertNil(try? JSONSerialization.jsonObject(with: data, options: []),
                     "a bracket-mismatched salvage must not masquerade as valid JSON")
    }

    func testSalvage_refusedWhenNoCloserWasEverObserved() {
        // `lastCloseEnd == nil`: there is no anchor to truncate at, so there is nothing to
        // salvage even at depth 1.
        let s: Substring = #"{"a":{"b":1"#
        XCTAssertNil(ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex))
    }

    func testSalvage_refusedWhenTheWalkerIsMidStringAtEOF() {
        // `!inString`: with an unterminated string we cannot know where it should close, so a
        // synthetic `}` would be pure invention. Isolated here from the depth/anchor guards —
        // both of those WOULD pass for this input (depth 1, a prior `}` observed).
        let s: Substring = #"{"a":{"b":1},"c":"oops"#
        XCTAssertNil(ToolCallParsingHelpers.extractJSONBracedValue(in: s, from: s.startIndex))
    }

    // MARK: - extractIdentifierOrQuoted

    func testExtractIdentifierOrQuoted_doubleQuoted_returnsNameAndCursorPastTheQuote() {
        let s: Substring = "\"read_file\" rest"
        let out = ToolCallParsingHelpers.extractIdentifierOrQuoted(in: s, from: s.startIndex)
        XCTAssertEqual(out?.0, "read_file")
        XCTAssertEqual(out.map { String(s[$0.1...]) }, " rest")
    }

    func testExtractIdentifierOrQuoted_singleQuoted() {
        let s: Substring = "'git_status'<|message|>"
        let out = ToolCallParsingHelpers.extractIdentifierOrQuoted(in: s, from: s.startIndex)
        XCTAssertEqual(out?.0, "git_status")
        XCTAssertEqual(out.map { String(s[$0.1...]) }, "<|message|>")
    }

    func testExtractIdentifierOrQuoted_dotsDashesDigits_areAccepted() {
        let s: Substring = "\"repo_browser.read-file2\" x"
        XCTAssertEqual(
            ToolCallParsingHelpers.extractIdentifierOrQuoted(in: s, from: s.startIndex)?.0,
            "repo_browser.read-file2")
    }

    func testExtractIdentifierOrQuoted_emptyQuotes_returnNil() {
        let s: Substring = "\"\" rest"
        XCTAssertNil(ToolCallParsingHelpers.extractIdentifierOrQuoted(in: s, from: s.startIndex))
    }

    func testExtractIdentifierOrQuoted_quotedTextWithASpace_isNotAnIdentifier() {
        // A quoted phrase is prose, not a tool name — accepting it would mint a call named
        // "read the file".
        let s: Substring = "\"read the file\" rest"
        XCTAssertNil(ToolCallParsingHelpers.extractIdentifierOrQuoted(in: s, from: s.startIndex))
    }

    func testExtractIdentifierOrQuoted_unterminatedQuote_returnsNil() {
        let s: Substring = "\"read_file"
        XCTAssertNil(ToolCallParsingHelpers.extractIdentifierOrQuoted(in: s, from: s.startIndex))
    }

    func testExtractIdentifierOrQuoted_unquoted_delegatesToPlainIdentifier() {
        let s: Substring = "read_file <|message|>"
        XCTAssertEqual(
            ToolCallParsingHelpers.extractIdentifierOrQuoted(in: s, from: s.startIndex)?.0,
            "read_file")
    }

    func testExtractIdentifierOrQuoted_atEndIndex_returnsNil() {
        let s: Substring = ""
        XCTAssertNil(ToolCallParsingHelpers.extractIdentifierOrQuoted(in: s, from: s.startIndex))
    }

    // MARK: - postCallJSON (the walk `classifyHarmonyCallIssue` and the diagnostic share)

    private static func describe(_ outcome: ToolCallParsingHelpers.PostCallJSON) -> String {
        switch outcome {
        case .noCallMarker: return "noCallMarker"
        case .noObject: return "noObject"
        case .unbalanced: return "unbalanced"
        case .extracted(let json): return "extracted:\(json)"
        }
    }

    func testPostCallJSON_noCallMarker() {
        XCTAssertEqual(
            Self.describe(ToolCallParsingHelpers.postCallJSON(in: "<|channel|>commentary prose only")),
            "noCallMarker")
    }

    func testPostCallJSON_markerWithNonObjectPayload_isNoObject() {
        XCTAssertEqual(
            Self.describe(ToolCallParsingHelpers.postCallJSON(in: "<|call|>ping<|end|>")),
            "noObject")
    }

    func testPostCallJSON_markerAtEndOfBuffer_isNoObject() {
        // A truncated stream that stops right after the marker: nothing follows, so there is
        // no object — and no crash from indexing past the end.
        XCTAssertEqual(
            Self.describe(ToolCallParsingHelpers.postCallJSON(in: "<|call|>")),
            "noObject")
        XCTAssertEqual(
            Self.describe(ToolCallParsingHelpers.postCallJSON(in: "<|call|>   ")),
            "noObject")
    }

    func testPostCallJSON_unbalancedBeyondSalvage_isUnbalanced() {
        XCTAssertEqual(
            Self.describe(ToolCallParsingHelpers.postCallJSON(in: #"<|call|>{"name":"x","arguments":{"p":"a"#)),
            "unbalanced")
    }

    func testPostCallJSON_extractsTheObjectAndSkipsLeadingWhitespace() {
        XCTAssertEqual(
            Self.describe(ToolCallParsingHelpers.postCallJSON(in: "<|call|>  {\"a\":1}<|end|>")),
            "extracted:{\"a\":1}")
    }

    func testPostCallJSON_salvageableImbalance_isExtractedNotUnbalanced() {
        // The shared walk inherits the salvage, so a dropped outer brace is a payload the
        // diagnostic can name concretely rather than "braces never balance".
        XCTAssertEqual(
            Self.describe(ToolCallParsingHelpers.postCallJSON(in: #"<|call|>{"a":{"b":1}<|end|>"#)),
            "extracted:{\"a\":{\"b\":1}}")
    }

    // MARK: - StartMarkerStrategy.remainderBeginsWithRoleMarker

    func testRemainderBeginsWithRoleMarker_inlinedRoleTurn_withNoSeparator() {
        // The documented shape: models inline the next turn with no delimiter.
        XCTAssertTrue(StartMarkerStrategy.remainderBeginsWithRoleMarker("userI've examined the code"))
        XCTAssertTrue(StartMarkerStrategy.remainderBeginsWithRoleMarker("ASSISTANT: hello"))
    }

    func testRemainderBeginsWithRoleMarker_channelStyleOpening_isNotARole() {
        XCTAssertFalse(StartMarkerStrategy.remainderBeginsWithRoleMarker("commentary to=read_file"))
        XCTAssertFalse(StartMarkerStrategy.remainderBeginsWithRoleMarker("functions.read_file"))
        XCTAssertFalse(StartMarkerStrategy.remainderBeginsWithRoleMarker(""))
    }

    func testRemainderBeginsWithRoleMarker_onlyInspectsTheLeadingWindow() {
        // Bounded at 16 characters: a role word further in is content, not an opening.
        let beyondWindow = Substring(String(repeating: "x", count: 16) + "user")
        XCTAssertFalse(StartMarkerStrategy.remainderBeginsWithRoleMarker(beyondWindow))
    }

    func testRemainderBeginsWithRoleMarker_coversEveryRoleIdentifier() {
        for role in ["user", "assistant", "system", "developer", "tool"] {
            XCTAssertTrue(
                StartMarkerStrategy.remainderBeginsWithRoleMarker(Substring(role + " rest")),
                "'\(role)' must be recognised as an inlined role turn")
        }
    }

    // MARK: - ChannelMarkerStrategy.isConstrainFormatKeyword

    func testIsConstrainFormatKeyword_coversEveryFormatWord() {
        for keyword in ["json", "text", "markdown", "xml", "html", "yaml"] {
            XCTAssertTrue(ChannelMarkerStrategy.isConstrainFormatKeyword(keyword),
                          "'\(keyword)' after <|constrain|> is a format hint, never a tool name")
        }
        XCTAssertFalse(ChannelMarkerStrategy.isConstrainFormatKeyword("read_file"))
        XCTAssertFalse(ChannelMarkerStrategy.isConstrainFormatKeyword(""))
    }

    // MARK: - CallMarkerStrategy: loop-termination guards

    func testCallMarker_bufferEndsAtTheMarker_yieldsNothingAndTerminates() {
        // `idx >= tail.endIndex` break. A stream cut mid-envelope must not spin.
        XCTAssertTrue(CallMarkerStrategy().parse(from: "<|call|>").isEmpty)
        XCTAssertTrue(CallMarkerStrategy().parse(from: "prose then <|call|>   ").isEmpty)
    }

    func testCallMarker_namedFormWithoutArguments_isDroppedAndTerminates() {
        // Identifier resolves but no `{` follows — fall through, advance past `<|end|>`, stop.
        XCTAssertTrue(CallMarkerStrategy().parse(from: "<|call|>read_file no json here<|end|>").isEmpty)
    }

    func testCallMarker_droppedBlockDoesNotSwallowTheFollowingCall() {
        let input = "<|call|>read_file no json here<|end|>"
            + #"<|call|>{"name":"git_status","arguments":{}}<|end|>"#
        let calls = CallMarkerStrategy().parse(from: input)
        XCTAssertEqual(calls.map(\.name), ["git_status"])
    }

    // MARK: - ChannelMarkerStrategy: block boundaries and continuation

    func testChannelMarker_unresolvableBlockDoesNotStopLaterBlocks() {
        // First block has no recipient at all → nil; the loop must still advance and resolve
        // the second block instead of returning early.
        let input = "<|channel|>commentary<|message|>just prose"
            + #"<|channel|>commentary to=git_status<|message|>{}"#
        let calls = ChannelMarkerStrategy().parse(from: input)
        XCTAssertEqual(calls.map(\.name), ["git_status"])
    }

    func testChannelMarker_argumentsOfALaterBlockCannotSatisfyAnEarlierOne() {
        // The plain-`{` fallback is bounded by `blockEnd`, so a `{` belonging to the NEXT
        // channel block must never be adopted as this block's arguments.
        let input = "<|channel|>commentary to=read_file no message marker here "
            + #"<|channel|>final<|message|>{"x":1}"#
        XCTAssertTrue(ChannelMarkerStrategy().parse(from: input).isEmpty,
                      "a later block's body must not supply an earlier block's arguments")
    }

    // MARK: - Composite parser: cross-strategy merge and dedup

    func testExtractAllToolCalls_mergesCallsFoundByDifferentStrategies() {
        // Exercises the non-empty `results` branch: strategy 1 already produced a call, so
        // strategy 3's call goes through the append-with-dedup path rather than replacing it.
        let input = #"<|call|>{"name":"read_file","arguments":{"path":"a.txt"}}<|end|>"#
            + #"<|channel|>commentary to=git_status<|message|>{}"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertEqual(calls.map(\.name), ["read_file", "git_status"])
    }

    func testExtractAllToolCalls_dedupsTheSameCallSeenByTwoStrategies() {
        // Same tool, byte-identical normalised arguments, reachable through both the
        // `<|call|>` and the `<|channel|>` framing — the model asked for ONE read.
        let input = #"<|call|>{"name":"read_file","arguments":{"path":"a.txt"}}<|end|>"#
            + #"<|channel|>commentary to=read_file<|message|>{"path":"a.txt"}"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertEqual(calls.count, 1, "duplicate framings of one call must not double-dispatch")
        XCTAssertEqual(calls.first?.name, "read_file")
    }

    func testExtractAllToolCalls_sameToolDifferentArguments_areBothKept() {
        // The dedup key is name + arguments: two reads of DIFFERENT files are two calls.
        let input = #"<|call|>{"name":"read_file","arguments":{"path":"a.txt"}}<|end|>"#
            + #"<|channel|>commentary to=read_file<|message|>{"path":"b.txt"}"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Set(calls.map(\.argumentsJSON)).count, 2)
    }

    func testExtractAllToolCalls_emptyAndMarkerlessInput_yieldNothing() {
        XCTAssertTrue(HarmonyToolCallParser().extractAllToolCalls(from: "").isEmpty)
        XCTAssertTrue(HarmonyToolCallParser().extractAllToolCalls(
            from: "I will now read the file and report back.").isEmpty)
    }
}
