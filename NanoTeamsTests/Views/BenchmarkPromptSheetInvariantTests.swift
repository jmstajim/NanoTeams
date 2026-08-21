import XCTest

@testable import NanoTeams

/// Structural pins on `BenchmarkPromptSheet`. Its load-bearing decisions live inside a `some View`
/// body and on `NSPasteboard`, where no behavioural assertion can reach them — the same idiom
/// `TeamActivityFeedContainerInvariantTests` and `PromptTemplateEditorLagInvariantTests` use.
final class BenchmarkPromptSheetInvariantTests: XCTestCase {

    /// RED: point either the `Text` or the pasteboard write at `BenchmarkPrompt.text` → the
    /// `Request …` line disappears, the varying field stops being shown at all, and the user
    /// copies a string no sample has ever sent.
    func testSheet_showsAndCopiesTheMarkerBearingPrompt_notTheBareText() throws {
        let source = try sheetCode()
        XCTAssertTrue(
            source.contains("BenchmarkPrompt.canonicalText"),
            "the sheet no longer references the canonical rendering at all")
        XCTAssertFalse(
            source.contains("BenchmarkPrompt.text"),
            "the sheet reaches past the canonical rendering to the bare workload text")
    }

    /// RED: delete `clearContents()` → the write joins whatever types are already on the
    /// pasteboard, and a paste can deliver something else entirely. An ordered assertion, because
    /// mere presence would pass with the two calls the wrong way round.
    func testSheet_clearsThePasteboardBeforeWriting() throws {
        let code = try sheetCode()
        let clear = try XCTUnwrap(code.range(of: "clearContents()"))
        let write = try XCTUnwrap(code.range(of: "setString"))
        XCTAssertLessThan(clear.lowerBound, write.lowerBound)
    }

    /// The comment stripper must not be able to pass by deleting everything: if it did, the
    /// ordering test above would fail to unwrap rather than silently succeed — but the write's
    /// RESULT check would go unpinned. RED: discard `setString`'s `Bool` and set the copied state
    /// unconditionally → the button reports a success the pasteboard refused.
    func testSheet_readsWhetherTheWriteLanded() throws {
        let code = try sheetCode()
        XCTAssertTrue(code.contains("clearContents()"), "the stripper ate the code")
        XCTAssertTrue(
            code.contains("let wrote = NSPasteboard.general.setString"),
            "the pasteboard's answer is discarded")
    }

    /// A sheet with no visible cancel cannot be dismissed with Escape on macOS (CLAUDE.md #28).
    /// RED: drop the shortcut → Escape stops closing the sheet and the only way out is the mouse.
    func testSheet_escapeDismissesItThroughTheVisibleDoneButton() throws {
        let source = try sheetCode()
        XCTAssertTrue(source.contains("keyboardShortcut(.cancelAction)"), "no Escape binding")
        XCTAssertTrue(source.contains("Button(\"Done\")"), "no visible dismiss button")
    }

    /// The pane must stay pure SwiftUI: an `NSScrollView`-backed representable here would re-open
    /// CLAUDE.md #50 on a view that renders eleven thousand characters.
    /// RED: swap the `ScrollView { Text }` for `EditableMessageTextView` → fails.
    func testSheet_rendersThePayloadWithoutAnAppKitTextView() throws {
        let source = try sheetCode()
        XCTAssertTrue(source.contains("ScrollView {"), "the payload pane is gone")
        XCTAssertTrue(source.contains("textSelection(.enabled)"), "the payload is not selectable")
        XCTAssertFalse(source.contains("EditableMessageTextView"), source.prefix(0).description)
        XCTAssertFalse(source.contains("NSViewRepresentable"), source.prefix(0).description)
    }

    /// Source with every comment line removed.
    ///
    /// Load-bearing, and learned the hard way one commit after this file was written: the doc
    /// comment above `copy()` explains what `setString` returns, so an ordering scan over the raw
    /// file found that word ABOVE `clearContents()` and reported the calls in the wrong order.
    /// Prose describing code is not code (CLAUDE.md #89).
    private func sheetCode() throws -> String {
        try sheetSource()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func sheetSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Views/
            .deletingLastPathComponent()  // NanoTeamsTests/
            .deletingLastPathComponent()  // repo root
        let production = repoRoot
            .appendingPathComponent("NanoTeams/Views/Settings/Benchmark/BenchmarkPromptSheet.swift")
        return try String(contentsOf: production, encoding: .utf8)
    }
}
