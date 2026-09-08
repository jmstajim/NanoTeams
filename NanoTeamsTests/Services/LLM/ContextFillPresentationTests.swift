import XCTest

@testable import NanoTeams

/// What the fill indicator says, and — the part that matters — how honestly it says it.
///
/// The number behind this control can be the server's own count or the app's estimator, and
/// the estimator's error against real tokenizers spans 0.45×–2.58×. Printing the two
/// identically would make a Cyrillic conversation look 2.2× fuller than it is, and a user who
/// compacts on that has discarded work to solve a problem they did not have.
final class ContextFillPresentationTests: XCTestCase {

    private func fill(
        _ tokens: Int, window: Int? = 8192, budget: Int? = 2048,
        isEstimate: Bool = false, compactions: Int = 0
    ) -> ContextFill {
        ContextFill(
            promptTokens: tokens, window: window, budget: budget,
            isEstimate: isEstimate, compactions: compactions)
    }

    // MARK: - Fraction

    /// Of the BUDGET, not of the window. A bar filling toward the window would sit at a
    /// quarter for the whole life of a step and then compact with three quarters still empty.
    func testFraction_isOfTheBudget() {
        XCTAssertEqual(ContextFillPresentation.fraction(fill(1024)) ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(ContextFillPresentation.fraction(fill(2048)) ?? 0, 1.0, accuracy: 0.0001)
    }

    func testFraction_clampsAtOne() {
        XCTAssertEqual(ContextFillPresentation.fraction(fill(9_999)) ?? 0, 1.0, accuracy: 0.0001)
    }

    func testFraction_withoutABudget_isNil() {
        XCTAssertNil(ContextFillPresentation.fraction(fill(100, window: nil, budget: nil)))
        XCTAssertNil(ContextFillPresentation.fraction(fill(100, budget: 0)))
    }

    // MARK: - Tier

    func testTier_bands() {
        XCTAssertEqual(ContextFillPresentation.tier(fill(0)), .comfortable)
        XCTAssertEqual(ContextFillPresentation.tier(fill(1_227)), .comfortable)  // 59.9%
        XCTAssertEqual(ContextFillPresentation.tier(fill(1_229)), .approaching)  // 60.0%
        XCTAssertEqual(ContextFillPresentation.tier(fill(1_843)), .approaching)  // 89.9%
        XCTAssertEqual(ContextFillPresentation.tier(fill(1_844)), .atBudget)     // 90.0%
    }

    /// No budget means no verdict — the indicator shows a count and no colour claim.
    func testTier_withoutABudget_isUnknown() {
        XCTAssertEqual(
            ContextFillPresentation.tier(fill(100, window: nil, budget: nil)), .unknown)
    }

    // MARK: - Tooltip

    /// With the on-chip label gone, the tooltip is the only place the count and its PROVENANCE
    /// are stated — and the provenance is the half that matters, since an estimate can be 2.2×
    /// off and nothing automatic is allowed to act on one.
    func testTooltip_namesTheSourceOfTheNumber() {
        XCTAssertTrue(
            ContextFillPresentation.tooltip(fill(1024), isCompacting: false)
                .contains("reported by the server"))
        XCTAssertTrue(
            ContextFillPresentation.tooltip(fill(1024, isEstimate: true), isCompacting: false)
                .contains("estimated"))
    }

    /// The exact count rides the tooltip at every tier, including the one with no budget where
    /// the bar itself can show nothing at all.
    func testTooltip_carriesTheExactCountEvenWithNoScaleToDrawIt() {
        let text = ContextFillPresentation.tooltip(
            fill(12_927, window: nil, budget: nil, isEstimate: true), isCompacting: false)
        XCTAssertTrue(text.contains(TokenCountFormat.exact(12_927)), text)
        XCTAssertTrue(text.contains("estimated"), text)
    }

    func testTooltip_namesTheBudgetTheWindowAndPastEpochs() {
        let text = ContextFillPresentation.tooltip(fill(1024, compactions: 2), isCompacting: false)
        XCTAssertTrue(text.contains(TokenCountFormat.exact(2048)), text)
        XCTAssertTrue(text.contains(TokenCountFormat.exact(8192)), text)
        XCTAssertTrue(text.contains("2 times"), text)
        XCTAssertTrue(text.contains("Click to compact"), text)
    }

    /// RED: print the budget as a bare number → the tooltip says "compacts at 65.5k" under
    /// "model window 262.1k" and gives the reader no way to tell whether that quarter is a
    /// model limit or a setting. It is a setting, and the share is what says so.
    func testTooltip_saysWhatShareOfTheWindowTheBudgetIs() {
        let text = ContextFillPresentation.tooltip(fill(1024), isCompacting: false)
        XCTAssertTrue(text.contains("25% of the window"), text)
        XCTAssertTrue(text.contains("Settings"), text)
    }

    /// No window, no share — and the budget line still prints its number. A fabricated "100%"
    /// here would be the one place claiming the budget IS the window.
    func testTooltip_withoutAWindow_printsTheBudgetWithoutAShare() {
        let text = ContextFillPresentation.tooltip(
            fill(1024, window: nil, budget: 2048), isCompacting: false)
        XCTAssertTrue(text.contains(TokenCountFormat.exact(2048)), text)
        XCTAssertFalse(text.contains("of the window"), text)
    }

    func testBudgetShare_isAWholePercentOrNothing() {
        XCTAssertEqual(ContextFillPresentation.budgetShare(fill(0, window: 262_144, budget: 65_536)), 25)
        XCTAssertEqual(ContextFillPresentation.budgetShare(fill(0, window: 8192, budget: 8192)), 100)
        XCTAssertEqual(ContextFillPresentation.budgetShare(fill(0, window: 300, budget: 1)), 0)
        XCTAssertNil(ContextFillPresentation.budgetShare(fill(0, window: nil, budget: 2048)))
        XCTAssertNil(ContextFillPresentation.budgetShare(fill(0, window: 0, budget: 2048)))
        XCTAssertNil(ContextFillPresentation.budgetShare(fill(0, window: 8192, budget: nil)))
    }

    /// An unknown window is stated, not omitted: the user needs to know why there is no
    /// percentage, and "the server did not report one" is the actionable half.
    func testTooltip_saysWhenTheWindowIsUnknown() {
        let text = ContextFillPresentation.tooltip(
            fill(1024, window: nil, budget: nil), isCompacting: false)
        XCTAssertTrue(text.contains("unknown"), text)
    }

    func testTooltip_whileCompacting_saysSo() {
        XCTAssertTrue(
            ContextFillPresentation.tooltip(fill(1024), isCompacting: true)
                .contains("Compacting"))
    }

    // MARK: - Accessibility

    /// The indicator prints nothing on the chip, so this and the tooltip are the entire spoken
    /// and written surface — a percentage when there is a budget, and an explicit "unknown"
    /// when there is not, never a silent zero.
    func testAccessibilityValue_carriesTheProportionOrSaysItCannot() {
        XCTAssertTrue(
            ContextFillPresentation.accessibilityValue(fill(1024), isCompacting: false)
                .contains("50 percent"))
        XCTAssertTrue(
            ContextFillPresentation.accessibilityValue(
                fill(1024, window: nil, budget: nil), isCompacting: false)
                .contains("budget unknown"))
        XCTAssertEqual(
            ContextFillPresentation.accessibilityValue(fill(1024), isCompacting: true),
            "Compacting")
    }
}

/// The single rounding rule every surface that prints a token count now shares.
///
/// Three of them grew their own, and they disagreed — `%.1f` against a
/// `(x*10).rounded()/10` trick — which is invisible until two of them name the same number on
/// the same screen.
final class TokenCountFormatTests: XCTestCase {

