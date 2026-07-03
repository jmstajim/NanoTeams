import XCTest
@testable import NanoTeams

/// Pins `TemplateResolver` invariants — including the bundled
/// `resolveSystemPrompt` helper that every system-prompt builder
/// (runtime + preview) now funnels through.
final class TemplateResolverTests: XCTestCase {

    // MARK: - resolve

    func testResolve_replacesPlaceholders() {
        let out = TemplateResolver.resolve(
            "Hello {name}, you have {count} messages.",
            placeholders: ["name": "Alice", "count": "3"]
        )
        XCTAssertEqual(out, "Hello Alice, you have 3 messages.")
    }

    func testResolve_unknownPlaceholdersStayLiteral() {
        let out = TemplateResolver.resolve(
            "{known} and {unknown}",
            placeholders: ["known": "Hi"]
        )
        XCTAssertEqual(out, "Hi and {unknown}")
    }

    // MARK: - appendingSeparator

    func testAppendingSeparator_emptySuffixReturnsTextUnchanged() {
        let base = "system prompt"
        XCTAssertEqual(TemplateResolver.appendingSeparator("", to: base), base)
        XCTAssertEqual(TemplateResolver.appendingSeparator("   \n  ", to: base), base)
    }

    func testAppendingSeparator_appendsAsGlobalGuidanceSection() {
        let out = TemplateResolver.appendingSeparator("global ctx", to: "base")
        XCTAssertEqual(out, "base\n\n## Global guidance\n\nglobal ctx")
    }

    func testAppendingSeparator_trimsSuffix() {
        let out = TemplateResolver.appendingSeparator("\n  suffix  \n", to: "base")
        XCTAssertEqual(out, "base\n\n## Global guidance\n\nsuffix")
    }

    // MARK: - collapseBlankLines

    func testCollapseBlankLines_emptyInput() {
        XCTAssertEqual(TemplateResolver.collapseBlankLines(""), "")
    }

    func testCollapseBlankLines_noNewlines_returnsUnchanged() {
        XCTAssertEqual(TemplateResolver.collapseBlankLines("abc def"), "abc def")
    }

    /// Single `\n` and `\n\n` (paragraph-break) must pass through unchanged —
    /// the helper only collapses RUNS of 3+ newlines.
    func testCollapseBlankLines_one_and_two_newlines_passThrough() {
        XCTAssertEqual(TemplateResolver.collapseBlankLines("a\nb"), "a\nb")
        XCTAssertEqual(TemplateResolver.collapseBlankLines("a\n\nb"), "a\n\nb")
    }

    func testCollapseBlankLines_threeNewlines_collapsesToTwo() {
        XCTAssertEqual(TemplateResolver.collapseBlankLines("a\n\n\nb"), "a\n\nb")
    }

    func testCollapseBlankLines_fiveNewlines_collapsesToTwo() {
        XCTAssertEqual(TemplateResolver.collapseBlankLines("a\n\n\n\n\nb"), "a\n\nb")
    }

    /// All-newline input collapses to exactly two — the boundary case where
    /// the run extends to EOF without a non-newline reset.
    func testCollapseBlankLines_allNewlines_collapsesToTwo() {
        XCTAssertEqual(TemplateResolver.collapseBlankLines("\n\n\n\n"), "\n\n")
    }

    /// Multiple separate runs collapse independently — the run counter must
    /// reset on every non-newline character.
    func testCollapseBlankLines_multipleRuns_collapseIndependently() {
        let input  = "a\n\n\n\nb\n\n\nc"
        let output = "a\n\nb\n\nc"
        XCTAssertEqual(TemplateResolver.collapseBlankLines(input), output)
    }

    /// Trailing newlines beyond run-of-2 also collapse (no terminator special case).
    func testCollapseBlankLines_trailingNewlines_collapse() {
        XCTAssertEqual(TemplateResolver.collapseBlankLines("body\n\n\n\n"), "body\n\n")
    }

