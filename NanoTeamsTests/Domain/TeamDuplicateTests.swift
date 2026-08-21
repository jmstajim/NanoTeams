import XCTest
@testable import NanoTeams

/// `Team.duplicate` used to rebuild every role and artifact through the
/// memberwise init, enumerating fields by hand. Anything the literal forgot fell
/// back to its default — silently, and it still compiled.
///
/// That was live at BOTH levels, and since
/// `TeamEditorView+Actions.handleCreateTeam` creates every template-based team
/// via `template.duplicate(withName:)`, picking "Coding Agent" in the New Team
/// sheet was the path that hit it:
///
/// - Team level: all three prompt templates were omitted, so the duplicate ran
///   `SystemTemplates.genericTemplate` instead of the template's own prompt.
/// - Role level: `icon`, `iconColor`, `iconBackground`,
///   `allowedDelegationTeamIDs` and `allowDelegationToGeneratedTeams` were
///   dropped, producing an agent that could not delegate at all — the whole
///   point of that template — plus a roster of identical grey `person` avatars.
///
/// These tests pin the two properties that matter: the intentional rewrites
/// (identity, provenance, timestamps) still happen, and **everything else is
/// carried over verbatim**. The catch-all encode comparisons are what protect
/// the next field somebody adds to `Team` or `TeamRoleDefinition`.
@MainActor
final class TeamDuplicateTests: XCTestCase {

    // MARK: - The regression that shipped

    func testDuplicate_codingAgentTemplate_keepsDelegationWhitelist() {
        let template = TeamTemplateFactory.codingAgent()
        guard let originalAgent = template.roles.first(where: { $0.hasDelegationConfigured }) else {
            return XCTFail("Coding Agent template must ship a delegation-configured role")
        }

        let copy = template.duplicate(withName: "My Agent")

        guard let copiedAgent = copy.roles.first(where: { $0.name == originalAgent.name }) else {
            return XCTFail("Duplicated team lost the agent role")
        }
        XCTAssertEqual(copiedAgent.allowedDelegationTeamIDs, originalAgent.allowedDelegationTeamIDs,
                       "Duplicating must not drop the baked-in delegation whitelist")
        XCTAssertTrue(copiedAgent.allowDelegationToGeneratedTeams,
                      "Duplicating must not drop the generated-team permission")
        XCTAssertTrue(copiedAgent.hasDelegationConfigured,
                      "A duplicated Coding Agent must still be able to delegate — this is the "
                          + "predicate that gates auto-injection of the 4-tool delegation pack")
    }

    func testDuplicate_keepsRoleIconAndColors() {
        let template = TeamTemplateFactory.faang()
        let copy = template.duplicate(withName: "FAANG Clone")

        for original in template.roles {
            guard let copied = copy.roles.first(where: { $0.name == original.name }) else {
                return XCTFail("Duplicated team lost role \(original.name)")
            }
            XCTAssertEqual(copied.icon, original.icon, "icon lost for \(original.name)")
            XCTAssertEqual(copied.iconColor, original.iconColor, "iconColor lost for \(original.name)")
            XCTAssertEqual(copied.iconBackground, original.iconBackground,
                           "iconBackground lost for \(original.name)")
        }
    }

    // MARK: - Catch-all: only identity / provenance / timestamps may differ

