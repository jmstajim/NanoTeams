import XCTest

@testable import NanoTeams

/// `AutovisorGoalLintCopy` — the pure findings → (symbol, copy, label) mapping
/// behind the ⓘ beside every **Goal** label.
///
/// The view around it is a `Button` + `.popover`, which XCTest cannot render, so
/// the mapping is extracted here and the tint ternary is left untested (one line,
/// and `Colors` resolution is already covered elsewhere).
final class AutovisorGoalLintCopyTests: XCTestCase {

    private func tool(_ token: String, line: Int = 1) -> AutovisorGoalLint.Finding {
        AutovisorGoalLint.Finding(token: token, line: line, kind: .unavailableTool)
    }

    private func buildClaim(_ token: String = "build", line: Int = 1) -> AutovisorGoalLint.Finding {
        AutovisorGoalLint.Finding(token: token, line: line, kind: .selfDirectedBuildClaim)
    }

    // MARK: - Clean state

    /// The neutral tip is capability info ONLY — no goal-specific sentence, and
    /// no paragraph break to make room for one.
    func testNoFindings_popoverIsTheCapabilityLineAlone() {
        let popover = AutovisorGoalLintCopy.popover(for: [])
        XCTAssertEqual(popover, AutovisorGoalLintCopy.capability)
        XCTAssertFalse(popover.contains("This goal"))
        XCTAssertFalse(popover.contains("\n\n"))
        XCTAssertNil(AutovisorGoalLintCopy.detail(for: []))
    }

    /// The capability line must not leave the reader at a dead end: it names the
    /// gap AND where the missing half actually happens.
    func testCapability_namesDelegationAsTheResolution() {
        XCTAssertTrue(AutovisorGoalLintCopy.capability.contains("delegates to"),
                      "a bare limitation with no resolution is the defect this sentence fixes")
    }

    /// The copy is HAND-WRITTEN prose about a DERIVED toolset, so nothing corrects
    /// it when the toolset moves — and in 1.8.4 it did: admitting the Xcode runners
    /// left this sentence telling users the manager "has no shell, write or build
    /// tools" while its own prompt instructed it to build. Every other test in this
    /// file compares the copy to itself, which is exactly why the whole suite stayed
    /// green through that.
    ///
    /// So: derive the PREMISES from `managerDefaultToolIDs` and assert the prose
    /// against them. If a premise ever flips, it fails HERE, naming the sentence to
    /// rewrite, instead of shipping a confident falsehood in the first-run UI.
    /// Checks POLARITY, not presence. The first cut of this test asserted only
    /// `copy.contains("build")` and passed against the very sentence it was written
    /// to reject — "it has no shell, write or **build** tools" contains the word
    /// while asserting the opposite. So split the sentence at its own hinge and
    /// require each capability to sit on the correct side of it.
    func testCapabilityCopy_agreesWithTheManagersActualToolset() {
        let has = Set(AutovisorConstants.managerDefaultToolIDs)
        let copy = AutovisorGoalLintCopy.capability.lowercased()

        let halves = copy.components(separatedBy: "it has no")
        guard halves.count == 2 else {
            return XCTFail("`capability` must state absences as \"it has no …\" — that hinge is "
                + "what lets this test tell a capability from a denial:\n\(copy)")
        }
        let can = halves[0], cannot = halves[1]

        XCTAssertTrue(has.contains(ToolNames.runXcodebuild),
                      "premise: the manager CAN build — if this flips, rewrite `capability`")
        XCTAssertTrue(can.contains("build"),
                      "the manager builds, so building belongs on the CAN side of the sentence")
        XCTAssertFalse(cannot.contains("build"),
                       "…and must not be listed among the things it lacks")

        XCTAssertFalse(has.contains(ToolNames.bash),
                       "premise: the manager has NO shell — if this flips, rewrite `capability`")
        XCTAssertTrue(cannot.contains("shell"), "a real gap the user might ask for must be named")

        XCTAssertFalse(has.contains(ToolNames.writeFile),
                       "premise: the manager cannot write — if this flips, rewrite `capability`")
        XCTAssertTrue(cannot.contains("write"), "…same for writes")
    }

    func testNoFindings_usesTheNeutralSymbol() {
        XCTAssertEqual(AutovisorGoalLintCopy.symbolName(for: []), "info.circle")
    }

