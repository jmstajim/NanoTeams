import XCTest

@testable import NanoTeams

/// Pure rule-engine tests for `BashPermissionService` — deny > ask > allow,
/// read-only bypass, word-boundary program matching, compound-command splitting,
/// glob/literal rules, and wrapper stripping.
final class BashPermissionServiceTests: XCTestCase {

    /// Defaults to `.semiAutomatic` — the rule-driven mode (deny > ask > allow >
    /// read-only bypass > default-ask) that most of these cases exercise. The
    /// stricter `.manual` (always confirm) mode is covered in its own section.
    private func policy(
        mode: BashExecutionMode = .semiAutomatic,
        restriction: BashRestrictionLevel = BashConstants.defaultRestrictionLevel,
        allow: [String] = [],
        ask: [String] = [],
        deny: [String] = []
    ) -> BashPolicy {
        BashPolicy(mode: mode, restrictionLevel: restriction, allowRules: allow, askRules: ask, denyRules: deny)
    }

    private func isAllow(_ d: BashPermissionDecision) -> Bool { d == .allow }
    private func isDeny(_ d: BashPermissionDecision) -> Bool {
        if case .deny = d { return true }; return false
    }
    private func isAsk(_ d: BashPermissionDecision) -> Bool {
        if case .ask = d { return true }; return false
    }

    // MARK: - Mode