    /// Encodes both roles, strips the fields `duplicate` is *supposed* to
    /// rewrite, and requires the remainder to match. A field added to
    /// `TeamRoleDefinition` later is covered with no edit here — which is
    /// exactly what the hand-enumerated rebuild could not offer.
    func testDuplicate_role_preservesEveryFieldExceptIdentityAndTimestamps() throws {
        let original = TeamRoleDefinition(
            id: "orig",
            name: "Engineer",
            icon: "hammer",
            prompt: "Do the work.",
            toolIDs: ["read_file", "write_file"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(requiredArtifacts: ["A"], producesArtifacts: ["B"]),
            llmOverride: LLMOverride(baseURLString: "http://127.0.0.1:1234", modelName: "m"),
            allowedDelegationTeamIDs: [NTMSID.from(name: "Engineering Team")],
            allowDelegationToGeneratedTeams: true,
            isSystemRole: true,
            systemRoleID: "softwareEngineer",
            iconColor: "#112233",
            iconBackground: "#445566"
        )
        let team = Team(name: "Src", roles: [original], artifacts: [],
                        settings: .default, graphLayout: .default)

        let copied = try XCTUnwrap(team.duplicate(withName: "Dst").roles.first)

        XCTAssertEqual(try mutableFields(of: copied), try mutableFields(of: original))
    }

    func testDuplicate_artifact_preservesEveryFieldExceptIdentityAndTimestamps() throws {
        let original = TeamArtifact(
            id: "orig",
            name: "Design Spec",
            icon: "paintbrush",
            mimeType: "text/markdown",
            description: "The spec.",
            isSystemArtifact: true,
            systemArtifactName: "Design Spec"
        )
        let team = Team(name: "Src", roles: [], artifacts: [original],
                        settings: .default, graphLayout: .default)

        let copied = try XCTUnwrap(team.duplicate(withName: "Dst").artifacts.first)

        XCTAssertEqual(try mutableFields(of: copied), try mutableFields(of: original))
    }

    // MARK: - Team level

    /// The bigger half of the same bug: the team literal omitted all three
    /// prompt templates, so every duplicate ran the GENERIC system prompt. A
    /// template's prompt is the main thing it contributes.
    func testDuplicate_keepsAllThreePromptTemplates() {
        for template in TeamTemplateFactory.allTemplates {
            let copy = template.duplicate(withName: "\(template.name) Copy")

            XCTAssertEqual(copy.systemPromptTemplate, template.systemPromptTemplate,
                           "\(template.name): system prompt template must carry over")
            XCTAssertEqual(copy.consultationPromptTemplate, template.consultationPromptTemplate,
                           "\(template.name): consultation template must carry over")
            XCTAssertEqual(copy.meetingPromptTemplate, template.meetingPromptTemplate,
                           "\(template.name): meeting template must carry over")
        }
    }

    /// At least one bundled template must differ from the generic prompt, or the
    /// test above would pass vacuously.
    func testAtLeastOneTemplate_differsFromTheGenericPrompt() {
        XCTAssertTrue(
            TeamTemplateFactory.allTemplates.contains {
                $0.systemPromptTemplate != SystemTemplates.genericTemplate
            },
            "Otherwise the prompt-carry-over test proves nothing")
    }

    /// Catch-all for the team's own fields — protects the next one added.
    func testDuplicate_team_preservesEveryFieldExceptIdentityAndCollections() throws {
        let template = TeamTemplateFactory.codingAgent()
        let copy = template.duplicate(withName: "Dst")

        // Rewritten by design; compared individually below or in sibling tests.
        let rewritten: Set<String> = [
            "id", "name", "createdAt", "updatedAt", "templateID",
            "roles", "artifacts", "settings", "graphLayout",
            "deletedSystemRoleIDs", "deletedSystemArtifactIDs",
        ]
        XCTAssertEqual(try teamFields(of: copy, excluding: rewritten),
                       try teamFields(of: template, excluding: rewritten))
    }

    /// A duplicate is a CUSTOM team. Carrying the template id over would make
    /// the version-bump reconcile rewrite the copy's prompt templates — undoing
    /// the very carry-over pinned above — and put two teams behind one identity
    /// in every picker that filters on `templateID`.
    func testDuplicate_dropsTemplateIdentity() {
        let copy = TeamTemplateFactory.codingAgent().duplicate(withName: "Dst")

        XCTAssertNil(copy.templateID)
        XCTAssertTrue(copy.deletedSystemRoleIDs.isEmpty)
        XCTAssertTrue(copy.deletedSystemArtifactIDs.isEmpty)
        XCTAssertFalse(copy.roles.contains { $0.isSystemRole },
                       "…which is what makes the deleted-system lists meaningless")
    }

    // MARK: - The intentional rewrites still happen

    func testDuplicate_rewritesIdentityProvenanceAndTimestamps() throws {
        let role = TeamRoleDefinition(
            id: "orig", name: "Engineer", prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies(),
            isSystemRole: true, systemRoleID: "softwareEngineer"
        )
        let artifact = TeamArtifact(id: "orig-a", name: "Spec", icon: "doc",
                                    mimeType: "text/markdown", description: "",
                                    isSystemArtifact: true)
        let team = Team(name: "Src", roles: [role], artifacts: [artifact],
                        settings: .default, graphLayout: .default)

        let copy = team.duplicate(withName: "Dst")
        let copiedRole = try XCTUnwrap(copy.roles.first)
        let copiedArtifact = try XCTUnwrap(copy.artifacts.first)

        XCTAssertNotEqual(copiedRole.id, role.id, "role id must be regenerated")
        XCTAssertNotEqual(copiedArtifact.id, artifact.id, "artifact id must be regenerated")
        XCTAssertFalse(copiedRole.isSystemRole, "duplicated roles are custom")
        XCTAssertFalse(copiedArtifact.isSystemArtifact, "duplicated artifacts are custom")
        XCTAssertEqual(copiedRole.systemRoleID, role.systemRoleID,
                       "systemRoleID is provenance, not identity — it is preserved")
        XCTAssertGreaterThan(copiedRole.createdAt, role.createdAt,
                             "duplicated roles get fresh timestamps")
        XCTAssertGreaterThan(copiedArtifact.createdAt, artifact.createdAt,
                             "duplicated artifacts get fresh timestamps")
    }

    func testDuplicate_isDeterministic_sameNameSameIDs() {
        let team = TeamTemplateFactory.codingAgent()
        let a = team.duplicate(withName: "Same")
        let b = team.duplicate(withName: "Same")
        XCTAssertEqual(a.roles.map(\.id), b.roles.map(\.id))
        XCTAssertEqual(a.artifacts.map(\.id), b.artifacts.map(\.id))
    }

    // MARK: - Helpers

    /// JSON of a value with the deliberately-rewritten keys removed, so equality
    /// means "every other field survived".
    private func mutableFields<T: Encodable>(of value: T) throws -> NSDictionary {
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(value)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        for key in ["id", "isSystemRole", "isSystemArtifact", "createdAt", "updatedAt"] {
            json.removeValue(forKey: key)
        }
        return json as NSDictionary
    }

    /// Same idea one level up, with the excluded key set passed in — the team's
    /// deliberate rewrites are a longer and less obvious list than the role's.
    private func teamFields(of team: Team, excluding keys: Set<String>) throws -> NSDictionary {
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(team)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        for key in keys { json.removeValue(forKey: key) }
        XCTAssertFalse(json.isEmpty,
                       "Every field is excluded — the comparison would be vacuous")
        return json as NSDictionary
    }
}
