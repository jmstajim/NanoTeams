import XCTest
@testable import NanoTeams

/// Rendering of role-attached agent skills into the `{roleSkills}` chip.
///
/// Two properties matter and are pinned separately:
/// 1. A role with NO skills produces a prompt byte-identical to the pre-skills
///    build — the section header is stripped along with the empty chip.
/// 2. A role WITH skills keeps its `## Skills` header, and no skill's own
///    markdown escapes to the prompt's own `##` section level.
@MainActor
final class PromptBuilderRoleSkillsTests: XCTestCase {

    private func skill(_ name: String, _ body: String) -> ResolvedRoleSkill {
        ResolvedRoleSkill(id: "claude-skill|project|\(name)/SKILL.md", name: name, body: body)
    }

    // MARK: - Renderer

    func testFormat_noSkills_isEmpty() {
        XCTAssertEqual(PromptBuilder.formatRoleSkills([]), "")
    }

    func testFormat_singleSkill_exactBytes() {
        let out = PromptBuilder.formatRoleSkills([skill("tdd", "Write the test first.")])

        XCTAssertEqual(out, "### Skill: tdd\n\nWrite the test first.")
    }

    /// The role's order is the section order — resolution already refuses to
    /// re-sort, and the renderer must not either.
    func testFormat_multipleSkills_preserveOrder_separatedByBlankLine() {
        let out = PromptBuilder.formatRoleSkills([
            skill("zeta", "Z body"),
            skill("alpha", "A body"),
        ])

        XCTAssertEqual(out, "### Skill: zeta\n\nZ body\n\n### Skill: alpha\n\nA body")
    }

    func testFormat_bodyIsTrimmed() {
        let out = PromptBuilder.formatRoleSkills([skill("tdd", "\n\n  Body.  \n\n")])

        XCTAssertEqual(out, "### Skill: tdd\n\nBody.")
    }

    /// Defence in depth: `RoleSkillsSnapshot.resolve` already drops empty bodies,
    /// so an empty `### Skill:` header can never ship. If a caller hands one over
    /// anyway, the renderer drops it rather than emitting a bodiless header.
    func testFormat_whitespaceOnlyBody_isDropped() {
        let out = PromptBuilder.formatRoleSkills([
            skill("empty", "   \n\n  "),
            skill("real", "Body."),
        ])

        XCTAssertEqual(out, "### Skill: real\n\nBody.")
    }

    /// Same name, two origins (project + global) — both render. Deduplication is
    /// by id and happens during resolution; the renderer must not second-guess it.
    func testFormat_sameNameTwice_bothRender() {
        let out = PromptBuilder.formatRoleSkills([skill("tdd", "First"), skill("tdd", "Second")])

        XCTAssertEqual(out, "### Skill: tdd\n\nFirst\n\n### Skill: tdd\n\nSecond")
    }

    // MARK: - Heading containment

    /// The measured motivation: 125 of 135 installed skills carry `#`/`##`
    /// headings. Injected raw they read as prompt-level sections.
    func testFormat_skillHeadings_neverReachTheTemplateSectionLevel() {
        let out = PromptBuilder.formatRoleSkills([
            skill("tdd", "# Overview\n\nText.\n\n## Rules\n\nMore."),
        ])

        XCTAssertEqual(out, "### Skill: tdd\n\n#### Overview\n\nText.\n\n##### Rules\n\nMore.")
        for line in out.components(separatedBy: "\n") where line.hasPrefix("#") {
            XCTAssertGreaterThanOrEqual(
                line.prefix(while: { $0 == "#" }).count, 3,
                "No heading in the Skills section may sit at the prompt's own level: \(line)")
        }
    }

    func testFormat_fencedHashComment_survivesVerbatim() {
        let out = PromptBuilder.formatRoleSkills([
            skill("shell", "# Title\n\n```bash\n# not a heading\nls\n```"),
        ])

        XCTAssertTrue(out.contains("\n# not a heading\n"), "A fenced `#` comment is code, not a heading")
    }

    // MARK: - Section lifecycle through the resolver

    private let template = """
        ## Guidance
        {roleGuidance}

        ## Skills
        {roleSkills}

        ## Final reminder
        Ship it.
        """

    /// The zero-skills contract: the header goes with the empty chip, so the
    /// prompt is byte-identical to one built from a template with no Skills
    /// section at all.
    func testResolve_noSkills_stripsTheWholeSection() {
        let out = TemplateResolver.resolveSystemPrompt(
            template,
            placeholders: ["roleGuidance": "Do the thing.", "roleSkills": ""],
            globalContext: "")

        XCTAssertFalse(out.contains("## Skills"))
        XCTAssertEqual(out, "## Guidance\nDo the thing.\n\n## Final reminder\nShip it.")
    }

