import XCTest
@testable import NanoTeams

/// Pins the `##`-header structure of every built-in step / consultation / meeting
/// template. The 2026-05 prompt rewrite normalised every template to `## Role` /
/// `## Guidance` / `## Constraints` / `## Deliverables` / `## Final reminder`
/// scaffolding; this test prevents a future cleanup from silently dropping any
/// of those sections (which `SystemTemplatesTests` would NOT catch since it
/// only asserts placeholder survival).
final class SystemTemplatesSectionPinTests: XCTestCase {

    // MARK: - Step templates (full scaffolding)

    func testSoftwareTemplate_containsRequiredSections() {
        let t = SystemTemplates.softwareTemplate
        for section in ["## Role", "## Team", "## Guidance", "## Constraints", "## Deliverables", "## Final reminder"] {
            XCTAssertTrue(t.contains(section), "softwareTemplate must contain `\(section)`")
        }
    }

    func testQuestPartyTemplate_containsRequiredSections() {
        let t = SystemTemplates.questPartyTemplate
        for section in ["## Role", "## Team", "## Guidance", "## Constraints", "## Deliverables", "## Final reminder"] {
            XCTAssertTrue(t.contains(section), "questPartyTemplate must contain `\(section)`")
        }
    }

    func testDiscussionTemplate_containsRequiredSections() {
        let t = SystemTemplates.discussionTemplate
        for section in ["## Role", "## Club", "## Guidance", "## Conversation style", "## Deliverables", "## Final reminder"] {
            XCTAssertTrue(t.contains(section), "discussionTemplate must contain `\(section)`")
        }
    }

    func testGenericTemplate_containsRequiredSections() {
        let t = SystemTemplates.genericTemplate
        for section in ["## Role", "## Team", "## Guidance", "## Deliverables", "## Final reminder"] {
            XCTAssertTrue(t.contains(section), "genericTemplate must contain `\(section)`")
        }
    }

    // MARK: - Personal Assistant / Coding Assistant (chat-mode, no Deliverables)

    func testAssistantTemplate_usesHeaderedScaffolding() {
        let t = SystemTemplates.assistantTemplate
        for section in ["## Role", "## Guidance", "## Final reminder"] {
            XCTAssertTrue(t.contains(section), "assistantTemplate must contain `\(section)`")
        }
    }

    func testAssistantTemplate_doesNotOpenWithYouAre() {
        // House anti-pattern (see CLAUDE.md; playbook §1 "right altitude"):
        // role identity is established via `{roleName}` in the template's
        // `## Role` line, not a duplicate "You are X..." preamble.
        let t = SystemTemplates.assistantTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(t.hasPrefix("You are"), "assistantTemplate must not open with 'You are X...'")
    }

    func testCodingAssistantTemplate_usesHeaderedScaffolding() {
        let t = SystemTemplates.codingAssistantTemplate
        for section in ["## Role", "## Guidance", "## Final reminder"] {
            XCTAssertTrue(t.contains(section), "codingAssistantTemplate must contain `\(section)`")
        }
    }

    func testCodingAssistantTemplate_doesNotOpenWithYouAre() {
        let t = SystemTemplates.codingAssistantTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(t.hasPrefix("You are"), "codingAssistantTemplate must not open with 'You are X...'")
    }

    // MARK: - Autovisor (single-role manager, no Team / Deliverables)

    func testAutovisorTemplate_usesHeaderedScaffolding() {
        let t = SystemTemplates.autovisorTemplate
        for section in ["## Role", "## Conversation mechanics", "## Guidance", "## Final reminder"] {
            XCTAssertTrue(t.contains(section), "autovisorTemplate must contain `\(section)`")
        }
        // Single-role template — must NOT carry the team-shaped sections.
        for section in ["## Team", "## Deliverables"] {
            XCTAssertFalse(t.contains(section), "autovisorTemplate must NOT contain `\(section)` (one-role team)")
        }
        // The FR's job is the termination contract: a pass ends via `wait_for_events`.
        XCTAssertTrue(t.contains("wait_for_events"),
                      "autovisorTemplate FR must steer toward `wait_for_events` (how a pass ends)")
        // End-position restate (Liu2024): the context refresh is the instruction the
        // manager keeps forgetting — it must be reinforced in the Final reminder,
        // anchored to BEFORE task creation (workers read the context at task start).
        XCTAssertTrue(t.contains("Work Folder Context"),
                      "autovisorTemplate FR must restate the Work Folder Context refresh")
        // Canary against an accidental repoint back to a producing-role template:
        // the deliverable-submission FR only exists in templates the Autovisor must NOT use.
        XCTAssertFalse(t.contains("Submit each deliverable"),
                       "autovisorTemplate must not carry the generic deliverable-submission Final reminder")
    }

