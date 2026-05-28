import Foundation

// MARK: - Template Resolver

/// Stateless template resolver for `{placeholder}` substitution in prompt templates.
/// Extracted from SystemTemplates to keep the Domain layer free of service-level logic.
nonisolated enum TemplateResolver {

    /// Resolves a template string by replacing `{key}` placeholders with values from the dictionary.
    static func resolve(_ template: String, placeholders: [String: String]) -> String {
        var result = template
        for (key, value) in placeholders {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }

    /// Wraps `globalContext` (`StoreConfiguration.globalContext`) in a
    /// `## Global guidance` section and appends it to `text`. Empty / whitespace-only
    /// `globalContext` returns `text` unchanged — no empty section emitted.
    ///
    /// Replaces the prior `\n\n---\n\n` horizontal-rule separator that mixed
    /// markdown-HR with the otherwise-pure `## Header` / `### Header` sectioning
    /// style (Sclar2024 antipattern §3.6).
    ///
    /// `header` is parametrised so a future caller could route a different
    /// user-set context block under a different label without duplicating the
    /// empty-suffix guard.
    static func appendingSeparator(
        _ suffix: String,
        to text: String,
        header: String = "## Global guidance"
    ) -> String {
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        return text + "\n\n" + header + "\n\n" + trimmed
    }

    /// One-call system-prompt assembly: resolve `{placeholder}` substitutions
    /// and collapse triple-newline runs left by empty placeholders.
    ///
    /// **globalContext placement** — controlled by the template author:
    /// - Template contains `{globalContext}` chip → placeholder receives the
    ///   formatted block (via the caller's placeholders dict), no auto-append.
    /// - Template does NOT contain `{globalContext}` → auto-append as a
    ///   trailing `## Global guidance` footer (backwards-compat for templates
    ///   created before the chip was exposed; also the deliberate
    ///   "empty template ⇒ empty system_prompt" path — when the user clears
    ///   the entire template, nothing is appended either).
    ///
    /// Bundling these steps eliminates by-construction the drift risk that
    /// previously existed across `PromptBuilder.buildChatMessages`,
    /// `TeammateConsultationService.buildSystemPrompt`,
    /// `MeetingStreamingService.buildSpeakerSystemPrompt`, and the wire-
    /// payload preview — any future change to the order or contents of the
    /// resolution pipeline now happens here in one place, and byte-identity
    /// between runtime and preview holds automatically.
    static func resolveSystemPrompt(
        _ template: String,
        placeholders: [String: String],
        globalContext: String
    ) -> String {
        let hasExplicitGlobalContext = template.contains("{globalContext}")
        var result = resolve(template, placeholders: placeholders)
        // Strip orphan `Team purpose: ` label-only lines left when
        // `{teamDescription}` resolves to empty. Runs BEFORE `collapseBlankLines`
        // so the removed line's neighbouring newlines collapse correctly.
        result = stripOrphanInlineLabels(result)
        result = collapseBlankLines(result)
        // Strip orphan `## Header\n\n` blocks left by chips that resolved to
        // empty values. Without this, a template like
        //     ## Global guidance\n\n{globalContext}\n\n## Final reminder
        // ships `## Global guidance\n\n## Final reminder` when globalContext is
        // empty — a heading with no body that confuses the model. The strip
        // pass removes the header and its trailing separator, leaving the
        // surrounding sections untouched.
        result = stripOrphanHeaders(result)
        // Trim leading/trailing whitespace so empty placeholders at the
        // template's tail (e.g. empty `{toolCallingBlock}` when the role has no
        // tools) don't leave dangling `\n\n`. Also makes the
        // "empty template ⇒ empty system_prompt" contract observable.
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only auto-append when the template doesn't already place the chip AND
        // the template isn't intentionally empty (a user-cleared template should
        // ship empty — that's the "control whole prompt" contract).
        if !hasExplicitGlobalContext && !result.isEmpty {
            result = appendingSeparator(globalContext, to: result)
        }
        return result
    }

    /// Strip `^## .+$` lines whose section body is empty — i.e. the header is
    /// immediately followed by the next `^## ` header or by end-of-string,
    /// with only whitespace in between. Iterative until stable so adjacent
    /// chains of empty sections (e.g. two consecutive empty-chip slots) all
    /// collapse in one pass-and-call. `### ` / `#### ` headers are intentionally
    /// not collapsed — they nest under `##` sections and an empty subsection
    /// is the author's call, not necessarily a chip-resolution side effect.
    static func stripOrphanHeaders(_ text: String) -> String {
        // Anchor on a `## ` line, capture its content, then assert the
        // remainder is whitespace until either the next `##` header or end
        // of string. Anchored with `(?m)^` to walk line-starts.
        let pattern = #"(?m)^##[ \t]+[^\n]*\n[\s]*(?=^##[ \t]|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        var current = text
        // Fixed-point iteration to handle adjacent matches. `NSRegularExpression.stringByReplacingMatches`
        // strips all non-overlapping matches in one pass for non-adjacent
        // occurrences (each match's look-ahead is zero-width and stays valid
        // for the next match), but two empty `## Foo`/`## Bar` headers
        // separated by only whitespace can still be order-dependent depending
        // on the exact whitespace shape — the loop is defensive. 8 iterations
        // cap is well past any realistic template (built-ins have ≤ 5
        // placeholders that could collapse). Tested by
        // `TemplateResolverTests.testStripOrphanHeaders_chainOfThreeEmptySections_allStripped`.
        for _ in 0..<8 {
            let nsRange = NSRange(location: 0, length: (current as NSString).length)
            let next = regex.stringByReplacingMatches(in: current, range: nsRange, withTemplate: "")
            if next == current { break }
            current = next
        }
        // Cleanup the final-section case: a `## Header` line at end-of-string
        // with no body slips past the look-ahead (`\z` matches but the trailing
        // newline + whitespace pattern requires non-zero match). One trailing
        // pass with a simpler "header line + only whitespace till EOS" pattern.
        let trailingPattern = #"(?m)^##[ \t]+[^\n]*[\s]*\z"#
        if let trailingRegex = try? NSRegularExpression(pattern: trailingPattern, options: []) {
            let nsRange = NSRange(location: 0, length: (current as NSString).length)
            current = trailingRegex.stringByReplacingMatches(in: current, range: nsRange, withTemplate: "")
        }
        return current
    }

    /// Strip label-only lines like `^Team purpose:[ \t]*$` left over when the
    /// placeholder behind the label resolved to empty. Sibling of
    /// `stripOrphanHeaders` for inline-labelled lines.
    ///
    /// Anchored to the single known `Team purpose:` label so user content that
    /// happens to start with `Team purpose:` followed by real text on the same
    /// line is never touched (the `$` end-of-line anchor requires only
    /// whitespace between the colon and the line break). Generalise to a
    /// label-set parameter only when a second such label shows up.
    static func stripOrphanInlineLabels(_ text: String) -> String {
        // Pattern detail: `(?m)^…$\n?`
        //   - `(?m)` enables multiline so `^`/`$` match line boundaries.
        //   - `[ \t]*$` requires the label to be IMMEDIATELY followed by
        //     end-of-line (after optional trailing whitespace) — so
        //     `Team purpose: Lean engineering` is NOT a match, but
        //     `Team purpose: \n` and `Team purpose:\n` are.
        //   - Trailing `\n?` absorbs the line separator so the strip removes
        //     the whole orphan line cleanly.
        let pattern = #"(?m)^Team purpose:[ \t]*$\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let nsRange = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: nsRange, withTemplate: "")
    }

    /// Collapses runs of 3+ consecutive newlines down to exactly 2. Used after
    /// placeholder substitution to clean up blank lines left by placeholders
    /// that resolved to empty strings — e.g. `{toolList}` rendering as `""`
    /// when the role has tools, or `{positionContext}` rendering as `""` for
    /// chat-mode roles with no artifact dependencies. Content-preserving:
    /// only whitespace between paragraphs is normalized.
    static func collapseBlankLines(_ text: String) -> String {
        // Replace 3+ newlines with exactly 2. Using a manual scan instead of
        // NSRegularExpression to stay allocation-light and nonisolated-safe.
        var result = ""
        result.reserveCapacity(text.count)
        var newlineRun = 0
        for ch in text {
            if ch == "\n" {
                newlineRun += 1
                if newlineRun <= 2 {
                    result.append(ch)
                }
            } else {
                newlineRun = 0
                result.append(ch)
            }
        }
        return result
    }
}
