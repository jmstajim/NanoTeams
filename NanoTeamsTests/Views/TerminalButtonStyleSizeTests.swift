import SwiftUI
import XCTest

@testable import NanoTeams

/// `TerminalButtonStyle.Size` — the metric table behind `[ … ]`.
///
/// It exists so a button in a dense row stays a DS button instead of becoming a `.plain` one
/// with a hand-written font and padding, which is how every previous dense-row button drifted.
/// The table is asserted rather than eyeballed for the same reason the tokens are: a size that
/// silently equals the regular one is a size nobody notices is doing nothing.
@MainActor
final class TerminalButtonStyleSizeTests: XCTestCase {

    // MARK: - The two sizes are actually different

    func testCompactIsSmallerThanRegularOnEveryMetric() {
        let regular = TerminalButtonStyle.Size.regular
        let compact = TerminalButtonStyle.Size.compact

        XCTAssertLessThan(compact.horizontalPadding, regular.horizontalPadding)
        XCTAssertLessThan(compact.verticalPadding, regular.verticalPadding)
        XCTAssertLessThan(compact.minHeight, regular.minHeight)
        XCTAssertNotEqual(compact.labelFont, regular.labelFont)
    }

    // MARK: - The values themselves

    /// Spelled from tokens, never as numbers: `Spacing` is the ladder the rest of the design
    /// system is built on, and a literal here would be a fifth spacing scale.
    func testRegularKeepsTheMetricsEveryExistingButtonWasDrawnWith() {
        let regular = TerminalButtonStyle.Size.regular

        XCTAssertEqual(regular.labelFont, Typography.subheadline.weight(.semibold))
        XCTAssertEqual(regular.bracketFont, Typography.subheadline.weight(.regular))
        XCTAssertEqual(regular.horizontalPadding, Spacing.m)
        XCTAssertEqual(regular.verticalPadding, Spacing.xs + 1)
        XCTAssertEqual(regular.minHeight, Spacing.l + Spacing.s)
    }

    /// 20pt is the height of the composer's question header, which is the row this size was
    /// added for: a taller cell would push that row open just by being in it.
    func testCompactFitsAnElevenPointRow() {
        let compact = TerminalButtonStyle.Size.compact

        XCTAssertEqual(compact.labelFont, Typography.captionSemibold)
        XCTAssertEqual(compact.bracketFont, Typography.caption)
        XCTAssertEqual(compact.horizontalPadding, Spacing.s)
        XCTAssertEqual(compact.verticalPadding, Spacing.xxs)
        XCTAssertEqual(compact.minHeight, Spacing.l)
    }

    /// The brackets are chrome around the label: same size, lighter weight. A bracket set
    /// heavier or larger than what it wraps reads as a box, not a terminal cell.
    func testBracketsNeverOutweighTheirLabel() {
        for size in [TerminalButtonStyle.Size.regular, .compact] {
            XCTAssertNotEqual(
                size.bracketFont, size.labelFont,
                "brackets must stay lighter than the label they wrap")
        }
    }

    // MARK: - Who uses which

    /// The `[ Ask as form ]` button is the compact size's only caller today, and it takes it
    /// from the style rather than restating a font and a padding of its own.
    func testTheQuestionnaireRequestButtonAsksForTheCompactSize() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("NanoTeams/Views/Shared/QuestionnaireRequestButton.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains(".buttonStyle(.terminalGhostCompact)"))
        for ownMetric in [".font(", ".padding(", ".frame(", ".background("] {
            XCTAssertFalse(
                source.contains(ownMetric),
                "\(ownMetric) restates a decision `TerminalButtonStyle` already owns")
        }
    }
}
