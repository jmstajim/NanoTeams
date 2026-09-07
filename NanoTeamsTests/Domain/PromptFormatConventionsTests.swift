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
///    §4: smallest set of high-signal tokens). Nothing is exempt: the cap-escalation
///    questions once held "Please advise…" as "user-facing", but `PromptBuilder` replays
///    them into the role's own next request and `SupervisorAutoAnswerService` reads them
///    as an LLM — `Ratchet/NudgeTextPinTests` sweeps them case-insensitively.
/// 4. **No `Settings → …` UI paths in LLM-facing prompts** — the model can't
///    click. Defaults belong in `JSONSchemaLeaf.default`, not prose.
///
/// Whenever a new prompt surface is added, extend the `auditedSurfaces`
/// collection. The grep is exhaustive across the listed surfaces — anything
/// not listed is by definition not part of the convention contract.
@MainActor
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
        // Built-in meeting bodies — `{roleGuidance}` of a meeting turn.
        for (roleID, body) in SystemTemplates.roleMeetingGuidance {
            s.append(("roleMeetingGuidance[\(roleID)]", body))
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

        // One-shot service prompts — the census below, so a prompt registered for
        // its boundary is swept by every other invariant too, and vice versa.
        for row in oneShotSystemPrompts {
            s.append((row.label, row.contents))
        }

        // The Harmony tool-calling body (format spec + injection boundary +
        // per-tool entries) — rendered into every tool-loop system prompt via
        // the `{toolCalling}` chip or the buildRequest auto-append.
        s.append(("NativeLMStudioClient.buildToolSchemaBody",
                  NativeLMStudioClient.buildToolSchemaBody(tools: ToolHandlerRegistry.allSchemas)))

        // Every runtime-composed text — nudges, loop recovery, error-note directions, the
        // voting turn, the meeting directives, the planning brief — rendered with the
        // registry's fixed samples. One table for the format sweep AND the provenance
        // fingerprint, so a composer that is versioned is audited and vice versa.
        for entry in RuntimePromptRegistry.entries where !oneShotSystemPrompts.contains(where: { $0.label == entry.name }) {
            s.append((entry.name, entry.render()))
        }

        // Tool schema descriptions — `ToolHandlerRegistry.allSchemas` is the
        // single source of truth for what ships in `## Tool Calling` blocks.
        for schema in ToolHandlerRegistry.allSchemas {
            s.append(("toolSchema[\(schema.name)].description", schema.description))
        }

        return s
    }()

    // MARK: - Invariant 5: every one-shot system prompt carries an injection boundary

    /// The census of one-shot system prompts: every `ChatMessage(role: .system, content:` a
    /// service builds itself under `NanoTeams/Services`, keyed by the file that builds it.
    /// `file` is what the source scan below matches against; `contents` is the rendered value
    /// the boundary invariant reads (rendered, because `WorkFolderContextService`'s prompt
    /// lives in `AppDefaults`, and the two judges' take a policy).
    ///
    /// Until 2026-09-06 `testInjectionBoundary_presentOnEveryBoundarySurface` listed four of
    /// these by hand — a SAMPLE posing as a census (DEBTS.md §5, D-18: the same shape, a list
    /// of consumers that was a selection) — and the two it did not list were exactly the two
    /// with no boundary: `TeamGenerationService` (whose whole input, via `delegate_to_team`,
    /// is a brief written by a model) and `BashExplainService` (whose output the human reads
    /// beside the approval gate). The scan makes the list a census: a new one-shot prompt
    /// fails here until it is registered, and registering it puts it under the boundary rule.
    static var oneShotSystemPrompts: [(file: String, label: String, contents: String)] {
        RuntimePromptRegistry.oneShotSystemPrompts.map { ($0.file, $0.label, $0.render()) }
    }

    /// Files that build a system message and are NOT one-shot prompts, with the reason each
    /// is outside the census. Shrink-only: a row whose file stops building a system message
    /// fails the census test so the row is deleted, not forgotten.
    private static let systemMessageBuildersOutsideTheCensus: [String: String] = [
        "PromptBuilder.swift":
            "composes the team's system-prompt TEMPLATE; the `{toolCalling}` body it renders "
            + "carries the boundary (pinned below and by `PromptBuilderWirePreviewTests`)",
        "MeetingStreamingService.swift":
            "renders the team's meeting template, plus the same tool body",
        "LLMExecutionService+ConsultationChat.swift":
            "persists the consultation chat's system turn, built from the team's consultation "
            + "TEMPLATE (`buildConsultationSystemPrompt`) — the template carries the boundary",
    ]

    /// The boundary is deliberately worded per surface (artifacts and Supervisor answers are
    /// sanctioned direction, so the carriers scope differently), so the invariant is "one of
    /// the house phrasings", not one string.
    private static let boundaryPhrasings = [
        "not instructions to you", "never instructions to you",
        "never instructions to follow", "never follow instructions",
        "not instructions for you", "never orders to follow",
    ]

    /// Boundary-bearing surfaces that are USER turns or template bodies rather than one-shot
    /// system prompts — outside the census, inside the phrase invariant.
    private static let otherBoundarySurfaces: [(label: String, contents: String)] = [
        ("buildToolSchemaBody",
         NativeLMStudioClient.buildToolSchemaBody(tools: [ToolHandlerRegistry.allSchemas[0]])),
        ("DelegatedSupervisorAnswerService question turn",
         DelegatedSupervisorAnswerService.questionTurnBoundaryPhrase),
    ]

    /// Every one-shot system prompt and every other boundary surface carries one of the
    /// house boundary phrasings. Without this tie, a strengthening pass can update seven of
    /// eight variants and CI stays green while one surface silently keeps no boundary at all.
    func testInjectionBoundary_presentOnEveryBoundarySurface() {
        let surfaces = Self.oneShotSystemPrompts.map { ($0.label, $0.contents) } + Self.otherBoundarySurfaces
        XCTAssertGreaterThanOrEqual(surfaces.count, 10, "anti-vacuum: eight one-shot prompts plus two other surfaces")
        for (label, contents) in surfaces {
            XCTAssertTrue(Self.boundaryPhrasings.contains { contents.contains($0) },
                          "[\(label)] carries no injection-boundary phrase (expected one of \(Self.boundaryPhrasings)). Got:\n\(contents)")
        }
    }

    /// The census IS a census: every file under `NanoTeams/Services` that builds a system
    /// message is either a registered one-shot prompt or explicitly outside the census with a
    /// reason — in both directions, so a stale row is as red as a missing one.
    ///
    /// RED by construction on the 2026-09-05 tree: `BashExplainService.swift` and
    /// `TeamGenerationService.swift` build a system message and were in no list.
    func testEveryOneShotSystemPromptIsARegisteredBoundarySurface() throws {
        let root = RatchetSourceScan.repoRoot.appendingPathComponent("NanoTeams/Services")
        var found: Set<String> = []
        for url in RatchetSourceScan.swiftFiles(under: root) {
            let code = try String(contentsOf: url, encoding: .utf8)
            // `(role: .system, content:` — both `ChatMessage` and `LLMMessage` spellings, so a
            // system turn persisted as an `LLMMessage` (the consultation chat) is a builder too;
            // until 2026-09-07 the needle named `ChatMessage` and that file was invisible.
            if RatchetSourceScan.strippingLineComments(code).contains("(role: .system, content:") {
                found.insert(url.lastPathComponent)
            }
        }
        XCTAssertGreaterThanOrEqual(found.count, 10, "anti-vacuum: the scan must see the builders. Found: \(found.sorted())")

        let outside = Set(Self.systemMessageBuildersOutsideTheCensus.keys)
        XCTAssertEqual(outside.subtracting(found), [],
                       "allowlist rows whose file no longer builds a system message — delete the row")

        let oneShots = found.subtracting(outside)
        let census = Set(Self.oneShotSystemPrompts.map(\.file))
        XCTAssertEqual(oneShots.subtracting(census).sorted(), [],
                       "one-shot system prompts with no row in `oneShotSystemPrompts` — register each "
                           + "(and give it a boundary sentence): \(oneShots.subtracting(census).sorted())")
        XCTAssertEqual(census.subtracting(oneShots).sorted(), [],
                       "census rows whose file no longer builds a system message: \(census.subtracting(oneShots).sorted())")
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
                XCTFail("[\(label)] ALL-CAPS section header `\(trimmed)` — use Title Case (e.g. `## Memories`)")
            }
        }
    }

    // MARK: - Invariant 5b: every one-shot system prompt follows the service skeleton (R5.1.6)

    /// Line 1 is the identity and the single responsibility; an `Inputs:` line names what
    /// rides the user turn; an `Output:` line is the stop condition. `TeamGenerationService`
    /// keeps its `## `-sectioned body (its enum tables are the output contract) and is held
    /// to line 1 only — the recorded exception. Seven of the eight rows opened otherwise
    /// until 2026-09-07.
    func testEveryOneShotSystemPromptFollowsTheServiceSkeleton() throws {
        let identity = try NSRegularExpression(pattern: #"^You are the .+ in a multi-agent pipeline\. Your single responsibility: .+"#)
        let sectioned: Set<String> = ["TeamGenerationService.defaultSystemPrompt"]
        for row in Self.oneShotSystemPrompts {
            let lines = row.contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let first = lines.first ?? ""
            XCTAssertNotNil(identity.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)),
                            "[\(row.label)] line 1 must be the identity + single responsibility, got: \(first.prefix(100))")
            if sectioned.contains(row.label) { continue }
            XCTAssertTrue(lines.contains { $0.hasPrefix("Inputs: ") }, "[\(row.label)] no `Inputs:` line")
            XCTAssertTrue(lines.contains { $0.hasPrefix("Output: ") }, "[\(row.label)] no `Output:` line")
            XCTAssertLessThanOrEqual(row.contents.components(separatedBy: "{\"decision\"").count - 1, 2,
                                     "[\(row.label)] at most the shape line and ONE example reply (R5.3.4)")
        }
    }

    // MARK: - Invariant 2b: no bare `Label:` line

    /// A line that is only a capitalised label and a colon opens a section in a second
    /// marker family — on a wire whose one boundary family is `## `/`### `, the block it
    /// should open merges into the line above it (playbook R1.3.2 / R1.5.1). Two labels are
    /// the house form and stay: `Args:` heads a tool's parameter list (R3.3.1) and
    /// `Example:` labels the one Harmony example (R1.3.5).
    func testNoBareColonLabelLines() {
        let allowed: Set<String> = ["Args:", "Example:"]
        // A one- or two-word capitalised label, or an ALL-CAPS one. A longer colon-terminated
        // line ("For each character:") is a sentence leading into a list, not a marker.
        let pattern = #"^(?:[A-Z][A-Za-z]*(?: [A-Za-z]+)?|[A-Z][A-Z0-9 ]+):\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            XCTFail("Regex did not compile — test broken")
            return
        }
        for (label, contents) in Self.auditedSurfaces {
            let ns = contents as NSString
            for match in regex.matches(in: contents, range: NSRange(location: 0, length: ns.length)) {
                let line = ns.substring(with: match.range).trimmingCharacters(in: .whitespaces)
                if allowed.contains(line) { continue }
                XCTFail("[\(label)] bare colon label `\(line)` — use a `## `/`### ` heading or fold it into a sentence")
            }
        }
    }

    // MARK: - Invariant 2c: no bold emphasis in a repo-authored layer

    /// `**bold**` is a second emphasis system beside the `## ` headings, and emphasis on a
    /// rule is a format change of unpredictable sign (playbook R4.3.2 / A6.19). The one
    /// sanctioned use is the tool entry `**name**: description` the Harmony body renders.
    func testNoBoldEmphasisInRepoAuthoredLayers() {
        let bold = try! NSRegularExpression(pattern: #"\*\*[^*\n]+\*\*"#)
        let toolEntry = try! NSRegularExpression(pattern: #"^\*\*[a-z0-9_]+\*\*: "#)
        for (label, contents) in Self.auditedSurfaces {
            for line in contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                let range = NSRange(line.startIndex..., in: line)
                guard bold.firstMatch(in: line, range: range) != nil else { continue }
                if toolEntry.firstMatch(in: line, range: range) != nil { continue }
                XCTFail("[\(label)] bold emphasis in a repo-authored layer: \(line.prefix(120))")
            }
        }
    }

    // MARK: - Invariant 3: no "Please" in LLM-facing prompts

    /// No exemption list. One existed — empty — for "surfaces that route their string to
    /// the Supervisor, not the LLM", on the belief that the cap-escalation questions were
    /// such a surface; they are replayed into the role's own next request. An empty
    /// exemption list is an invitation, so it is gone.
    func testNoPleaseInLLMFacingPrompts() {
        // Whole-word "Please" / "please" with word boundary.
        let pattern = #"\b[Pp]lease\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("Regex did not compile — test broken")
            return
        }
        for (label, contents) in Self.auditedSurfaces {
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
