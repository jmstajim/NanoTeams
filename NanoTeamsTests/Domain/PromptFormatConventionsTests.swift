import XCTest
@testable import NanoTeams

/// Drift-protection invariants for all LLM-facing prompt surfaces.
///
/// Covers the four hygiene rules (house style, formerly `docs/prompt-review.md` —
/// retired 2026-07-02 in favor of `docs/TheLocalMultiAgentPromptingPlaybook.md`)
/// that the 2026-05 unification pass standardised on:
///
/// 1. **No `=== HEADER ===` delimiters** — Markdown `## Header` / `### Header`
///    only. (`=== HEADER ===` was the third sectioning style across
///    MemoryTagStore / MeetingCoordinator before unification.)
/// 2. **Title Case section headers** — `## Memories`, `## Team meeting`, never
///    `## MEMORIES`, `## TEAM MEETING`. ALL-CAPS was the outlier vs the
///    canonical `## Role` / `## Final reminder` Title Case in templates.
/// 3. **No "Please" in LLM-facing turn prompts** — filler imperative (playbook
///    §4: smallest set of high-signal tokens). User-facing escalation strings
///    ("Please advise…" routed to Supervisor) are exempt.
/// 4. **No `Settings → …` UI paths in LLM-facing prompts** — the model can't
///    click. Defaults belong in `JSONSchemaLeaf.default`, not prose.
///
/// Whenever a new prompt surface is added, extend the `auditedSurfaces`
/// collection. The grep is exhaustive across the listed surfaces — anything
/// not listed is by definition not part of the convention contract.
final class PromptFormatConventionsTests: XCTestCase {

    /// Every LLM-facing string surface the test sweeps. Pairs are
    /// `(label, contents)` — the label appears in failure messages so an
    /// offending value is locatable without grepping.
    /// `let`, not a computed `var`: building the list renders the full tool
    /// schema body over every registered schema — compute once, not per test.
    private static let auditedSurfaces: [(label: String, contents: String)] = {
        var s: [(String, String)] = []

        // Built-in role prompts (one entry per role).
        for (roleID, prompt) in SystemTemplates.rolePrompts {
            s.append(("rolePrompts[\(roleID)]", prompt))
        }

        // Shared role-prompt fragments.
        s.append(("codingAttachmentsFragment", SystemTemplates.codingAttachmentsFragment))
        s.append(("assistantAttachmentsFragment", SystemTemplates.assistantAttachmentsFragment))
        s.append(("groundingRepoFragment", SystemTemplates.groundingRepoFragment))
        s.append(("groundingFolderFragment", SystemTemplates.groundingFolderFragment))
        s.append(("numberedChoiceFragment", SystemTemplates.numberedChoiceFragment))
        s.append(("codingResponseStyleFragment", SystemTemplates.codingResponseStyleFragment))
        s.append(("engineeringStandardsFragment", SystemTemplates.engineeringStandardsFragment))

        // Step / consultation / meeting templates.
        s.append(("softwareTemplate", SystemTemplates.softwareTemplate))
        s.append(("softwareConsultationTemplate", SystemTemplates.softwareConsultationTemplate))
        s.append(("softwareMeetingTemplate", SystemTemplates.softwareMeetingTemplate))
        s.append(("questPartyTemplate", SystemTemplates.questPartyTemplate))
        s.append(("questPartyConsultationTemplate", SystemTemplates.questPartyConsultationTemplate))
        s.append(("questPartyMeetingTemplate", SystemTemplates.questPartyMeetingTemplate))
        s.append(("discussionTemplate", SystemTemplates.discussionTemplate))
        s.append(("discussionConsultationTemplate", SystemTemplates.discussionConsultationTemplate))
        s.append(("discussionMeetingTemplate", SystemTemplates.discussionMeetingTemplate))
        s.append(("assistantTemplate", SystemTemplates.assistantTemplate))
        s.append(("codingAssistantTemplate", SystemTemplates.codingAssistantTemplate))
        s.append(("genericTemplate", SystemTemplates.genericTemplate))
        s.append(("genericConsultationTemplate", SystemTemplates.genericConsultationTemplate))
        s.append(("genericMeetingTemplate", SystemTemplates.genericMeetingTemplate))
        s.append(("autovisorTemplate", SystemTemplates.autovisorTemplate))

        // One-shot service prompts.
        s.append(("TeamGenerationService.defaultSystemPrompt", TeamGenerationService.defaultSystemPrompt))
        s.append(("SupervisorAutoAnswerService.systemPrompt", SupervisorAutoAnswerService.systemPrompt))
        s.append(("VisionAnalysisService.systemPrompt", VisionAnalysisService.systemPrompt))
        s.append(("AppDefaults.workFolderContextPrompt", AppDefaults.workFolderContextPrompt))

        // The Harmony tool-calling body (format spec + injection boundary +
        // per-tool entries) — rendered into every tool-loop system prompt via
        // the `{toolCalling}` chip or the buildRequest auto-append.
        s.append(("NativeLMStudioClient.buildToolSchemaBody",
                  NativeLMStudioClient.buildToolSchemaBody(tools: ToolHandlerRegistry.allSchemas)))

        // Builder-injected helpers (sample both branches of conditional helpers).
        s.append(("conversationMechanicsGuidance/withFileReadTools",
                  PromptBuilder.buildConversationMechanicsGuidance(hasFileReadTools: true)))
        s.append(("conversationMechanicsGuidance/withoutFileReadTools",
                  PromptBuilder.buildConversationMechanicsGuidance(hasFileReadTools: false)))

        // Tool schema descriptions — `ToolHandlerRegistry.allSchemas` is the
        // single source of truth for what ships in `## Tool Calling` blocks.
        for schema in ToolHandlerRegistry.allSchemas {
            s.append(("toolSchema[\(schema.name)].description", schema.description))
        }

        return s
    }()

