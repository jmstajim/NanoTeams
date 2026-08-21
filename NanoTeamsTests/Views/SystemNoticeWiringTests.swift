import XCTest
@testable import NanoTeams

/// Pins that the collapsed-system-notice feature is actually WIRED, not merely
/// implemented.
///
/// `SystemNoticePresentationTests` proves the classifier is right and
/// `ActivityDetailWindowDedupTests` proves the window value behaves — but
/// neither would notice if `MessageBubbleView` stopped calling them, because a
/// SwiftUI body is not asserted anywhere. Deleting the branch would leave every
/// other suite green while every nudge went back to rendering as full prose.
///
/// Two halves:
///   * a behavioural pin on the one decision that could be extracted as pure
///     logic (the header-label suppression), against the PRODUCTION symbol;
///   * a source scan for the parts that only exist as view composition.
final class SystemNoticeWiringTests: XCTestCase {

    // MARK: - Header label suppression (behavioural)

    func testHeaderSourceLabel_systemNotice_suppressesTheDuplicateLabel() {
        let message = LLMMessage(role: .user, content: "nudge", sourceContext: .retryNudge)
        XCTAssertEqual(message.sourceContextDisplayLabel, "retry",
                       "precondition: the header would otherwise show `(retry)`")
        XCTAssertNil(MessageBubbleView.headerSourceLabel(for: message, isSystemNotice: true),
                     "the row already says `system: retry` — the header must not repeat it")
    }

    func testHeaderSourceLabel_ordinaryTurn_keepsItsLabel() {
        let message = LLMMessage(
            role: .user, content: "answer", sourceRole: .techLead, sourceContext: .consultation)
        XCTAssertEqual(
            MessageBubbleView.headerSourceLabel(for: message, isSystemNotice: false),
            "consultation")
    }

    func testHeaderSourceLabel_noContext_isStillNil() {
        let message = LLMMessage(role: .assistant, content: "plain")
        XCTAssertNil(MessageBubbleView.headerSourceLabel(for: message, isSystemNotice: false))
    }

    /// The suppression is scoped to the FEED. `conversation_log.md` keeps the
    /// label, because there the row's `system:` prefix does not exist.
    func testTranscriptHelper_isUnaffectedBySuppression() {
        let message = LLMMessage(role: .user, content: "nudge", sourceContext: .retryNudge)
        _ = MessageBubbleView.headerSourceLabel(for: message, isSystemNotice: true)
        XCTAssertEqual(message.sourceContextDisplayLabel, "retry",
                       "`sourceContextDisplayLabel` is shared with the transcript renderer and "
                           + "must not be narrowed for a feed concern")
    }

    // MARK: - Source scan

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Views
            .deletingLastPathComponent()   // NanoTeamsTests
            .deletingLastPathComponent()   // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "\(relativePath) not found — the scan would pass vacuously")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Everything before `//`, so prose that legitimately NAMES a retired symbol
    /// is not mistaken for a live reference. Load-bearing: the branch's own
    /// comment explains what `.serverError` used to render as.
    private func strippingLineComments(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line -> String in
                guard let range = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// Preview fixtures legitimately CONSTRUCT messages in every context they
    /// want to show, so a "no per-context branch" scan has to stop at the
    /// preview block or it reports the demonstration as the drift. Assembled at
    /// runtime so this file's own prose can't be the marker it searches for.
    private func droppingPreviews(_ text: String) -> String {
        let marker = "#Pre" + "view"
        guard let range = text.range(of: marker) else { return text }
        return String(text[text.startIndex..<range.lowerBound])
    }

    func testMessageBubbleView_routesSystemContextsThroughTheResolverAndTheRow() throws {
        let code = strippingLineComments(try source(
            "NanoTeams/Views/TeamBoard/ActivityFeed/MessageBubbleView.swift"))
        XCTAssertTrue(code.contains("SystemNoticePresentation" + ".resolve("),
                      "the bubble must classify via the shared resolver")
        XCTAssertTrue(code.contains("SystemNoticeRow("),
                      "the bubble must render the collapsed row")

        // `headerSourceLabel` is pinned behaviourally above, but a truth table
        // says nothing about what the CALL SITE feeds it — a hard-coded `false`
        // there would restore the duplicate `(retry)` with every test green.
        //
        // The first `isSystemNotice:` in the file is the PARAMETER DECLARATION,
        // whose remainder is a type. Argument sites are everything else, and
        // every one of them has to be driven by the resolved value.
        let argumentSites = Self.remaindersAfter("isSystemNotice:", in: code)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("Bool") }
        XCTAssertFalse(argumentSites.isEmpty, "the header must go through the helper")
        for site in argumentSites {
            XCTAssertTrue(site.contains("systemNotice"),
                          "the header's suppression must be driven by the resolved notice, not by "
                              + "a literal — found `isSystemNotice:\(site)`")
        }
    }

    /// Every occurrence's line-remainder, so a scan can distinguish a
    /// declaration from its call sites instead of trusting the first match.
    private static func remaindersAfter(_ needle: String, in text: String) -> [String] {
        var out: [String] = []
        var cursor = text.startIndex
        while let found = text.range(of: needle, range: cursor..<text.endIndex) {
            out.append(String(text[found.upperBound...].prefix { $0 != "\n" }))
            cursor = found.upperBound
        }
        return out
    }

    /// The resolver is the ONLY place that decides which contexts collapse. A
    /// second per-context branch in the view is how the two would drift — and it
    /// is exactly the shape the retired `.serverError` red card had.
    func testMessageBubbleView_hasNoPerContextBranchForASystemContext() throws {
        let full = try source("NanoTeams/Views/TeamBoard/ActivityFeed/MessageBubbleView.swift")
        let code = strippingLineComments(droppingPreviews(full))
        XCTAssertLessThan(code.count, full.count,
                          "the preview block was not found — the scan is reading a file shape it "
                              + "does not understand")
        for context in [".serverError", ".retryNudge", ".loopCorrection"] {
            XCTAssertFalse(code.contains(context),
                           "\(context) is classified by SystemNoticePresentation; a branch here "
                               + "would be a second, drifting copy of that decision")
        }
        // Anti-vacuum: the scan is looking at the right file.
        XCTAssertTrue(code.contains(".supervisorMessage"),
                      "the supervisor-message branch is expected to still be inline")
    }

    func testSystemNoticeRow_opensTheDetailWindow() throws {
        let code = strippingLineComments(try source(
            "NanoTeams/Views/TeamBoard/ActivityFeed/SystemNoticeRow.swift"))
        XCTAssertTrue(code.contains("ActivityDetailWindow" + ".systemNotice("),
                      "the row's whole point is opening the full text in a window")
        XCTAssertTrue(code.contains("openWindow("))
        // House rule: the feed retired inline expansion — a chevron here would
        // mean someone reintroduced a disclosure idiom that was deliberately
        // removed (see TeamActivityFeedViewModel's doc comment).
        XCTAssertFalse(code.contains("chevron"),
                       "feed rows open windows; they do not expand inline")
    }
}
