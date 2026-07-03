import XCTest

@testable import NanoTeams

/// Pure decision-logic pins for the computer-use permission evaluator.
final class ComputerUsePermissionServiceTests: XCTestCase {

    private func policy(
        mode: ComputerUseMode = .manual,
        restriction: ComputerUseRestrictionLevel = .standard,
        allowlist: [String] = [],
        typing: [String] = [],
        keys: [String] = [],
        gateFirstCaptureOnly: Bool = true
    ) -> ComputerUsePolicy {
        ComputerUsePolicy(
            mode: mode, restrictionLevel: restriction,
            targetAppAllowlist: allowlist, blockedTypingPatterns: typing, blockedKeyCombos: keys,
            gateFirstCaptureOnly: gateFirstCaptureOnly)
    }

    private func input(
        _ action: ComputerUseAction,
        isSelf: Bool = false, allowed: Bool = true, session: Bool = false,
        bounds: Bool? = nil, captured: Bool = false
    ) -> ComputerUseEvalInput {
        ComputerUseEvalInput(
            action: action, isSelfTarget: isSelf, targetAllowedByAllowlist: allowed,
            sessionPreApproved: session, clickInBounds: bounds, captureAlreadyOccurredThisRun: captured)
    }

    private func isDeny(_ d: ComputerUsePermissionDecision) -> Bool { if case .deny = d { return true }; return false }
    private func isAsk(_ d: ComputerUsePermissionDecision) -> Bool { if case .ask = d { return true }; return false }
    private func isAllow(_ d: ComputerUsePermissionDecision) -> Bool { if case .allow = d { return true }; return false }

    func testSelfGuard_deniesInEveryMode() {
        let click = ComputerUseAction.click(x: 1, y: 1, button: "left", double: false, target: "NanoTeams")
        for mode: ComputerUseMode in [.off, .manual, .auto] {
            let d = ComputerUsePermissionService.evaluate(input(click, isSelf: true), policy: policy(mode: mode))
            XCTAssertTrue(isDeny(d), "self-target must deny in mode \(mode)")
        }
    }

    func testOutOfBounds_denies() {
        let click = ComputerUseAction.click(x: 9999, y: 9999, button: "left", double: false, target: nil)
        XCTAssertTrue(isDeny(ComputerUsePermissionService.evaluate(input(click, bounds: false), policy: policy())))
    }

    func testOff_deniesAll() {
        let click = ComputerUseAction.click(x: 1, y: 1, button: "left", double: false, target: nil)
        XCTAssertTrue(isDeny(ComputerUsePermissionService.evaluate(input(click, bounds: true), policy: policy(mode: .off))))
    }

    func testBlockedTypingPattern_denies() {
        let type = ComputerUseAction.typeText(text: "my password is hunter2", target: nil)
        let d = ComputerUsePermissionService.evaluate(input(type), policy: policy(typing: ["password"]))
        XCTAssertTrue(isDeny(d))
    }

    func testBlockedKeyCombo_denies() {
        let key = ComputerUseAction.pressKey(keys: "cmd+q", target: nil)
        let d = ComputerUsePermissionService.evaluate(input(key), policy: policy(keys: ["cmd\\+q"]))
        XCTAssertTrue(isDeny(d))
    }

    func testAllowlistViolation_denies() {
        let click = ComputerUseAction.click(x: 1, y: 1, button: "left", double: false, target: "SomeApp")
        let d = ComputerUsePermissionService.evaluate(input(click, allowed: false, bounds: true), policy: policy(allowlist: ["Safari"]))
        XCTAssertTrue(isDeny(d))
    }

    func testSessionPreApproved_allows() {
        let click = ComputerUseAction.click(x: 1, y: 1, button: "left", double: false, target: "Safari")
        let d = ComputerUsePermissionService.evaluate(input(click, session: true, bounds: true), policy: policy())
        XCTAssertTrue(isAllow(d))
    }

    func testFirstCapture_asksInManual_thenAllows() {
        let capture = ComputerUseAction.capture(target: "screen", windowTitle: nil)
        XCTAssertTrue(isAsk(ComputerUsePermissionService.evaluate(input(capture, captured: false), policy: policy())))
        XCTAssertTrue(isAllow(ComputerUsePermissionService.evaluate(input(capture, captured: true), policy: policy())))
    }

    func testCaptureInAuto_allowsWithoutJudge() {
        let capture = ComputerUseAction.capture(target: "screen", windowTitle: nil)
        XCTAssertTrue(isAllow(ComputerUsePermissionService.evaluate(input(capture), policy: policy(mode: .auto))))
    }

    func testAction_asksForHumanOrJudge() {
        let click = ComputerUseAction.click(x: 10, y: 10, button: "left", double: false, target: nil)
        XCTAssertTrue(isAsk(ComputerUsePermissionService.evaluate(input(click, bounds: true), policy: policy(mode: .manual))))
        XCTAssertTrue(isAsk(ComputerUsePermissionService.evaluate(input(click, bounds: true), policy: policy(mode: .auto))))
    }

    // MARK: - Precedence & ordering corners