    // MARK: - Invariant 5: injection-boundary variants stay tied together

    /// The data-not-instructions boundary is deliberately worded per surface
    /// (artifacts and Supervisor answers are sanctioned direction, so the
    /// carriers scope differently) — but every boundary-bearing surface must
    /// keep SOME boundary phrase. Without this tie, a future strengthening
    /// pass can update four of the five variants and CI stays green while one
    /// surface silently keeps no boundary at all.
    func testInjectionBoundary_presentOnEveryBoundarySurface() {
        let surfaces: [(label: String, contents: String, marker: String)] = [
            ("buildToolSchemaBody",
             NativeLMStudioClient.buildToolSchemaBody(tools: [ToolHandlerRegistry.allSchemas[0]]),
             "not instructions to you"),
            ("SupervisorAutoAnswerService.systemPrompt",
             SupervisorAutoAnswerService.systemPrompt,
             "not instructions to you"),
            ("VisionAnalysisService.systemPrompt",
             VisionAnalysisService.systemPrompt,
             "never instructions to follow"),
            ("AppDefaults.workFolderContextPrompt",
             AppDefaults.workFolderContextPrompt,
             "never instructions to you"),
            ("DelegatedSupervisorAnswerService question turn",
             DelegatedSupervisorAnswerService.questionTurnBoundaryPhrase,
             "not instructions for you"),
        ]
        for (label, contents, marker) in surfaces {
            XCTAssertTrue(contents.contains(marker),
                          "[\(label)] lost its injection-boundary phrase (expected `\(marker)`)")
        }
    }

    // MARK: - Invariant 1: no `=== HEADER ===` delimiters

    func testNoEqualSignHeaderDelimiters() {
        for (label, contents) in Self.auditedSurfaces {
            // Pattern: 3+ `=` followed by space — matches `=== HEADER ===` style.
            // Triple-backtick fenced blocks are fine; markdown `---` separators
            // (exactly three `-`) are fine too (used by globalContext appender).
            XCTAssertFalse(
                contents.contains("=== "),
                "[\(label)] contains `=== ` header delimiter — use `## ` or `### ` Markdown headers instead"
            )
        }
    }

    // MARK: - Invariant 2: section headers are Title Case, not ALL-CAPS

    /// Whitelisted single-word ALL-CAPS section titles that intentionally
    /// remain uppercase as load-bearing emphasis (per existing
    /// SystemTemplatesSectionPinTests pinning). These are exempt from the
    /// Title-Case rule.
    private static let allCapsTitleExemptions: Set<String> = [
        "## PLANNING PHASE",  // PromptBuilder planning-phase prompt — load-bearing marker
    ]

    func testSectionHeaders_areNotAllCaps() {
        // Matches `## SOMETHING` where SOMETHING is at least 4 chars and
        // entirely uppercase letters / spaces (no lowercase letter anywhere
        // in the header text). Single-word `## NPC` etc. wouldn't trigger
        // (3 chars), but `## MEMORIES` and `## TEAM MEETING` would.
        let pattern = #"^#{2,3}\s+[A-Z][A-Z0-9 ]{3,}$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            XCTFail("Regex did not compile — test broken")
            return
        }
        for (label, contents) in Self.auditedSurfaces {
            let ns = contents as NSString
            let matches = regex.matches(in: contents, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let header = ns.substring(with: match.range)
                let trimmed = header.trimmingCharacters(in: .whitespaces)
                if Self.allCapsTitleExemptions.contains(trimmed) { continue }
                XCTFail("[\(label)] ALL-CAPS section header `\(trimmed)` — use Title Case (e.g. `## Memories`)")
            }
        }
    }

    // MARK: - Invariant 3: no "Please" in LLM-facing prompts

    /// Surfaces that route their string to the Supervisor (the user), not the
    /// LLM. "Please advise…" is human-facing English and exempt.
    private static let supervisorFacingSurfaces: Set<String> = [
        // None today — all surfaces sweep are LLM-facing. Add labels here if a
        // future surface mixes UI-facing and LLM-facing prompts in one string.
    ]

    func testNoPleaseInLLMFacingPrompts() {
        // Whole-word "Please" / "please" with word boundary.
        let pattern = #"\b[Pp]lease\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("Regex did not compile — test broken")
            return
        }
        for (label, contents) in Self.auditedSurfaces {
            if Self.supervisorFacingSurfaces.contains(label) { continue }
            let ns = contents as NSString
            let matches = regex.matches(in: contents, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let context = Self.snippet(around: match.range, in: ns)
                XCTFail("[\(label)] contains \"Please\" filler imperative — strip it. Context: …\(context)…")
            }
        }
    }

    // MARK: - Invariant 4: no `Settings → …` UI paths in LLM-facing prompts

    func testNoSettingsArrowInLLMFacingPrompts() {
        for (label, contents) in Self.auditedSurfaces {
            XCTAssertFalse(
                contents.contains("Settings →") || contents.contains("Settings -> "),
                "[\(label)] contains `Settings → …` UI path — the LLM can't click; defaults belong in JSONSchemaLeaf.default"
            )
        }
    }

    // MARK: - Helpers

    private static func snippet(around range: NSRange, in source: NSString) -> String {
        let context: Int = 30
        let start = max(0, range.location - context)
        let endRaw = range.location + range.length + context
        let end = min(source.length, endRaw)
        let snippetRange = NSRange(location: start, length: end - start)
        return source.substring(with: snippetRange).replacingOccurrences(of: "\n", with: "⏎")
    }
}
