import XCTest
@testable import NanoTeams

/// Codable + helper guards for `TeamRoleDefinition.attachedSkillIDs` — the
/// per-role agent-skill references injected into the role's system prompt.
///
/// Mirrors `TeamRoleDefinitionDelegationTests`, with one extra property the
/// delegation whitelist does not need: **order is significant**. The ids render
/// in sequence as `## Skill:` sections in segment 0, so a reshuffle re-prefills
/// the prompt cache and changes which skill the model reads first.
@MainActor
final class TeamRoleDefinitionSkillsTests: XCTestCase {

    private func makeRole(skills: [String]) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "swe",
            name: "Software Engineer",
            prompt: "You write code.",
            toolIDs: [ToolNames.readFile],
            usePlanningPhase: true,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Notes"]),
            attachedSkillIDs: skills
        )
    }

    // MARK: - Codable round-trip

    func testRoundTrip_preservesAttachedSkillIDs() throws {
        let role = makeRole(skills: ["claude-skill|project|tdd", "claude-plugin-skill|global|ads"])

        let data = try JSONCoderFactory.makePersistenceEncoder().encode(role)
        let decoded = try JSONCoderFactory.makeDateDecoder()
            .decode(TeamRoleDefinition.self, from: data)

        XCTAssertEqual(decoded.attachedSkillIDs,
                       ["claude-skill|project|tdd", "claude-plugin-skill|global|ads"])
    }

    /// The property the delegation whitelist does not have: a round-trip must not
    /// reorder. If this ever goes through a `Set`, this test is what catches it.
    func testRoundTrip_preservesOrderExactly() throws {
        let ordered = ["c|project|c", "a|project|a", "b|global|b", "z|global|z"]
        let role = makeRole(skills: ordered)

        var current = role
        for _ in 0..<3 {
            let data = try JSONCoderFactory.makePersistenceEncoder().encode(current)
            current = try JSONCoderFactory.makeDateDecoder()
                .decode(TeamRoleDefinition.self, from: data)
        }

        XCTAssertEqual(current.attachedSkillIDs, ordered,
                       "attachedSkillIDs order is segment-0 byte order — it must survive verbatim, "
                           + "not be sorted or set-shuffled")
    }

    func testDecode_legacyJSONWithoutKey_defaultsToEmpty() throws {
        let legacyJSON = """
        {
            "id": "swe",
            "name": "Software Engineer",
            "icon": "hammer",
            "prompt": "SWE prompt",
            "toolIDs": [],
            "usePlanningPhase": true,
            "isSystemRole": false,
            "iconColor": "#FFFFFF",
            "iconBackground": "#007AFF",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z"
        }
        """
        let role = try JSONCoderFactory.makeDateDecoder()
            .decode(TeamRoleDefinition.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(role.attachedSkillIDs, [])
    }

    /// Encodable must stay SYNTHESIZED — the key has to appear in the payload,
    /// and no hand-written `encode(to:)` may quietly omit it.
    func testEncode_alwaysWritesTheKey() throws {
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(makeRole(skills: []))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(json["attachedSkillIDs"],
                        "attachedSkillIDs must always be encoded, empty included")
    }

    // MARK: - Interaction with the rest of the model

    /// Skills are orthogonal to delegation — attaching one must not flip the
    /// predicate that auto-injects the 4-tool delegation pack.
    func testAttachingSkills_doesNotAffectDelegationPredicate() {
        XCTAssertFalse(makeRole(skills: ["claude-skill|project|tdd"]).hasDelegationConfigured)
    }

    /// `Team.duplicate` copies roles by mutating a copy, so a new field rides
    /// along with no edit there (pinned generally by `TeamDuplicateTests`; this
    /// asserts it specifically for skills, the field that motivated the fix).
    func testDuplicate_carriesAttachedSkills() throws {
        let team = Team(name: "Src", roles: [makeRole(skills: ["claude-skill|project|tdd"])],
                        artifacts: [], settings: .default, graphLayout: .default)

        let copied = try XCTUnwrap(team.duplicate(withName: "Dst").roles.first)

        XCTAssertEqual(copied.attachedSkillIDs, ["claude-skill|project|tdd"])
    }
}