    /// Leading newlines beyond run-of-2 also collapse (no preamble special case).
    func testCollapseBlankLines_leadingNewlines_collapse() {
        XCTAssertEqual(TemplateResolver.collapseBlankLines("\n\n\n\nbody"), "\n\nbody")
    }

    /// Content between newline runs is preserved exactly — the helper is
    /// content-preserving, not just whitespace-normalizing.
    func testCollapseBlankLines_preservesContent() {
        let input  = "## Header\n\n\n\nParagraph one.\n\n\n\nParagraph two."
        let output = "## Header\n\nParagraph one.\n\nParagraph two."
        XCTAssertEqual(TemplateResolver.collapseBlankLines(input), output)
    }

    /// Realistic placeholder-substitution residue: `{toolList}` resolving to
    /// `""` between two non-empty blocks leaves a triple-newline run. The
    /// helper collapses it without touching the surrounding content.
    func testCollapseBlankLines_realisticPlaceholderResidue() {
        // Simulates what `resolve` produces when `{toolList}` resolves to "":
        let input = """
            You are a role.


            Your expertise:
            something.


            Deliverables: foo.
            """
        // The double-blank `\n\n\n` runs become `\n\n` (one blank line).
        let output = """
            You are a role.

            Your expertise:
            something.

            Deliverables: foo.
            """
        XCTAssertEqual(TemplateResolver.collapseBlankLines(input), output)
    }

    /// Documents a known limitation: only `\n` is counted toward the run.
    /// CRLF-encoded sequences (`\r\n\r\n\r\n…`) are NOT collapsed because
    /// the intervening `\r` resets the run counter on every newline. Prompt
    /// templates in this project are LF-only (Swift multi-line string
    /// literals emit `\n`), so this is acceptable. Pin the behaviour so a
    /// future implementation switch doesn't silently change semantics on
    /// any future CRLF-bearing template (e.g. loaded from a Windows-encoded
    /// disk file).
    func testCollapseBlankLines_crlf_isNotCollapsed_documentedLimitation() {
        let crlfTriple = "a\r\n\r\n\r\nb"
        XCTAssertEqual(
            TemplateResolver.collapseBlankLines(crlfTriple),
            crlfTriple,
            "CRLF runs are documented as not collapsed; if this fails, update the helper's comment in TemplateResolver.swift."
        )
    }

    // MARK: - stripOrphanHeaders (G2 — direct unit tests for chip-format contract linchpin)

    /// Single empty `## ` header between two non-empty sections → stripped.
    /// The simplest case — header has no body, next `##` follows after blank
    /// lines. This is the case exercised by chip resolution to `""`.
    func testStripOrphanHeaders_emptyBetweenTwoSections_strips() {
        let input = """
            ## A
            content A

            ## Empty

            ## B
            content B
            """
        let result = TemplateResolver.stripOrphanHeaders(input)
        XCTAssertFalse(result.contains("## Empty"),
                       "Empty `## Empty` header must be stripped; got:\n\(result)")
        XCTAssertTrue(result.contains("## A\ncontent A"))
        XCTAssertTrue(result.contains("## B\ncontent B"))
    }

    /// Chain of TWO consecutive empty `## ` headers → BOTH stripped.
    /// The fixed-point loop is load-bearing here — `NSRegularExpression.stringByReplacingMatches`
    /// strips all non-overlapping matches in one pass for non-adjacent
    /// occurrences, but adjacent matches require re-scan because each
    /// strip can make the next match's look-ahead newly satisfiable.
    func testStripOrphanHeaders_chainOfTwoEmptySections_bothStripped() {
        let input = """
            ## A
            content A

            ## Empty1

            ## Empty2

            ## B
            content B
            """
        let result = TemplateResolver.stripOrphanHeaders(input)
        XCTAssertFalse(result.contains("## Empty1"),
                       "First empty header must be stripped; got:\n\(result)")
        XCTAssertFalse(result.contains("## Empty2"),
                       "Second empty header must be stripped (fixed-point); got:\n\(result)")
    }