    func testAutovisorTemplate_doesNotOpenWithYouAre() {
        let t = SystemTemplates.autovisorTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(t.hasPrefix("You are"), "autovisorTemplate must not open with 'You are X...'")
    }

    /// §2.2 / §9.5 attention sinks: the "delegate, never implement" rule — the constraint
    /// a weak local model ignores when it's buried mid-prompt — must sit in BOTH the opening
    /// `## Role` slot and the closing `## Final reminder` slot, not only in `{roleGuidance}`'s
    /// mid-prompt Boundaries. This is the structural fix for the manager self-fixing instead
    /// of delegating.
    func testAutovisorTemplate_neverImplementRule_atStartAndEnd() {
        let t = SystemTemplates.autovisorTemplate
        guard let mechanics = t.range(of: "## Conversation mechanics"),
              let finalReminder = t.range(of: "## Final reminder") else {
            return XCTFail("autovisorTemplate must have its section headers")
        }
        // Start slot — the `## Role` block (everything before the next header).
        let roleBlock = String(t[t.startIndex..<mechanics.lowerBound])
        XCTAssertTrue(roleBlock.contains("never implement"),
                      "## Role (opening attention-sink) must state the delegate/never-implement rule")
        // End slot — the Final reminder restates the never-implement / delegate rule.
        let finalBlock = String(t[finalReminder.lowerBound...])
        XCTAssertTrue(finalBlock.contains("never implement") && finalBlock.contains("managed task"),
                      "## Final reminder (closing attention-sink) must restate the never-implement / delegate rule")
        // The existing FR pins (wait_for_events + Work Folder Context) must survive the addition.
        XCTAssertTrue(finalBlock.contains("wait_for_events") && finalBlock.contains("Work Folder Context"),
                      "## Final reminder must keep the termination + context-refresh contract")
    }

    /// F2 (pass-2 review): the prohibition ("never implement") must NOT monopolise the two
    /// attention-sink slots. The POSITIVE act/delegate directive must LEAD both the `## Role` and
    /// the `## Final reminder` (positive before prohibition) so a weak quantized model isn't biased
    /// toward passivity — the opposite failure of the bug this rewrite targets. F6: the Final
    /// reminder must also restate the manager's only reply channel (one short line; no `ask_supervisor`).
    func testAutovisorTemplate_positiveDirectiveLeadsBothSinks() {
        let t = SystemTemplates.autovisorTemplate
        guard let mechanics = t.range(of: "## Conversation mechanics"),
              let fr = t.range(of: "## Final reminder") else {
            return XCTFail("autovisorTemplate must have its section headers")
        }
        let roleBlock = String(t[t.startIndex..<mechanics.lowerBound])
        let finalBlock = String(t[fr.lowerBound...])
        // ## Role: the positive directive precedes the never-implement constraint.
        guard let rolePos = roleBlock.range(of: "delegate"),
              let roleNo = roleBlock.range(of: "never implement") else {
            return XCTFail("## Role must carry both the positive directive and the constraint")
        }
        XCTAssertLessThan(rolePos.lowerBound, roleNo.lowerBound,
                          "## Role must LEAD with the positive delegate/steer directive, then never-implement (F2)")
        // ## Final reminder: the positive lead precedes the constraint.
        guard let frPos = finalBlock.range(of: "Act on"),
              let frNo = finalBlock.range(of: "never implement") else {
            return XCTFail("## Final reminder must carry both the positive lead and the constraint")
        }
        XCTAssertLessThan(frPos.lowerBound, frNo.lowerBound,
                          "## Final reminder must LEAD with the positive act/delegate directive (F2)")
        // F6: reply-format restatement at the tail sink.
        XCTAssertTrue(finalBlock.lowercased().contains("one short line"),
                      "## Final reminder must restate the manager's reply format (one short line — its only channel)")
    }

