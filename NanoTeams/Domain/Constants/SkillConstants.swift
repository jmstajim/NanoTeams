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
    /// Header prefix for the LLM-side skill section (sibling of `## Clipped Text`
    /// / `## Attached File:`).
    static let promptHeaderPrefix = "## Skill: "

    /// Full section header for a named skill.
    static func promptHeader(name: String) -> String {
        "\(promptHeaderPrefix)\(name)"
    }

    /// Line-anchored regex matching a `## Skill: <name>` header (use with
    /// `.anchorsMatchLines`). Mirrors the `## Clipped Text` / `## Attached File:`
    /// strip patterns — bare phrases inside body text don't trigger.
    static let stripPattern = "^## Skill: [^\n]+$"
}
