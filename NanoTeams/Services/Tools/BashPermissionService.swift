import Foundation

/// Pure, stateless rule engine that classifies a shell command against a
/// `BashPolicy`. Precedence is **deny > ask > allow**, with a read-only
/// bypass applied last. No I/O, no isolation — fully unit-testable.
///
/// Matching is segment-aware: a compound command (`a && b ; c | d`) is split on
/// shell separators and the leading program of EACH segment is extracted, so a
/// benign-looking `cat x && rm -rf /` cannot smuggle `rm` past a deny rule that
/// only inspected the first word.
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

        let segments = splitSegments(trimmed)
        let programs = segments.map { leadingProgram(of: $0) }.filter { !$0.isEmpty }

        // 1. Deny rules win over everything.
        if let rule = firstMatch(rules: policy.denyRules, command: trimmed, segments: segments, programs: programs) {
            return .deny(reason: "Blocked by deny rule “\(rule)”.")
        }

        // 1b. Manual (always confirm): every non-denied command requires fresh human
        //     approval. The read-only bypass, allow rules, and prior "always"
        //     approvals are all intentionally skipped — the user opted into
        //     confirming each command, so only the deny rules above act silently.
        if policy.mode == .manual {
            return .ask(reason: "Manual mode — every command needs your approval.")
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
        let askMatched = firstMatch(rules: policy.askRules, command: trimmed, segments: segments, programs: programs) != nil
        if askMatched {
            return .ask(reason: "Matched an ask rule — requires review.")
        }

        // 3. Allow rules short-circuit to allow — EXCEPT a BARE-PROGRAM allow rule
        //    does not vouch for a segment that smuggles command / process
        //    substitution ($( ), backticks, <( )). The rule only names the outer
        //    program (`echo`); it can't speak for the arbitrary code inside
        //    `echo $(rm -rf ~)`, which the segment-level program extraction never
        //    inspects. Glob / multi-word literal allow rules are more specific
        //    (including the verbatim command persisted by an "always" approval)
        //    and still short-circuit.
        if let rule = firstMatch(rules: policy.allowRules, command: trimmed, segments: segments, programs: programs) {
            let bareProgramRule = !rule.contains("*") && !rule.contains(" ")
            if !(bareProgramRule && hasCommandSubstitution(trimmed)) {
                return .allow
            }
        }

        // 4. Read-only bypass: every segment is a known read-only program and
        //    there's no redirection / command substitution.
        if isReadOnly(trimmed, programs: programs) {
            return .allow
        }

        // 5. Default: unknown command → review (judge in Auto, human in Manual).
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

    // MARK: - Read-only classification

    static func isReadOnly(_ command: String, programs: [String]) -> Bool {
        // Any output redirection, command substitution, or process substitution
        // can mutate state or run arbitrary code — disqualify.
        if command.contains(">") { return false }
        if hasCommandSubstitution(command) { return false }
        guard !programs.isEmpty else { return false }
        // Program folding matches the rule layer: `LS` resolves to /bin/ls on macOS,
        // so an uppercased read-only program auto-allows just like its lowercase form.
        return programs.allSatisfy { BashConstants.readOnlyPrograms.contains($0.lowercased()) }
    }

    /// Command / process substitution — `$( )`, backticks, `<( )` — runs arbitrary
    /// nested code that the segment-level program extraction never inspects, so it
    /// disqualifies the read-only bypass and a bare-program allow rule.
    static func hasCommandSubstitution(_ command: String) -> Bool {
        command.contains("$(") || command.contains("`") || command.contains("<(")
    }

    // MARK: - Segmenting & program extraction

    /// Splits a command line into independently-evaluated segments on `;`, `&`,
    /// `|`, and newlines (so `&&`, `||`, `|` all split). Quoted spans are
    /// respected so a separator inside `'...'` / `"..."` doesn't split.
    static func splitSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in command {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                current.append(ch)
                escaped = true
                continue
            }
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                current.append(ch)
                continue
            }
            if BashConstants.segmentSeparators.contains(ch) {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { segments.append(t) }
                current = ""
                continue
            }
            current.append(ch)
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { segments.append(t) }
        return segments.isEmpty ? [command.trimmingCharacters(in: .whitespaces)] : segments
    }

    /// Extracts the leading program (basename) of a segment, skipping leading
    /// `VAR=value` environment assignments. Does NOT strip `sudo`/`env` — those
    /// ARE the effective program for policy purposes (so a `sudo` deny rule
    /// matches `sudo rm`, and `env FOO=x rm` resolves to `env`, which is not in
    /// the read-only set).
    static func leadingProgram(of segment: String) -> String {
        var tokens = tokenize(segment)
        // Skip leading `KEY=value` assignments.
        while let first = tokens.first, isAssignment(first) {
            tokens.removeFirst()
        }
        guard let program = tokens.first, !program.isEmpty else { return "" }
        let unquoted = stripQuotes(program)
        if unquoted.contains("/") {
            return String(unquoted.split(separator: "/").last ?? "")
        }
        return unquoted
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "=") else { return false }
        let name = token[token.startIndex..<eq]
        return !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            && (name.first?.isNumber == false)
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    /// Whitespace tokenizer that respects single/double quotes.
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; continue }
            if ch == " " || ch == "\t" {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Rule matching

    private static func firstMatch(
        rules: [String], command: String, segments: [String], programs: [String]
    ) -> String? {
        for rule in rules {
            let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if ruleMatches(trimmed, command: command, segments: segments, programs: programs) {
                return trimmed
            }
        }
        return nil
    }

    static func ruleMatches(
        _ rule: String, command: String, segments: [String], programs: [String]
    ) -> Bool {
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
        if rule.contains(" ") {
            let lowerRule = rule.lowercased()
            // Whole-command EXACT match: an "always allow" of a COMPOUND command
            // (e.g. `cd app && npm test`) persists the verbatim line, which equals no
            // single segment — so without this the command would re-prompt on every
            // emission despite "always". Compared through `decisionKey` (trim +
            // lowercase + collapse internal whitespace) so a cosmetic spacing change
            // in the re-emission still matches. Still EXACT, never a prefix: an
            // appended segment changes the normalized key, so `<rule> && rm -rf ~`
            // cannot smuggle past.
            if decisionKey(for: command) == decisionKey(for: rule) { return true }
            // Multi-word literal: word-boundary prefix of a segment (a single-segment
            // rule like `git push` vouches for `git push origin main`).
            return segments.contains { seg in
                let lower = seg.lowercased()
                return lower == lowerRule || lower.hasPrefix(lowerRule + " ")
            }
        }
        // Bare program name: match the leading program of any segment (word boundary,
        // so `ls` does not match `lsof`).
        return programs.contains { $0.caseInsensitiveCompare(rule) == .orderedSame }
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