    // MARK: - Consultation templates (every variant carries `## Final reminder`)

    func testEveryConsultationTemplate_hasFinalReminder() {
        for (name, t) in [
            ("software", SystemTemplates.softwareConsultationTemplate),
            ("questParty", SystemTemplates.questPartyConsultationTemplate),
            ("discussion", SystemTemplates.discussionConsultationTemplate),
            ("generic", SystemTemplates.genericConsultationTemplate),
        ] {
            XCTAssertTrue(t.contains("## Final reminder"),
                          "\(name) consultation template must close with `## Final reminder`")
        }
    }

    // MARK: - Meeting templates (every variant carries `## Final reminder`)

    func testEveryMeetingTemplate_hasFinalReminder() {
        for (name, t) in [
            ("software", SystemTemplates.softwareMeetingTemplate),
            ("questParty", SystemTemplates.questPartyMeetingTemplate),
            ("discussion", SystemTemplates.discussionMeetingTemplate),
            ("generic", SystemTemplates.genericMeetingTemplate),
        ] {
            XCTAssertTrue(t.contains("## Final reminder"),
                          "\(name) meeting template must close with `## Final reminder`")
        }
    }

    // MARK: - Role-guidance hierarchy invariant (H-7)

    /// Role-guidance internal sections must be `###` so they nest cleanly
    /// under the template's `## Guidance` scaffold. A `## Section` inside role
    /// guidance breaks the two-level hierarchy and confuses the model about
    /// what's scaffold vs. role content.
    ///
    /// Exception: fenced code blocks (``` ``` ```) inside role guidance MAY
    /// carry `##` headers — those are example outputs the model should emit,
    /// living in their own document scope.
    func testEveryRolePrompt_internalHeadersAreH3NotH2() {
        for (roleID, prompt) in SystemTemplates.rolePrompts {
            let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false)
            var insideFence = false
            for (lineIndex, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line == "```" || line.hasPrefix("```") {
                    insideFence.toggle()
                    continue
                }
                if insideFence { continue }
                // Anything outside a fenced block starting with `## ` (h2) is a
                // hierarchy violation — must be `### ` (h3) so it nests under
                // the template's `## Guidance` scaffold.
                XCTAssertFalse(
                    line.hasPrefix("## ") && !line.hasPrefix("### "),
                    "[\(roleID)] line \(lineIndex + 1) carries a stray `##` header outside a fenced block: \(line)"
                )
                // Also catch legacy `Workflow:` / `Engineering Standards:`
                // forms — every section should be a proper `### Header`,
                // not a colon-suffixed paragraph label.
                let knownColonLabels = ["Workflow:", "Engineering Standards:", "Design Standards:",
                                        "Output format:", "Constraints:", "Guidance:",
                                        "Focus areas:", "Personality:"]
                for label in knownColonLabels {
                    XCTAssertNotEqual(
                        line, label,
                        "[\(roleID)] uses legacy paragraph label `\(label)` — convert to `### \(label.dropLast())`"
                    )
                }
            }
        }
    }

    // MARK: - Discussion-style invariants (conversation, no markdown structure)

    func testDiscussionTemplate_enforcesPlainProseStyle() {
        // Load-bearing: discussion club roles must NOT emit headers or lists.
        // If a future cleanup softens this to "minimal structure", the model
        // will revert to bullet-pointed assessments, breaking the chat illusion.
        let t = SystemTemplates.discussionTemplate
        XCTAssertTrue(t.contains("no markdown structure"),
                      "discussionTemplate's plain-prose contract is load-bearing")
    }

    // MARK: - `## Final reminder` LITERAL-last invariant (Liu2024 §0.3 / G3)

    /// `## Final reminder` must be the LITERAL last `## ` section in every step
    /// template's source. Liu2024 §0.3 requires the single most critical
    /// constraint at the prompt's tail; this test pins position (not just
    /// presence — `testEveryStepTemplate_hasFinalReminder`-style assertions
    /// allow FR to be mid-template, which silently undoes attention-sink benefit).
    ///
    /// "Last `##` section" = no `^## ` heading appears AFTER the FR heading
    /// in the template source. Subsections (`###`) under FR are allowed; what
    /// we forbid is a sibling `##` section after `## Final reminder`.
    func testEveryStepTemplate_finalReminderIsLastH2Section() {
        let stepTemplates: [(String, String)] = [
            ("softwareTemplate", SystemTemplates.softwareTemplate),
            ("questPartyTemplate", SystemTemplates.questPartyTemplate),
            ("discussionTemplate", SystemTemplates.discussionTemplate),
            ("assistantTemplate", SystemTemplates.assistantTemplate),
            ("codingAssistantTemplate", SystemTemplates.codingAssistantTemplate),
            ("genericTemplate", SystemTemplates.genericTemplate),
            ("autovisorTemplate", SystemTemplates.autovisorTemplate),
        ]
        for (name, template) in stepTemplates {
            let lines = template.split(separator: "\n", omittingEmptySubsequences: false)
            var lastH2HeaderText: String?
            for raw in lines {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("## ") && !line.hasPrefix("### ") else { continue }
                lastH2HeaderText = line
            }
            XCTAssertEqual(
                lastH2HeaderText, "## Final reminder",
                "[\(name)] last `## ` section must be `## Final reminder` (Liu2024 §0.3 attention-sink). "
                    + "Actual last `## ` header: \(lastH2HeaderText ?? "<none>")"
            )
        }
    }

    // MARK: - Role skills scope

    /// Role-attached agent skills ride the STEP prompt only — the user's scope
    /// decision. Every step template carries the chip so the section's position
    /// is the author's call; no consultation / meeting template does, so a
    /// role's skills never leak into an `ask_teammate` answer or a meeting turn.
    func testRoleSkillsChip_isInEveryStepTemplateAndNoCollaborationTemplate() {
        let stepTemplates: [(String, String)] = [
            ("softwareTemplate", SystemTemplates.softwareTemplate),
            ("questPartyTemplate", SystemTemplates.questPartyTemplate),
            ("discussionTemplate", SystemTemplates.discussionTemplate),
            ("assistantTemplate", SystemTemplates.assistantTemplate),
            ("codingAssistantTemplate", SystemTemplates.codingAssistantTemplate),
            ("genericTemplate", SystemTemplates.genericTemplate),
            ("autovisorTemplate", SystemTemplates.autovisorTemplate),
        ]
        let collaborationTemplates: [(String, String)] = [
            ("softwareConsultationTemplate", SystemTemplates.softwareConsultationTemplate),
            ("softwareMeetingTemplate", SystemTemplates.softwareMeetingTemplate),
            ("questPartyConsultationTemplate", SystemTemplates.questPartyConsultationTemplate),
            ("questPartyMeetingTemplate", SystemTemplates.questPartyMeetingTemplate),
            ("discussionConsultationTemplate", SystemTemplates.discussionConsultationTemplate),
            ("discussionMeetingTemplate", SystemTemplates.discussionMeetingTemplate),
            ("genericConsultationTemplate", SystemTemplates.genericConsultationTemplate),
            ("genericMeetingTemplate", SystemTemplates.genericMeetingTemplate),
        ]

        for (name, template) in stepTemplates {
            XCTAssertTrue(template.contains("{roleSkills}"), "[\(name)] must carry the chip")
            XCTAssertTrue(template.contains("## Skills"),
                          "[\(name)] chip resolves to a bare body — the header lives in the template")
        }
        for (name, template) in collaborationTemplates {
            XCTAssertFalse(template.contains("{roleSkills}"),
                           "[\(name)] skills are step-execution-only")
        }
    }

    // MARK: - Section order in opening 20% (Xiao2023 attention sinks / G4)

    /// `## Role` → `## Team` (where present) → `## Conversation mechanics`
    /// must occupy the prompt's opening attention-sink slot. Pins the ORDER
    /// of the leading `## ` sections so a future reorder (e.g. moving CM to
    /// mid-template) breaks visibly. CM is the load-bearing section here:
    /// it carries the «task and artifacts are already in the conversation»
    /// notice the model needs FIRST to avoid re-fetching.
    func testEveryStepTemplate_openingOrderRoleThenCMFirst() {
        let stepTemplates: [(name: String, body: String, expectsTeam: Bool)] = [
            ("softwareTemplate", SystemTemplates.softwareTemplate, true),
            ("questPartyTemplate", SystemTemplates.questPartyTemplate, true),
            ("discussionTemplate", SystemTemplates.discussionTemplate, false), // uses `## Club`
            ("assistantTemplate", SystemTemplates.assistantTemplate, false),
            ("codingAssistantTemplate", SystemTemplates.codingAssistantTemplate, false),
            ("genericTemplate", SystemTemplates.genericTemplate, true),
            ("autovisorTemplate", SystemTemplates.autovisorTemplate, false), // one-role team, no `## Team`
        ]
        for (name, body, expectsTeam) in stepTemplates {
            let h2Sections = body.split(separator: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("## ") && !trimmed.hasPrefix("### ") else { return nil }
                return trimmed
            }
            // 1. First section is `## Role`.
            XCTAssertEqual(h2Sections.first, "## Role", "[\(name)] first `## ` section must be `## Role`")
            // 2. `## Conversation mechanics` must appear before `## Guidance`.
            guard let cmIdx = h2Sections.firstIndex(of: "## Conversation mechanics") else {
                XCTFail("[\(name)] must contain `## Conversation mechanics` (Liu2024 attention-sink opening)")
                continue
            }
            if let guidanceIdx = h2Sections.firstIndex(of: "## Guidance") {
                XCTAssertTrue(cmIdx < guidanceIdx,
                              "[\(name)] `## Conversation mechanics` must precede `## Guidance` "
                                  + "(attention-sink opening slot — Xiao2023streamingllm)")
            }
            // 3. CM in opening-third — `cmIdx` must be ≤ floor(count/3).
            //    Templates carry 7-11 `##` sections; floor/3 = 2-3. CM at position 2 or 3 is fine.
            let openingBudget = max(3, h2Sections.count / 3)
            XCTAssertLessThan(
                cmIdx, openingBudget,
                "[\(name)] `## Conversation mechanics` at index \(cmIdx) of \(h2Sections.count) sections "
                    + "exceeds opening-third budget (\(openingBudget)). "
                    + "Liu2024: critical info in first ~20-30% — Xiao2023 attention-sinks."
            )
            // 4. If `## Team` is expected, it must sit between `## Role` and `## CM`.
            if expectsTeam, let teamIdx = h2Sections.firstIndex(of: "## Team") {
                XCTAssertLessThan(teamIdx, cmIdx, "[\(name)] `## Team` must precede `## Conversation mechanics`")
            }
        }
    }

    // MARK: - Chat-mode FR restates output format (Liu2024 §0.3 / Issue 3)

    /// Chat-mode templates have an implicit output contract — reply by calling
    /// `ask_supervisor`. Per Liu2024 §0.3 (house rule; playbook §1 «state the
    /// exact format» + §5 skeleton) the most critical constraint must occupy
    /// the tail attention-sink slot. The standalone `## Output format` section
    /// sat mid-prompt with FR carrying unrelated content — a buried-in-middle
    /// output format.
    ///
    /// Fix: FR text MUST mention `ask_supervisor` for chat-mode
    /// templates. Either as a dedicated restatement or by folding the entire
    /// output-format rule into FR (current approach). The tool is referenced by
    /// NAME only (no `tool.param` dotted form — house rule, see the dotted-param
    /// pin below); the dotted `ask_supervisor.question`
    /// made some models emit it verbatim as the tool-call name.
    func testChatModeTemplate_finalReminderRestatesOutputFormat() {
        for (name, template) in [
            ("assistantTemplate", SystemTemplates.assistantTemplate),
            ("codingAssistantTemplate", SystemTemplates.codingAssistantTemplate),
        ] {
            // Extract the FR block — everything after the last `## Final reminder` header.
            guard let frRange = template.range(of: "## Final reminder") else {
                XCTFail("[\(name)] missing `## Final reminder`")
                continue
            }
            let frBody = String(template[frRange.upperBound...])
            XCTAssertTrue(
                frBody.contains("ask_supervisor`"),
                "[\(name)] chat-mode FR must restate output contract (reply via `ask_supervisor`). "
                    + "Liu2024 §0.3 — critical constraint at tail. Got FR body:\n\(frBody)"
            )
        }
    }

    // MARK: - No dotted `tool.param` token in any LLM-facing prompt

    /// Regression pin for the `ask_supervisor.question` tool-call-name bug: no
    /// LLM-facing prompt string may reference a tool in dotted `` `tool.param` ``
    /// form. Some models copy that token verbatim as the tool-call NAME, no
    /// handler matches, and the step loops on `tool_not_authorized`. Reference
    /// tools by NAME only (house rule; playbook §3 — tool wording measurably
    /// affects call quality); name any parameter
    /// as a separate token. Scans every step / consultation / meeting template and
    /// every role prompt against all registered tool names — the manual grep the
    /// fix relied on, codified so a future prompt edit can't silently reintroduce it.
    func testNoPromptSurface_referencesToolWithDottedParam() {
        let toolNames = ToolHandlerRegistry.allTypes.map { $0.name }
        var surfaces: [(String, String)] = [
            ("softwareTemplate", SystemTemplates.softwareTemplate),
            ("questPartyTemplate", SystemTemplates.questPartyTemplate),
            ("discussionTemplate", SystemTemplates.discussionTemplate),
            ("genericTemplate", SystemTemplates.genericTemplate),
            ("assistantTemplate", SystemTemplates.assistantTemplate),
            ("codingAssistantTemplate", SystemTemplates.codingAssistantTemplate),
            ("autovisorTemplate", SystemTemplates.autovisorTemplate),
            ("softwareConsultationTemplate", SystemTemplates.softwareConsultationTemplate),
            ("questPartyConsultationTemplate", SystemTemplates.questPartyConsultationTemplate),
            ("discussionConsultationTemplate", SystemTemplates.discussionConsultationTemplate),
            ("genericConsultationTemplate", SystemTemplates.genericConsultationTemplate),
            ("softwareMeetingTemplate", SystemTemplates.softwareMeetingTemplate),
            ("questPartyMeetingTemplate", SystemTemplates.questPartyMeetingTemplate),
            ("discussionMeetingTemplate", SystemTemplates.discussionMeetingTemplate),
            ("genericMeetingTemplate", SystemTemplates.genericMeetingTemplate),
        ]
        for (roleID, prompt) in SystemTemplates.rolePrompts {
            surfaces.append(("rolePrompt[\(roleID)]", prompt))
        }
        // Match an OPEN backtick + tool name + a literal `.` — the dotted-param
        // signature. Legitimate `` `tool`. `` (closing backtick before the period)
        // and the paren form `tool(param:` do NOT match, so no false positives.
        for (surfaceName, text) in surfaces {
            for tool in toolNames {
                XCTAssertFalse(
                    text.contains("`\(tool)."),
                    "[\(surfaceName)] references `\(tool).<param>` in dotted form — reference tools "
                        + "by NAME only (house rule). The dotted token is copied "
                        + "verbatim as the tool-call name by some models (tool_not_authorized loop)."
                )
            }
        }
    }

    // MARK: - Role-guidance dedup pin (G5)

    /// 2026-05 dedup removed the `### Communication (critical)` block from
    /// `assistant` / `codingAssistant` / `codingAgent` role guidance — the rule
    /// «every response = tool call» now lives only in the template's
    /// `## Final reminder` section. Without this pin, a future polish pass can
    /// silently re-inline the duplicate.
    ///
    /// Same pin for `### ask_supervisor format` and `### Safety` (originally
    /// in `assistant` only) — both were folded into the FR/Output-format rules.
    func testChatModeRoleGuidance_omitsDedupedSections() {
        for roleID in ["assistant", "codingAssistant", "codingAgent"] {
            guard let prompt = SystemTemplates.rolePrompts[roleID] else {
                XCTFail("Role prompt '\(roleID)' missing from rolePrompts")
                continue
            }
            XCTAssertFalse(
                prompt.contains("### Communication"),
                "[\(roleID)] must NOT contain `### Communication` — rule lives in template's `## Final reminder` per 2026-05 dedup"
            )
        }
        // `assistant`-specific dedup: ask_supervisor format + Safety sections
        // were removed (folded into FR).
        if let assistantPrompt = SystemTemplates.rolePrompts["assistant"] {
            XCTAssertFalse(
                assistantPrompt.contains("### ask_supervisor format"),
                "assistant role must NOT contain `### ask_supervisor format` — folded into template's FR per 2026-05 dedup"
            )
            XCTAssertFalse(
                assistantPrompt.contains("### Safety"),
                "assistant role must NOT contain `### Safety` — folded into template's FR per 2026-05 dedup"
            )
        }
    }

    // MARK: - Positive-instruction de-stack pins (playbook §1/§6)

    /// codeReviewer's review-only rule is stated positively ("Review only… the
    /// Software Engineer writes all code"), not as the 2026-05 four-negative
    /// stack ("don't redo… don't provide… don't fill in…"). Negative-instruction
    /// stacking degrades small local models (playbook §6); the single retained
    /// self-check ("stop and reframe") is the strongest guard, kept by design.
    func testCodeReviewerGuidance_positiveReviewOnlyRule() {
        let p = SystemTemplates.rolePrompts["codeReviewer"] ?? ""
        XCTAssertTrue(p.contains("Review only"), "positive lead")
        XCTAssertTrue(p.contains("request_changes"), "fix routing stays explicit")
        XCTAssertFalse(p.contains("don't redo"), "negative stack stays removed")
        XCTAssertFalse(p.contains("don't provide rewritten"), "negative stack stays removed")
    }

    /// questMaster carries the compressed format contract instead of the
    /// removed Good/Bad few-shot pair (few-shot degrades reasoning models —
    /// playbook §1; the format rule itself is load-bearing and stays).
    func testQuestMasterGuidance_formatRuleWithoutFewShotPair() {
        let p = SystemTemplates.rolePrompts["questMaster"] ?? ""
        XCTAssertTrue(p.contains("### ask_supervisor format"), "format contract section stays")
        XCTAssertTrue(p.contains("ENTIRE scene"), "whole-scene-inside-question rule stays")
        XCTAssertFalse(p.contains("Good example"), "few-shot pair stays removed")
        XCTAssertFalse(p.contains("Bad example"), "few-shot pair stays removed")
    }

    // MARK: - Role guidance is a placeholder VALUE — it must not embed chips

    /// `TemplateResolver.resolve` is single-pass: placeholder VALUES are data and
    /// are never re-scanned for `{key}` tokens. A chip embedded in role guidance
    /// therefore ships to the model as a literal `{expectedArtifacts}` string.
    /// (Pre-fix this was worse: dictionary-order resolution made it random per
    /// app launch whether the token expanded.) Guard the whole class.
    func testNoRolePrompt_embedsTemplateChips() {
        let chips = [
            "roleName", "roleGuidance", "teamRoles", "teamDescription", "toolList",
            "expectedArtifacts", "artifactInstructions", "stepInfo", "positionContext",
            "globalContext", "conversationMechanics", "toolCalling", "workFolderContext",
        ]
        for (roleID, prompt) in SystemTemplates.rolePrompts {
            for chip in chips {
                XCTAssertFalse(
                    prompt.contains("{\(chip)}"),
                    "[\(roleID)] role guidance embeds `{\(chip)}` — values are never re-resolved; "
                        + "the model would receive the literal token"
                )
            }
        }
    }

    /// Role guidance lands mid-prompt under `## Guidance`; a `### Final reminder`
    /// inside it competes with the template's real tail `## Final reminder`
    /// (two "final" blocks, one in the worst recall zone — Liu2024).
    func testNoRolePrompt_carriesItsOwnFinalReminder() {
        for (roleID, prompt) in SystemTemplates.rolePrompts {
            XCTAssertFalse(
                prompt.localizedCaseInsensitiveContains("final reminder"),
                "[\(roleID)] role guidance carries its own 'Final reminder' — rename the section; "
                    + "the template's tail `## Final reminder` must stay the single final block"
            )
        }
    }
}
