import XCTest

@testable import NanoTeams

/// The one part of `TerminalChoiceList` that can be wrong: what a tap does to the selection.
///
/// It lives as a `nonisolated static func` precisely so a test can reach it — `Views/` is
/// outside the coverage denominator and a `let` inside `some View` is unreachable from
/// XCTest, so selection arithmetic buried in a `body` is arithmetic nothing checks.
final class TerminalChoiceListTests: XCTestCase {

    private typealias List = TerminalChoiceList<String>

    private func tap(_ id: String, _ selection: Set<String>, _ mode: List.Mode) -> Set<String> {
        List.toggling(id, in: selection, mode: mode)
    }

    // MARK: - Single

    func testSingleChoiceReplacesWhateverWasSelected() {
        XCTAssertEqual(tap("b", ["a"], .single), ["b"])
    }

    func testSingleChoiceSelectsFromEmpty() {
        XCTAssertEqual(tap("a", [], .single), ["a"])
    }

    /// Tapping the sole selection CLEARS it. A questionnaire may be submitted without
    /// deciding, so "unanswered" is a real state — an answer that cannot be un-given turns a
    /// mis-click into a decision the Supervisor never gets to take back.
    func testSingleChoiceTappedAgainClearsTheAnswer() {
        XCTAssertEqual(tap("a", ["a"], .single), [])
    }

    /// Degenerate input a caller can produce by seeding the binding itself: two ids under
    /// `.single`. Tapping either one still lands on exactly one selection rather than
    /// subtracting into another illegal state.
    func testSingleChoiceHealsASelectionThatHeldTwo() {
        XCTAssertEqual(tap("b", ["a", "b"], .single), [])
        XCTAssertEqual(tap("c", ["a", "b"], .single), ["c"])
    }

    // MARK: - Multiple

    func testMultipleChoiceAddsWithoutDisturbingTheRest() {
        XCTAssertEqual(tap("b", ["a"], .multiple), ["a", "b"])
    }

    func testMultipleChoiceRemovesOnlyWhatWasTapped() {
        XCTAssertEqual(tap("a", ["a", "b"], .multiple), ["b"])
    }

    func testMultipleChoiceCanBeEmptied() {
        XCTAssertEqual(tap("a", ["a"], .multiple), [])
    }

    func testAnUnknownIdIsStillAddedUnderMultiple() {
        // The component never calls it this way, but the function is the contract: it decides
        // membership, and it is not the place that knows which options exist.
        XCTAssertEqual(tap("z", ["a"], .multiple), ["a", "z"])
    }

    // MARK: - The vocabulary

    /// Marks come from `TerminalGlyph` and nowhere else. Three surfaces each invented their
    /// own SF Symbol pair before this component existed; a fourth would start the same way —
    /// with a literal in a `body` that nothing compares to anything.
    func testTheMarksAreTheDesignSystemsOwn() {
        XCTAssertEqual(
            List.Mode.multiple.mark.checked, TerminalGlyph.checkedBox,
            "the multi-select mark must be the one the DS switch draws")
        XCTAssertEqual(List.Mode.multiple.mark.unchecked, TerminalGlyph.uncheckedBox)
        XCTAssertEqual(List.Mode.single.mark.checked, TerminalGlyph.checkedRadio)
        XCTAssertEqual(List.Mode.single.mark.unchecked, TerminalGlyph.uncheckedRadio)
    }

    /// Checked and unchecked must be the same width, or a column of them shimmers as marks
    /// swap. In SF Mono that is a character count.
    func testEachMarkPairIsTheSameWidth() {
        for mode in [List.Mode.single, .multiple] {
            XCTAssertEqual(
                mode.mark.checked.count, mode.mark.unchecked.count, "\(mode)")
        }
    }
}