    private func reason(_ d: ComputerUsePermissionDecision) -> String? {
        switch d {
        case .deny(let r), .ask(let r): return r
        case .allow: return nil
        }
    }

    func testSelfGuard_winsOverOffMode() {
        let click = ComputerUseAction.click(x: 1, y: 1, button: "left", double: false, target: "NanoTeams")
        let d = ComputerUsePermissionService.evaluate(input(click, isSelf: true), policy: policy(mode: .off))
        XCTAssertTrue(reason(d)?.contains("NanoTeams") ?? false, "self-guard reason should win over Off")
    }

    func testOutOfBounds_winsOverAutoJudge() {
        let click = ComputerUseAction.click(x: 9999, y: 9999, button: "left", double: false, target: nil)
        let d = ComputerUsePermissionService.evaluate(input(click, bounds: false), policy: policy(mode: .auto))
        XCTAssertTrue(reason(d)?.contains("outside") ?? false, "out-of-bounds should deny before the judge")
    }

    func testSessionPreApproved_beatsCaptureGate() {
        // A capture that would otherwise ask (first this run) is allowed when the app is pre-approved.
        let capture = ComputerUseAction.capture(target: "Safari", windowTitle: nil)
        let d = ComputerUsePermissionService.evaluate(input(capture, session: true, captured: false), policy: policy())
        XCTAssertTrue(isAllow(d))
    }

    func testGateFirstCaptureOnlyFalse_asksEveryCapture() {
        let capture = ComputerUseAction.capture(target: "screen", windowTitle: nil)
        let p = policy(gateFirstCaptureOnly: false)
        XCTAssertTrue(isAsk(ComputerUsePermissionService.evaluate(input(capture, captured: false), policy: p)))
        XCTAssertTrue(isAsk(ComputerUsePermissionService.evaluate(input(capture, captured: true), policy: p)))
    }

    func testBlockedKeyCombo_doesNotBlockTyping() {
        // The key denylist applies to ui_key, not to typing the same text.
        let type = ComputerUseAction.typeText(text: "cmd+q", target: nil)
        let d = ComputerUsePermissionService.evaluate(input(type), policy: policy(keys: ["cmd\\+q"]))
        XCTAssertTrue(isAsk(d))
    }

    func testEmptyAllowlist_allows() {
        let click = ComputerUseAction.click(x: 1, y: 1, button: "left", double: false, target: "AnyApp")
        // allowed:true models an empty allowlist (no restriction).
        XCTAssertFalse(isDeny(ComputerUsePermissionService.evaluate(input(click, allowed: true, bounds: true), policy: policy())))
    }

    // MARK: - Safety = Off (restrictionLevel .off)

    func testSafetyOff_auto_allowsActionsWithoutReview() {
        // Every action kind that would otherwise .ask runs without the judge.
        let p = policy(mode: .auto, restriction: .off)
        let actions: [ComputerUseAction] = [
            .click(x: 10, y: 10, button: "left", double: false, target: nil),
            .typeText(text: "hello", target: nil),
            .pressKey(keys: "cmd+s", target: nil),
            .scroll(x: 5, y: 5, dx: 0, dy: -3, target: nil),
        ]
        for action in actions {
            let d = ComputerUsePermissionService.evaluate(input(action, bounds: true), policy: p)
            XCTAssertTrue(isAllow(d), "Safety Off in Auto must allow \(action) without review")
        }
    }

    func testSafetyOff_manual_stillAsksHuman() {
        // The safety picker is hidden outside Auto mode — a stored `.off` must
        // never bypass the human approval Manual mode promises.
        let click = ComputerUseAction.click(x: 10, y: 10, button: "left", double: false, target: nil)
        let d = ComputerUsePermissionService.evaluate(
            input(click, bounds: true), policy: policy(mode: .manual, restriction: .off))
        XCTAssertTrue(isAsk(d), "Manual mode must still ask even with restrictionLevel .off")
    }

    func testSafetyOff_modeOff_stillDeniesAll() {
        // Master switch (Approval = Off) outranks the safety level.
        let click = ComputerUseAction.click(x: 10, y: 10, button: "left", double: false, target: nil)
        let d = ComputerUsePermissionService.evaluate(
            input(click, bounds: true), policy: policy(mode: .off, restriction: .off))
        XCTAssertTrue(isDeny(d))
    }

    func testSafetyOff_hardDenyRulesStillApply() {
        let p = policy(mode: .auto, restriction: .off, typing: ["password"], keys: ["cmd\\+q"])
        // Self-guard.
        let selfClick = ComputerUseAction.click(x: 1, y: 1, button: "left", double: false, target: "NanoTeams")
        XCTAssertTrue(isDeny(ComputerUsePermissionService.evaluate(input(selfClick, isSelf: true), policy: p)))
        // Out-of-bounds.
        let oob = ComputerUseAction.click(x: 9999, y: 9999, button: "left", double: false, target: nil)
        XCTAssertTrue(isDeny(ComputerUsePermissionService.evaluate(input(oob, bounds: false), policy: p)))
        // Blocked typing pattern.
        let type = ComputerUseAction.typeText(text: "my password", target: nil)
        XCTAssertTrue(isDeny(ComputerUsePermissionService.evaluate(input(type), policy: p)))
        // Blocked key combo.
        let key = ComputerUseAction.pressKey(keys: "cmd+q", target: nil)
        XCTAssertTrue(isDeny(ComputerUsePermissionService.evaluate(input(key), policy: p)))
        // Allowlist violation.
        let click = ComputerUseAction.click(x: 1, y: 1, button: "left", double: false, target: "SomeApp")
        XCTAssertTrue(isDeny(ComputerUsePermissionService.evaluate(input(click, allowed: false, bounds: true), policy: p)))
    }

