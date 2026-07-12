import XCTest
@testable import NanoTeams

final class SkillClipTests: XCTestCase {

    // MARK: - Staged form round-trip

    func testStagedForm_roundTrips() {
        let clip = SkillClip(
            name: "code-review",
            agentLabel: "Claude Code",
            origin: .project,
            body: "# Review\nLine one\nLine two"
        )
        let parsed = SkillClip.parse(clip.encoded())
        XCTAssertEqual(parsed?.name, "code-review")
        XCTAssertEqual(parsed?.agentLabel, "Claude Code")
        XCTAssertEqual(parsed?.origin, .project)
        XCTAssertEqual(parsed?.body, "# Review\nLine one\nLine two")
    }

    func testStagedForm_globalOrigin_roundTrips() {
        let clip = SkillClip(name: "commit", agentLabel: "Codex", origin: .global, body: "do the thing")
        let parsed = SkillClip.parse(clip.encoded())
        XCTAssertEqual(parsed?.origin, .global)
        XCTAssertEqual(parsed?.agentLabel, "Codex")
    }

    func testStagedForm_withID_roundTrips() {
        let clip = SkillClip(
            id: "claude-plugin-skill|global|foo@mp/skills/review/SKILL.md",
            name: "review", agentLabel: "Claude Code", origin: .global, body: "b")
        let parsed = SkillClip.parse(clip.encoded())
        XCTAssertEqual(parsed?.id, "claude-plugin-skill|global|foo@mp/skills/review/SKILL.md")
        XCTAssertEqual(parsed?.name, "review")
        XCTAssertEqual(parsed?.origin, .global)
    }

    func testStagedForm_withoutID_parsesNilID() {
        // A staged clip built without an id (legacy / coarse) still parses cleanly.
        let parsed = SkillClip.parse(SkillClip(name: "x", agentLabel: "Codex", origin: .project, body: "b").encoded())
        XCTAssertNil(parsed?.id)
        XCTAssertEqual(parsed?.agentLabel, "Codex")
    }

    func testStagedForm_bodyContainingID_notConfusedWithHeaderID() {
        // The id lives on the header line (before the first newline); an id-looking
        // body line must not be mistaken for it.
        let clip = SkillClip(id: "real|id", name: "n", agentLabel: "A", origin: .global,
                             body: "line\nfake|id\u{200B}stuff")
        let parsed = SkillClip.parse(clip.encoded())
        XCTAssertEqual(parsed?.id, "real|id")
        XCTAssertEqual(parsed?.body, "line\nfake|id\u{200B}stuff")
    }

    func testStagedForm_agentWithoutOrigin_roundTripsWithNilOrigin() {
        // encoded() emits both fields whenever either is present; an empty origin
        // rawValue parses back to nil.
        let clip = SkillClip(name: "x", agentLabel: "Cursor", origin: nil, body: "b")
        let parsed = SkillClip.parse(clip.encoded())
        XCTAssertEqual(parsed?.agentLabel, "Cursor")
        XCTAssertNil(parsed?.origin)
    }

    // MARK: - Display form (feed re-extraction) round-trip

    func testDisplayForm_nilAgentAndOrigin_roundTrips() {
        let clip = SkillClip(name: "review", body: "body text")
        let encoded = clip.encoded()
        // Display form has only the sentinel prefix ZWSP, no field-separator ZWSPs.
        XCTAssertEqual(encoded.filter { $0 == "\u{200B}" }.count, 1)
        let parsed = SkillClip.parse(encoded)
        XCTAssertEqual(parsed?.name, "review")
        XCTAssertNil(parsed?.agentLabel)
        XCTAssertNil(parsed?.origin)
        XCTAssertEqual(parsed?.body, "body text")
    }

    func testMultilineBody_preserved() {
        let body = "line1\nline2\n\nline4"
        let parsed = SkillClip.parse(SkillClip(name: "n", body: body).encoded())
        XCTAssertEqual(parsed?.body, body)
    }

