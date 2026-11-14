import Foundation

/// The shell-lexing half of `BashPermissionService`: how a command line becomes segments, and
/// a segment becomes the program it runs. Split out of the rule engine on 2026-11-12 (F6 L3),
/// when per-segment allow coverage and redirect-aware splitting took the file past 500 lines —
/// the policy (which tier fires, and on what) changes for different reasons than the lexing.
nonisolated extension BashPermissionService {

    /// Splits a command line into independently-evaluated segments on `;`, `&`,
    /// `|`, and newlines (so `&&`, `||`, `|` all split). Quoted spans are
    /// respected so a separator inside `'...'` / `"..."` doesn't split.
    ///
    /// With `redirectAware` (the default), an `&` that belongs to a REDIRECT is not a
    /// separator: `2>&1`, `>&2`, `1>&2`, `<&3` (an `&` right after an unescaped `>` / `<`) and
    /// `&>`, `&>>` (an `&` right before `>` that does not close an `&&`). Split there,
    /// `npm test 2>&1` became `npm test 2>` + `1`, and once allow is judged per segment the
    /// phantom `1` would send every redirected command to a human. `&&>log` stays `&&` +
    /// `>log`, as bash tokenizes it; `\>&` is a literal `>` and then a real `&`.
    ///
    /// `&>` is the bash / zsh / fish reading; a POSIX `sh` (dash) reads `a &>f b` as `a &` +
    /// `>f b`. The deny and ask tiers therefore also match against the split with
    /// `redirectAware: false` (every `&` splits), which is what they always saw — so the
    /// redirect reading can only narrow the ALLOW tier's segments, never hide one from a deny.
    static func splitSegments(_ command: String, redirectAware: Bool = true) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        // The previous character when it was an unquoted, unescaped operator candidate —
        // what decides whether an `&` closes a `>&` / `<&` / `&&`.
        var previousBare: Character?
        let chars = Array(command)
        for (index, ch) in chars.enumerated() {
            if escaped {
                current.append(ch)
                escaped = false
                previousBare = nil
                continue
            }
            if ch == "\\" {
                current.append(ch)
                escaped = true
                previousBare = nil
                continue
            }
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                previousBare = nil
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                current.append(ch)
                previousBare = nil
                continue
            }
            if redirectAware, ch == "&" {
                let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
                let closesDup = previousBare == ">" || previousBare == "<"
                let opensRedirect = next == ">" && previousBare != "&"
                if closesDup || opensRedirect {
                    current.append(ch)
                    previousBare = nil
                    continue
                }
            }
            previousBare = ch
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

    /// The segments the DENY and ASK tiers match against: the redirect-aware split plus every
    /// segment of the legacy every-`&` split that it does not already contain (see
    /// `splitSegments`). Only ever MORE candidates than either split alone, and a deny or ask
    /// rule fires on any one of them.
    static func ruleSegments(_ command: String, segments: [String]) -> [String] {
        var out = segments
        var seen = Set(segments)
        for segment in splitSegments(command, redirectAware: false) where seen.insert(segment).inserted {
            out.append(segment)
        }
        return out
    }

    /// The segments a DENY rule must be matched against: every original segment, plus,
    /// for a segment led by a command wrapper, the sub-command lines hiding in its tail.
    ///
    /// `"command rm -rf x"` → `["command rm -rf x", "rm -rf x", "x"]`
    /// `"timeout 5 rm -rf x"` → `[…, "5 rm -rf x", "rm -rf x", "x"]`
    ///
    /// One tail per subsequent NON-FLAG, non-assignment token rather than "the tail
    /// after the first one", because wrappers take operands (`timeout 5`, `nice -n 5`)
    /// and the alternative is a per-program flag-arity table. Such a table is a text
    /// heuristic that fails OPEN the first time a program grows a flag (CLAUDE.md #85),
    /// and failing open is exactly the defect being closed. Emitting a few extra
    /// candidate tails costs a deny rule nothing: a rule that matches none of them is
    /// unchanged, and one that matches is a rule the user wrote about a program that
    /// really is about to run.
    ///
    /// Capped at the first 8 tokens so a pathological argv cannot turn one rule check
    /// into a quadratic scan.
    static func denySegments(_ segments: [String]) -> [String] {
        var out: [String] = []
        for segment in segments {
            out.append(segment)
            guard BashConstants.commandWrappers.contains(leadingProgram(of: segment).lowercased())
            else { continue }

            let tokens = tokenize(segment)
            for index in tokens.indices.dropFirst().prefix(8) {
                let token = tokens[index]
                guard !token.hasPrefix("-"), !isAssignment(token), !token.isEmpty else { continue }
                let tail = tokens[index...].joined(separator: " ")
                if !tail.isEmpty, tail != segment { out.append(tail) }
            }
        }
        return out
    }

    /// Extracts the leading program (basename) of a segment, skipping leading
    /// `VAR=value` environment assignments. Does NOT strip `sudo`/`env` — those
    /// ARE the effective program for policy purposes (so a `sudo` deny rule
    /// matches `sudo rm`, and `env FOO=x rm` resolves to `env`, which is not in
    /// the read-only set). `BashConstants.commandWrappers` is the enumeration of
    /// that class, and `denySegments` is what lets a deny rule see past it.
    ///
    /// Leading REDIRECTIONS are skipped too, in any order with the assignments: bash runs
    /// `rm` in `>/tmp/x rm -rf ~` and `2>/dev/null rm -rf ~`, so before 2026-11-12 (F6 L3)
    /// a deny rule `rm` read the program as `x` / `null` and let both through. A bare
    /// operator token (`>`, `2>>`) takes the next token with it as its target.
    static func leadingProgram(of segment: String) -> String {
        var tokens = tokenize(segment)
        while let first = tokens.first {
            if isAssignment(first) {
                tokens.removeFirst()
            } else if let operatorEnd = redirectOperatorEnd(first) {
                tokens.removeFirst()
                // `> out` — the operator stands alone and its target is the next token.
                if operatorEnd == first.endIndex, !tokens.isEmpty { tokens.removeFirst() }
            } else {
                break
            }
        }
        guard let program = tokens.first, !program.isEmpty else { return "" }
        let unquoted = stripQuotes(program)
        if unquoted.contains("/") {
            return String(unquoted.split(separator: "/").last ?? "")
        }
        return unquoted
    }

    /// When `token` opens with a redirection operator — an optional fd number, then `>`, `>>`,
    /// `<`, `<<`, `<>`, `>&`, `<&`, `>|`, `&>` or `&>>` — the index just past the operator.
    private static func redirectOperatorEnd(_ token: String) -> String.Index? {
        var index = token.startIndex
        while index < token.endIndex, token[index].isASCII, token[index].isNumber {
            index = token.index(after: index)
        }
        let rest = token[index...]
        let operators = ["&>>", "&>", ">>", ">&", ">|", "<<", "<>", "<&", ">", "<"]
        guard let op = operators.first(where: { rest.hasPrefix($0) }) else { return nil }
        // `&>` takes no fd number in front of it.
        if op.hasPrefix("&"), index != token.startIndex { return nil }
        return token.index(index, offsetBy: op.count)
    }

    static func isAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "=") else { return false }
        let name = token[token.startIndex..<eq]
        return !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            && (name.first?.isNumber == false)
    }

    static func stripQuotes(_ s: String) -> String {
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
}
