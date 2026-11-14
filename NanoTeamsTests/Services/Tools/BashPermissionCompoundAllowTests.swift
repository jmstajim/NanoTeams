import XCTest

@testable import NanoTeams

/// The ALLOW tier of `BashPermissionService.evaluate` for compound commands (F6 L3, 2026-11-11).
///
/// Until then an allow rule that matched ONE segment of `a; b` allowed the whole line, and a glob
/// matched against the whole line covered every segment after its prefix. Live repro (AgentCheck,
/// task 14, Semi-automatic under the Autovisor): rule `touch probe/*`, command
/// `touch probe/allowed2.txt; touch smuggled.txt` ran with no human, and `smuggled.txt` was
/// created. The rule now: a compound line is allowed only when EVERY segment is covered — by an
/// allow rule matched against that segment, or by being read-only — or when the whole line is
/// verbatim an allow rule (the shape an "always" approval persists). Deny and ask are unchanged.
final class BashPermissionCompoundAllowTests: XCTestCase {

    private func policy(allow: [String] = [], ask: [String] = [], deny: [String] = []) -> BashPolicy {
        BashPolicy(mode: .semiAutomatic, restrictionLevel: BashConstants.defaultRestrictionLevel,
                   allowRules: allow, askRules: ask, denyRules: deny)
    }

    private func decide(_ command: String, allow: [String] = [], deny: [String] = []) -> BashPermissionDecision {
        BashPermissionService.evaluate(command: command, policy: policy(allow: allow, deny: deny))
    }

    private func isAsk(_ d: BashPermissionDecision) -> Bool {
        if case .ask = d { return true }; return false
    }

    private func isDeny(_ d: BashPermissionDecision) -> Bool {
        if case .deny = d { return true }; return false
    }

    // MARK: - An uncovered segment asks

    func testLiveRepro_globCoversFirstSegmentOnly_asks() {
        XCTAssertTrue(isAsk(decide("touch probe/allowed2.txt; touch smuggled.txt", allow: ["touch probe/*"])),
                      "the glob covers the first segment only; the second must reach a human")
    }

    func testBareProgramRuleCoversOneSegment_asks() {
        XCTAssertTrue(isAsk(decide("make build && npm publish", allow: ["make"])))
    }

    func testPhraseRuleCoversOneSegment_asks() {
        XCTAssertTrue(isAsk(decide("npm test && rm -rf build", allow: ["npm test"])))
    }

    func testGlobIsMatchedPerSegment_notAgainstTheWholeLine() {
        // `cd app*` matched the whole line before — `.*` swallowed `&& rm -rf ~`.
        XCTAssertTrue(isAsk(decide("cd app && rm -rf ~", allow: ["cd app*"])))
        // …and a glob that only a whole-line match could satisfy covers no segment.
        XCTAssertTrue(isAsk(decide("make && rm -rf x", allow: ["make*rm*"])))
    }

    // MARK: - Every segment covered allows

    func testEverySegmentCoveredByRules_allows() {
        XCTAssertEqual(decide("make build && npm test", allow: ["make", "npm test"]), .allow)
        XCTAssertEqual(decide("touch probe/a; touch probe/b", allow: ["touch probe/*"]), .allow)
    }

    func testBareProgramRule_coversEverySegmentItLeads() {
        XCTAssertEqual(decide("git add -A && git commit -m wip", allow: ["git"]), .allow)
    }

    func testReadOnlySegmentNeedsNoRule() {
        XCTAssertEqual(decide("make build && ls -la", allow: ["make"]), .allow)
        XCTAssertEqual(decide("npm test | grep FAIL", allow: ["npm test"]), .allow)
    }

    func testReadOnlyProgramWithOutputRedirect_isNotCoverage() {
        XCTAssertTrue(isAsk(decide("make && cat x > y", allow: ["make"])))
    }

    func testAllReadOnly_noRules_stillAllows() {
        XCTAssertEqual(decide("ls -la | grep x && cat y"), .allow)
    }

    // MARK: - "Always" (verbatim whole line)

    func testAlwaysOfACompoundLine_allowsThatLine() {
        // Neither segment is covered on its own; the person approved exactly this line.
        XCTAssertEqual(decide("touch a.txt; touch b.txt", allow: ["touch a.txt; touch b.txt"]), .allow)
        XCTAssertEqual(decide("cd app && npm test", allow: ["cd app && npm test"]), .allow)
    }

