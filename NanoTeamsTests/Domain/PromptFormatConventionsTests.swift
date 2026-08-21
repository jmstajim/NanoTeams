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
                  PromptBuilder.buildConversationMechanicsGuidance(hasTagProducingTools: true)))
        s.append(("conversationMechanicsGuidance/withoutFileReadTools",
                  PromptBuilder.buildConversationMechanicsGuidance(hasTagProducingTools: false)))

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

    // MARK: - Invariant 4: no Settings/Preferences UI paths in LLM-facing text

    /// Every spelling of "go click something in the app" that has actually appeared in this
    /// codebase. The rule is NOT arrow-anchored: an arrow-only needle let
    /// `"…disabled in Settings (mode: Off)"` and `"Set Computer Use to Auto in Settings"`
    /// through for months, and the latter is a line-for-line twin of the bash denial that
    /// prompted the sweep.
    ///
    /// `Preferences →` / `in Preferences` rather than a bare `Preferences`: the bare token's
    /// only hit in the corpus is `rolePrompts["sre"]`'s "Not for style preferences", which is
    /// legitimate prose. Shaping the needle beats adding an exemption.
    ///
    /// Note the historical `"Settings -> "` needle carried a TRAILING SPACE, so
    /// `"Settings ->LLM"` slipped past it. The variants below are space-free.
    static let settingsPathNeedles = [
        "Settings →", "Settings ->", "System Settings",
        "in Settings", "app's settings", "Preferences →", "in Preferences",
    ]

    func testNoSettingsArrowInLLMFacingPrompts() {
        for (label, contents) in Self.auditedSurfaces {
            for needle in Self.settingsPathNeedles where contents.contains(needle) {
                XCTFail("[\(label)] names the UI path \"\(needle)\" — the LLM can't click it. "
                    + "Name the capability and who can change it, not where they'd click.")
            }
        }
    }

    /// Invariant 4, second surface: the tool-rejection envelopes.
    ///
    /// `auditedSurfaces` covers prompts and STATIC tool schemas. It never saw
    /// `makeUnavailableToolResult`'s messages, which are built inline in a `switch` and reach
    /// the model as `precondition_failed` / `tool_not_authorized` envelopes. `CaseIterable`
    /// makes a future reason sweep automatically rather than relying on someone remembering.
    func testNoSettingsPathInToolUnavailabilityMessages() {
        for reason in LLMExecutionService.ToolUnavailabilityReason.allCases {
            let envelope = LLMExecutionService.makeUnavailableToolResult(
                call: StepToolCall(name: ToolNames.readFile, argumentsJSON: "{}"),
                canonicalName: ToolNames.readFile,
                scope: "role",
                reason: reason
            ).outputJSON
            for needle in Self.settingsPathNeedles where envelope.contains(needle) {
                XCTFail("ToolUnavailabilityReason.\(reason) names the UI path \"\(needle)\" — "
                    + "the model reads this envelope and cannot click it.")
            }
            XCTAssertFalse(envelope.isEmpty, "every reason must produce an envelope")
        }
    }

    // MARK: - Invariant 4, third surface: a source scan over model-facing constructions

    /// The value-surface sweeps above can only see strings something hands them. Most
    /// model-read text is an inline literal interpolated into an envelope at the point of
    /// failure, and no registry enumerates those — `makeErrorEnvelope` takes a free-form
    /// `String`, and `ToolErrorCode` enumerates CODES, not messages.
    ///
    /// So scope by the CONSTRUCTION SHAPE that makes a string model-facing rather than by
    /// directory. Two properties fall out of that choice, and both are the point:
    ///
    /// - It reaches `Services/Core`, where `AutovisorActionResult.failure(…)` strings become
    ///   `commandFailed` envelopes. A directory list drawn around `Services/LLM|Tools|Team`
    ///   misses it — and that is exactly where the Autovisor's team-block denials live.
    /// - It excludes `Views/`, so human-facing Settings copy (which SHOULD name panes) can
    ///   never become collateral of its own sweep.
    ///
    /// Files whose Settings references are genuinely human-facing opt out with an explicit
    /// `NTMS-USER-FACING-STRING:` marker carrying a rationale.
    private static let modelFacingConstructions = [
        "makeErrorEnvelope(", "makeErrorResult(", ".deny(reason:",
        "AutovisorActionResult.failure(", "appendSystemMessage:",
    ]

    /// Assembled at runtime so this test's own prose can't match itself.
    private static let userFacingOptOut = "NTMS-USER-FACING" + "-STRING:"

    func testNoSettingsPathInFilesThatBuildModelFacingErrors() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Domain
            .deletingLastPathComponent()   // NanoTeamsTests
            .deletingLastPathComponent()   // repo root
        let sources = root.appendingPathComponent("NanoTeams")
        guard let walker = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil) else {
            return XCTFail("could not walk \(sources.path)")
        }

        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            // Views build the Settings UI itself; naming a pane there is correct.
            guard !url.path.contains("/NanoTeams/Views/") else { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard Self.modelFacingConstructions.contains(where: { raw.contains($0) }) else { continue }
            guard !raw.contains(Self.userFacingOptOut) else { continue }
            scanned += 1

            // Comments legitimately cite Settings paths to explain WHY a gate exists.
            for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = line.contains("//") ? String(line[line.startIndex..<line.range(of: "//")!.lowerBound]) : String(line)
                for needle in Self.settingsPathNeedles where code.contains(needle) {
                    XCTFail("\(url.lastPathComponent) builds model-facing errors and names the UI "
                        + "path \"\(needle)\": \(code.trimmingCharacters(in: .whitespaces)). "
                        + "Name the capability and who can change it — or, if this string is "
                        + "genuinely human-facing, add a \(Self.userFacingOptOut) <why> marker.")
                }
            }
        }
        // Anti-vacuum: the shape list must still select a real population.
        XCTAssertGreaterThan(scanned, 10, "the construction-shape filter selected almost nothing — "
            + "the shapes probably drifted and the scan is now vacuous")
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
