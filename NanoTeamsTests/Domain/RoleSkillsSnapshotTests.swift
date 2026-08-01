import XCTest
@testable import NanoTeams

/// Pure resolution rules for `RoleSkillsSnapshot` — the step between "the role
/// stores ids" and "the prompt renders bodies".
@MainActor
final class RoleSkillsSnapshotTests: XCTestCase {

    private func item(_ id: String, name: String) -> AgentSkillsSnapshot.Item {
        AgentSkillsSnapshot.Item(
            id: id,
            name: name,
            description: nil,
            agentID: "claude-skill",
            agentLabel: "Claude Code",
            kindLabel: "Skill",
            origin: .project,
            fileURL: URL(fileURLWithPath: "/tmp/\(name)/SKILL.md"),
            displayPath: ".claude/skills/\(name)/SKILL.md"
        )
    }

    private func snapshot(
        _ pairs: [(id: String, name: String, body: String?)],
        unresolved: Set<String> = []
    ) -> RoleSkillsSnapshot {
        RoleSkillsSnapshot(
            items: pairs.map { item($0.id, name: $0.name) },
            bodies: pairs.reduce(into: [:]) { acc, p in if let b = p.body { acc[p.id] = b } },
            unresolvedIDs: unresolved
        )
    }

    // MARK: - Order

    /// The role's order IS the prompt's section order, so resolution must never
    /// re-sort. Ids are deliberately reverse-alphabetical to catch an accidental
    /// `.sorted()`.
    func testResolve_preservesRoleOrder_notAlphabetical() {
        let snap = snapshot([("z", "zeta", "Z body"), ("a", "alpha", "A body")])

        let resolved = snap.resolve(["z", "a"])

        XCTAssertEqual(resolved.map(\.name), ["zeta", "alpha"])
        XCTAssertEqual(resolved.map(\.body), ["Z body", "A body"])
    }

    func testResolve_respectsReordering() {
        let snap = snapshot([("a", "alpha", "A"), ("b", "beta", "B")])

        XCTAssertEqual(snap.resolve(["a", "b"]).map(\.name), ["alpha", "beta"])
        XCTAssertEqual(snap.resolve(["b", "a"]).map(\.name), ["beta", "alpha"])
    }

    // MARK: - Skips

    func testResolve_unknownID_isSkipped() {
        let snap = snapshot([("a", "alpha", "A")])

        XCTAssertEqual(snap.resolve(["a", "ghost"]).map(\.id), ["a"])
    }

    func testResolve_idWithNoBody_isSkipped() {
        // Discovered but unreadable — reported via `unresolvedIDs`, never
        // rendered as an empty `## Skill:` section.
        let snap = snapshot([("a", "alpha", nil)], unresolved: ["a"])

        XCTAssertTrue(snap.resolve(["a"]).isEmpty)
        XCTAssertTrue(snap.unresolvedIDs.contains("a"))
    }

    func testResolve_emptyBody_isSkipped() {
        let snap = snapshot([("a", "alpha", "")])

        XCTAssertTrue(snap.resolve(["a"]).isEmpty)
    }

    func testResolve_duplicateID_rendersOnce_keepingFirstPosition() {
        let snap = snapshot([("a", "alpha", "A"), ("b", "beta", "B")])

        XCTAssertEqual(snap.resolve(["a", "b", "a"]).map(\.id), ["a", "b"])
    }

    // MARK: - Degenerate

    func testResolve_noAttachments_isEmpty() {
        XCTAssertTrue(snapshot([("a", "alpha", "A")]).resolve([]).isEmpty)
    }

    func testResolve_emptySnapshot_isEmpty() {
        XCTAssertTrue(RoleSkillsSnapshot.empty.resolve(["a"]).isEmpty)
    }

    func testEmpty_isEmptyAndCarriesNothing() {
        XCTAssertTrue(RoleSkillsSnapshot.empty.isEmpty)
        XCTAssertTrue(RoleSkillsSnapshot.empty.bodies.isEmpty)
        XCTAssertTrue(RoleSkillsSnapshot.empty.unresolvedIDs.isEmpty)
    }
}