    /// Chain of THREE consecutive empty sections — all three stripped.
    func testStripOrphanHeaders_chainOfThreeEmptySections_allStripped() {
        let input = """
            ## A
            content

            ## E1

            ## E2

            ## E3

            ## B
            content
            """
        let result = TemplateResolver.stripOrphanHeaders(input)
        for header in ["## E1", "## E2", "## E3"] {
            XCTAssertFalse(result.contains(header),
                           "All chained empty headers must be stripped; `\(header)` survived:\n\(result)")
        }
    }

    /// Trailing empty `## ` at end-of-string — handled by the trailing-pattern
    /// regex (the body pattern's `(?=^##|\z)` look-ahead does match `\z` but
    /// `[\s]*` requires whitespace to consume, which isn't always present at
    /// EOS without the secondary pass).
    func testStripOrphanHeaders_trailingEmptyAtEOS_strips() {
        let input = """
            ## A
            content

            ## Trailing
            """
        let result = TemplateResolver.stripOrphanHeaders(input)
        XCTAssertFalse(result.contains("## Trailing"),
                       "Trailing empty header at EOS must be stripped; got:\n\(result)")
        XCTAssertTrue(result.contains("## A\ncontent"))
    }

    /// `## Header\n### Subsection` content → the `## Header` is NOT stripped.
    /// The look-ahead in the main regex requires `^## ` (two hashes followed
    /// by space), not `^#` — so a `### ` subsection does NOT match and the
    /// parent's body counts as non-empty.
    func testStripOrphanHeaders_h3SubsectionUnderH2_doesNotStripParent() {
        let input = """
            ## Parent

            ### Sub
            sub content

            ## After
            content
            """
        let result = TemplateResolver.stripOrphanHeaders(input)
        XCTAssertTrue(result.contains("## Parent"),
                      "Parent `## ` header with `### ` subsection content must NOT be stripped; got:\n\(result)")
        XCTAssertTrue(result.contains("### Sub"))
    }

    /// No-op fast path: input has no `## ` headers at all.
    func testStripOrphanHeaders_noHeaders_returnsUnchanged() {
        let input = "Just plain text\nwith no headers\nat all."
        XCTAssertEqual(TemplateResolver.stripOrphanHeaders(input), input)
    }

    /// No-op when every section has body — nothing to strip.
    func testStripOrphanHeaders_allSectionsHaveBody_returnsUnchanged() {
        let input = """
            ## A
            content A

            ## B
            content B
            """
        XCTAssertEqual(TemplateResolver.stripOrphanHeaders(input), input)
    }

    /// 2026-05 chip-rendering refactor: `{teamDescription}` resolves to the
    /// bare description text. With a real value present, the label + value
    /// sit on one line.
    func testResolveSystemPrompt_nonEmptyTeamDescription_labelAndValueOnOneLine() {
        let template = "## Team\nMembers: {teamRoles}.\n\nTeam purpose: {teamDescription}\nYour position: {positionContext}."
        let resolved = TemplateResolver.resolveSystemPrompt(
            template,
            placeholders: ["teamRoles": "A, B", "teamDescription": "Lean engineering.", "positionContext": "lead"],
            globalContext: ""
        )
        XCTAssertEqual(resolved, "## Team\nMembers: A, B.\n\nTeam purpose: Lean engineering.\nYour position: lead.")
    }

    // MARK: - stripOrphanInlineLabels

    /// Trailing space + end-of-line — the most common shape after `resolve`
    /// substitutes `{teamDescription}` with `""`.
    func testStripOrphanInlineLabels_trailingSpaceEmpty_lineRemoved() {
        let input = "Members: A, B.\n\nTeam purpose: \nYour position: lead.\n"
        XCTAssertEqual(
            TemplateResolver.stripOrphanInlineLabels(input),
            "Members: A, B.\n\nYour position: lead.\n"
        )
    }

    /// Bare label without trailing space (`Team purpose:\n`) — the `[ \t]*` is
    /// "zero or more" so this strips too.
    func testStripOrphanInlineLabels_bareLabel_lineRemoved() {
        let input = "Members: x.\nTeam purpose:\nYour position: y.\n"
        XCTAssertEqual(
            TemplateResolver.stripOrphanInlineLabels(input),
            "Members: x.\nYour position: y.\n"
        )
    }

