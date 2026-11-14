import XCTest

@testable import NanoTeams

/// Pins the relevance-gating of `BashSettingsView` sections per execution mode.
/// `Off` hides every policy section (judge, sandbox, rules); they are shown for
/// both `Manual` and `Auto`.
final class BashSettingsVisibilityTests: XCTestCase {

    func testPolicySections_shownForManualAndAuto_hiddenForOff() {
        XCTAssertFalse(BashSettingsVisibility.showsPolicySections(mode: .off))
        XCTAssertTrue(BashSettingsVisibility.showsPolicySections(mode: .manual))
        XCTAssertTrue(BashSettingsVisibility.showsPolicySections(mode: .auto))
    }

    func testBashSettingsView_rulesHelpText_explainsPrefixMatchingAndFullPath() {
        let text = BashSettingsView.rulesHelpText
        XCTAssertTrue(text.contains("prefix"), "Rules copy must mention prefix matching: \(text)")
        XCTAssertTrue(text.contains("PATH"), "Rules copy must mention commands outside PATH: \(text)")
        XCTAssertTrue(text.contains("jsc"), "Rules copy must mention jsc example: \(text)")
    }

    /// F6 L3 (2026-11-12): an allow rule covers only the part of a compound command it
    /// matches, and the person writing rules has to know that, or `touch probe/*` reads as
    /// permission for `touch probe/a; touch elsewhere`.
    func testBashSettingsView_rulesHelpText_saysAllowMustCoverEveryPart() {
        let text = BashSettingsView.rulesHelpText
        XCTAssertTrue(text.contains("every part"), "Rules copy must say allow covers every part: \(text)")
        XCTAssertTrue(text.contains("any part"), "Rules copy must say deny and ask fire on any part: \(text)")
    }

    func testBashSettingsView_judgeModelOverrideHelpText_distinguishesRoleModelFallback() {
        let text = BashSettingsView.judgeModelOverrideHelpText
        XCTAssertTrue(text.contains("role"), "Must clarify fallback to role model: \(text)")
        XCTAssertFalse(text.contains("global LLM configuration"), "Must not claim global LLM fallback for role gate: \(text)")
    }

    /// The help the card is built from, `rulesHelp`, parses its Markdown — code spans and the
    /// strong precedence, no backtick or asterisk left in the text. Red if the property stops
    /// parsing (`AttributedString(rulesHelpText)`, F6 T12). It does NOT see what the card draws:
    /// a card that went back to `Text(Self.rulesHelpText)` keeps this green, and
    /// `BashSettingsRulesCardRenderTests` reads the rendered card for that (E1 review R6).
    func testRulesHelp_isShownWithItsMarkdownRendered() {
        let shown = BashSettingsView.rulesHelp
        let plain = String(shown.characters)
        XCTAssertFalse(plain.contains("`"), plain)
        XCTAssertFalse(plain.contains("**"), plain)
        func spans(_ intent: InlinePresentationIntent) -> [String] {
            shown.runs.filter { $0.inlinePresentationIntent?.contains(intent) == true }
                .map { String(shown[$0.range].characters) }
        }
        XCTAssertEqual(Array(spans(.code).prefix(4)), ["rm", "rm -rf x", "rmdir", "*"])
        XCTAssertTrue(spans(.code).contains("jsc"), "\(spans(.code))")
        XCTAssertEqual(spans(.stronglyEmphasized), ["deny → ask → allow"])
    }
}