    /// The reason the per-skill header is `###` and not `##`: with an `##` header
    /// the resolver would see `## Skills` immediately followed by another `##`
    /// line — a header with an empty body — and delete the section header the
    /// template author wrote.
    func testResolve_withSkills_keepsTheSectionHeader() {
        let body = PromptBuilder.formatRoleSkills([skill("tdd", "Write the test first.")])
        let out = TemplateResolver.resolveSystemPrompt(
            template,
            placeholders: ["roleGuidance": "Do the thing.", "roleSkills": body],
            globalContext: "")

        XCTAssertTrue(out.contains("## Skills"), "The section header must survive when the chip has content")
        XCTAssertTrue(out.contains("### Skill: tdd"))
        XCTAssertTrue(out.contains("Write the test first."))
    }

    /// Direct pin on the failure mode above: an h2 per-skill header makes the
    /// resolver eat the section header. Documents WHY the level was chosen —
    /// if someone lowers `systemPromptHeaderLevel` to 2, this shows the cost.
    func testResolve_h2PerSkillHeader_wouldEatTheSectionHeader() {
        let out = TemplateResolver.resolveSystemPrompt(
            template,
            placeholders: [
                "roleGuidance": "Do the thing.",
                "roleSkills": "## Skill: tdd\n\nWrite the test first.",
            ],
            globalContext: "")

        XCTAssertFalse(out.contains("## Skills"),
                       "Confirms the hazard the ### level avoids — an h2 skill header "
                       + "makes `## Skills` look like an empty section")
    }

    // MARK: - buildChatMessages