    /// Non-empty value MUST survive untouched. The `$` end-of-line anchor
    /// requires only whitespace between the colon and the line break — any
    /// real content after the space defeats the match.
    func testStripOrphanInlineLabels_nonEmptyValue_preserved() {
        let input = "Team purpose: Lean engineering pipeline.\n"
        XCTAssertEqual(TemplateResolver.stripOrphanInlineLabels(input), input)
    }

    /// Mid-line mention (e.g. `"Note: Team purpose: is a section header."`)
    /// must survive — anchored on `^` so only line-start orphans match.
    func testStripOrphanInlineLabels_midLineMention_preserved() {
        let input = "Note: Team purpose: is a section header.\n"
        XCTAssertEqual(TemplateResolver.stripOrphanInlineLabels(input), input)
    }

    /// Other empty-label-shaped lines (e.g. `Members: \n`) are NOT touched —
    /// the pattern is anchored to the single known `Team purpose:` label.
    func testStripOrphanInlineLabels_otherLabels_preserved() {
        let input = "Members: \nYour position: \n"
        XCTAssertEqual(TemplateResolver.stripOrphanInlineLabels(input), input)
    }

    /// Single trailing tab between colon and newline — `[ \t]*` covers tabs too.
    func testStripOrphanInlineLabels_trailingTab_lineRemoved() {
        let input = "Team purpose:\t\nYour position: lead.\n"
        XCTAssertEqual(
            TemplateResolver.stripOrphanInlineLabels(input),
            "Your position: lead.\n"
        )
    }

    // MARK: - resolveSystemPrompt — empty teamDescription end-to-end

    /// Empty `{teamDescription}` MUST NOT leave an orphan `Team purpose: `
    /// label in the resolved prompt. Symmetric with `stripOrphanHeaders` (which
    /// collapses empty `##` sections). Reproduces the user-visible bug:
    /// custom teams with no description currently show a dangling label.
    func testResolveSystemPrompt_emptyTeamDescription_dropsOrphanLabel() {
        let template = "## Team\nMembers: {teamRoles}.\n\nTeam purpose: {teamDescription}\nYour position: {positionContext}."
        let resolved = TemplateResolver.resolveSystemPrompt(
            template,
            placeholders: ["teamRoles": "A, B", "teamDescription": "", "positionContext": "lead"],
            globalContext: ""
        )
        XCTAssertFalse(resolved.contains("Team purpose:"),
                       "empty `{teamDescription}` must collapse the whole `Team purpose: ` line, "
                       + "not leave an orphan label. Got:\n\(resolved)")
        XCTAssertEqual(resolved, "## Team\nMembers: A, B.\n\nYour position: lead.",
                       "neighbouring blank line must collapse the same way `stripOrphanHeaders` "
                       + "handles empty `##` sections")
    }

    // MARK: - resolve — single-pass semantics (values are data, never re-scanned)

    /// A placeholder VALUE containing another `{key}` token must ship verbatim.
    /// The prior implementation looped `for (key, value) in placeholders` with
    /// `replacingOccurrences` — Swift Dictionary iteration order is re-randomized
    /// per process, so whether the nested token expanded depended on hash seeding
    /// at app launch (non-deterministic bytes on the wire, and a mild injection
    /// vector: user-authored roleGuidance/globalContext mentioning `{toolCalling}`
    /// could smuggle a second tool-catalog copy into the prompt).
    func testResolve_valueContainingPlaceholderToken_isNotReExpanded() {
        let out = TemplateResolver.resolve(
            "{roleGuidance}\n{expectedArtifacts}",
            placeholders: [
                "roleGuidance": "Use the EXACT names from {expectedArtifacts}.",
                "expectedArtifacts": "Release Notes",
            ]
        )
        XCTAssertEqual(out, "Use the EXACT names from {expectedArtifacts}.\nRelease Notes")
    }