    func testSafetyOff_manual_firstCapture_stillAsks() {
        // The capture privacy prompt (step 7) sits ABOVE the Safety=Off rule —
        // a hidden stored `.off` must not skip the first-capture confirmation
        // that Manual mode promises.
        let capture = ComputerUseAction.capture(target: "screen", windowTitle: nil)
        let d = ComputerUsePermissionService.evaluate(
            input(capture, captured: false),
            policy: policy(mode: .manual, restriction: .off))
        XCTAssertTrue(isAsk(d))
    }

    func testSafetyOff_auto_capture_allowsEvenWithPerCaptureGating() {
        // gateFirstCaptureOnly=false makes MANUAL ask on every capture, but in
        // Auto captures are read-only and always allowed at step 7 — with or
        // without Safety=Off. Pins the step ordering (7 before 8) so a future
        // reorder can't route captures to a judge that Safety=Off disabled.
        let capture = ComputerUseAction.capture(target: "screen", windowTitle: nil)
        for captured in [false, true] {
            let d = ComputerUsePermissionService.evaluate(
                input(capture, captured: captured),
                policy: policy(mode: .auto, restriction: .off, gateFirstCaptureOnly: false))
            XCTAssertTrue(isAllow(d), "auto-mode capture (captured=\(captured)) must allow")
        }
    }

    // MARK: - Scroll (deterministic allow)

    func testScroll_allowsWithoutReview_inManualAndAuto() {
        // A scroll is a read-oriented viewport move — reviewing it burned 2–15 s of judge
        // latency per action for rubber-stamp OKs. Deterministic allow in both modes,
        // at every restriction level.
        let scroll = ComputerUseAction.scroll(x: 5, y: 5, dx: 0, dy: -3, target: nil)
        for mode: ComputerUseMode in [.manual, .auto] {
            for level: ComputerUseRestrictionLevel in [.off, .permissive, .standard, .strict] {
                let d = ComputerUsePermissionService.evaluate(
                    input(scroll, bounds: true), policy: policy(mode: mode, restriction: level))
                XCTAssertTrue(isAllow(d), "scroll must auto-allow in \(mode)/\(level)")
            }
        }
    }

    func testScroll_hardDenyRulesStillApply() {
        // The allow sits BELOW every deny tier: self-guard, bounds, master off, allowlist.
        let scroll = ComputerUseAction.scroll(x: 5, y: 5, dx: 0, dy: -3, target: nil)
        XCTAssertTrue(isDeny(ComputerUsePermissionService.evaluate(
            input(scroll, isSelf: true, bounds: true), policy: policy(mode: .auto))))
        XCTAssertTrue(isDeny(ComputerUsePermissionService.evaluate(
            input(scroll, bounds: false), policy: policy(mode: .auto))))
        XCTAssertTrue(isDeny(ComputerUsePermissionService.evaluate(
            input(scroll, bounds: true), policy: policy(mode: .off))))
        XCTAssertTrue(isDeny(ComputerUsePermissionService.evaluate(
            input(scroll, allowed: false, bounds: true), policy: policy(mode: .auto, allowlist: ["Safari"]))))
    }

    func testScroll_clickStillAsks_scrollScopeDoesNotLeak() {
        // The deterministic allow is scroll-ONLY — a click at the same policy must still review.
        let click = ComputerUseAction.click(x: 5, y: 5, button: "left", double: false, target: nil)
        XCTAssertTrue(isAsk(ComputerUsePermissionService.evaluate(
            input(click, bounds: true), policy: policy(mode: .auto, restriction: .permissive))))
    }

    // MARK: - matchesAny

    func testMatchesAny_invalidRegexFallsBackToSubstring() {
        // "[" is not a valid regex — must still match as a literal substring.
        XCTAssertTrue(ComputerUsePermissionService.matchesAny("has a [ bracket", patterns: ["["]))
        XCTAssertFalse(ComputerUsePermissionService.matchesAny("clean text", patterns: ["["]))
    }

    func testMatchesAny_emptyAndWhitespacePatternsSkipped() {
        XCTAssertFalse(ComputerUsePermissionService.matchesAny("anything", patterns: ["", "   "]))
    }

    func testMatchesAny_regexAndCaseInsensitive() {
        XCTAssertTrue(ComputerUsePermissionService.matchesAny("my PASSWORD", patterns: ["pass\\w+"]))
    }
}