    func testAlwaysOfACompoundLineWithoutSpaces_allowsThatLine() {
        // No space, no `*` — a bare-program-shaped rule; still the verbatim line.
        XCTAssertEqual(decide("make;make", allow: ["make;make"]), .allow)
        XCTAssertEqual(decide("touch a;touch b", allow: ["touch a;touch b"]), .allow)
    }

    func testAlwaysOfACompoundLine_doesNotCoverAnAppendedSegment() {
        XCTAssertTrue(isAsk(decide("touch a.txt; touch b.txt; rm -rf ~", allow: ["touch a.txt; touch b.txt"])))
    }

    func testAlwaysIsStillBehindDeny() {
        XCTAssertTrue(isDeny(decide("touch a; rm b", allow: ["touch a; rm b"], deny: ["rm"])))
    }

    // MARK: - Substitution and wrappers, as before

    func testBareRuleDoesNotVouchForSubstitution_inAnySegment() {
        XCTAssertTrue(isAsk(decide("make $(rm -rf x)", allow: ["make"])))
        XCTAssertTrue(isAsk(decide("make && echo $(rm -rf x)", allow: ["make"])))
        XCTAssertTrue(isAsk(decide("make && echo `whoami`", allow: ["make"])))
    }

    func testSubstitutionDisqualifiesReadOnlyCoverage() {
        // `echo` is read-only, but not with nested code on the line.
        XCTAssertTrue(isAsk(decide("npm test && echo $(rm -rf x)", allow: ["npm test"])))
    }

    func testBareRuleDoesNotVouchForAWrapperSegment() {
        XCTAssertTrue(isAsk(decide("make && sudo rm -rf x", allow: ["make", "sudo"])))
        XCTAssertTrue(isAsk(decide("make && timeout 5 rm -rf x", allow: ["make", "timeout"])))
    }

    func testPhraseRuleStillVouchesForSubstitutionInItsSegment() {
        XCTAssertEqual(decide("echo hi $(date)", allow: ["echo hi"]), .allow)
    }

    // MARK: - Redirects are not separators

    func testStderrRedirects_doNotSplit() {
        for line in ["npm test 2>&1", "npm test >&2", "npm test 1>&2", "npm test &> out.log",
                     "npm test &>> out.log", "npm test 2>&1 | tee log.txt"] {
            XCTAssertEqual(BashPermissionService.splitSegments(line).first, line.components(separatedBy: " | ").first,
                           "‘\(line)’ must not split on the `&` of a redirect")
        }
        XCTAssertEqual(BashPermissionService.splitSegments("npm test 2>&1"), ["npm test 2>&1"])
        XCTAssertEqual(BashPermissionService.splitSegments("cat x <&3"), ["cat x <&3"])
    }

    func testRedirectedCommand_coveredByItsRule_allows() {
        XCTAssertEqual(decide("npm test 2>&1", allow: ["npm test"]), .allow)
        XCTAssertEqual(decide("npm test &> out.log", allow: ["npm test"]), .allow)
        XCTAssertEqual(decide("npm test >&2", allow: ["npm test"]), .allow)
    }

    func testRedirectedCommand_thenUncoveredSegment_asks() {
        XCTAssertTrue(isAsk(decide("npm test 2>&1 && rm -rf x", allow: ["npm test"])))
        XCTAssertTrue(isAsk(decide("npm test &>out.log & rm -rf x", allow: ["npm test"])))
    }

    func testBackgroundAmpersand_stillSplits() {
        XCTAssertEqual(BashPermissionService.splitSegments("npm test & rm -rf x"), ["npm test", "rm -rf x"])
        XCTAssertEqual(BashPermissionService.splitSegments("make && rm x"), ["make", "rm x"])
        // `&&` is taken whole, as bash's tokenizer does: the `>log` after it is a redirect of
        // the next command, not an `&>` of this one.
        XCTAssertEqual(BashPermissionService.splitSegments("make &&>log rm"), ["make", ">log rm"])
    }

    func testRedirectAmpersand_doesNotHideASegmentFromDeny() {
        XCTAssertTrue(isDeny(decide("npm test 2>&1; rm -rf x", deny: ["rm"])))
        XCTAssertTrue(isDeny(decide("npm test &> log && rm -rf x", deny: ["rm"])))
    }

