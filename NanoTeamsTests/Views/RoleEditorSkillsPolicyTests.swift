import XCTest
@testable import NanoTeams

/// Pure logic behind the Role editor's Skills tab.
///
/// The property under test throughout is ORDER. The attached list is the order of
/// the `### Skill:` sections in the role's system prompt — segment-0 bytes — so
/// every operation here must be order-preserving and, critically, must never
/// round-trip through a `Set`. `Array(Set<String>)` yields a different order per
/// process, which would reshuffle the prompt on a no-op re-save and cost a full
/// prefix re-prefill.
final class RoleEditorSkillsPolicyTests: XCTestCase {

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

    private lazy var catalogue = [item("a", name: "alpha"), item("b", name: "beta")]

    // MARK: - Attach / detach

    func testAttaching_appendsAtTheEnd() {
        XCTAssertEqual(RoleEditorSkillsPolicy.attaching("b", to: ["a"]), ["a", "b"])
    }

    func testAttaching_isIdempotent() {
        XCTAssertEqual(RoleEditorSkillsPolicy.attaching("a", to: ["a", "b"]), ["a", "b"])
    }

    func testDetaching_preservesTheOrderOfTheRest() {
        XCTAssertEqual(RoleEditorSkillsPolicy.detaching("b", from: ["a", "b", "c"]), ["a", "c"])
    }

    func testDetaching_absentID_isANoOp() {
        XCTAssertEqual(RoleEditorSkillsPolicy.detaching("z", from: ["a", "b"]), ["a", "b"])
    }

    func testDetaching_removesEveryOccurrence() {
        XCTAssertEqual(RoleEditorSkillsPolicy.detaching("a", from: ["a", "b", "a"]), ["b"])
    }

    func testIsAttached() {
        XCTAssertTrue(RoleEditorSkillsPolicy.isAttached(item("a", name: "alpha"), in: ["a"]))
        XCTAssertFalse(RoleEditorSkillsPolicy.isAttached(item("a", name: "alpha"), in: ["b"]))
    }

    // MARK: - Reorder

    func testMovingUp_swapsWithThePredecessor() {
        XCTAssertEqual(RoleEditorSkillsPolicy.movingUp("c", in: ["a", "b", "c"]), ["a", "c", "b"])
    }

    func testMovingUp_atTheFront_isANoOp() {
        XCTAssertEqual(RoleEditorSkillsPolicy.movingUp("a", in: ["a", "b"]), ["a", "b"])
    }

    func testMovingDown_swapsWithTheSuccessor() {
        XCTAssertEqual(RoleEditorSkillsPolicy.movingDown("a", in: ["a", "b", "c"]), ["b", "a", "c"])
    }

    func testMovingDown_atTheBack_isANoOp() {
        XCTAssertEqual(RoleEditorSkillsPolicy.movingDown("c", in: ["a", "b", "c"]), ["a", "b", "c"])
    }