    /// Same-input resolution must be byte-identical across repeated calls —
    /// no dependence on dictionary iteration order.
    func testResolve_isDeterministic() {
        let template = "{a}{b}{c}"
        let placeholders = ["a": "{b}", "b": "{c}", "c": "X"]
        let first = TemplateResolver.resolve(template, placeholders: placeholders)
        for _ in 0..<50 {
            XCTAssertEqual(TemplateResolver.resolve(template, placeholders: placeholders), first)
        }
        XCTAssertEqual(first, "{b}{c}X", "values are data — chained expansion must not occur")
    }

    func testResolve_adjacentPlaceholders() {
        XCTAssertEqual(
            TemplateResolver.resolve("{a}{b}", placeholders: ["a": "1", "b": "2"]),
            "12"
        )
    }

    func testResolve_placeholderAtStartAndEnd() {
        XCTAssertEqual(
            TemplateResolver.resolve("{a} mid {b}", placeholders: ["a": "S", "b": "E"]),
            "S mid E"
        )
    }

    func testResolve_emptyBraces_stayLiteral() {
        XCTAssertEqual(TemplateResolver.resolve("{} {a}", placeholders: ["a": "x"]), "{} x")
    }

    func testResolve_unclosedBrace_staysLiteral() {
        XCTAssertEqual(TemplateResolver.resolve("{a and {b}", placeholders: ["b": "x"]), "{a and x")
    }

    func testResolve_emptyTemplate() {
        XCTAssertEqual(TemplateResolver.resolve("", placeholders: ["a": "x"]), "")
    }

    func testResolve_emptyPlaceholders_returnsTemplateUnchanged() {
        XCTAssertEqual(TemplateResolver.resolve("{a} {b}", placeholders: [:]), "{a} {b}")
    }

    // MARK: - insertingGlobalGuidance (tail-slot preservation)

    func testInsertingGlobalGuidance_beforeTrailingFinalReminder() {
        let text = "## Role\nX\n\n## Final reminder\nSubmit once."
        let out = TemplateResolver.insertingGlobalGuidance("ctx", into: text)
        XCTAssertEqual(out, "## Role\nX\n\n## Global guidance\n\nctx\n\n## Final reminder\nSubmit once.")
    }

    func testInsertingGlobalGuidance_noFinalReminder_appends() {
        let out = TemplateResolver.insertingGlobalGuidance("ctx", into: "## Role\nX")
        XCTAssertEqual(out, "## Role\nX\n\n## Global guidance\n\nctx")
    }

    func testInsertingGlobalGuidance_emptySuffix_unchanged() {
        let text = "## Role\nX\n\n## Final reminder\nY"
        XCTAssertEqual(TemplateResolver.insertingGlobalGuidance("  \n ", into: text), text)
    }

    /// A "## Final reminder" mentioned mid-line (not at a line start) is prose,
    /// not a header — must not trigger the insertion split.
    func testInsertingGlobalGuidance_midLineMention_isNotAHeader() {
        let text = "The section named ## Final reminder is special."
        let out = TemplateResolver.insertingGlobalGuidance("ctx", into: text)
        XCTAssertTrue(out.hasSuffix("## Global guidance\n\nctx"),
                      "mid-line mention must be treated as prose; guidance appends at the end")
    }

    /// The legacy auto-append path in `resolveSystemPrompt` (template without a
    /// `{globalContext}` chip) must not displace the tail reminder either.
    func testResolveSystemPrompt_legacyAutoAppend_keepsFinalReminderLast() {
        let template = "## Role\n{roleName}\n\n## Final reminder\nSubmit once."
        let out = TemplateResolver.resolveSystemPrompt(
            template, placeholders: ["roleName": "PM"], globalContext: "ctx"
        )
        guard let guidance = out.range(of: "## Global guidance"),
              let fr = out.range(of: "## Final reminder") else {
            return XCTFail("both sections expected, got:\n\(out)")
        }
        XCTAssertLessThan(guidance.lowerBound, fr.lowerBound)
        XCTAssertTrue(out.hasSuffix("Submit once."))
    }
}
