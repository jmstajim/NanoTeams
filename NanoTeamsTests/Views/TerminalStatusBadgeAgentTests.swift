import XCTest
@testable import NanoTeams

/// The agent mark — `TerminalStatusBadge.agent(label:)` — is the one way the feed shows who wrote
/// a Supervisor turn or created a task when it was not the person. Its visible label is capped so
/// a long name cannot push a header's time off the line; the tooltip and the VoiceOver label keep
/// the whole name, which is otherwise lost at the cap.
@MainActor
final class TerminalStatusBadgeAgentTests: XCTestCase {

    func testAgent_trimsTheLabel_andKeepsItWhole() async {
        let mark = TerminalStatusBadge.agent(label: "  Claude Code \n")
        XCTAssertEqual(mark.label, "Claude Code")
        XCTAssertEqual(mark.tooltip, "Claude Code")
        XCTAssertEqual(mark.accessibilityText, "by Claude Code")
    }

    func testAgent_capsTheVisibleLabel_butNotTheTooltip() async {
        let long = "An agent whose label runs far longer than any header has room for"
        let mark = TerminalStatusBadge.agent(label: long)
        XCTAssertEqual(mark.label, String(long.prefix(TerminalStatusBadge.agentLabelCap)) + "…")
        XCTAssertEqual(mark.tooltip, long)
        XCTAssertEqual(mark.accessibilityText, "by \(long)")
    }

    func testAgent_atTheCap_isNotEllipsized() async {
        let exact = String(repeating: "a", count: TerminalStatusBadge.agentLabelCap)
        XCTAssertEqual(TerminalStatusBadge.agent(label: exact).label, exact)
    }

    /// The unsigned automated Supervisor wears the same mark under the word its turns already
    /// carry — passed through untouched, not restyled.
    func testAgent_automatedSupervisorWord_passesThrough() async {
        let mark = TerminalStatusBadge.agent(label: LLMMessage.automatedSupervisorLabel)
        XCTAssertEqual(mark.label, "auto")
        XCTAssertEqual(mark.accessibilityText, "by auto")
    }

    /// Fixed-size everywhere by default: the Autovisor pane's row lets its title truncate first.
    /// Only a header that has already moved the mark to its own line opts in to truncation.
    func testAgent_truncatesOnlyWhenTheCallerOptsIn() async {
        XCTAssertFalse(TerminalStatusBadge.agent(label: "Claude Code").truncatesWhenNarrow)
        XCTAssertTrue(
            TerminalStatusBadge.agent(label: "Claude Code", truncatesWhenNarrow: true).truncatesWhenNarrow)
    }

    /// A status badge and a plain tag name nobody, so they carry no author text.
    func testStatusAndTag_carryNoAuthorText() async {
        let status = TerminalStatusBadge(glyph: TerminalGlyph.done, label: "done", color: Colors.success)
        XCTAssertNil(status.tooltip)
        XCTAssertNil(status.accessibilityText)
        XCTAssertFalse(status.truncatesWhenNarrow)
        let tag = TerminalStatusBadge.tag(label: "recommended")
        XCTAssertNil(tag.tooltip)
        XCTAssertNil(tag.accessibilityText)
        XCTAssertFalse(tag.truncatesWhenNarrow)
    }

    // MARK: - Wiring (source scan)

    /// Both Supervisor headers — the task card's and a message bubble's — draw the author with
    /// this mark, through one header view. Until 2026-11-08 the bubble printed it in parentheses
    /// (`Supervisor (Claude Code)`) beside a card that wore the chip; a SwiftUI body is asserted
    /// nowhere else, so the drift is pinned at the source.
    func testBothSupervisorHeaders_drawTheAuthorWithTheMark() async throws {
        let header = droppingPreviews(
            try source("NanoTeams/Views/TeamBoard/ActivityFeed/MessageBubbleHeader.swift"))
        XCTAssertTrue(header.contains("TerminalStatusBadge.agent("),
                      "the header must draw its author as the agent mark")
        // The parentheses hold the context word and nothing else: the pre-2026-11-08 header
        // printed `Text("(\\(sourceLabel))")`, the merged string, author included.
        let parenthesised = header.components(separatedBy: "Text(\"(\\(").count - 1
        XCTAssertEqual(parenthesised, 1, "exactly one parenthesised interpolation in the header")
        XCTAssertTrue(header.contains("Text(\"(\\(contextLabel))\")"),
                      "the parenthesised interpolation must be the context word")

        let card = try source("NanoTeams/Views/TeamBoard/ActivityFeed/SupervisorTaskItemView.swift")
        XCTAssertTrue(card.contains("MessageBubbleHeader("),
                      "the task card's header must be the same view as the bubble's")

        // The call site is where the drift would come back: handing the header the JOINED label
        // as its context reads `Supervisor [CLAUDE CODE] (Claude Code)` with every other pin green.
        let bubble = droppingPreviews(
            try source("NanoTeams/Views/TeamBoard/ActivityFeed/MessageBubbleView.swift"))
        XCTAssertTrue(bubble.contains("contextLabel: attribution.context"),
                      "the bubble must hand the header the context half of the attribution")
        XCTAssertTrue(bubble.contains("authorLabel: attribution.author"),
                      "the bubble must hand the header the author half of the attribution")
        XCTAssertFalse(bubble.contains("sourceContextDisplayLabel"),
                       "the joined label is for `conversation_log.md`; the feed reads the halves")
    }

    /// Everything before the first preview macro: previews construct headers with literal
    /// labels, which a scan of the production body must not read. Assembled at runtime so this
    /// file's own prose can't be the marker it searches for.
    private func droppingPreviews(_ text: String) -> String {
        let marker = "#Pre" + "view"
        guard let range = text.range(of: marker) else { return text }
        return String(text[text.startIndex..<range.lowerBound])
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Views
            .deletingLastPathComponent()   // NanoTeamsTests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "\(relativePath) not found — the scan would pass vacuously")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
