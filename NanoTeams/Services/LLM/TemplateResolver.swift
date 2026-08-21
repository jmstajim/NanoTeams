import Foundation

// MARK: - Template Resolver

/// Stateless template resolver for `{placeholder}` substitution in prompt templates.
/// Extracted from SystemTemplates to keep the Domain layer free of service-level logic.
nonisolated enum TemplateResolver {

    /// Resolves a template string by replacing `{key}` placeholders with values from the dictionary.
    ///
    /// Single-pass scan over the TEMPLATE only — substituted values are data and are never
    /// re-scanned for `{key}` tokens. The prior `for (key, value) in placeholders` +
    /// `replacingOccurrences` loop made nested-token expansion depend on Swift Dictionary
    /// iteration order (re-randomized per process): a value containing `{otherKey}` was
    /// expanded or left literal based on hash seeding, producing non-deterministic prompt
    /// bytes and letting user-authored guidance smuggle chips like `{toolCalling}` into
    /// the resolved prompt. Unknown placeholders stay literal, as before.
    static func resolve(_ template: String, placeholders: [String: String]) -> String {
        guard !placeholders.isEmpty, template.contains("{") else { return template }
        var result = String()
        result.reserveCapacity(template.count)
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            if ch == "{",
               case let afterBrace = template.index(after: i),
               afterBrace < template.endIndex,
               let close = template[afterBrace...].firstIndex(of: "}"),
               let value = placeholders[String(template[afterBrace..<close])] {
                result += value
                i = template.index(after: close)
            } else {
                result.append(ch)
                i = template.index(after: i)
            }
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

    /// Like `appendingSeparator`, but when `text` ends in a `## Final reminder`
    /// section the block is inserted BEFORE it — the tail attention slot must
    /// keep the single most critical constraint [Liu2024]; an arbitrary-length
    /// user content block appended after it displaces the reminder from the
    /// position that makes it work.
    ///
    /// Splices the chip-less fallback sections (`## Skills`, `## Global
    /// guidance`) at ONE anchor, in the given order, each with an empty body
    /// dropped.
    ///
    /// Computing the `## Final reminder` anchor once — against the text as it
    /// stands BEFORE any insertion — is what keeps the sections independent of
    /// each other. Inserting them one at a time would re-find the anchor in text
    /// that already contains the previous body, so INSERTED content could supply
    /// the match: a third-party skill body carrying a fenced `## Final reminder`
    /// line would have the global-guidance block spliced into its middle. The
    /// bytes for any single section, and for the two stacked in template order,
    /// are unchanged by this consolidation.
    static func insertingSections(
        _ sections: [(header: String, body: String)],
        into text: String
    ) -> String {
        let blocks = sections.compactMap { section -> String? in
            let trimmed = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return section.header + "\n\n" + trimmed
        }
        guard !blocks.isEmpty else { return text }
        let joined = blocks.joined(separator: "\n\n")

        let frHeader = "## Final reminder"
        if let range = text.range(of: frHeader, options: .backwards),
           range.lowerBound == text.startIndex
           || text[text.index(before: range.lowerBound)] == "\n" {
            let head = String(text[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(text[range.lowerBound...])
            return head + "\n\n" + joined + "\n\n" + tail
        }
        return text + "\n\n" + joined
    }

    /// One-call system-prompt assembly: resolve `{placeholder}` substitutions
    /// and collapse triple-newline runs left by empty placeholders.
    ///
    /// **globalContext / roleSkills placement** — controlled by the template
    /// author, same rule for both:
    /// - Template contains the chip → the placeholder receives the formatted
    ///   block (via the caller's placeholders dict), no auto-append.
    /// - Template does NOT contain the chip → auto-append as a trailing
    ///   `## Global guidance` / `## Skills` footer, inserted before a trailing
    ///   `## Final reminder`.
    ///
    /// The fallback is not merely backwards-compat. `Team.duplicate` clears
    /// `templateID`, so EVERY team created from a template in the New Team sheet
    /// is a "custom" team that `NTMSRepository+Reconcile` never rewrites — it can
    /// never receive a chip added after its creation. Without the fallback, a
    /// user attaching a skill to a role on such a team would watch it silently
    /// never reach the prompt.
    ///
    /// Both fallbacks are suppressed when the resolved body is empty — a
    /// user-cleared template must ship an empty `system_prompt` (the "control the
    /// whole prompt" contract).
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
        globalContext: String,
        roleSkills: String = ""
    ) -> String {
        let hasExplicitGlobalContext = template.contains("{globalContext}")
        let hasExplicitRoleSkills = template.contains("{roleSkills}")
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
        // ship empty — that's the "control whole prompt" contract). Inserted
        // BEFORE a trailing `## Final reminder` so the legacy-template path
        // never displaces the tail reminder.
        // Skills first so that when BOTH fall back they stack in template order
        // (skills sit above global guidance in every built-in template). Spliced
        // in ONE pass at ONE anchor — see `insertingSections`.
        if !result.isEmpty {
            var sections: [(header: String, body: String)] = []
            if !hasExplicitRoleSkills { sections.append(("## Skills", roleSkills)) }
            if !hasExplicitGlobalContext { sections.append(("## Global guidance", globalContext)) }
            result = insertingSections(sections, into: result)
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
