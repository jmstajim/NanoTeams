import XCTest

@testable import NanoTeams

/// Corner cases for the `ComputerUseAction` domain value type — target normalization + summary.
final class ComputerUseActionTests: XCTestCase {

    // MARK: - appTargetSpec

    func testCapture_screenKeyword_hasNoAppTarget() {
        XCTAssertNil(ComputerUseAction.capture(target: "screen", windowTitle: nil).appTargetSpec)
        XCTAssertNil(ComputerUseAction.capture(target: "Display", windowTitle: nil).appTargetSpec)  // case-insensitive
        XCTAssertNil(ComputerUseAction.capture(target: "SCREEN", windowTitle: nil).appTargetSpec)
    }

    func testCapture_emptyOrWhitespaceTarget_hasNoAppTarget() {
        XCTAssertNil(ComputerUseAction.capture(target: "", windowTitle: nil).appTargetSpec)
        XCTAssertNil(ComputerUseAction.capture(target: "   ", windowTitle: nil).appTargetSpec)
    }

    func testCapture_appName_isAppTarget() {
        XCTAssertEqual(ComputerUseAction.capture(target: "Safari", windowTitle: nil).appTargetSpec, "Safari")
    }

    func testAction_targetNormalization() {
        XCTAssertEqual(ComputerUseAction.click(x: 1, y: 1, button: "left", double: false, target: "Safari").appTargetSpec, "Safari")
        XCTAssertNil(ComputerUseAction.click(x: 1, y: 1, button: "left", double: false, target: nil).appTargetSpec)
        XCTAssertNil(ComputerUseAction.click(x: 1, y: 1, button: "left", double: false, target: "  ").appTargetSpec)
        XCTAssertNil(ComputerUseAction.typeText(text: "x", target: "").appTargetSpec)
        XCTAssertEqual(ComputerUseAction.scroll(x: 0, y: 0, dx: 0, dy: 0, target: "Mail").appTargetSpec, "Mail")
    }

    // MARK: - summary

    func testSummary_click() {
        let s = ComputerUseAction.click(x: 12, y: 34, button: "left", double: false, target: nil).summary
        XCTAssertTrue(s.contains("(12, 34)"))
        XCTAssertTrue(s.contains("left"))
        XCTAssertFalse(s.contains("Double"))
    }

    func testSummary_doubleRightClick() {
        let s = ComputerUseAction.click(x: 1, y: 2, button: "right", double: true, target: nil).summary
        XCTAssertTrue(s.contains("Double"))
        XCTAssertTrue(s.contains("right"))
    }

    func testSummary_typeTruncatesLongText() {
        let long = String(repeating: "a", count: 200)
        let s = ComputerUseAction.typeText(text: long, target: nil).summary
        XCTAssertTrue(s.contains("…"))
        XCTAssertLessThan(s.count, 120)
    }

    // MARK: - detail (FULL, untruncated — used by the judge + approval card)

    func testDetail_typeTextIsUntruncated() {
        let long = String(repeating: "a", count: 200)
        let d = ComputerUseAction.typeText(text: long, target: nil).detail
        XCTAssertFalse(d.contains("…"), "detail must not truncate")
        XCTAssertTrue(d.contains(long), "detail must carry the full typed text so the reviewer sees exactly what runs")
    }

    func testDetail_matchesSummaryForNonTypeActions() {
        // Only typeText differs between summary and detail; other actions are identical.
        let click = ComputerUseAction.click(x: 1, y: 2, button: "left", double: false, target: nil)
        XCTAssertEqual(click.summary, click.detail)
        let scroll = ComputerUseAction.scroll(x: 1, y: 2, dx: 0, dy: -10, target: nil)
        XCTAssertEqual(scroll.summary, scroll.detail)
    }

    func testSummary_captureWholeScreenVsWindow() {
        XCTAssertTrue(ComputerUseAction.capture(target: "screen", windowTitle: nil).summary.contains("whole screen"))
        let win = ComputerUseAction.capture(target: "Safari", windowTitle: "GitHub").summary
        XCTAssertTrue(win.contains("Safari"))
        XCTAssertTrue(win.contains("GitHub"))
    }

    func testSummary_scrollAndKey() {
        XCTAssertTrue(ComputerUseAction.scroll(x: 5, y: 6, dx: 0, dy: -40, target: nil).summary.contains("(0, -40)"))
        XCTAssertTrue(ComputerUseAction.pressKey(keys: "cmd+s", target: nil).summary.contains("cmd+s"))
    }

    // MARK: - Shared button / target normalization
    //
    // The permission gate and the handler each used to resolve these two on their
    // own. Duplicated resolution is how the judge approves "left-click" while a
    // right-click opens a context menu — so both now call these, and these are
    // what the pins below protect.

    func testNormalizedButton_onlyExplicitRightIsRight() {
        XCTAssertEqual(ComputerUseAction.normalizedButton("right"), "right")
        XCTAssertEqual(ComputerUseAction.normalizedButton("RIGHT"), "right")
        XCTAssertEqual(ComputerUseAction.normalizedButton(" Right "), "right")
    }

    func testNormalizedButton_anythingElseIsLeft() {
        // A spelling the model invented must not become the more disruptive
        // action — unknown resolves to the safe default, never to right.
        XCTAssertEqual(ComputerUseAction.normalizedButton(nil), "left")
        XCTAssertEqual(ComputerUseAction.normalizedButton(""), "left")
        XCTAssertEqual(ComputerUseAction.normalizedButton("left"), "left")
        XCTAssertEqual(ComputerUseAction.normalizedButton("secondary"), "left")
        XCTAssertEqual(ComputerUseAction.normalizedButton("rightclick"), "left")
        XCTAssertEqual(ComputerUseAction.normalizedButton("2"), "left")
    }

    func testNormalizedTargetSpec_blankFormsCollapseToNil() {
        XCTAssertNil(ComputerUseAction.normalizedTargetSpec(nil))
        XCTAssertNil(ComputerUseAction.normalizedTargetSpec(""))
        XCTAssertNil(ComputerUseAction.normalizedTargetSpec("   "))
        XCTAssertNil(ComputerUseAction.normalizedTargetSpec("\n\t"))
    }

    func testNormalizedTargetSpec_trimsButPreservesInnerText() {
        XCTAssertEqual(ComputerUseAction.normalizedTargetSpec("  Safari  "), "Safari")
        XCTAssertEqual(ComputerUseAction.normalizedTargetSpec("Google Chrome"), "Google Chrome")
    }
}
