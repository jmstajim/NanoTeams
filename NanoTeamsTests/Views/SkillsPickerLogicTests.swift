import XCTest
@testable import NanoTeams

final class SkillsPickerLogicTests: XCTestCase {

    private func makeItem(
        name: String,
        description: String? = nil,
        id: String? = nil,
        agentID: String = "claude-skill",
        agentLabel: String = "Claude Code",
        kindLabel: String = "Skill",
        origin: AgentSkillOrigin = .project
    ) -> AgentSkillsSnapshot.Item {
        AgentSkillsSnapshot.Item(
            id: id ?? "\(agentID)|\(origin.rawValue)|\(name)",
            name: name,
            description: description,
            agentID: agentID,
            agentLabel: agentLabel,
            kindLabel: kindLabel,
            origin: origin,
            fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
            displayPath: name
        )
    }

    // MARK: - filter

    func testFilter_emptyQuery_returnsAll() {
        let items = [makeItem(name: "a"), makeItem(name: "b")]
        XCTAssertEqual(SkillsPickerLogic.filter(items, query: "  ").count, 2)
    }

    func testFilter_byName_caseInsensitive() {
        let items = [makeItem(name: "Code-Review"), makeItem(name: "deploy")]
        let result = SkillsPickerLogic.filter(items, query: "REVIEW")
        XCTAssertEqual(result.map(\.name), ["Code-Review"])
    }

    func testFilter_byDescription() {
        let items = [
            makeItem(name: "x", description: "audits security issues"),
            makeItem(name: "y", description: "formats code"),
        ]
        XCTAssertEqual(SkillsPickerLogic.filter(items, query: "security").map(\.name), ["x"])
    }

    func testFilter_trimsQuery() {
        let items = [makeItem(name: "deploy")]
        XCTAssertEqual(SkillsPickerLogic.filter(items, query: "  deploy  ").count, 1)
    }

    func testFilter_noMatch_empty() {
        let items = [makeItem(name: "deploy")]
        XCTAssertTrue(SkillsPickerLogic.filter(items, query: "zzz").isEmpty)
    }

    // MARK: - grouped

    func testGrouped_bySectionLabel_preservesOrder() {
        let items = [
            makeItem(name: "review", agentID: "claude-skill", agentLabel: "Claude Code", kindLabel: "Skill"),
            makeItem(name: "commit", agentID: "claude-command", agentLabel: "Claude Code", kindLabel: "Command"),
            makeItem(name: "summarize", agentID: "codex-prompt", agentLabel: "Codex", kindLabel: "Prompt"),
        ]
        let groups = SkillsPickerLogic.grouped(items)
        XCTAssertEqual(groups.map(\.section), [
            "Claude Code — Skills",
            "Claude Code — Commands",
            "Codex — Prompts",
        ])
        XCTAssertEqual(groups[0].items.map(\.name), ["review"])
    }