    func testBody_startingWithFrontmatterDashes_preserved() {
        let body = "---\nname: x\n---\ncontent"
        let parsed = SkillClip.parse(SkillClip(name: "n", body: body).encoded())
        XCTAssertEqual(parsed?.body, body)
    }

    // MARK: - Rejection cases

    func testParse_rejectsSourceContextClip() {
        let sourceClip = "\u{200B}// Source: file.swift:1-2\nselected code"
        XCTAssertNil(SkillClip.parse(sourceClip))
        // And SourceContext must not recognize a skill clip.
        let skillClip = SkillClip(name: "n", body: "b").encoded()
        XCTAssertNil(SourceContext.parse(skillClip))
    }

    func testParse_rejectsPlainText() {
        XCTAssertNil(SkillClip.parse("just some clipboard text"))
    }

    func testParse_rejectsEmptyBody() {
        XCTAssertNil(SkillClip.parse("\u{200B}// Skill: name\n"))
    }

    func testParse_rejectsEmptyName() {
        XCTAssertNil(SkillClip.parse("\u{200B}// Skill: \nbody"))
    }

    func testParse_rejectsHeaderWithoutNewline() {
        XCTAssertNil(SkillClip.parse("\u{200B}// Skill: name-no-body"))
    }

    // MARK: - Corner cases

    func testRoundTrip_nameWithNamespaceColon() {
        // Claude commands namespace as "git:commit".
        let parsed = SkillClip.parse(SkillClip(name: "git:commit", agentLabel: "Claude Code", origin: .project, body: "b").encoded())
        XCTAssertEqual(parsed?.name, "git:commit")
    }

    func testRoundTrip_agentLabelWithParentheses() {
        // The ZWSP-field codec is immune to the "name (agent)" naive-parse hazard.
        let parsed = SkillClip.parse(SkillClip(name: "review (v2)", agentLabel: "GitHub Copilot (preview)", origin: .global, body: "b").encoded())
        XCTAssertEqual(parsed?.name, "review (v2)")
        XCTAssertEqual(parsed?.agentLabel, "GitHub Copilot (preview)")
        XCTAssertEqual(parsed?.origin, .global)
    }

    func testRoundTrip_bodyContainingSkillHeaderLine() {
        // A skill body that itself contains a "## Skill:" line survives — parse
        // splits on the FIRST newline only.
        let body = "intro\n## Skill: nested\nmore"
        let parsed = SkillClip.parse(SkillClip(name: "outer", body: body).encoded())
        XCTAssertEqual(parsed?.name, "outer")
        XCTAssertEqual(parsed?.body, body)
    }

    func testRoundTrip_bodyContainingZeroWidthSpace() {
        let body = "before\u{200B}after"
        let parsed = SkillClip.parse(SkillClip(name: "x", agentLabel: "A", origin: .project, body: body).encoded())
        XCTAssertEqual(parsed?.name, "x")
        XCTAssertEqual(parsed?.body, body)
    }

    func testResolve_precedence_notConfusedByBodyWithSourceHeader() {
        // A skill whose body starts with a SourceContext-looking line still parses
        // as a skill (prefix discriminates on the first line only).
        let clip = SkillClip(name: "x", body: "// Source: not-real\ncode").encoded()
        XCTAssertNotNil(SkillClip.parse(clip))
        XCTAssertNil(SourceContext.parse(clip))
    }

    // MARK: - SkillConstants

    func testPromptHeader_format() {
        XCTAssertEqual(SkillConstants.promptHeader(name: "code-review"), "## Skill: code-review")
        XCTAssertEqual(SkillConstants.promptHeaderPrefix, "## Skill: ")
    }

    func testOriginBadgeLabels() {
        XCTAssertEqual(AgentSkillOrigin.project.badgeLabel, "project")
        XCTAssertEqual(AgentSkillOrigin.global.badgeLabel, "global")
    }
}
