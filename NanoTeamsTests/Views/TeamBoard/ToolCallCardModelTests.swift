import XCTest

@testable import NanoTeams

/// `ToolCallCardModel` — every field a tool-call card renders, derived ONCE from the call.
///
/// The parse-once property is pinned as wiring in `Ratchet/BodyPassHoistPinTests` (a test
/// that calls `make` cannot count how many times a body calls it — CLAUDE.md #57). What
/// this file pins is that folding four computed properties into one derivation did not
/// change any of their ANSWERS.
@MainActor
final class ToolCallCardModelTests: XCTestCase {

    private func call(_ name: String, args: String, result: String? = nil,
                      isError: Bool = false) -> StepToolCall {
        StepToolCall(name: name, argumentsJSON: args, resultJSON: result, isError: isError)
    }

    func testSearch_exploratoryFlagDrivesTheBadge() {
        let on = ToolCallCardModel.make(
            call: call(ToolNames.search, args: #"{"query": "x", "exploratory": true}"#))
        XCTAssertTrue(on.isExploratorySearch)
        let off = ToolCallCardModel.make(
            call: call(ToolNames.search, args: #"{"query": "x"}"#))
        XCTAssertFalse(off.isExploratorySearch)
    }

    func testExploratoryBadge_isSearchOnly_evenWhenTheArgIsPresent() {
        // The `canonicalName == search` guard, pinned on its own: without it any tool
        // whose args happen to carry `exploratory` would grow a binoculars badge.
        let model = ToolCallCardModel.make(
            call: call(ToolNames.readFile, args: #"{"path": "a.swift", "exploratory": true}"#))
        XCTAssertFalse(model.isExploratorySearch)
    }

    func testCanonicalName_stripsTheModelEmittedNamespace() {
        let model = ToolCallCardModel.make(
            call: call("repo_browser.read_file", args: #"{"path": "a.swift"}"#))
        XCTAssertEqual(model.canonicalName, ToolNames.readFile,
                       "the card and tool-name matching always work on the canonical form; "
                           + "`call.name` stays as-emitted for the error envelope")
    }

    func testAskTeammate_carriesTheQuestionAsACustomSummary_andStillShowsArguments() {
        let model = ToolCallCardModel.make(
            call: call(ToolNames.askTeammate,
                       args: #"{"teammate": "tech_lead", "question": "Which module owns retry?"}"#))
        XCTAssertEqual(model.customSummary, .question("Which module owns retry?"))
        XCTAssertFalse(model.argumentSummary.isEmpty,
                       "`ask_teammate` is NOT in `customSummaryTools`, so the argument tail "
                           + "renders beside the question. Note the summarizer keys on "
                           + "`teammate`, not `role` — an argument dict without it summarizes "
                           + "to empty, which is what this fixture originally got wrong")
    }

    func testRequestTeamMeeting_suppressesTheArgumentTail_becauseItsSummaryOwnsTheRow() {
        let model = ToolCallCardModel.make(
            call: call(ToolNames.requestTeamMeeting,
                       args: #"{"topic": "Retry policy", "participants": []}"#))
        XCTAssertEqual(model.customSummary, .meeting(topic: "Retry policy", participantNames: []))
        XCTAssertEqual(model.argumentSummary, "",
                       "a tool in `customSummaryTools` renders its rich summary INSTEAD of "
                           + "the tail; both would double the row")
    }

    func testMalformedJSON_keepsTheContractTheStringFormAlwaysHad() {
        let model = ToolCallCardModel.make(call: call(ToolNames.readFile, args: "broken"))
        XCTAssertEqual(model.argumentSummary, "?",
                       "`summarizeArguments` has always answered `?` for unparseable "
                           + "arguments; routing through the dict primitive must not change it")
        XCTAssertNil(model.customSummary)
        XCTAssertFalse(model.isExploratorySearch)
    }

    /// The forwarder and the primitive must never become a second opinion (CLAUDE.md #91).
    func testDictAndStringCardSummariesAgree() {
        let cases: [(String, String, String?)] = [
            (ToolNames.readFile, #"{"path": "Sources/A.swift"}"#, nil),
            (ToolNames.editFile, #"{"path": "Sources/A.swift"}"#,
             #"{"ok": true, "data": {"path": "Sources/A.swift", "start_line": 12, "end_line": 40, "replacements_made": 3}}"#),
            (ToolNames.editFile, #"{"path": "Sources/A.swift"}"#,
             #"{"ok": true, "data": {"start_line": 7, "end_line": 7}}"#),
            (ToolNames.search, #"{"query": "retry"}"#, nil),
            (ToolNames.readFile, "broken", nil),
        ]
        for (tool, args, result) in cases {
            let viaString = ToolCallSummarizer.cardSummary(
                toolName: tool, argumentsJSON: args, resultJSON: result, isError: false)
            let viaDict = ToolCallSummarizer.cardSummary(
                toolName: tool, arguments: JSONUtilities.parseJSONDictionary(args),
                resultJSON: result, isError: false)
            XCTAssertEqual(viaString, viaDict, "the two entry points disagree for \(tool)")
        }
    }

    /// The `edit_file` branch reads three keys out of ONE envelope parse now. Each key
    /// still has to reach the summary, or "parse once" silently became "read less".
    func testEditFileSummary_stillCarriesPathSpanAndReplacementCount() {
        let summary = ToolCallSummarizer.cardSummary(
            toolName: ToolNames.editFile,
            argumentsJSON: #"{"path": "ignored.swift"}"#,
            resultJSON: #"{"ok": true, "data": {"path": "Real.swift", "start_line": 12, "end_line": 40, "replacements_made": 3}}"#,
            isError: false)
        XCTAssertTrue(summary.contains("Real.swift"), "path came from the ENVELOPE, not args")
        XCTAssertTrue(summary.contains("12-40"), "the line span survived the shared parse")
        XCTAssertTrue(summary.contains("3"), "the replacement count survived the shared parse")
    }
}