    func testExact_switchesToThousandsAtOneThousand() {
        XCTAssertEqual(TokenCountFormat.exact(0), "0")
        XCTAssertEqual(TokenCountFormat.exact(840), "840")
        XCTAssertEqual(TokenCountFormat.exact(999), "999")
        XCTAssertEqual(TokenCountFormat.exact(1000), "1.0k")
        XCTAssertEqual(TokenCountFormat.exact(12_927), "12.9k")
        XCTAssertEqual(TokenCountFormat.exact(4_200), "4.2k")
    }

    func testApproximate_isExactWithATilde() {
        for value in [0, 840, 999, 1000, 12_927] {
            XCTAssertEqual(
                TokenCountFormat.approximate(value), "~" + TokenCountFormat.exact(value))
        }
    }

    /// The two existing formatters now delegate here, and their outputs are pinned elsewhere —
    /// this states the equivalence so a change to the rule fails in one obvious place rather
    /// than in two unrelated suites.
    func testTheDelegatingFormattersAgree() {
        XCTAssertEqual(PrefixCachePolicy.formatTokens(12_927), "~12.9k")
        XCTAssertEqual(PrefixCachePolicy.formatTokens(840), "~840")
        XCTAssertEqual(RoleEditorSkillsPolicy.formatTokens(4_200), "~4.2k tokens")
        XCTAssertEqual(RoleEditorSkillsPolicy.formatTokens(840), "~840 tokens")
    }
}