    // MARK: - Warning state

    func testFindings_switchSymbolAndAppendExactlyOneParagraph() {
        let popover = AutovisorGoalLintCopy.popover(for: [tool("write_file")])

        XCTAssertEqual(AutovisorGoalLintCopy.symbolName(for: [tool("write_file")]),
                       "exclamationmark.triangle")
        XCTAssertTrue(popover.hasPrefix(AutovisorGoalLintCopy.capability),
                      "the capability line stays first — the warning is additive")
        XCTAssertEqual(popover.components(separatedBy: "\n\n").count, 2,
                       "exactly one paragraph break between capability and detail")
    }

    /// The phrase rule catches goals that name no tool at all, so its wording has
    /// to describe the behaviour rather than list identifiers.
    func testOnlyBuildClaims_usesTheProseBranchAndNamesNoToken() {
        let detail = AutovisorGoalLintCopy.detail(for: [buildClaim(), buildClaim("compile", line: 2)])
        XCTAssertEqual(detail, "This goal tells it to build or run something itself. "
            + "If that's meant for the teams it delegates to, say so in the goal.")
    }

    /// One offender named on three lines is still ONE name in a 240pt popover.
    func testToolFindings_namesAreDedupedAndSorted() {
        let detail = AutovisorGoalLintCopy.detail(for: [
            tool("write_file", line: 1),
            tool("bash", line: 2),
            tool("write_file", line: 3),
        ])
        XCTAssertEqual(detail, "This goal names bash, write_file. "
            + "If that's meant for the teams it delegates to, you can ignore this.")
    }

    /// The truncation branch: first three SORTED names, then the overflow marker.
    func testToolFindings_moreThanThree_truncatesAfterTheFirstThreeSorted() {
        let detail = AutovisorGoalLintCopy.detail(for: [
            tool("write_file"), tool("bash"), tool("git_commit"),
            tool("delete_file"), tool("run_xcodebuild"),
        ])
        XCTAssertEqual(detail, "This goal names bash, delete_file, git_commit, …. "
            + "If that's meant for the teams it delegates to, you can ignore this.")
    }

    /// Exactly three must NOT get the overflow marker (the off-by-one either way).
    func testToolFindings_exactlyThree_carriesNoOverflowMarker() {
        let detail = AutovisorGoalLintCopy.detail(for: [
            tool("write_file"), tool("bash"), tool("git_commit"),
        ])
        XCTAssertEqual(detail, "This goal names bash, git_commit, write_file. "
            + "If that's meant for the teams it delegates to, you can ignore this.")
    }

    /// Precedence: a concrete tool name is more actionable than the prose rule,
    /// so a mixed finding set takes the token branch.
    func testMixedFindings_preferTheTokenBranch() {
        let detail = AutovisorGoalLintCopy.detail(for: [buildClaim(), tool("bash", line: 2)])
        XCTAssertEqual(detail, "This goal names bash. "
            + "If that's meant for the teams it delegates to, you can ignore this.")
    }

    // MARK: - Accessibility

    /// The icon IS the whole affordance now, so its label carries the state that
    /// the tint conveys visually.
    func testAccessibilityLabel_differsByStateAndIsNeverEmpty() {
        let clean = AutovisorGoalLintCopy.accessibilityLabel(for: [])
        let warning = AutovisorGoalLintCopy.accessibilityLabel(for: [tool("bash")])

        XCTAssertFalse(clean.isEmpty)
        XCTAssertFalse(warning.isEmpty)
        XCTAssertNotEqual(clean, warning)
    }

    // MARK: - End to end through the real lint

    /// Pins the mapping against `scanUserAuthored` rather than hand-built findings,
    /// so a change to the scan's output shape surfaces here too.
    func testRealGoalText_flowsThroughToTheWarningState() {
        let clean = AutovisorGoalLint.scanUserAuthored(
            "Keep the test suite green and report findings.")
        let offending = AutovisorGoalLint.scanUserAuthored(
            "Then call write_file to save the report.")

        XCTAssertEqual(AutovisorGoalLintCopy.symbolName(for: clean), "info.circle")
        XCTAssertEqual(AutovisorGoalLintCopy.symbolName(for: offending),
                       "exclamationmark.triangle")
        XCTAssertTrue(AutovisorGoalLintCopy.popover(for: offending).contains("write_file"))
    }
}