    func testModeOff_deniesEverything() {
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "ls", policy: policy(mode: .off))))
    }

    func testEmptyCommand_denied() {
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "   ", policy: policy())))
    }

    // MARK: - Manual (always confirm)

    func testManualMode_readOnlyCommand_asksInsteadOfAllow() {
        // The read-only auto-allow is intentionally skipped in always-confirm mode —
        // even `ls` must be approved each time.
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(command: "ls -la", policy: policy(mode: .manual))))
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(command: "cat file.txt", policy: policy(mode: .manual))))
    }

    func testManualMode_allowRule_stillAsks() {
        // An explicit allow rule does NOT short-circuit in always-confirm mode.
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(
            command: "make build", policy: policy(mode: .manual, allow: ["make"]))))
    }

    func testManualMode_unknownCommand_asks() {
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(command: "make install", policy: policy(mode: .manual))))
    }

    func testManualMode_denyRuleStillWins() {
        // Deny rules are the ONLY thing that acts silently in always-confirm mode.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "rm -rf /", policy: policy(mode: .manual, deny: ["rm"]))))
        // …and a denied read-only command (deny > the always-confirm ask) denies, not asks.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "ls -la", policy: policy(mode: .manual, deny: ["ls"]))))
    }

    func testManualMode_emptyCommandStillDenied() {
        // The empty-command guard precedes the always-confirm short-circuit.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "   ", policy: policy(mode: .manual))))
    }

    func testManualMode_compoundCommand_denySegmentStillWins() {
        // Deny is evaluated per-segment BEFORE the always-confirm short-circuit, so a
        // denied program smuggled into a later segment still denies (not just asks).
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "cat x && rm -rf /", policy: policy(mode: .manual, deny: ["rm"]))))
    }

    func testManualMode_allReadOnlyCompound_asks() {
        // Every segment read-only, but always-confirm still asks (no read-only bypass).
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(
            command: "cat x && grep y z", policy: policy(mode: .manual))))
    }

    func testManualMode_askRule_asks() {
        // An ask rule and the always-confirm default agree — still asks.
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(
            command: "npm test", policy: policy(mode: .manual, ask: ["npm"]))))
    }

    // MARK: - Judge strictness Off (mirrors ComputerUsePermissionServiceTests' Safety-Off quartet)

    func testJudgeOff_autoMode_unknownCommand_allows() {
        // Off disables the judge: in Auto mode an unknown command that survives the
        // deny rules runs without review instead of routing to the (disabled) judge.
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(
            command: "make install", policy: policy(mode: .auto, restriction: .off))))
    }

    func testJudgeOff_autoMode_denyRuleStillDenies() {
        // Deny rules are ABOVE the off short-circuit — Off never bypasses them.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "rm -rf /", policy: policy(mode: .auto, restriction: .off, deny: ["rm"]))))
        // …including a denied program smuggled into a later segment.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "cat x && rm -rf /", policy: policy(mode: .auto, restriction: .off, deny: ["rm"]))))
    }

    func testJudgeOff_autoMode_askRuleBypassed() {
        // Decision pin: Off means NO review at all in Auto — a custom ask rule is
        // moot (it exists to route a command to review; with the judge off there is
        // no reviewer). Only deny rules act. Mirrors CU's "hard denies only".
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(
            command: "npm publish", policy: policy(mode: .auto, restriction: .off, ask: ["npm"]))))
    }

    func testJudgeOff_manualMode_stillAsks() {
        // The strictness picker is meaningful only for Auto verdicts — a stored
        // `.off` must never bypass the human approval Manual mode promises.
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(
            command: "make install", policy: policy(mode: .manual, restriction: .off))))
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(
            command: "ls -la", policy: policy(mode: .manual, restriction: .off))))
    }

    func testJudgeOff_semiAutomaticMode_unknownCommand_stillAsks() {
        // Semi-automatic routes "ask" outcomes to the human, not the judge — Off
        // (a judge setting) must not swallow that ask.
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(
            command: "make install", policy: policy(mode: .semiAutomatic, restriction: .off))))
    }

    func testJudgeOff_modeOff_stillDeniesEverything() {
        // The mode master switch outranks the strictness level.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "ls", policy: policy(mode: .off, restriction: .off))))
    }

    func testJudgeOff_autoMode_emptyCommand_stillDenied() {
        // The empty-command guard precedes the off short-circuit.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "   ", policy: policy(mode: .auto, restriction: .off))))
    }

    // MARK: - Precedence: deny > ask > allow

    func testDenyBeatsAllowAndReadOnly() {
        // "ls" is read-only and allow-listed, but a deny rule wins.
        let d = BashPermissionService.evaluate(
            command: "ls -la", policy: policy(allow: ["ls"], deny: ["ls"]))
        XCTAssertTrue(isDeny(d))
    }

    func testAskBeatsAllow() {
        let d = BashPermissionService.evaluate(
            command: "npm test", policy: policy(allow: ["npm"], ask: ["npm"]))
        XCTAssertTrue(isAsk(d))
    }

    func testAllowRule_allows() {
        let d = BashPermissionService.evaluate(command: "make build", policy: policy(allow: ["make"]))
        XCTAssertTrue(isAllow(d))
    }

    // MARK: - Read-only bypass

    func testReadOnlyCommand_allowed() {
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(command: "ls -la", policy: policy())))
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(command: "cat file.txt", policy: policy())))
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(command: "grep foo src | head", policy: policy())))
    }

    func testReadOnlyWithRedirection_notBypassed() {
        // `echo` is read-only but `> file` writes — must NOT bypass.
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(command: "echo hi > out.txt", policy: policy())))
    }

    func testReadOnlyWithCommandSubstitution_notBypassed() {
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(command: "cat $(whoami).txt", policy: policy())))
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(command: "echo `rm -rf x`", policy: policy())))
    }

    func testUnknownCommand_defaultsToAsk() {
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(command: "make install", policy: policy())))
    }

    func testSudoIsNotReadOnly() {
        // `sudo ls` resolves to program `sudo`, not `ls` → not read-only → ask.
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(command: "sudo ls", policy: policy())))
    }

    // MARK: - Word-boundary program matching

    func testBareRule_matchesProgramNotPrefix() {
        // deny "ls" must match `ls -la` but NOT `lsof`.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "ls -la", policy: policy(deny: ["ls"]))))
        let lsof = BashPermissionService.evaluate(command: "lsof -i", policy: policy(deny: ["ls"]))
        XCTAssertFalse(isDeny(lsof), "deny rule 'ls' must not match program 'lsof'")
    }

    func testBareRule_matchesBasenameOfAbsolutePath() {
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "/bin/rm -rf x", policy: policy(deny: ["rm"]))))
    }

    // MARK: - Glob & literal rules

    func testGlobRule_prefixMatch() {
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "rm -rf /tmp/x", policy: policy(deny: ["rm -rf *"]))))
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "git push origin main", policy: policy(deny: ["git push*"]))))
    }

    func testGlob_ls_doesNotMatch_lsof() {
        // The documented `ls *` ≠ `lsof` corner.
        let lsof = BashPermissionService.evaluate(command: "lsof", policy: policy(deny: ["ls *"]))
        XCTAssertFalse(isDeny(lsof))
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "ls -la", policy: policy(deny: ["ls *"]))))
    }

    func testLiteralPhraseRule_wordBoundary() {
        // Use a DENY rule: an unmatched ASK rule would be indistinguishable from
        // the default `.ask` for an unknown command, so deny is the clean probe.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "git push origin", policy: policy(deny: ["git push"]))))
        // "git pushx" must NOT match the literal "git push".
        let pushx = BashPermissionService.evaluate(command: "git pushx", policy: policy(deny: ["git push"]))
        XCTAssertFalse(isDeny(pushx))
    }

    // MARK: - Compound splitting & wrapper stripping

    func testCompoundCommand_denyMatchesAnySegment() {
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "cat x && rm -rf /", policy: policy(deny: ["rm"]))))
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "echo hi; sudo reboot", policy: policy(deny: ["sudo"]))))
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "ls | xargs rm", policy: policy(deny: ["xargs"]))))
    }

    func testEnvAssignmentStripped_forProgramMatch() {
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "FOO=bar npm publish", policy: policy(deny: ["npm"]))))
    }

    func testQuotedSeparatorNotSplit() {
        // `;` inside quotes must not split the command.
        let d = BashPermissionService.evaluate(command: "echo 'a ; b'", policy: policy(deny: ["b"]))
        XCTAssertFalse(isDeny(d), "a separator inside quotes must not create a phantom 'b' segment")
    }

    // MARK: - Allow rules vs command substitution

    func testBareAllowRule_doesNotVouchForCommandSubstitution() {
        // allow "echo" must NOT let `echo $(rm -rf x)` smuggle `rm` — the bare
        // program rule only speaks for `echo`, not the nested command.
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(
            command: "echo $(rm -rf x)", policy: policy(allow: ["echo"]))))
        // Backtick substitution is treated the same.
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(
            command: "echo `whoami`", policy: policy(allow: ["echo"]))))
    }

    func testBareAllowRule_plainCommandStillAllows() {
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(
            command: "echo hello", policy: policy(allow: ["echo"]))))
    }

    func testDenyStillWinsOverSubstitution() {
        // The substitution carve-out only suppresses ALLOW; a deny on the outer
        // program still denies.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "echo $(date)", policy: policy(deny: ["echo"]))))
    }

    func testPhraseAllowRule_vouchesForSubstitution() {
        // A multi-word literal allow rule is specific intent (this is also the
        // shape an "always allow <command>" approval persists), so it still allows
        // even with substitution present.
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(
            command: "echo hi $(date)", policy: policy(allow: ["echo hi"]))))
    }

    // MARK: - Allow rules for COMPOUND commands ("always allow" of a multi-segment command)

    func testCompoundAllowRule_exactWholeCommand_allows() {
        // "Always allow" of a compound command persists the verbatim command as a
        // multi-word rule. None of its segments (`cd app`, `npm test`) equal the
        // whole rule, so only a WHOLE-COMMAND exact match can re-approve it —
        // without that the command re-prompts on EVERY emission despite "always".
        let p = policy(mode: .semiAutomatic, allow: ["cd app && npm test"])
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(command: "cd app && npm test", policy: p)))
    }

    func testCompoundAllowRule_pipeline_exactWholeCommand_allows() {
        let p = policy(mode: .semiAutomatic, allow: ["grep foo src | sort | uniq -c"])
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(
            command: "grep foo src | sort | uniq -c", policy: p)))
    }

    func testCompoundAllowRule_caseInsensitiveExact_allows() {
        // Whole-command exact match is case-insensitive, like the rest of the layer.
        let p = policy(mode: .semiAutomatic, allow: ["cd App && NPM Test"])
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(command: "cd app && npm test", policy: p)))
    }

    func testCompoundAllowRule_appendedSegment_doesNotSmuggle() {
        // The whole-command match must be EXACT, never a prefix — otherwise
        // `<allowed compound> && rm -rf ~` would ride in on the allow.
        let p = policy(mode: .semiAutomatic, allow: ["cd app && npm test"])
        let d = BashPermissionService.evaluate(command: "cd app && npm test && rm -rf ~", policy: p)
        XCTAssertFalse(isAllow(d), "an appended segment must not be allowed by the exact compound rule")
    }

    func testCompoundAllowRule_denySegmentStillWins() {
        // Deny precedence is unaffected: a deny-matched segment in an otherwise
        // exactly-allowed compound still denies (deny is evaluated before allow).
        let p = policy(mode: .semiAutomatic, allow: ["cd app && rm -rf build"], deny: ["rm"])
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "cd app && rm -rf build", policy: p)))
    }

    func testSingleSegmentPrefixAllowRule_stillMatches() {
        // Regression: the whole-command exact addition must not break the existing
        // per-segment prefix match for a single-segment multi-word rule.
        let p = policy(mode: .semiAutomatic, allow: ["git push"])
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(command: "git push origin main", policy: p)))
    }

    func testCompoundAllowRule_internalWhitespaceVariation_stillAllows() {
        // "Always allow" persists the verbatim command; a re-emission with different
        // internal whitespace (extra spaces, a newline) must still match — the
        // whole-command compare normalizes whitespace (same as decisionKey), so an
        // always-allowed compound command doesn't re-prompt over cosmetic spacing.
        let p = policy(mode: .semiAutomatic, allow: ["cd app && npm test"])
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(command: "cd  app  &&  npm  test", policy: p)))
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(command: "cd app &&\nnpm test", policy: p)))
        // The normalization must NOT defeat the no-smuggling guard.
        XCTAssertFalse(isAllow(BashPermissionService.evaluate(
            command: "cd  app  &&  npm  test  &&  rm -rf ~", policy: p)))
    }

    // MARK: - decisionKey

    func testDecisionKey_normalizesWhitespace() {
        XCTAssertEqual(
            BashPermissionService.decisionKey(for: "  ls   -la \n"),
            BashPermissionService.decisionKey(for: "ls -la"))
    }

    func testDecisionKey_isCaseInsensitive() {
        // Case-folded so a recorded one-shot decision is consumed when the model
        // re-emits the same command with different casing (consistent with the
        // case-insensitive rule layer).
        XCTAssertEqual(
            BashPermissionService.decisionKey(for: "RM -rf Foo"),
            BashPermissionService.decisionKey(for: "rm -rf foo"))
    }

    // MARK: - Rule list hygiene

    func testRuleWhitespaceTrimmed_blankSkipped() {
        // `firstMatch` trims each rule then skips blank ones. A whitespace-PADDED rule
        // must still match (trimmed to `rm`) — discriminating, since an untrimmed
        // "  rm  " would match no program. A truly blank rule blocks nothing.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "rm -rf /", policy: policy(deny: ["  rm  "]))),
        "a padded deny rule must be trimmed and still match")
        XCTAssertFalse(isDeny(BashPermissionService.evaluate(
            command: "rm -rf /", policy: policy(deny: ["", "   ", "\n"]))),
        "blank deny rules must not block a command")
    }

    // MARK: - Segment splitting edges

    func testNewlineSeparator_splitsAndDeniesSegment() {
        // A newline is a segment separator too, so a deny rule must catch a program
        // smuggled onto a second line.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "echo a\nrm -rf /", policy: policy(deny: ["rm"]))))
    }

    func testEscapedSeparator_doesNotSplit() {
        // A backslash-escaped `;` is literal, not a separator — `echo a\; echo b` stays
        // ONE segment, so there is no standalone `echo b` segment. Probe with the
        // multi-word literal deny `echo b` (matches only a standalone `echo b` segment):
        // it must NOT fire. Discriminating — a regression that split on `\;` WOULD
        // create an `echo b` segment and trip this deny.
        let d = BashPermissionService.evaluate(
            command: #"echo a\; echo b"#, policy: policy(deny: ["echo b"]))
        XCTAssertFalse(isDeny(d), "an escaped separator must not create a standalone 'echo b' segment")
    }

    func testConsecutiveSeparators_dropEmptySegments() {
        // `;;` yields an empty middle segment which splitSegments must drop. Assert the
        // split DIRECTLY — an undropped empty segment changes the result (the indirect
        // "rm is denied" check would pass either way, since leadingProgram("") is "").
        XCTAssertEqual(
            BashPermissionService.splitSegments("cat x ;; rm -rf /"),
            ["cat x", "rm -rf /"])
    }

    // MARK: - Glob metacharacter safety

    func testGlobMetacharsAreLiteral() {
        // A `.` in a glob rule must match a literal dot, NOT "any character" — otherwise
        // `cat *.txt` would also match `cat aXtxt`.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "cat a.txt", policy: policy(deny: ["cat *.txt"]))))
        let xtxt = BashPermissionService.evaluate(command: "cat aXtxt", policy: policy(deny: ["cat *.txt"]))
        XCTAssertFalse(isDeny(xtxt), "the '.' in a glob must be literal, not a regex wildcard")
    }

    func testGlobRule_matchesSegmentOfCompound() {
        // A glob is tested against the whole command AND each segment, so it catches a
        // matching program smuggled into a later segment of a compound command — even
        // when the command as a whole doesn't start with the glob's prefix.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "cat x && rm -rf /tmp/y", policy: policy(deny: ["rm -rf *"]))))
        // And a glob that matches NO segment does not fire.
        let safe = BashPermissionService.evaluate(
            command: "cat x && grep y z", policy: policy(deny: ["rm -rf *"]))
        XCTAssertFalse(isDeny(safe), "a glob matching no segment must not deny")
    }

    // MARK: - Program extraction edges

    func testQuotedEnvAssignmentWithSpace_programResolves() {
        // A quoted env value containing a space stays one token, so the leading program
        // after stripping assignments is `rm` — a deny rule must still match.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: #"FOO="a b" rm -rf x"#, policy: policy(deny: ["rm"]))))
    }

    func testEnvIsLeadingProgram_notReadOnly() {
        // `env` is NOT stripped (it IS the effective program) and is not in the
        // read-only set, so `env FOO=x rm` falls through to review, not auto-allow.
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(command: "env FOO=x rm", policy: policy())))
        // And a deny rule on `env` matches it.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "env FOO=x rm", policy: policy(deny: ["env"]))))
    }

    func testSudoDenyRule_matchesSudoSegment() {
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(
            command: "sudo rm -rf /", policy: policy(deny: ["sudo"]))))
    }

    func testPureEnvAssignment_noProgram_asks() {
        // A command that is ONLY an env assignment has no program → not read-only,
        // not matched by any rule → default ask.
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(command: "FOO=bar", policy: policy())))
    }

    // MARK: - Read-only classification edges

    func testReadOnlyBypass_isCaseInsensitive() {
        // The read-only auto-allow folds case like the rule layer: `LS`/`CAT` resolve
        // to /bin/ls, /bin/cat on macOS, so they auto-allow just like the lowercase form.
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(command: "LS -la", policy: policy())))
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(command: "CAT file.txt", policy: policy())))
        // …but folding must not OVER-allow: an uppercased NON-read-only program (`MAKE`
        // is not in the read-only set) still requires review.
        XCTAssertTrue(isAsk(BashPermissionService.evaluate(command: "MAKE install", policy: policy())))
    }

    func testInputRedirect_doesNotDisqualifyReadOnly() {
        // Only OUTPUT redirection (`>`) disqualifies the read-only bypass; an input
        // redirect (`<`) is a read and stays allowed. Documents the `<`/`>` asymmetry.
        XCTAssertTrue(isAllow(BashPermissionService.evaluate(command: "cat < file.txt", policy: policy())))
    }

    // MARK: - Case-insensitive rule matching (Finding F1)

    func testRuleMatching_isCaseInsensitive() {
        // macOS's case-insensitive filesystem resolves `RM` → /bin/rm, so a deny rule
        // `rm` MUST still block `RM -rf /` — otherwise the explicit deny is silently
        // downgraded to a review (deny → ask). Program, glob, and multi-word literal
        // rules all match case-insensitively.
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "RM -rf /", policy: policy(deny: ["rm"]))))
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "rm -rf /", policy: policy(deny: ["RM"]))))
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "GIT PUSH origin", policy: policy(deny: ["git push*"]))))
        XCTAssertTrue(isDeny(BashPermissionService.evaluate(command: "GIT PUSH origin", policy: policy(deny: ["git push"]))))
        // The word-boundary guard still holds across cases: deny `ls` ≠ `LSOF`.
        XCTAssertFalse(isDeny(BashPermissionService.evaluate(command: "LSOF -i", policy: policy(deny: ["ls"]))))
    }
}