    func testGrouped_sameSection_groupsTogether() {
        let items = [
            makeItem(name: "alpha", origin: .project),
            makeItem(name: "beta", origin: .global),
        ]
        let groups = SkillsPickerLogic.grouped(items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].items.map(\.name), ["alpha", "beta"])
    }

    func testGrouped_pluginSkillsAndCommands_separateGroupsFromLocalSkills() {
        let items = [
            makeItem(name: "train-app", agentID: "claude-skill",
                     agentLabel: "Claude Code", kindLabel: "Skill", origin: .project),
            makeItem(name: "swiftui-expert", agentID: "claude-plugin-skill",
                     agentLabel: "Claude Code", kindLabel: "Plugin Skill", origin: .global),
            makeItem(name: "code-review:review", agentID: "claude-plugin-command",
                     agentLabel: "Claude Code", kindLabel: "Plugin Command", origin: .global),
        ]
        XCTAssertEqual(SkillsPickerLogic.grouped(items).map(\.section),
                       ["Claude Code — Skills", "Claude Code — Plugin Skills", "Claude Code — Plugin Commands"])
    }

    // MARK: - isStaged

    func testIsStaged_sameNameAgentOrigin_true() {
        let item = makeItem(name: "review", agentLabel: "Claude Code", origin: .project)
        let clips = [SkillClip(name: "review", agentLabel: "Claude Code", origin: .project, body: "b").encoded()]
        XCTAssertTrue(SkillsPickerLogic.isStaged(item, in: clips))
    }

    func testIsStaged_differentOrigin_false() {
        let item = makeItem(name: "review", agentLabel: "Claude Code", origin: .global)
        let clips = [SkillClip(name: "review", agentLabel: "Claude Code", origin: .project, body: "b").encoded()]
        XCTAssertFalse(SkillsPickerLogic.isStaged(item, in: clips))
    }

    func testIsStaged_nonSkillClips_ignored() {
        let item = makeItem(name: "review")
        XCTAssertFalse(SkillsPickerLogic.isStaged(item, in: ["plain clip", "\u{200B}// Source: f.swift\nbody"]))
    }

    func testIsStaged_displayFormClip_missingAgent_false() {
        // A feed-re-extracted skill clip carries no agent/origin, so it never
        // matches a picker item (which always has them) — staged detection is for
        // the composer's own picks, not feed history.
        let item = makeItem(name: "review", agentLabel: "Claude Code", origin: .project)
        let displayClip = SkillClip(name: "review", body: "b").encoded()
        XCTAssertFalse(SkillsPickerLogic.isStaged(item, in: [displayClip]))
    }

    func testIsStaged_differentAgent_false() {
        let item = makeItem(name: "review", agentLabel: "Claude Code", origin: .project)
        let clips = [SkillClip(name: "review", agentLabel: "Codex", origin: .project, body: "b").encoded()]
        XCTAssertFalse(SkillsPickerLogic.isStaged(item, in: clips))
    }

    func testIsStaged_sameNameAgentOrigin_differentIDs_notCrossStaged() {
        // Two distinct plugin skills both named "review", same agent+origin, but
        // different ids (different plugins). Staging one must NOT mark the other.
        let a = makeItem(name: "review", id: "claude-plugin-skill|global|a@mp/skills/review/SKILL.md",
                         agentLabel: "Claude Code", origin: .global)
        let b = makeItem(name: "review", id: "claude-plugin-skill|global|b@mp/skills/review/SKILL.md",
                         agentLabel: "Claude Code", origin: .global)
        let clips = [SkillClip(id: a.id, name: "review", agentLabel: "Claude Code", origin: .global, body: "x").encoded()]
        XCTAssertTrue(SkillsPickerLogic.isStaged(a, in: clips))
        XCTAssertFalse(SkillsPickerLogic.isStaged(b, in: clips))
    }

    func testIsStaged_idBearingClip_matchesByIDNotName() {
        // An id-bearing clip matches the item with that id even if a same-named
        // sibling exists; and does not match a different-id item of the same name.
        let item = makeItem(name: "review", id: "claude-skill|project|review", agentLabel: "Claude Code", origin: .project)
        let clips = [SkillClip(id: "claude-skill|project|review", name: "review",
                               agentLabel: "Claude Code", origin: .project, body: "b").encoded()]
        XCTAssertTrue(SkillsPickerLogic.isStaged(item, in: clips))
    }

    func testFilter_matchesNamespaceColon() {
        let items = [makeItem(name: "git:commit"), makeItem(name: "deploy")]
        XCTAssertEqual(SkillsPickerLogic.filter(items, query: "commit").map(\.name), ["git:commit"])
    }

    // MARK: - emptyStateHint

    func testEmptyStateHint_variants() {
        let withProject = SkillsPickerLogic.emptyStateHint(hasProjectRoot: true)
        let globalOnly = SkillsPickerLogic.emptyStateHint(hasProjectRoot: false)
        XCTAssertNotEqual(withProject, globalOnly)
        XCTAssertTrue(withProject.contains("work folder"))
        XCTAssertTrue(globalOnly.contains("Open a work folder"))
    }

    // MARK: - helpText (tooltip)

    private func makeItem(name: String, description: String?, displayPath: String) -> AgentSkillsSnapshot.Item {
        AgentSkillsSnapshot.Item(
            id: "id|\(name)", name: name, description: description,
            agentID: "claude-skill", agentLabel: "Claude Code", kindLabel: "Skill",
            origin: .project, fileURL: URL(fileURLWithPath: "/tmp/\(name)"), displayPath: displayPath)
    }

    func testHelpText_withDescription_threeBlocks() {
        let item = makeItem(name: "review", description: "Review the diff", displayPath: ".claude/skills/review/SKILL.md")
        XCTAssertEqual(SkillsPickerLogic.helpText(for: item),
                       "/review\n\nReview the diff\n\n.claude/skills/review/SKILL.md")
    }

    func testHelpText_nilDescription_twoBlocks() {
        let item = makeItem(name: "review", description: nil, displayPath: "p/SKILL.md")
        XCTAssertEqual(SkillsPickerLogic.helpText(for: item), "/review\n\np/SKILL.md")
    }

    func testHelpText_emptyDescription_droppedNotBlankLine() {
        // An empty-string description must be dropped (no double blank line).
        let item = makeItem(name: "review", description: "", displayPath: "p/SKILL.md")
        XCTAssertEqual(SkillsPickerLogic.helpText(for: item), "/review\n\np/SKILL.md")
    }

    func testHelpText_namespacedName_prefixesSlash() {
        let item = makeItem(name: "code-review:review", description: nil, displayPath: "~/.claude/plugins/x")
        XCTAssertTrue(SkillsPickerLogic.helpText(for: item).hasPrefix("/code-review:review\n\n"))
    }

    // MARK: - ClipCellPresentation precedence

    func testClipCellPresentation_skillWins() {
        let skill = SkillClip(name: "review", agentLabel: "Claude Code", origin: .project, body: "body").encoded()
        guard case .skill(let parsed) = ClipCellPresentation.resolve(skill) else {
            return XCTFail("expected .skill")
        }
        XCTAssertEqual(parsed.name, "review")
    }

    func testClipCellPresentation_sourcedWhenSourceContext() {
        let clip = "\u{200B}// Source: main.swift:1-3\nlet x = 1"
        guard case .sourced(let source, let body) = ClipCellPresentation.resolve(clip) else {
            return XCTFail("expected .sourced")
        }
        XCTAssertEqual(source, "main.swift:1-3")
        XCTAssertEqual(body, "let x = 1")
    }

    func testClipCellPresentation_plainOtherwise() {
        guard case .plain(let body) = ClipCellPresentation.resolve("just text") else {
            return XCTFail("expected .plain")
        }
        XCTAssertEqual(body, "just text")
    }
}
