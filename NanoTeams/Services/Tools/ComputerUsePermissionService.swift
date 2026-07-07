import Foundation

/// Resolved runtime facts about a computer-use action, computed by the (impure) gate and
/// handed to the pure evaluator. Keeping resolution (NSWorkspace / capture metadata) out of
/// the evaluator makes the decision logic fully unit-testable.
nonisolated struct ComputerUseEvalInput: Hashable, Sendable {
    let action: ComputerUseAction
    /// The action targets NanoTeams itself (its own window) — unconditional deny.
    let isSelfTarget: Bool
    /// True if the allowlist is empty (no restriction) OR the target is in it.
    let targetAllowedByAllowlist: Bool
    /// Target app is in the per-run "always allow" set → skip the prompt.
    let sessionPreApproved: Bool
    /// Click/scroll coordinate falls inside the captured screenshot. `nil` when N/A
    /// (not a click/scroll) or unknown (no capture metadata yet, e.g. same-batch).
    let clickInBounds: Bool?
    /// A `screen_capture` already happened this run (for the first-capture gate).
    let captureAlreadyOccurredThisRun: Bool
}

/// Pure, stateless evaluator for computer-use actions. Precedence: **self-guard / deny > ask > allow**.
/// No I/O, no isolation — fully unit-testable. The gate turns `.ask` into a human prompt (manual)
/// or a judge call (auto), and denies `.ask` when no human is available in manual mode.
nonisolated enum ComputerUsePermissionService {

    static func evaluate(_ input: ComputerUseEvalInput, policy: ComputerUsePolicy) -> ComputerUsePermissionDecision {
        // 1. Self-guard — never let the model touch NanoTeams itself (e.g. its own Allow button).
        if input.isSelfTarget {
            return .deny(reason: "Cannot target NanoTeams itself.")
        }

        // 2. Out-of-bounds click/scroll — reject (never clamp onto a random display).
        if input.clickInBounds == false {
            return .deny(reason: "Coordinates are outside the captured screenshot.")
        }

        // 3. Off disables everything.
        if policy.mode == .off {
            return .deny(reason: "Computer Use is disabled in Settings (mode: Off).")
        }

        // 4. Blocked typing / key patterns.
        if case .typeText(let text, _) = input.action,
           matchesAny(text, patterns: policy.blockedTypingPatterns) {
            return .deny(reason: "The text to type matches a blocked pattern.")
        }
        if case .pressKey(let keys, _) = input.action,
           matchesAny(keys, patterns: policy.blockedKeyCombos) {
            return .deny(reason: "The key combination is blocked.")
        }

        // 5. Target-app allowlist.
        if !input.targetAllowedByAllowlist {
            return .deny(reason: "The target app is not in the allowlist.")
        }

        // 6. Per-run "always allow in this app" short-circuit.
        if input.sessionPreApproved {
            return .allow
        }

        // 7. Capture is read-only + privacy-sensitive: gate only the first per run.
        if case .capture = input.action {
            if input.captureAlreadyOccurredThisRun, policy.gateFirstCaptureOnly {
                return .allow
            }
            // Read-only tier: auto-allowed without review in Auto (no judge for a
            // read) and Semi-automatic (the user opted into auto-allowing reads).
            // Manual confirms the first screen-share for privacy.
            if policy.mode == .auto || policy.mode == .semiAutomatic {
                return .allow
            }
            return .ask(reason: "First screen capture this run — confirm sharing your screen.")
        }

        // 8. Scroll is a read-oriented viewport move — it can't delete, submit, or grant
        // anything, and reviewing it added 2–15 s of LLM-judge latency per action for
        // rubber-stamp OKs (observed). Runs in EVERY mode once it survives the hard deny
        // rules above (self-guard, bounds, off, blocklists, allowlist); in Manual mode this
        // also stops a per-scroll approval card.
        if case .scroll = input.action {
            return .allow
        }

        // 9. Auto mode with Safety = Off — every action that survived the hard
        // deny rules above (self-guard, bounds, blocklists, allowlist) runs
        // without review. Scoped to `.auto`: the safety picker is only shown in
        // Auto mode, and a stored-but-hidden `.off` must never bypass the human
        // approval that Manual mode promises.
        if policy.mode == .auto, policy.restrictionLevel == .off {
            return .allow
        }

        // 10. Mutating action (click / type / key) → review. The gate dispatches:
        // Auto → judge; Manual / Semi-automatic → human Allow/Deny (denied when no
        // human is available). Semi-automatic reaches here only for mutating
        // actions — its read-only tier (capture, scroll) already allowed above.
        return .ask(reason: "Confirm this action.")
    }

    /// Case-insensitive match: tries each pattern as a regex, falling back to substring.
    static func matchesAny(_ text: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let re = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..., in: text)
                if re.firstMatch(in: text, options: [], range: range) != nil { return true }
            } else if text.range(of: trimmed, options: [.caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }
}