    func testEscapedGreaterThan_thenAmpersand_stillSplits() {
        // `\>` is a literal `>`, so the `&` after it is a real background separator.
        XCTAssertEqual(BashPermissionService.splitSegments(#"echo \>& rm -rf x"#), [#"echo \>"#, "rm -rf x"])
        XCTAssertTrue(isDeny(decide(#"echo \>& rm -rf x"#, deny: ["rm"])))
        XCTAssertTrue(isAsk(decide(#"echo \>& rm -rf x"#, allow: ["echo"])))
    }

    func testQuotedGreaterThan_thenAmpersand_stillSplits() {
        XCTAssertEqual(BashPermissionService.splitSegments(#"echo ">"& rm -rf x"#), [#"echo ">""#, "rm -rf x"])
    }

    // MARK: - A leading redirect does not hide the program

    func testLeadingRedirect_isSkippedToFindTheProgram() {
        XCTAssertEqual(BashPermissionService.leadingProgram(of: ">/tmp/x rm -rf y"), "rm")
        XCTAssertEqual(BashPermissionService.leadingProgram(of: "2>/dev/null rm -rf y"), "rm")
        XCTAssertEqual(BashPermissionService.leadingProgram(of: "> out rm -rf y"), "rm")
        XCTAssertEqual(BashPermissionService.leadingProgram(of: ">> out FOO=1 rm y"), "rm")
        XCTAssertEqual(BashPermissionService.leadingProgram(of: "<in cat"), "cat")
        XCTAssertEqual(BashPermissionService.leadingProgram(of: "&>log make"), "make")
        XCTAssertEqual(BashPermissionService.leadingProgram(of: ">"), "")
    }

    func testLeadingRedirect_doesNotHideAProgramFromDeny() {
        // bash runs `rm` here, with its stdout redirected; the deny rule must see it.
        XCTAssertTrue(isDeny(decide(">/tmp/x rm -rf ~", deny: ["rm"])))
        XCTAssertTrue(isDeny(decide("ls; 2>/dev/null rm -rf ~", deny: ["rm"])))
        XCTAssertTrue(isDeny(decide("ls && > out rm -rf ~", deny: ["rm"])))
    }

    func testLeadingRedirect_isStillNotReadOnly() {
        XCTAssertTrue(isAsk(decide(">/tmp/x ls")))
        XCTAssertEqual(decide("<in cat"), .allow)
    }

    // MARK: - Every separator

    func testEverySeparator_uncoveredSecondSegment_asks() {
        for sep in [" && ", " | ", "; ", " & ", " || ", "\n"] {
            XCTAssertTrue(isAsk(decide("make\(sep)rm -rf x", allow: ["make"])),
                          "separator ‘\(sep)’: the uncovered segment must ask")
        }
    }

    func testEverySeparator_bothSegmentsCovered_allows() {
        for sep in [" && ", " | ", "; ", " & ", " || ", "\n"] {
            XCTAssertEqual(decide("make\(sep)npm test", allow: ["make", "npm test"]), .allow,
                           "separator ‘\(sep)’: both segments covered must allow")
        }
    }

    // MARK: - Empty segments and quotes

    func testEmptySegments_areNotSegmentsToCover() {
        XCTAssertEqual(decide("make ;; make", allow: ["make"]), .allow)
        XCTAssertEqual(decide("; make", allow: ["make"]), .allow)
        XCTAssertEqual(decide("make ;", allow: ["make"]), .allow)
    }

    func testSeparatorOnly_isNotAllowed() {
        XCTAssertTrue(isAsk(decide(";", allow: ["make"])))
        XCTAssertTrue(isAsk(decide("&&", allow: ["make"])))
    }

    func testSeparatorInsideQuotes_isOneSegment() {
        XCTAssertEqual(decide("echo 'a; rm -rf x'", allow: ["echo"]), .allow)
        XCTAssertEqual(decide(#"git commit -m "fix; rm -rf x""#, allow: ["git commit"]), .allow)
        XCTAssertEqual(decide(#"git commit -m "a && b""#, allow: ["git commit"]), .allow)
    }

    func testAssignmentOnlySegment_isNotCovered() {
        // `PATH=/tmp/evil; make` changes what `make` resolves to; the rule names `make` only.
        XCTAssertTrue(isAsk(decide("PATH=/tmp/evil; make", allow: ["make"])))
    }

    // MARK: - Deny and ask are unchanged

    func testDenyAndAsk_stillMatchAnySegment() {
        XCTAssertTrue(isDeny(decide("make && rm -rf x", allow: ["make"], deny: ["rm"])))
        let askOne = BashPermissionService.evaluate(
            command: "make && curl x", policy: policy(allow: ["make", "curl"], ask: ["curl"]))
        XCTAssertTrue(isAsk(askOne))
        // A deny glob still matches against the whole line too.
        XCTAssertTrue(isDeny(decide("make && rm -rf x", deny: ["make*rm*"])))
    }
}
