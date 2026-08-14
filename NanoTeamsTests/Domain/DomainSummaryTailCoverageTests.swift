import XCTest

@testable import NanoTeams

/// Wave 10 — the two Domain projections that render a value for a human or for a prompt, and
/// whose last arm nothing entered.
///
/// Both are total functions over a shape the caller does not control: `RecurrenceRule.summary`
/// switches over four rule kinds, `derivedDescription` over three prompt shapes. In each case the
/// covered arms were the ones a test happens to construct, and the uncovered arm was the one a
/// USER produces.
final class DomainSummaryTailCoverageTests: XCTestCase {

    // MARK: - RecurrenceRule.summary

    /// `summary` is the schedule the user reads in the toolbar tooltip and the sidebar subtitle.
    /// `.once` is the arm that shows up the moment anyone schedules a one-off run — the other
    /// three had tests and it did not.
    ///
    /// Asserted through the rule's own date rather than a literal string: `formatted(date:time:)`
    /// is locale-dependent, so pinning the rendered text would make the test a locale assertion.
    /// What must hold is that the label says WHICH occurrence, i.e. that the date reaches it.
    ///
    /// RED: return a constant like "Once" from the `.once` arm → the year assertion fails and
    /// the distinctness assertion collapses two different dates onto one label.
    func testSummary_onceArm_namesItsDate() {
        var comps = DateComponents()
        comps.year = 2031
        comps.month = 4
        comps.day = 9
        comps.hour = 21
        comps.minute = 30
        let calendar = Calendar(identifier: .gregorian)
        guard let target = calendar.date(from: comps) else { return XCTFail("fixture date") }

        let summary = RecurrenceRule.once(date: target).summary
        XCTAssertTrue(summary.hasPrefix("Once on "), "got: \(summary)")
        XCTAssertTrue(summary.contains("2031"),
                      "the date must reach the label or the user cannot tell two one-offs apart; got: \(summary)")

        let other = RecurrenceRule.once(date: target.addingTimeInterval(86_400 * 400)).summary
        XCTAssertNotEqual(summary, other)

        // All four arms render, and render distinctly — the property the per-arm assert protects.
        let labels: Set<String> = [
            RecurrenceRule.interval(seconds: 3600).summary,
            RecurrenceRule.dailyAt(hour: 21, minute: 0, weekdays: []).summary,
            RecurrenceRule.monthlyAt(day: 1, hour: 21, minute: 0).summary,
            summary,
        ]
        XCTAssertEqual(labels.count, 4)
    }

    // MARK: - GeneratedTeamConfig.derivedDescription

    /// The description an auto-synthesized artifact stub carries into every downstream role's
    /// prompt when the team generator produced a role that names an artifact it never described.
    ///
    /// Three shapes, and the clipping one was untested. It is not the exotic case: a model writing
    /// a role prompt as one long unpunctuated instruction is exactly what small local models do,
    /// and without the clip that whole prompt would be pasted into the artifact catalogue of every
    /// consumer's system prompt.
    ///
    /// RED: drop the 80-char clip and return `prompt` → the length assertion fails, and in
    /// production the artifact description grows to the full role prompt.
    func testDerivedDescription_longPromptWithNoSentenceEnd_isClipped() {
        func role(_ prompt: String) -> GeneratedTeamConfig.RoleConfig {
            GeneratedTeamConfig.RoleConfig(
                name: "R", prompt: prompt,
                producesArtifacts: [], requiresArtifacts: [], tools: [])
        }

        // No terminator anywhere, 120 chars — the clipping arm.
        let long = String(repeating: "ab ", count: 40)
        let clipped = GeneratedTeamConfig.derivedDescription(producedBy: role(long))
        XCTAssertTrue(clipped.hasSuffix("…"), "got: \(clipped)")
        XCTAssertLessThanOrEqual(clipped.count, 81, "80 chars plus the ellipsis; got \(clipped.count)")
        XCTAssertTrue(long.hasPrefix(clipped.dropLast().trimmingCharacters(in: .whitespaces)))

        // The two arms that already had coverage, kept here so a change that merges them is
        // visible: short prompts pass through whole, and a real sentence wins over the clip.
        XCTAssertEqual(GeneratedTeamConfig.derivedDescription(producedBy: role("Short one")),
                       "Short one")
        XCTAssertEqual(
            GeneratedTeamConfig.derivedDescription(
                producedBy: role("Writes the deployment runbook. Then hands it over.")),
            "Writes the deployment runbook.")
        XCTAssertEqual(GeneratedTeamConfig.derivedDescription(producedBy: role("   ")), "")
    }
}