    private func makeContext(
        team: Team?,
        role: TeamRoleDefinition?,
        skills: [ResolvedRoleSkill],
        globalContext: String = ""
    ) -> PromptBuilder.Context {
        let step = StepExecution(id: "s", role: .softwareEngineer, title: "Step")
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "T", supervisorTask: "Build it", runs: [run])
        return PromptBuilder.Context(
            task: task,
            step: step,
            stepIndex: 0,
            run: run,
            workFolder: nil,
            artifactReader: { _ in nil },
            activeTeam: team,
            roleDefinition: role,
            globalContext: globalContext,
            attachedSkills: skills)
    }

    private func teamWithSkillsChip() -> Team {
        var team = Team.default
        team.systemPromptTemplate = template
        return team
    }

    private func systemPrompt(_ messages: [ChatMessage]) -> String {
        messages.first(where: { $0.role == .system })?.content ?? ""
    }

    /// The regression that matters most: threading the new field through changes
    /// nothing for every role that has no skills attached.
    func testBuildChatMessages_noSkills_isByteIdenticalToTheDefaultBuild() {
        let team = teamWithSkillsChip()
        let role = team.nonSupervisorRoles.first

        let withField = PromptBuilder.buildChatMessages(
            context: makeContext(team: team, role: role, skills: []), tools: [])
        let withoutField = PromptBuilder.buildChatMessages(
            context: PromptBuilder.Context(
                task: makeContext(team: team, role: role, skills: []).task,
                step: makeContext(team: team, role: role, skills: []).step,
                stepIndex: 0,
                run: makeContext(team: team, role: role, skills: []).run,
                workFolder: nil,
                artifactReader: { _ in nil },
                activeTeam: team,
                roleDefinition: role),
            tools: [])

        XCTAssertEqual(systemPrompt(withField), systemPrompt(withoutField))
        XCTAssertFalse(systemPrompt(withField).contains("## Skills"))
    }

    func testBuildChatMessages_withSkills_landInTheSystemPrompt() {
        let team = teamWithSkillsChip()
        let role = team.nonSupervisorRoles.first

        let messages = PromptBuilder.buildChatMessages(
            context: makeContext(team: team, role: role,
                                 skills: [skill("tdd", "Write the test first.")]),
            tools: [])

        let system = systemPrompt(messages)
        XCTAssertTrue(system.contains("## Skills"))
        XCTAssertTrue(system.contains("### Skill: tdd"))
        XCTAssertTrue(system.contains("Write the test first."))
        // Skills ride the SYSTEM prompt, never a user turn.
        for message in messages where message.role != .system {
            XCTAssertFalse(message.content?.contains("### Skill: tdd") ?? false)
        }
    }

    /// A chip-less template still gets the section, appended. This is the case
    /// that makes the feature work at all for teams created from the New Team
    /// sheet: `Team.duplicate` clears `templateID`, so those teams are "custom",
    /// the reconcile pass never rewrites their template, and they can never
    /// receive a chip added later.
    func testBuildChatMessages_templateWithoutChip_appendsTheSection() {
        var team = Team.default
        team.systemPromptTemplate = "## Guidance\n{roleGuidance}"

        let messages = PromptBuilder.buildChatMessages(
            context: makeContext(team: team, role: team.nonSupervisorRoles.first,
                                 skills: [skill("tdd", "Body")]),
            tools: [])

        let system = systemPrompt(messages)
        XCTAssertTrue(system.contains("## Skills"))
        XCTAssertTrue(system.contains("### Skill: tdd"))
    }

    /// The tail attention slot keeps the critical reminder [Liu2024] — an
    /// arbitrary-length skill body appended after it would displace it.
    func testBuildChatMessages_chipLessFallback_insertsBeforeTheFinalReminder() {
        var team = Team.default
        team.systemPromptTemplate = "## Guidance\n{roleGuidance}\n\n## Final reminder\nShip it."

        let system = systemPrompt(PromptBuilder.buildChatMessages(
            context: makeContext(team: team, role: team.nonSupervisorRoles.first,
                                 skills: [skill("tdd", "Body")]),
            tools: []))

        let skills = try? XCTUnwrap(system.range(of: "## Skills"))
        let reminder = try? XCTUnwrap(system.range(of: "## Final reminder"))
        XCTAssertNotNil(skills)
        XCTAssertNotNil(reminder)
        if let skills, let reminder {
            XCTAssertLessThan(skills.lowerBound, reminder.lowerBound)
        }
    }

    /// A chip-less template with NO attached skills gains nothing — the fallback
    /// must not manufacture an empty section.
    func testBuildChatMessages_chipLessTemplate_noSkills_appendsNothing() {
        var team = Team.default
        team.systemPromptTemplate = "## Guidance\n{roleGuidance}"

        let system = systemPrompt(PromptBuilder.buildChatMessages(
            context: makeContext(team: team, role: team.nonSupervisorRoles.first, skills: []),
            tools: []))

        XCTAssertFalse(system.contains("## Skills"))
    }

    /// "Control the whole prompt": a user who clears the template ships an empty
    /// `system_prompt`, and the fallback must not break that contract.
    func testBuildChatMessages_clearedTemplate_staysEmpty() {
        var team = Team.default
        team.systemPromptTemplate = ""

        let system = systemPrompt(PromptBuilder.buildChatMessages(
            context: makeContext(team: team, role: team.nonSupervisorRoles.first,
                                 skills: [skill("tdd", "Body")]),
            tools: []))

        XCTAssertEqual(system, "")
    }

    // MARK: - Third-party bodies vs the resolver's own passes

    /// A skill body is untrusted markdown, and the chip-less fallback splices the
    /// global-guidance block relative to a trailing `## Final reminder`. If that
    /// anchor were re-found AFTER the skills block was inserted, a skill carrying
    /// that exact line inside a code fence would supply the match and get the
    /// guidance block spliced into its middle. One anchor, computed once, makes
    /// that unrepresentable.
    func testChipLessFallback_skillBodyCarryingTheReminderPhrase_doesNotSplitIt() {
        var team = Team.default
        team.systemPromptTemplate = "## Guidance\n{roleGuidance}\n\n## Final reminder\nStay on task."

        let body = "Example:\n\n```md\n## Final reminder\nnot ours\n```\n\nDone."
        let context = makeContext(team: team, role: team.nonSupervisorRoles.first,
                                  skills: [skill("tricky", body)],
                                  globalContext: "ONE TOOL CALL PER RESPONSE")

        let system = systemPrompt(PromptBuilder.buildChatMessages(context: context, tools: []))

        // The fenced line survives verbatim, and nothing is spliced between it
        // and the rest of the skill.
        XCTAssertTrue(system.contains("```md\n## Final reminder\nnot ours\n```\n\nDone."),
                      "The skill's fenced block must not be split open:\n\(system)")
        // Both fallback sections land above the template's own trailing reminder.
        guard let skillsAt = system.range(of: "## Skills"),
              let guidanceAt = system.range(of: "## Global guidance"),
              let reminderAt = system.range(of: "## Final reminder", options: .backwards)
        else { return XCTFail("Expected all three sections in:\n\(system)") }
        XCTAssertLessThan(skillsAt.lowerBound, guidanceAt.lowerBound,
                          "Skills stack above global guidance")
        XCTAssertLessThan(guidanceAt.lowerBound, reminderAt.lowerBound,
                          "Both stay above the tail reminder")
    }

    /// Known limit, pinned so it can't silently widen: `stripOrphanHeaders` is
    /// not fence-aware, so two adjacent `## ` lines inside a skill's code fence
    /// would be treated as an empty section. Re-levelling is what keeps this
    /// unreachable in practice — every unfenced heading is pushed to h4+, and no
    /// installed skill in the measured corpus has this shape inside a fence.
    func testSkillBody_unfencedAdjacentHeaders_areRelevelledOutOfHarmsWay() {
        let out = PromptBuilder.formatRoleSkills([skill("x", "## A\n## B\nBody")])

        // Re-levelled to h4 — below the `## ` level `stripOrphanHeaders` acts on.
        XCTAssertTrue(out.contains("#### A"))
        XCTAssertTrue(out.contains("#### B"))
        XCTAssertFalse(out.contains("\n## A"), "No h2 may survive into the prompt")
    }
}
