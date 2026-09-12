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

    private func measured(
        _ tokens: Int, window: Int? = 8192, budget: Int? = 2048,
        isEstimate: Bool = false, compactions: Int = 0
    ) -> ContextFillPresentation.State {
        .measured(
            fill(
                tokens, window: window, budget: budget,
                isEstimate: isEstimate, compactions: compactions))
    }

    /// The census population, and the reason it is a CARTESIAN PRODUCT of the resolver's inputs
    /// rather than a hand-written list of cases.
    ///
    /// A list is the enumeration rule #236 condemns: it can only contain the states its author
    /// remembered, which is precisely how this defect happened one level up — `emptyBar` was the
    /// state nobody enumerated, and no test read it. Here every state that
    /// `ContextFillProjection` can hand the view is CONSTRUCTED from what it can return
    /// (`ContextFill?` × `isCompacting`), so a state added to the enum cannot slip past the
    /// census by being forgotten in a literal.
    private var everyState: [ContextFillPresentation.State] {
        let fills: [ContextFill?] = [
            nil,
            fill(0),
            fill(1_024),
            fill(1_900),
            fill(9_999),
            fill(1_024, window: nil, budget: nil),
            fill(1_024, window: 8192, budget: 0),
            fill(1_024, isEstimate: true),
            fill(1_024, compactions: 3),
        ]
        return fills.flatMap { candidate in
            [false, true].map { ContextFillPresentation.state(fill: candidate, isCompacting: $0) }
        }
    }

    /// The `switch` is exhaustive, so a fourth `State` case will NOT COMPILE here until its
    /// author names it — the census is led by the compiler rather than by a list. This is the
    /// pin, in place of a `Ratchet` source scan whose population would itself be a hand-named
    /// file path (rule #236 again, one level further out).
    private func kind(_ state: ContextFillPresentation.State) -> String {
        switch state {
        case .unmeasured: "unmeasured"
        case .measured: "measured"
        case .compacting: "compacting"
        }
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

    // MARK: - State

    /// The resolver is total over what the projection can return, and the pair collapses to a
    /// state in exactly ONE place — which is what leaves the view with no branch of its own.
    func testState_isTotalOverWhatTheProjectionCanReturn() {
        // ONE instance, reused. `ContextFill` carries a `MonotonicClock` stamp, so two calls to
        // the helper are never equal — comparing against a second `fill(1024)` would fail for a
        // reason that has nothing to do with the resolver.
        let measurement = fill(1024)
        XCTAssertEqual(kind(ContextFillPresentation.state(fill: nil, isCompacting: false)),
                       "unmeasured")
        XCTAssertEqual(kind(ContextFillPresentation.state(fill: measurement, isCompacting: false)),
                       "measured")
        XCTAssertEqual(kind(ContextFillPresentation.state(fill: nil, isCompacting: true)),
                       "compacting")
        XCTAssertEqual(kind(ContextFillPresentation.state(fill: measurement, isCompacting: true)),
                       "compacting")
        // An epoch keeps the measurement it was started from: the bar holds its length while
        // the wire is rewritten, and a bar that emptied mid-epoch would claim the conversation
        // was already gone.
        XCTAssertEqual(
            ContextFillPresentation.measurement(
                of: ContextFillPresentation.state(fill: measurement, isCompacting: true)),
            measurement)
        XCTAssertNil(ContextFillPresentation.measurement(of: .unmeasured))
    }

    /// THE PROPERTY THAT BROKE, stated over the whole domain.
    ///
    /// Until 2026-09-09 the state with no measurement had no tooltip, no button and
    /// `.accessibilityHidden(true)` — a bar that looked like a control and answered neither the
    /// mouse nor VoiceOver. It was reachable by every role that had not answered in the current
    /// run, which on any installation with history is most chips.
    func testEveryStateSaysSomethingOnHoverAndToVoiceOver() {
        // The premise first: a green assertion over a population that is missing a case says
        // nothing at all. This fails if the product above stops producing all three.
        XCTAssertEqual(Set(everyState.map(kind)), ["unmeasured", "measured", "compacting"])

        for state in everyState {
            let tooltip = ContextFillPresentation.tooltip(state)
            XCTAssertFalse(
                tooltip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "silent on hover: \(kind(state))")
            XCTAssertFalse(
                ContextFillPresentation.accessibilityValue(state)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "silent to VoiceOver: \(kind(state))")
            let value = ContextFillPresentation.barValue(state)
            XCTAssertTrue((0...1).contains(value), "bar value \(value) for \(kind(state))")
        }
    }

    // MARK: - Tooltip

    /// With the on-chip label gone, the tooltip is the only place the count and its PROVENANCE
    /// are stated — and the provenance is the half that matters, since an estimate can be 2.2×
    /// off and nothing automatic is allowed to act on one.
    func testTooltip_namesTheSourceOfTheNumber() {
        XCTAssertTrue(
            ContextFillPresentation.tooltip(measured(1024)).contains("reported by the server"))
        XCTAssertTrue(
            ContextFillPresentation.tooltip(measured(1024, isEstimate: true))
                .contains("estimated"))
    }

    /// The exact count rides the tooltip at every tier, including the one with no budget where
    /// the bar itself can show nothing at all.
    func testTooltip_carriesTheExactCountEvenWithNoScaleToDrawIt() {
        let text = ContextFillPresentation.tooltip(
            measured(12_927, window: nil, budget: nil, isEstimate: true))
        XCTAssertTrue(text.contains(TokenCountFormat.exact(12_927)), text)
        XCTAssertTrue(text.contains("estimated"), text)
    }

    func testTooltip_namesTheBudgetTheWindowAndPastEpochs() {
        let text = ContextFillPresentation.tooltip(measured(1024, compactions: 2))
        XCTAssertTrue(text.contains(TokenCountFormat.exact(2048)), text)
        XCTAssertTrue(text.contains(TokenCountFormat.exact(8192)), text)
        XCTAssertTrue(text.contains("2 times"), text)
        XCTAssertTrue(text.contains("Click to compact"), text)
    }

    /// One epoch reads "1 time", not "1 times". Never covered before, and the plural is the
    /// branch every author writes first.
    func testTooltip_countsEpochsInSingularAndPlural() {
        XCTAssertFalse(ContextFillPresentation.tooltip(measured(1024)).contains("so far"))
        XCTAssertTrue(
            ContextFillPresentation.tooltip(measured(1024, compactions: 1))
                .contains("Compacted 1 time so far"))
        XCTAssertTrue(
            ContextFillPresentation.tooltip(measured(1024, compactions: 2))
                .contains("Compacted 2 times so far"))
    }

    // MARK: - How full it is

    /// The question the user actually asks this control — "how full is it now" — answered in
    /// words, against BOTH bases and with each named.
    ///
    /// Two bases, because the two answers differ and the bar can only draw one of them: it
    /// fills toward the BUDGET (crossing that is what compacts), while "how much of the model's
    /// context is spoken for" is of the WINDOW. Printing one unlabelled number would be read as
    /// whichever the reader had in mind.
    func testTooltip_saysHowFullTheContextIs() {
        let text = ContextFillPresentation.tooltip(measured(1_024))
        XCTAssertTrue(text.contains("Filled: 50% of the budget"), text)
        XCTAssertTrue(text.contains("13% of the model window"), text)  // 1024/8192 = 12.5%
    }

    func testPromptShares_areOfTheBudgetAndOfTheWindowSeparately() {
        XCTAssertEqual(ContextFillPresentation.promptShareOfBudget(fill(1_024)), 50)
        XCTAssertEqual(ContextFillPresentation.promptShareOfWindow(fill(1_024)), 13)
        XCTAssertNil(ContextFillPresentation.promptShareOfBudget(fill(1_024, budget: 0)))
        XCTAssertNil(ContextFillPresentation.promptShareOfWindow(fill(1_024, window: 0)))
    }

    /// Corner case: with the threshold at 100% the budget IS the window, so the second share
    /// would be the same number twice — which reads as a rendering fault, not as information.
    /// The line then names one base, and "Compacts at: … (100% of the window)" a line below is
    /// what says the two coincide.
    func testTooltip_whenTheBudgetIsTheWholeWindow_printsOneShare() {
        let text = ContextFillPresentation.tooltip(measured(1_024, window: 8192, budget: 8192))
        XCTAssertTrue(text.contains("Filled: 13% of the budget"), text)
        XCTAssertFalse(text.contains("of the model window,"), text)
        XCTAssertFalse(text.contains("13% of the model window"), text)
    }

    /// Corner case, and the reason these are not `fraction`: the BAR clamps at 1.0 because a
    /// bar cannot draw past its own end, but the TEXT must not. A prompt at 488% of the budget
    /// under a full bar explains why the bar has stopped moving; a text that also said "100%"
    /// would make the control look stuck instead.
    func testTooltip_pastTheBudget_doesNotClampTheNumber() {
        let text = ContextFillPresentation.tooltip(measured(9_999))
        XCTAssertTrue(text.contains("488% of the budget"), text)
        XCTAssertEqual(ContextFillPresentation.barValue(measured(9_999)), 1.0)
    }

    /// Only the share it can compute, and never a base it does not have.
    func testTooltip_withOnlyOneBase_namesOnlyThatOne() {
        let noBudget = ContextFillPresentation.tooltip(measured(1_024, budget: 0))
        XCTAssertTrue(noBudget.contains("13% of the model window"), noBudget)
        XCTAssertFalse(noBudget.contains("of the budget"), noBudget)

        let noWindow = ContextFillPresentation.tooltip(measured(1_024, window: nil))
        XCTAssertTrue(noWindow.contains("50% of the budget"), noWindow)
        XCTAssertFalse(noWindow.contains("of the model window"), noWindow)

        let neither = ContextFillPresentation.tooltip(measured(1_024, window: nil, budget: nil))
        XCTAssertFalse(neither.contains("Filled:"), neither)
    }

    /// RED: print the budget as a bare number → the tooltip says "compacts at 65.5k" under
    /// "model window 262.1k" and gives the reader no way to tell whether that quarter is a
    /// model limit or a setting. It is a setting, and the share is what says so.
    func testTooltip_saysWhatShareOfTheWindowTheBudgetIs() {
        let text = ContextFillPresentation.tooltip(measured(1024))
        XCTAssertTrue(text.contains("25% of the window"), text)
        XCTAssertTrue(text.contains("Settings"), text)
    }

    /// No window, no share — and the budget line still prints its number. A fabricated "100%"
    /// here would be the one place claiming the budget IS the window.
    func testTooltip_withoutAWindow_printsTheBudgetWithoutAShare() {
        let text = ContextFillPresentation.tooltip(measured(1024, window: nil, budget: 2048))
        XCTAssertTrue(text.contains(TokenCountFormat.exact(2048)), text)
        XCTAssertFalse(text.contains("of the window"), text)
    }

    /// Corner case, RED before this wave: a persisted `budget: 0` drew an UNLIT bar — `fraction`
    /// requires `> 0`, so "there is no proportion" — under a tooltip reading "Compacts at: 0
    /// tokens (0% of the window, Settings → LLM)". The control contradicted itself in the one
    /// state where the bar cannot speak for itself. One notion of "there is a budget", read by
    /// the bar, the tooltip and the share alike.
    func testTooltip_withANonPositiveBudget_doesNotClaimOne() {
        let text = ContextFillPresentation.tooltip(measured(1024, budget: 0))
        XCTAssertFalse(text.contains("Compacts at"), text)
        XCTAssertNil(ContextFillPresentation.fraction(fill(1024, budget: 0)))
    }

    /// The same corner on the other axis: `window: 0` printed "Model window: 0 tokens", which
    /// reads as a measurement rather than as the absence of one.
    func testTooltip_withANonPositiveWindow_saysUnknownRatherThanZero() {
        let text = ContextFillPresentation.tooltip(measured(1024, window: 0))
        XCTAssertTrue(text.contains("Model window: unknown"), text)
        XCTAssertFalse(text.contains("Model window: 0"), text)
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
        let text = ContextFillPresentation.tooltip(measured(1024, window: nil, budget: nil))
        XCTAssertTrue(text.contains("unknown"), text)
    }

    func testTooltip_whileCompacting_saysSo() {
        XCTAssertTrue(
            ContextFillPresentation.tooltip(.compacting(fill(1024))).contains("Compacting"))
    }

    /// One sentence in BOTH forms of the epoch — carrying a last measurement and not. The counts
    /// on either side of a fold describe different conversations, so printing the one being
    /// replaced would show it as the one being built.
    func testTooltip_whileCompacting_isTheSameWithAndWithoutALastMeasurement() {
        XCTAssertEqual(
            ContextFillPresentation.tooltip(.compacting(fill(1024))),
            ContextFillPresentation.tooltip(.compacting(nil)))
        XCTAssertFalse(
            ContextFillPresentation.tooltip(.compacting(fill(1024)))
                .contains(TokenCountFormat.exact(1024)))
    }

    // MARK: - The state with no measurement

    /// The reported symptom, as an assertion: hovering says something, and VoiceOver reaches it.
    func testUnmeasured_isNotSilent() {
        let text = ContextFillPresentation.tooltip(.unmeasured)
        XCTAssertTrue(text.contains("not measured yet"), text)
        XCTAssertTrue(text.contains("server"), text)
        XCTAssertEqual(ContextFillPresentation.accessibilityValue(.unmeasured), "Not measured yet")
    }

    /// "Not measured" is NOT "nothing to compact". A conversation last written before the app
    /// began measuring is both long and unmeasured, and it is exactly the one worth folding —
    /// the silent branch used to hide a working operation from the longest conversations there
    /// are. Whether this particular one can be folded is `compactRoleContext`'s answer, given as
    /// a banner; the tooltip must not pre-empt it with a guess.
    func testUnmeasured_stillOffersTheAction() {
        XCTAssertTrue(ContextFillPresentation.tooltip(.unmeasured).contains("Click to compact"))
    }

    /// Corner case: the absence of a measurement must not render as a measured zero. No digit
    /// appears anywhere in the text — not "0 tokens", not "0%".
    func testUnmeasured_inventsNoNumber() {
        let text = ContextFillPresentation.tooltip(.unmeasured)
        XCTAssertFalse(text.contains(where: \.isNumber), text)
    }

    /// The two unlit pictures, told apart ONLY by hover — which is the whole argument for the
    /// tooltip existing in the empty state, turned into a measurement.
    ///
    /// `.unmeasured` and a measurement whose window was never probed draw byte-identically: same
    /// bar value, same `.clear` ink (tier `.unknown`). If they also said the same thing on hover
    /// the user could not tell "no reply yet" from "the server never reported a window".
    func testTheTwoUnlitStatesAreToldApartOnlyByTheTooltip() {
        let unprobed = measured(1_024, window: nil, budget: nil)
        XCTAssertEqual(ContextFillPresentation.barValue(.unmeasured), 0)
        XCTAssertEqual(ContextFillPresentation.barValue(unprobed), 0)
        XCTAssertEqual(ContextFillPresentation.tier(fill(1_024, window: nil, budget: nil)),
                       .unknown)

        let silentLooking = ContextFillPresentation.tooltip(.unmeasured)
        let probeless = ContextFillPresentation.tooltip(unprobed)
        XCTAssertNotEqual(silentLooking, probeless)
        XCTAssertTrue(silentLooking.contains("not measured yet"), silentLooking)
        XCTAssertTrue(probeless.contains("Model window: unknown"), probeless)
    }

    /// The third look-alike: zero tokens WITH a budget is a real measurement, and says so.
    func testMeasuredZero_isNotTheUnmeasuredState() {
        let text = ContextFillPresentation.tooltip(measured(0))
        XCTAssertTrue(text.contains("reported by the server"), text)
        XCTAssertTrue(text.contains("Prompt: 0 tokens"), text)
        XCTAssertEqual(ContextFillPresentation.tier(fill(0)), .comfortable)
    }

    // MARK: - Bar value

    /// Zero wherever there is no proportion — and unambiguous, because `TerminalProgressBar`
    /// lights at least one eighth for any value above zero.
    func testBarValue_isZeroWhereverThereIsNoProportion() {
        XCTAssertEqual(ContextFillPresentation.barValue(.unmeasured), 0)
        XCTAssertEqual(ContextFillPresentation.barValue(.compacting(nil)), 0)
        XCTAssertEqual(
            ContextFillPresentation.barValue(measured(1_024, window: nil, budget: nil)), 0)
        XCTAssertEqual(ContextFillPresentation.barValue(measured(1_024, budget: 0)), 0)
    }

    func testBarValue_whileCompacting_keepsTheLastMeasuredLength() {
        XCTAssertEqual(
            ContextFillPresentation.barValue(.compacting(fill(1024))), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ContextFillPresentation.barValue(.compacting(nil)), 0)
    }

    // MARK: - Accessibility

    /// The indicator prints nothing on the chip, so this and the tooltip are the entire spoken
    /// and written surface — a percentage when there is a budget, and an explicit "unknown"
    /// when there is not, never a silent zero.
    func testAccessibilityValue_carriesTheProportionOrSaysItCannot() {
        XCTAssertTrue(
            ContextFillPresentation.accessibilityValue(measured(1024)).contains("50 percent"))
        XCTAssertTrue(
            ContextFillPresentation.accessibilityValue(measured(1024, window: nil, budget: nil))
                .contains("budget unknown"))
        XCTAssertEqual(
            ContextFillPresentation.accessibilityValue(.compacting(fill(1024))), "Compacting")
    }

    /// A spoken "0 percent of the budget" would be worse than either silence or the truth: it
    /// is the one reading this indicator may never fake. A share it CAN compute is not a
    /// fabrication, so the assertion is about the missing base specifically — a blanket "no
    /// percent anywhere" would forbid the window share the same call can legitimately carry.
    func testAccessibilityValue_neverInventsAPercentage() {
        XCTAssertFalse(
            ContextFillPresentation.accessibilityValue(.unmeasured).contains("percent"))
        XCTAssertFalse(
            ContextFillPresentation.accessibilityValue(measured(1_024, window: nil, budget: nil))
                .contains("percent"))
        let zeroBudget = ContextFillPresentation.accessibilityValue(measured(1_024, budget: 0))
        XCTAssertFalse(zeroBudget.contains("of the compaction budget"), zeroBudget)
        XCTAssertTrue(zeroBudget.contains("13 percent of the model window"), zeroBudget)
    }

    /// VoiceOver hears what the tooltip shows — both bases. A spoken surface that knows less
    /// than the written one is the asymmetry this file exists to prevent.
    func testAccessibilityValue_carriesBothBases() {
        let spoken = ContextFillPresentation.accessibilityValue(measured(1_024))
        XCTAssertTrue(spoken.contains("50 percent of the compaction budget"), spoken)
        XCTAssertTrue(spoken.contains("13 percent of the model window"), spoken)
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
