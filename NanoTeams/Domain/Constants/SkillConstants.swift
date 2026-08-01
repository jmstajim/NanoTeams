import Foundation

/// Single source of truth for the LLM-side "agent skill" section format.
///
/// A skill snippet picked in the composer rides the `clippedTexts` pipe as a
/// `SkillClip` (see `Domain/SkillClip.swift`) and is rendered into the prompt as
/// a `## Skill: <name>` section by `AnswerTextBuilder.clipSections`. The activity
/// feed re-extracts those sections back into skill chips via
/// `ActivityFeedBuilder.stripAttachedFiles`. All three consumers reference the
/// constants here so the header/regex can never drift between emit and strip.
nonisolated enum SkillConstants {
    /// The label both surfaces share. Kept separate from the `#` prefixes so the
    /// two call sites can sit at different heading depths without the wording
    /// drifting apart.
    static let headerLabel = "Skill: "

    /// Header prefix for the LLM-side skill section in a USER message (sibling of
    /// `## Clipped Text` / `## Attached File:`).
    static let promptHeaderPrefix = "## \(headerLabel)"

    /// Header prefix for a skill inside the SYSTEM prompt's `## Skills` section.
    ///
    /// One level deeper than the chat path, and that is load-bearing rather than
    /// stylistic: the system prompt is a flat sequence of h2 sections, so an h2
    /// per-skill header would (a) read as a prompt-level section rather than as
    /// part of the skill and (b) make `TemplateResolver.stripOrphanHeaders` see
    /// `## Skills` immediately followed by another `##` line — i.e. a header with
    /// an empty body — and delete the section header the template author wrote.
    static let systemPromptHeaderPrefix = "### \(headerLabel)"

    /// Heading level of `systemPromptHeaderPrefix`; skill bodies nest below it.
    static let systemPromptHeaderLevel = 3

    /// Full section header for a named skill in a user message.
    static func promptHeader(name: String) -> String {
        "\(promptHeaderPrefix)\(singleLine(name))"
    }

    /// Full section header for a named skill inside the system prompt.
    static func systemPromptHeader(name: String) -> String {
        "\(systemPromptHeaderPrefix)\(singleLine(name))"
    }

    /// Folds a name onto one line, because a header IS one line.
    ///
    /// `SkillMetadataExtractor` only ever yields single-line frontmatter
    /// scalars, but the fallback name is derived from a path component — and
    /// POSIX permits a newline in a filename. Such a name would emit a second
    /// line into the middle of a header, fabricating a prompt-level section
    /// inside the `## Skills` block and breaking `stripPattern`'s `[^\n]+`
    /// round-trip on the chat side. Every real name is unaffected byte-for-byte.
    private static func singleLine(_ name: String) -> String {
        name.components(separatedBy: .newlines).joined(separator: " ")
    }

    /// Line-anchored regex matching a `## Skill: <name>` header (use with
    /// `.anchorsMatchLines`). Mirrors the `## Clipped Text` / `## Attached File:`
    /// strip patterns — bare phrases inside body text don't trigger.
    static let stripPattern = "^## Skill: [^\n]+$"

    /// Re-levels a skill body's markdown headings so they nest UNDER the
    /// `Skill:` header instead of competing with the system prompt's own
    /// sections.
    ///
    /// **Why this is not optional.** A role's system prompt is a flat sequence of
    /// h2 sections — `## Guidance`, `## Constraints`, `## Deliverables`,
    /// `## Tool Calling`, `## Final reminder`. A skill body pasted in verbatim
    /// brings its own `#`/`##` headings, which then read as prompt-level
    /// directives rather than as part of the skill: a skill with a `## Rules`
    /// section becomes structurally indistinguishable from the prompt's own
    /// `## Constraints`. Measured on this machine, **125 of 135** installed
    /// skills carry such headings (worst case 22 in one file), so this is the
    /// common case, not an edge one.
    ///
    /// The house already forbids exactly this for role guidance —
    /// `SystemTemplatesSectionPinTests.testEveryRolePrompt_internalHeadersAreH3NotH2`
    /// requires every in-guidance header to be h3 "so it nests under the
    /// template's `## Guidance` scaffold". Role prompts are ours to write;
    /// skill bodies are third-party, so the same invariant has to be enforced
    /// at render time instead of by review.
    ///
    /// **Content-preserving, not a cap.** Nothing is dropped or truncated — only
    /// the `#` prefix depth shifts. Relative structure is preserved by shifting
    /// every heading by the same delta (derived from the shallowest one), so a
    /// document's own hierarchy still reads correctly. A body whose headings are
    /// already h3-or-deeper passes through byte-identical.
    ///
    /// Fenced code blocks are skipped — a `# comment` inside a shell example is
    /// not a heading. Both ``` and ~~~ fences are honoured, and a fence left
    /// unclosed keeps the remainder untouched (the safe direction: never rewrite
    /// what might be code).
    ///
    /// - Parameter headingLevel: depth of the header this body sits under. The
    ///   shallowest heading in `body` lands one level below it. Required rather
    ///   than defaulted: the whole job of this function is getting a level
    ///   right, so the call site says which one.
    static func nestedBody(_ body: String, under headingLevel: Int) -> String {
        let lines = body.components(separatedBy: "\n")
        let minimumLevel = headingLevel + 1

        var shallowest = Int.max
        forEachHeading(in: lines) { _, level in shallowest = min(shallowest, level) }
        guard shallowest != .max, shallowest < minimumLevel else { return body }
        let delta = minimumLevel - shallowest

        var result = lines
        forEachHeading(in: lines) { index, level in
            let newLevel = min(level + delta, 6)
            let rest = lines[index].drop(while: { $0 == "#" })
            result[index] = String(repeating: "#", count: newLevel) + rest
        }
        return result.joined(separator: "\n")
    }

    /// Walks `lines`, invoking `body` with the index and heading level of every
    /// ATX heading outside a fenced code block. Leading whitespace disqualifies
    /// a heading (an indented `#` is code or a list continuation, not a header),
    /// matching CommonMark closely enough for prompt text.
    private static func forEachHeading(
        in lines: [String],
        _ body: (_ index: Int, _ level: Int) -> Void
    ) {
        var fence: String?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") { fence = "```"; continue }
            if trimmed.hasPrefix("~~~") { fence = "~~~"; continue }
            // Unindented only: `line`, not `trimmed`, so an indented heading-like
            // line inside a list or code sample is left alone.
            guard line.hasPrefix("#") else { continue }
            let level = line.prefix(while: { $0 == "#" }).count
            // `#Foo` is not a heading in CommonMark — a space must follow.
            guard level <= 6, line.dropFirst(level).hasPrefix(" ") else { continue }
            body(index, level)
        }
    }
}