    func testMoving_absentID_isANoOp() {
        XCTAssertEqual(RoleEditorSkillsPolicy.movingUp("z", in: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(RoleEditorSkillsPolicy.movingDown("z", in: ["a", "b"]), ["a", "b"])
    }

    // MARK: - Rows

    /// Ids are deliberately reverse-alphabetical: an accidental `.sorted()` shows up.
    func testAttachedRows_followTheRoleOrder_notTheCatalogueOrder() {
        let rows = RoleEditorSkillsPolicy.attachedRows(attachedIDs: ["b", "a"], catalogue: catalogue)

        XCTAssertEqual(rows.map(\.id), ["b", "a"])
        XCTAssertEqual(rows.map(\.displayName), ["beta", "alpha"])
        XCTAssertFalse(rows.contains { $0.isDangling })
    }

    /// A deleted / renamed skill stays VISIBLE so the user can remove it. Dropping
    /// it silently would leave a role whose stored ids don't match what it shows.
    func testAttachedRows_unknownID_rendersAsDangling() {
        let rows = RoleEditorSkillsPolicy.attachedRows(attachedIDs: ["a", "ghost"], catalogue: catalogue)

        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows[0].isDangling)
        XCTAssertTrue(rows[1].isDangling)
        XCTAssertEqual(rows[1].displayName, "ghost", "falls back to the id so the row is identifiable")
    }

    func testAttachedRows_duplicateID_rendersOnce_keepingFirstPosition() {
        let rows = RoleEditorSkillsPolicy.attachedRows(attachedIDs: ["a", "b", "a"], catalogue: catalogue)

        XCTAssertEqual(rows.map(\.id), ["a", "b"])
    }

    func testAttachedRows_empty() {
        XCTAssertTrue(RoleEditorSkillsPolicy.attachedRows(attachedIDs: [], catalogue: catalogue).isEmpty)
    }

    // MARK: - Token estimate

    func testEstimatedTotal_sumsOnlyAttachedBodies() {
        let bodies = ["a": String(repeating: "x", count: 350), "unused": String(repeating: "x", count: 99999)]

        let total = RoleEditorSkillsPolicy.estimatedTotalTokens(attachedIDs: ["a"], bodies: bodies)

        XCTAssertEqual(total, RoleEditorSkillsPolicy.estimatedTokens(forBody: bodies["a"]!))
        XCTAssertGreaterThan(total, 0)
    }

    func testEstimatedTotal_countsADuplicateIDOnce() {
        let bodies = ["a": String(repeating: "x", count: 350)]

        XCTAssertEqual(
            RoleEditorSkillsPolicy.estimatedTotalTokens(attachedIDs: ["a", "a"], bodies: bodies),
            RoleEditorSkillsPolicy.estimatedTotalTokens(attachedIDs: ["a"], bodies: bodies))
    }

    func testEstimatedTotal_unresolvedID_contributesNothing() {
        XCTAssertEqual(
            RoleEditorSkillsPolicy.estimatedTotalTokens(attachedIDs: ["ghost"], bodies: [:]), 0)
    }

    /// One estimator for the picker and for `ContextBudgetPolicy`'s overflow
    /// warning, or the number shown at attach time and the number that triggers
    /// the warning could disagree.
    func testEstimator_isTheSameOneTheBudgetPolicyUses() {
        let body = "Some skill body with a few words in it."

        XCTAssertEqual(RoleEditorSkillsPolicy.estimatedTokens(forBody: body),
                       WorkFolderContextPromptPlanner.estimateTokens(body))
    }

    func testFormatTokens_isCoarse() {
        XCTAssertEqual(RoleEditorSkillsPolicy.formatTokens(840), "~840 tokens")
        XCTAssertEqual(RoleEditorSkillsPolicy.formatTokens(4200), "~4.2k tokens")
        XCTAssertEqual(RoleEditorSkillsPolicy.formatTokens(0), "~0 tokens")
    }

    // MARK: - Role-list badge
    //
    // The badge is built from `attachedRows`, the same function the tab renders,
    // so a count shown in the list can never disagree with the list behind it.

    func testBadge_nothingAttached_isNil() {
        XCTAssertNil(RoleEditorSkillsPolicy.badge(attachedIDs: [], catalogue: catalogue))
    }

    func testBadge_emptyStringIDs_areNotCounted() {
        XCTAssertNil(RoleEditorSkillsPolicy.badge(attachedIDs: ["", ""], catalogue: catalogue))
    }

    func testBadge_duplicateID_countsOnce() {
        let badge = RoleEditorSkillsPolicy.badge(
            attachedIDs: ["a", "b", "a"], catalogue: catalogue)

        XCTAssertEqual(badge?.count, 2)
        XCTAssertEqual(badge?.entries.map(\.name), ["alpha", "beta"])
    }

    func testBadge_keepsPromptOrder_notCatalogueOrder() {
        let badge = RoleEditorSkillsPolicy.badge(attachedIDs: ["b", "a"], catalogue: catalogue)

        XCTAssertEqual(badge?.entries.map(\.name), ["beta", "alpha"],
                       "the tooltip lists the order the prompt injects, never a sort")
    }

    func testBadge_someIDsDangling_marksOnlyThose() {
        let badge = RoleEditorSkillsPolicy.badge(
            attachedIDs: ["a", "gone"], catalogue: catalogue)

        XCTAssertEqual(badge?.count, 2, "a dangling id still occupies a slot in the role")
        XCTAssertEqual(badge?.danglingCount, 1)
        XCTAssertEqual(badge?.entries.first?.isDangling, false)
        XCTAssertEqual(badge?.entries.last?.isDangling, true)
    }

    func testBadge_allIDsDangling_stillShowsTheBadge() {
        let badge = RoleEditorSkillsPolicy.badge(
            attachedIDs: ["x", "y"], catalogue: catalogue)

        XCTAssertEqual(badge?.count, 2)
        XCTAssertEqual(badge?.danglingCount, 2)
    }

    /// An empty catalogue means "no scan yet", not "every skill is broken" — the
    /// same rule `TeamValidationService.validateAttachedSkills` follows. Claiming
    /// otherwise would light up every skilled role the moment Settings opens cold.
    func testBadge_emptyCatalogue_claimsNothingIsMissing() {
        let badge = RoleEditorSkillsPolicy.badge(attachedIDs: ["a", "b"], catalogue: [])

        XCTAssertEqual(badge?.count, 2)
        XCTAssertEqual(badge?.danglingCount, 0)
        XCTAssertEqual(badge?.catalogueUnavailable, true)
    }

    func testBadgeTooltip_emptyCatalogue_showsNoNames() {
        let badge = RoleEditorSkillsPolicy.badge(attachedIDs: ["a"], catalogue: [])!
        let text = RoleEditorSkillsPolicy.badgeTooltip(badge)

        XCTAssertFalse(text.contains("/a"),
                       "the raw composite id is not a name and must never be shown")
        XCTAssertTrue(text.contains("scan"))
    }

    func testBadgeTooltip_listsNamesWithTheSlashConvention_andFlagsMissing() {
        let badge = RoleEditorSkillsPolicy.badge(
            attachedIDs: ["a", "gone"], catalogue: catalogue)!
        let text = RoleEditorSkillsPolicy.badgeTooltip(badge)

        XCTAssertTrue(text.contains("/alpha"))
        XCTAssertTrue(text.contains("missing"))
        XCTAssertTrue(text.hasPrefix("2 agent skills"), "got: \(text)")
    }

    func testBadgeTooltip_singularNoun() {
        let badge = RoleEditorSkillsPolicy.badge(attachedIDs: ["a"], catalogue: catalogue)!

        XCTAssertTrue(RoleEditorSkillsPolicy.badgeTooltip(badge).hasPrefix("1 agent skill "))
    }
}
