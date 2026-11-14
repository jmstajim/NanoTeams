import Foundation

/// Pure, stateless rule engine that classifies a shell command against a
/// `BashPolicy`. Precedence is **deny > ask > allow**, with a read-only
/// bypass applied last. No I/O, no isolation — fully unit-testable.
///
/// Matching is segment-aware: a compound command (`a && b ; c | d`) is split on
/// shell separators and the leading program of EACH segment is extracted, so a
/// benign-looking `cat x && rm -rf /` cannot smuggle `rm` past a deny rule that
/// only inspected the first word. The tiers read the segments in opposite ways: a deny or
/// ask rule fires on ANY segment, while an allow rule (or the read-only bypass) must cover
/// EVERY segment — or the rule must be the whole line verbatim — before the line runs
/// unattended.
nonisolated enum BashPermissionService {

    // MARK: - Public API

    static func evaluate(command: String, policy: BashPolicy) -> BashPermissionDecision {
        // Mode Off disables the tool entirely.
        if policy.mode == .off {
            // Model-read (rides `makeErrorEnvelope` into the tool result), so it names the
            // policy, not the Settings pane the model cannot open. "disabled" stays in the
            // first sentence — `ComputerUseGateResolutionTests` pins that word.
            return .deny(reason: "The bash tool is disabled by policy (execution mode: Off). No command can run in this step.")
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .deny(reason: "Empty command — nothing to run.")
        }

        // `segments` is the redirect-aware split the ALLOW tier covers; deny and ask match
        // against `ruleSegs`, which adds the legacy every-`&` split (see `splitSegments`).
        let segments = splitSegments(trimmed)
        let programs = segments.map { leadingProgram(of: $0) }.filter { !$0.isEmpty }
        let ruleSegs = ruleSegments(trimmed, segments: segments)

        // 1. Deny rules win over everything — and they see THROUGH a command wrapper.
        //
        //    Rules match against the leading program of each segment, so before
        //    `denySegments` a user's `rm` deny rule did not match `command rm -rf x`
        //    (leading program `command`) and a `rm *` glob missed it too, being
        //    `^`-anchored. That half of the wrapper defect is mode-INDEPENDENT: it
        //    reaches `.manual`, the fresh-install default, where the read-only bypass
        //    below is never even consulted. Removing the wrappers from
        //    `readOnlyPrograms` fixes the auto-allow half and leaves this one standing
        //    (CLAUDE.md #52 — the unguarded branch was the common path).
        //
        //    Deliberately deny-ONLY. Feeding the widened segments to the ask and allow
        //    tiers too would make `allow: ["rm"]` start vouching for `sudo rm` — a
        //    permissiveness regression wearing a fix's clothes.
        let denySegs = denySegments(ruleSegs)
        if let rule = firstMatch(rules: policy.denyRules, command: trimmed, segments: denySegs) {
            return .deny(reason: "Blocked by deny rule “\(rule)”.")
        }

        // 1b. Manual (always confirm): every non-denied command requires fresh human
        //     approval. The read-only bypass, allow rules, and prior "always"
        //     approvals are all intentionally skipped — the user opted into
        //     confirming each command, so only the deny rules above act silently.
        if policy.mode == .manual {
            // Reason strings are MODEL-read, not human-read: the approval card carries no
            // reason, and the only consumer is `gateBashCalls`' no-human arm, which
            // interpolates this into "This command needs human approval (<reason>), but no
            // human is available to review it." Written in the second person it produced
            // "…needs YOUR approval…, but no human is available" — a sentence that
            // contradicts itself for its one reader. Third person, always.
            return .ask(reason: "Manual mode — every command is reviewed individually.")
        }

        // 1c. Auto mode with judge strictness Off — every command that survives the
        //     deny rules runs without review: ask rules, allow rules, and the
        //     read-only bypass are all moot (everything not denied is allowed).
        //     Scoped to `.auto`: Manual/Semi-automatic still route "ask" outcomes to
        //     the human, and mode Off (top of the function) still disables the tool
        //     entirely. Mirrors `ComputerUsePermissionService.evaluate` step 9.
        if policy.mode == .auto, policy.restrictionLevel == .off {
            return .allow
        }

        // 2. Ask rules force review even if an allow rule or the read-only bypass
        //    would otherwise pass it.
        let askMatched = firstMatch(rules: policy.askRules, command: trimmed, segments: ruleSegs) != nil
        if askMatched {
            return .ask(reason: "Matched an ask rule — requires review.")
        }

        // 3. The verbatim line. An "always" approval persists the command exactly as the
        //    card showed it, and the person approved THAT line — so a rule equal to the
        //    whole command (through `decisionKey`: trim + case + inner whitespace) allows
        //    it even when no segment is covered on its own (`cd app && npm test`). Exact,
        //    never a prefix: an appended `&& rm -rf ~` changes the key. Any rule shape —
        //    `make;make` has neither a space nor a `*` and is still a verbatim line.
        let commandKey = decisionKey(for: trimmed)
        if policy.allowRules.contains(where: { decisionKey(for: $0) == commandKey && !commandKey.isEmpty }) {
            return .allow
        }

        // 4. Every segment covered. Allow and read-only are judged PER SEGMENT and the
        //    line runs unattended only when each one is covered (F6 L3, 2026-11-11): an
        //    allow rule speaks for the segment it matches, never for its neighbours. Until
        //    then one matching segment allowed the whole line, and a glob matched against
        //    the whole line covered everything after its prefix — live, `touch probe/*`
        //    ran `touch probe/a; touch smuggled.txt` with no human.
        if segments.allSatisfy({
            segmentIsCovered($0, command: trimmed, allowRules: policy.allowRules)
        }) {
            return .allow
        }

        // 5. Default: an uncovered segment → review (judge in Auto, human in Manual).
        //    Name the near-miss when there is one: a program that mutates with no `>`
        //    on the line looks read-only to a human reading the approval card, and the
        //    card is where that misreading turns into an approval.
        if let writer = programs.first(where: {
            BashConstants.writesWithoutRedirection.contains($0.lowercased())
        }) {
            return .ask(reason: "`\(writer)` can modify files in place without a redirect, so it is not treated as read-only — requires review.")
        }
        return .ask(reason: "Command is not pre-approved and is not read-only — requires review.")
    }

    /// Stable key identifying a command for the one-shot approval decision map.
    /// Whitespace-normalized so cosmetic re-emission differences don't miss a
    /// recorded decision.
    static func decisionKey(for command: String) -> String {
        // Case-folded too, so a one-shot recorded decision is consumed when the model
        // re-emits the same command with different casing — consistent with the
        // case-insensitive rule layer (`ruleMatches`) and a persisted "always" rule.
        command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
    }

    // MARK: - Allow coverage

    /// Whether ONE segment may run unattended: an allow rule matches it, or it is read-only.
    ///
    /// A BARE-PROGRAM rule (`echo`) names only the outer program, so it vouches for neither a
    /// line that carries command / process substitution (`echo $(rm -rf ~)` — the nested code
    /// is never inspected, and `splitSegments` does not even keep it in one segment) nor a
    /// segment led by a WRAPPER (`allow: ["sudo"]` says nothing about the argv tail that
    /// actually runs). That is why `git`/`make`/`npm` are deliberately NOT in
    /// `commandWrappers` — they can execute things, but not through their tail. Glob and
    /// multi-word rules are more specific intent and keep covering their segment.
    ///
    /// Read-only coverage requires the WHOLE line to be free of substitution, as the
    /// line-level bypass did: a `$(` split across two segments must not let its tail pass as
    /// a harmless `echo`.
    static func segmentIsCovered(_ segment: String, command: String, allowRules: [String]) -> Bool {
        let program = leadingProgram(of: segment)
        let substituted = hasCommandSubstitution(command)
        for rule in allowRules {
            let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, segmentMatches(trimmed, segment: segment, program: program) else { continue }
            let bareProgramRule = !trimmed.contains("*") && !trimmed.contains(" ")
            if bareProgramRule,
               substituted || BashConstants.commandWrappers.contains(program.lowercased()) {
                continue
            }
            return true
        }
        guard !substituted, !program.isEmpty else { return false }
        return isReadOnly(segment, programs: [program], segments: [segment])
    }

    // MARK: - Read-only classification

    static func isReadOnly(_ command: String, programs: [String], segments: [String] = []) -> Bool {
        // Any output redirection, command substitution, or process substitution
        // can mutate state or run arbitrary code — disqualify.
        if command.contains(">") { return false }
        if hasCommandSubstitution(command) { return false }
        guard !programs.isEmpty else { return false }
        // Program folding matches the rule layer: `LS` resolves to /bin/ls on macOS,
        // so an uppercased read-only program auto-allows just like its lowercase form.
        guard programs.allSatisfy({ BashConstants.readOnlyPrograms.contains($0.lowercased()) })
        else { return false }

        // A flag-gated program is read-only only while every flag it carries is
        // recognised. Unknown flag → not read-only → review (fails CLOSED).
        return segments.allSatisfy { everyFlagIsRecognised(in: $0) }
    }

    /// For a segment led by a flag-gated program, whether all of its flags are on that
    /// program's allowlist. `true` for every other segment — this decides nothing about
    /// programs that are not flag-gated.
    static func everyFlagIsRecognised(in segment: String) -> Bool {
        let program = leadingProgram(of: segment).lowercased()
        guard let allowed = BashConstants.flagGatedReadOnlyPrograms[program] else { return true }

        for token in tokenize(segment).dropFirst() {
            let bare = stripQuotes(token)
            guard bare.hasPrefix("-"), bare != "-", bare != "--" else { continue }

            if bare.hasPrefix("--") {
                // `--pre=sh` is the flag `--pre`; the payload is not the question.
                let name = bare.split(separator: "=", maxSplits: 1).first.map(String.init) ?? bare
                if !allowed.contains(name) { return false }
            } else {
                // Bundled shorts: `-ni` is `-n` and `-i`, and one unrecognised
                // character in the bundle disqualifies the whole segment.
                for ch in bare.dropFirst() where !allowed.contains("-\(ch)") { return false }
            }
        }
        return true
    }

    /// Command / process substitution — `$( )`, backticks, `<( )` — runs arbitrary
    /// nested code that the segment-level program extraction never inspects, so it
    /// disqualifies the read-only bypass and a bare-program allow rule.
    static func hasCommandSubstitution(_ command: String) -> Bool {
        command.contains("$(") || command.contains("`") || command.contains("<(")
    }

    // MARK: - Rule matching

    private static func firstMatch(rules: [String], command: String, segments: [String]) -> String? {
        for rule in rules {
            let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if ruleMatches(trimmed, command: command, segments: segments) {
                return trimmed
            }
        }
        return nil
    }

    /// Whether a DENY or ASK rule fires on this command: ANY match is enough — the line as a
    /// whole, or any one segment. That is the right reading for a rule that stops a command,
    /// and the wrong one for a rule that lets it through: the allow tier does not come here
    /// but asks `segmentIsCovered` of EVERY segment (F6 L3, 2026-11-11). Until then this
    /// function served all three tiers, and its comment claimed that "an appended segment
    /// changes the normalized key, so `<rule> && rm -rf ~` cannot smuggle past" — true of the
    /// whole-line compare, while the per-segment prefix match two lines below matched the
    /// rule's first segment and let the line through anyway.
    static func ruleMatches(_ rule: String, command: String, segments: [String]) -> Bool {
        // All matching is case-insensitive: macOS's case-insensitive filesystem
        // resolves `RM` → /bin/rm, so a deny rule `rm` must still block `RM` rather
        // than silently downgrade it to a review.
        if rule.contains("*") {
            // Glob: anchored prefix match against the whole command AND each segment.
            // Compile once per rule (the pattern depends only on `rule`, not the
            // candidate), then test the command and every segment against it.
            guard let re = compileGlob(rule) else { return false }
            return ([command] + segments).contains { globMatch(re, $0) }
        }
        // The whole line, compared through `decisionKey` (trim + case + inner whitespace):
        // a multi-segment rule (`cd app && rm -rf build`) equals no single segment.
        if rule.contains(" "), decisionKey(for: command) == decisionKey(for: rule) { return true }
        return segments.contains { seg in
            segmentMatches(rule, segment: seg, program: leadingProgram(of: seg))
        }
    }

    /// Whether `rule` matches ONE segment: a glob anchored at the segment's start, a
    /// multi-word literal as a word-boundary prefix of the segment (`git push` matches
    /// `git push origin main`, not `git pushx`), or a bare program name equal to the
    /// segment's leading program (`ls` does not match `lsof`). Case-insensitive throughout.
    static func segmentMatches(_ rule: String, segment: String, program: String) -> Bool {
        if rule.contains("*") {
            guard let re = compileGlob(rule) else { return false }
            return globMatch(re, segment)
        }
        if rule.contains(" ") {
            let lowerRule = rule.lowercased()
            let lower = segment.lowercased()
            return lower == lowerRule || lower.hasPrefix(lowerRule + " ")
        }
        return program.caseInsensitiveCompare(rule) == .orderedSame
    }

    /// Compiles a `*`-glob into an anchored, case-insensitive regex (every non-`*`
    /// character escaped to a literal). Returns nil only for an unconstructable pattern.
    private static func compileGlob(_ pattern: String) -> NSRegularExpression? {
        var regex = "^"
        for ch in pattern {
            if ch == "*" {
                regex += ".*"
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        return try? NSRegularExpression(
            pattern: regex, options: [.dotMatchesLineSeparators, .caseInsensitive])
    }

    private static func globMatch(_ re: NSRegularExpression, _ candidate: String) -> Bool {
        let range = NSRange(candidate.startIndex..., in: candidate)
        return re.firstMatch(in: candidate, options: [], range: range) != nil
    }
}
