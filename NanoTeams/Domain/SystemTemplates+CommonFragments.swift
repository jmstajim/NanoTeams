import Foundation

// MARK: - Common Prompt Fragments
//
// Shared text snippets reused across role prompts so a single edit
// propagates to every role that references the fragment. Without this,
// the same rule lived as near-duplicate prose in 2-3 role prompts and
// drifted with every cleanup pass.
//
// Per-call cost is unchanged (only one role is active at a time); the
// win is purely maintenance — and the unit test
// `SharedRoleFragmentsUsageTests` pins each fragment to its known
// consumers so a future role-prompt rewrite can't silently re-inline
// the body.

nonisolated extension SystemTemplates {

    // `toolCallRequiredFragment` removed 2026-05 — the rule lives in chat-mode
    // templates' `## Output format` section. No production caller references
    // this fragment anymore; the test pinning each fragment to consumers
    // (`SharedRoleFragmentsUsageTests`) catches any re-inlining.

    /// Coding-flavoured attachment processing rule. The "Deictic question +
    /// UI screenshot" extension lives inline in codingAssistant only —
    /// keeping the shared fragment lean.
    /// Used by: codingAssistant, codingAgent.
    static let codingAttachmentsFragment = """
    A `## Attached Files` section lists paths. Open each before doing anything else; filenames are opaque, only content matters.
    - Text / source / PDF / DOCX / XLSX → `read_file` (auto-detected).
    - Image (.png/.jpg/.gif/.webp/.bmp) → `analyze_image` if it's in your tool list; otherwise note the path and ask the Supervisor.
    Do NOT search for the filename, ask what an attachment means, or skip one as "unrelated".
    """

    /// Generic attachment processing rule for non-coding assistants
    /// (documents/notes-flavoured, no source-code references).
    /// Used by: assistant.
    static let assistantAttachmentsFragment = """
    The Supervisor's message may include a `## Attached Files` section. Open each attachment before anything else; the filename is opaque, only content matters.
    - Text / PDF / DOCX / XLSX → `read_file` (auto-detected).
    - Image (.png/.jpg/.jpeg/.gif/.webp/.bmp) → `analyze_image` if it's in your tool list; otherwise note the path and ask the Supervisor.
    Don't search for the filename, ask what an attachment means, or skip one as "unrelated".
    """

    /// "For code or file content, ground in files" rule. Does NOT contradict
    /// `## Conversation mechanics` (which says "Task and artifacts already in
    /// conversation — act on them directly") — this fragment narrows to code /
    /// file content specifically, leaving the in-conversation task as-is.
    /// Used by: codingAssistant, codingAgent.
    static let groundingRepoFragment = """
    For code or file content this project hosts, open the relevant files (list_files / search / read_file) before replying. Cite paths + line numbers (`Services/Foo.swift:42`). For questions clearly NOT about this repo, say "(general — not from this repo)".
    """

    /// Docs-flavoured grounding rule for non-coding assistants. Narrows to
    /// document/notes content (not the in-conversation Supervisor task) so it
    /// doesn't conflict with `## Conversation mechanics`.
    /// Used by: assistant.
    static let groundingFolderFragment = """
    For any question about file content in this folder (documents, notes, decisions stored as files), open the relevant files before replying.
    - Start with top-level docs if present: README*, CLAUDE.md, AGENTS.md, docs/. Then use list_files / search / read_file to find the specific file.
    - Quote file paths in the reply (e.g. `notes/plan.md`) so the user can verify.
    - For questions clearly NOT about this folder (e.g. "capital of France"), say "(general — not from this folder)".
    - Bare greetings and very short replies don't need exploration.
    """

    /// Numbered-choice convention so the Supervisor can answer with one digit.
    /// Used by: assistant, codingAssistant, codingAgent.
    static let numberedChoiceFragment = """
    When offering a choice, use a numbered list (`1.`, `2.`, …) so the Supervisor can answer with just the number. Mark the preferred option `(recommended)`.
    """

    /// Concise / paths / line-numbers / no-empty-question response style for
    /// chat-mode coding roles.
    /// Used by: codingAssistant, codingAgent.
    static let codingResponseStyleFragment = """
    - Concise and practical. Show paths, line numbers, diffs when reporting changes.
    - Never send "What next?" without context.
    """

    /// Engineering standards block (readability / minimal changes /
    /// existing patterns / error paths / no dead code).
    /// Used by: codingAssistant (and inline-paraphrased in softwareEngineer's
    /// role guidance only — codingAgent's prompt does not carry an
    /// `### Engineering standards` section).
    static let engineeringStandardsFragment = """
    - Readability first; minimal changes; match existing patterns. Use only APIs/types already in the repo — don't invent frameworks (`Logger`, `Analytics`) that aren't imported.
    - Explicit error paths, no silent failures.
    - No commented-out code, unused imports, or untracked TODOs.
    """
}
