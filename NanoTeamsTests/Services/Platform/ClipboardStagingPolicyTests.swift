import XCTest

@testable import NanoTeams

/// Routing for a Context-Capture (⌃⌥⌘K) result.
///
/// This logic sat at 0% coverage because its only production route in is
/// `ClipboardCaptureService.captureSelection`, which simulates a real ⌘C via CGEvent — a test
/// exercising it would clobber the developer's clipboard on every run. Extracting the decision
/// (`ClipboardStagingPolicy`) from the staging side effect makes the rules assertable without
/// touching the pasteboard, which is the same split `MessageComposerFileStaging` already uses.
final class ClipboardStagingPolicyTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    /// `StagedAttachment.init` reads the file off disk, so fixtures must be real files.
    private func makeAttachment(_ name: String) throws -> StagedAttachment {
        let url = tempDir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return try StagedAttachment(url: url, stagedRelativePath: "staged/\(name)")
    }

    private func fileURL(_ name: String) -> URL { tempDir.appendingPathComponent(name) }

    // MARK: - Files take priority over text

    /// Not a preference — a correctness rule. With a Finder selection, macOS puts the file PATHS
    /// on the pasteboard as `.string` as well, so routing to both buckets would attach the files
    /// AND clip a block of raw paths into the prompt.
    func testFilesPresent_textIsIgnoredEntirely() throws {
        let attachment = try makeAttachment("a.txt")

        let outcome = ClipboardStagingPolicy.plan(
            fileURLs: [fileURL("a.txt")],
            text: "/Users/alex/a.txt",
            existing: [],
            stage: { _ in attachment })

        XCTAssertEqual(outcome.staged, [attachment])
        XCTAssertNil(outcome.clip, "the pasteboard's path-string must not become a clip")
    }

    func testNoFiles_textBecomesAClip() {
        let outcome = ClipboardStagingPolicy.plan(
            fileURLs: [], text: "let x = 1", existing: [], stage: { _ in nil })

        XCTAssertEqual(outcome.clip, "let x = 1")
        XCTAssertTrue(outcome.staged.isEmpty)
    }

    /// No orchestrator ⇒ nothing can be staged, so the text branch is the only one left. This is
    /// the `if let store` guard in the caller, expressed as data.
    func testFilesButNoStagingAvailable_fallsBackToTheText() {
        let outcome = ClipboardStagingPolicy.plan(
            fileURLs: [fileURL("a.txt")], text: "fallback", existing: [], stage: nil)

        XCTAssertEqual(outcome.clip, "fallback")
        XCTAssertTrue(outcome.staged.isEmpty)
    }

    // MARK: - The false-failure regression

    /// Re-capturing a selection that is already attached is an ordinary thing to do — hit ⌃⌥⌘K
    /// twice on the same Finder selection. The count used to be derived from how many items were
    /// APPENDED, so a successfully-staged duplicate was indistinguishable from a staging failure
    /// and produced "1 of 1 files could not be attached." That is false, and it burns the single
    /// coalescing `lastErrorMessage` slot on a non-event.
    func testDuplicateFile_isNotReportedAsAFailure() throws {
        let attachment = try makeAttachment("a.txt")

        let outcome = ClipboardStagingPolicy.plan(
            fileURLs: [fileURL("a.txt")],
            text: nil,
            existing: [attachment],
            stage: { _ in attachment })

        XCTAssertTrue(outcome.staged.isEmpty, "already attached — nothing to append")
        XCTAssertNil(outcome.failureMessage, "a duplicate is not a failure")
    }

    /// Dedup within one batch too: the pasteboard can carry the same URL twice.
    func testDuplicateWithinOneBatch_appendsOnceAndDoesNotWarn() throws {
        let attachment = try makeAttachment("a.txt")

        let outcome = ClipboardStagingPolicy.plan(
            fileURLs: [fileURL("a.txt"), fileURL("a.txt")],
            text: nil, existing: [],
            stage: { _ in attachment })

        XCTAssertEqual(outcome.staged, [attachment])
        XCTAssertNil(outcome.failureMessage)
    }

    // MARK: - Genuine failures still surface

    func testStagingFailure_reportsTheCount() throws {
        let ok = try makeAttachment("a.txt")

        let outcome = ClipboardStagingPolicy.plan(
            fileURLs: [fileURL("a.txt"), fileURL("b.txt"), fileURL("c.txt")],
            text: nil, existing: [],
            stage: { $0.lastPathComponent == "a.txt" ? ok : nil })

        XCTAssertEqual(outcome.staged, [ok])
        XCTAssertEqual(outcome.failureMessage, "2 of 3 files could not be attached.")
    }

    /// The denominator is what the user selected, not what was new — "1 of 2" when one failed and
    /// one was a duplicate is the honest report.
    func testMixedDuplicateAndFailure_countsOnlyTheFailure() throws {
        let existing = try makeAttachment("a.txt")

        let outcome = ClipboardStagingPolicy.plan(
            fileURLs: [fileURL("a.txt"), fileURL("b.txt")],
            text: nil, existing: [existing],
            stage: { $0.lastPathComponent == "a.txt" ? existing : nil })

        XCTAssertTrue(outcome.staged.isEmpty)
        XCTAssertEqual(outcome.failureMessage, "1 of 2 files could not be attached.")
    }

    func testAllFilesStage_noFailureMessage() throws {
        let a = try makeAttachment("a.txt")
        let b = try makeAttachment("b.txt")

        let outcome = ClipboardStagingPolicy.plan(
            fileURLs: [fileURL("a.txt"), fileURL("b.txt")],
            text: nil, existing: [],
            stage: { $0.lastPathComponent == "a.txt" ? a : b })

        XCTAssertEqual(outcome.staged, [a, b], "input order is preserved")
        XCTAssertNil(outcome.failureMessage)
    }

    // MARK: - Degenerate captures

    /// ⌘C on an empty selection: nothing on the pasteboard, so nothing must be appended. An
    /// empty clip would render as a blank attachment card the user can't explain.
    func testEmptyCapture_producesNothing() {
        XCTAssertEqual(
            ClipboardStagingPolicy.plan(fileURLs: [], text: nil, existing: [], stage: nil),
            ClipboardStagingPolicy.Outcome())
    }

    func testEmptyStringText_producesNothing() {
        let outcome = ClipboardStagingPolicy.plan(
            fileURLs: [], text: "", existing: [], stage: nil)

        XCTAssertNil(outcome.clip)
    }

    /// Whitespace is NOT empty: a captured indentation block or a blank line inside a code
    /// selection is meaningful context, and the source-header enrichment rides on the raw string.
    func testWhitespaceOnlyText_isStillAClip() {
        let outcome = ClipboardStagingPolicy.plan(
            fileURLs: [], text: "   \n\t", existing: [], stage: nil)

        XCTAssertEqual(outcome.clip, "   \n\t")
    }

    /// The zero-width-space sentinel that carries `// Source: path:start-end` must survive
    /// verbatim — `SourceContext.parse` on the display side matches the raw string, and Foundation
    /// on macOS 26 counts U+200B as whitespace, so any trimming here would silently strip it.
    func testSourceEnrichedClip_isPassedThroughByteForByte() {
        let enriched = "\u{200B}// Source: Sources/A.swift:42-51\nlet x = 1"

        let outcome = ClipboardStagingPolicy.plan(
            fileURLs: [], text: enriched, existing: [], stage: nil)

        XCTAssertEqual(outcome.clip, enriched)
    }
}
