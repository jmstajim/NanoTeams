import XCTest
@testable import NanoTeams

@MainActor
final class PromptBuilderPreviewTests: XCTestCase {

    private func makeTeamRoleDef(
        id: String,
        name: String,
        prompt: String,
        toolIDs: Set<String> = [],
        dependencies: RoleDependencies? = nil
    ) -> TeamRoleDefinition {
        return TeamRoleDefinition(
            id: id,
            name: name,
            prompt: prompt,
            toolIDs: Array(toolIDs),
            usePlanningPhase: true,
            dependencies: dependencies ?? SystemTemplates.roles[id]?.dependencies ?? RoleDependencies(),
            llmOverride: nil,
            isSystemRole: Role.isBuiltInID(id),
            systemRoleID: Role.isBuiltInID(id) ? id : nil,
            createdAt: MonotonicClock.shared.now(),
            updatedAt: MonotonicClock.shared.now()
        )
    }

    func testBuildSystemPromptPreview_softwareEngineer() throws {
        // Given
        let role = makeTeamRoleDef(
            id: Role.builtInID(.softwareEngineer),
            name: "Software Engineer",
            prompt: "Build high-quality software",
            toolIDs: ["read_file", "write_file"]
        )

        let tools = [
            ToolDefinitionRecord(
                id: "read_file",
                name: "read_file",
                prompt: "Read a file",
                parameters: JSONSchema(
                    type: "object",
                    properties: ["path": JSONSchemaProperty(type: "string", description: nil, properties: nil, required: nil, items: nil, enumValues: nil)]
                ),
                isBuiltIn: true
            ),
            ToolDefinitionRecord(
                id: "write_file",
                name: "write_file",
                prompt: "Write a file",
                parameters: JSONSchema(
                    type: "object",
                    properties: ["path": JSONSchemaProperty(type: "string", description: nil, properties: nil, required: nil, items: nil, enumValues: nil), "content": JSONSchemaProperty(type: "string", description: nil, properties: nil, required: nil, items: nil, enumValues: nil)]
                ),
                isBuiltIn: true
            )
        ]

        // When
        let prompt = PromptBuilder.buildSystemPromptPreview(
            roleDefinition: role,
            toolDefinitions: tools,
            team: nil
        )

        // Then
        XCTAssertTrue(prompt.contains("Software Engineer"), "Should include role name")
        XCTAssertTrue(prompt.contains("Build high-quality software"), "Should include role guidance")
    }

    func testBuildSystemPromptPreview_customRole() throws {
        // Given
        let customDeps = RoleDependencies(
            requiredArtifacts: ["Input Spec"],
            producesArtifacts: ["Custom Output"]
        )

        let role = makeTeamRoleDef(
            id: "custom-role-123",
            name: "Custom Role",
            prompt: "Custom role prompt text",
            toolIDs: ["search"],
            dependencies: customDeps
        )

        let tools = [
            ToolDefinitionRecord(
                id: "search",
                name: "search",
                prompt: "Search the project",
                parameters: JSONSchema(
                    type: "object",
                    properties: ["query": JSONSchemaProperty(type: "string", description: nil, properties: nil, required: nil, items: nil, enumValues: nil)]
                ),
                isBuiltIn: true
            )
        ]

        // When
        let prompt = PromptBuilder.buildSystemPromptPreview(
            roleDefinition: role,
            toolDefinitions: tools,
            team: nil
        )

        // Then
        XCTAssertTrue(prompt.contains("Custom Role"), "Should include custom role name")
        XCTAssertTrue(prompt.contains("Custom role prompt text"), "Should include custom prompt")
        XCTAssertTrue(prompt.contains("Custom Output"), "Should include custom expected artifacts")
        XCTAssertTrue(prompt.contains("search"), "Should list custom tool")
    }

    func testBuildSystemPromptPreview_noTools() throws {
        // Given
        let role = makeTeamRoleDef(
            id: Role.builtInID(.productManager),
            name: "Product Manager",
            prompt: "Write requirements",
            toolIDs: []
        )

        // When
        let prompt = PromptBuilder.buildSystemPromptPreview(
            roleDefinition: role,
            toolDefinitions: [],
            team: Team.default
        )

        // Then
        XCTAssertTrue(prompt.contains("Product Manager"), "Should include role name")
        XCTAssertTrue(prompt.contains("No tools are available"), "Should indicate no tools")
    }

    func testBuildSystemPromptPreview_customDependencies() throws {
        // Given
        let customDeps = RoleDependencies(
            requiredArtifacts: ["Spec A", "Spec B"],
            producesArtifacts: ["Output X", "Output Y"]
        )

        let role = makeTeamRoleDef(
            id: Role.builtInID(.uxDesigner),
            name: "UX Designer",
            prompt: "Design the UI",
            dependencies: customDeps
        )

        // When
        let prompt = PromptBuilder.buildSystemPromptPreview(
            roleDefinition: role,
            toolDefinitions: [],
            team: Team.default
        )

        // Then
        XCTAssertTrue(prompt.contains("UX Designer"), "Should include role name")
        XCTAssertTrue(prompt.contains("Output X, Output Y"), "Should include both expected artifacts")
    }

    func testBuildSystemPromptPreview_withWorkFolder() throws {
        // Given
        let role = makeTeamRoleDef(
            id: Role.builtInID(.softwareEngineer),
            name: "Software Engineer",
            prompt: "Build software"
        )

        let teamArtifact = TeamArtifact(
            id: UUID().uuidString,
            name: "Engineering Notes",
            icon: "note.text",
            mimeType: "text/markdown",
            description: "Technical implementation notes and decisions",
            isSystemArtifact: true,
            systemArtifactName: "Engineering Notes",
            createdAt: MonotonicClock.shared.now(),
            updatedAt: MonotonicClock.shared.now()
        )

        let team = Team(
            id: "test_team",
            createdAt: MonotonicClock.shared.now(),
            updatedAt: MonotonicClock.shared.now(),
            name: "Test Team",
            roles: [role],
            artifacts: [teamArtifact],
            settings: .default,
            graphLayout: .default
        )

        // When
        let prompt = PromptBuilder.buildSystemPromptPreview(
            roleDefinition: role,
            toolDefinitions: [],
            team: team
        )

        // Then
        XCTAssertTrue(prompt.contains("Engineering Notes"), "Should include artifact name")
        XCTAssertTrue(prompt.contains("Technical implementation notes"), "Should include artifact description")
    }

    func testBuildSystemPromptPreview_productManagerWithWorkFolder() throws {
        // Given
        let role = makeTeamRoleDef(
            id: Role.builtInID(.productManager),
            name: "Product Manager",
            prompt: "Write PRD"
        )

        // When
        let prompt = PromptBuilder.buildSystemPromptPreview(
            roleDefinition: role,
            toolDefinitions: [],
            team: nil
        )

        // Then
        XCTAssertTrue(prompt.contains("Product Manager"), "Should include role name")
        XCTAssertTrue(prompt.contains("Write PRD"), "Should include role guidance")
    }

    // MARK: - Template Resolution Tests

    func testResolveTemplate_replacesAllPlaceholders() {
        let template = "Hello {name}, welcome to {team}!"
        let placeholders = ["name": "Alice", "team": "FAANG"]

        let result = SystemTemplates.resolveTemplate(template, placeholders: placeholders)

        XCTAssertEqual(result, "Hello Alice, welcome to FAANG!")
    }

    func testResolveTemplate_unknownPlaceholdersStay() {
        let template = "Hello {name}, your {unknownKey} is ready."
        let placeholders = ["name": "Bob"]

        let result = SystemTemplates.resolveTemplate(template, placeholders: placeholders)

        XCTAssertEqual(result, "Hello Bob, your {unknownKey} is ready.")
    }

    func testResolveTemplate_softwareTemplate_containsAllPlaceholders() {
        let template = SystemTemplates.softwareTemplate
        let placeholders: [String: String] = [
            "roleName": "SWE",
            "stepInfo": "Step 1 of 5",
            "teamRoles": "PM, TL, SWE",
            "teamDescription": "A dev team",
            "positionContext": "After TL",
            "roleGuidance": "Build things",
            "toolList": "read_file, write_file",
            "expectedArtifacts": "Engineering Notes",
            "artifactInstructions": "",
        ]

        let result = SystemTemplates.resolveTemplate(template, placeholders: placeholders)

        XCTAssertTrue(result.contains("SWE"), "Should resolve roleName")
        XCTAssertTrue(result.contains("Step 1 of 5"), "Should resolve stepInfo")
        XCTAssertTrue(result.contains("PM, TL, SWE"), "Should resolve teamRoles")
        XCTAssertTrue(result.contains("After TL"), "Should resolve positionContext")
        XCTAssertTrue(result.contains("Build things"), "Should resolve roleGuidance")
        XCTAssertTrue(result.contains("Engineering Notes"), "Should resolve expectedArtifacts")
        XCTAssertFalse(result.contains("{roleName}"), "Should not contain unresolved placeholder")
        XCTAssertFalse(result.contains("{stepInfo}"), "Should not contain unresolved placeholder")
    }

    func testResolveTemplate_questPartyTemplate_containsRoleName() {
        let template = SystemTemplates.questPartyTemplate
        let result = SystemTemplates.resolveTemplate(template, placeholders: ["roleName": "Lore Master"])

        XCTAssertTrue(result.contains("Lore Master"))
        XCTAssertTrue(result.contains("single-player"), "Quest Party template should mention single-player")
    }

    func testResolveTemplate_discussionTemplate_containsRoleName() {
        let template = SystemTemplates.discussionTemplate
        let result = SystemTemplates.resolveTemplate(template, placeholders: ["roleName": "Moderator"])

        XCTAssertTrue(result.contains("Moderator"))
        XCTAssertTrue(result.contains("discussion club"), "Discussion template should mention discussion club")
    }

    func testDefaultTemplateForTeamID() {
        XCTAssertEqual(SystemTemplates.defaultSystemTemplate(for: "faang"), SystemTemplates.softwareTemplate)
        XCTAssertEqual(SystemTemplates.defaultSystemTemplate(for: "startup"), SystemTemplates.softwareTemplate)
        XCTAssertEqual(SystemTemplates.defaultSystemTemplate(for: "questParty"), SystemTemplates.questPartyTemplate)
        XCTAssertEqual(SystemTemplates.defaultSystemTemplate(for: "discussionClub"), SystemTemplates.discussionTemplate)
        XCTAssertEqual(SystemTemplates.defaultSystemTemplate(for: nil), SystemTemplates.genericTemplate)
        XCTAssertEqual(SystemTemplates.defaultSystemTemplate(for: "unknownTeam"), SystemTemplates.genericTemplate)
    }

    func testDefaultConsultationTemplateForTeamID() {
        XCTAssertEqual(SystemTemplates.defaultConsultationTemplate(for: "faang"), SystemTemplates.softwareConsultationTemplate)
        XCTAssertEqual(SystemTemplates.defaultConsultationTemplate(for: "questParty"), SystemTemplates.questPartyConsultationTemplate)
        XCTAssertEqual(SystemTemplates.defaultConsultationTemplate(for: "discussionClub"), SystemTemplates.discussionConsultationTemplate)
        XCTAssertEqual(SystemTemplates.defaultConsultationTemplate(for: nil), SystemTemplates.genericConsultationTemplate)
    }

    func testDefaultMeetingTemplateForTeamID() {
        XCTAssertEqual(SystemTemplates.defaultMeetingTemplate(for: "faang"), SystemTemplates.softwareMeetingTemplate)
        XCTAssertEqual(SystemTemplates.defaultMeetingTemplate(for: "questParty"), SystemTemplates.questPartyMeetingTemplate)
        XCTAssertEqual(SystemTemplates.defaultMeetingTemplate(for: "discussionClub"), SystemTemplates.discussionMeetingTemplate)
        XCTAssertEqual(SystemTemplates.defaultMeetingTemplate(for: nil), SystemTemplates.genericMeetingTemplate)
    }

    func testBuildSystemPromptPreview_usesTeamTemplate() throws {
        let role = makeTeamRoleDef(
            id: Role.builtInID(.softwareEngineer),
            name: "Software Engineer",
            prompt: "Build software"
        )

        let team = Team.defaultTeams.first(where: { $0.name == "FAANG Team" })!

        let prompt = PromptBuilder.buildSystemPromptPreview(
            roleDefinition: role,
            toolDefinitions: [],
            team: team
        )

        // Should use the software template which mentions "software development team"
        XCTAssertTrue(prompt.contains("software development team"), "FAANG team should use software template")
        XCTAssertTrue(prompt.contains("Software Engineer"), "Should resolve role name")
    }

    func testBuildSystemPromptPreview_questPartyTeamUsesQuestPartyTemplate() throws {
        let teams = Team.defaultTeams
        guard let questTeam = teams.first(where: { $0.name == "Quest Party" }) else {
            XCTFail("Quest Party not found")
            return
        }

        let loreMaster = questTeam.roles.first(where: { $0.systemRoleID == "loreMaster" })!

        let prompt = PromptBuilder.buildSystemPromptPreview(
            roleDefinition: loreMaster,
            toolDefinitions: [],
            team: questTeam
        )

        XCTAssertTrue(prompt.contains("single-player"), "Quest Party team should use quest party template")
        XCTAssertTrue(prompt.contains(loreMaster.name), "Should resolve role name")
    }

    func testBuildSystemPromptPreview_defaultToolIDs() throws {
        // Given - role with default toolIDs
        let role = makeTeamRoleDef(
            id: Role.builtInID(.softwareEngineer),
            name: "Software Engineer",
            prompt: "Build software",
            toolIDs: (SystemTemplates.fallbackToolIDs[Role.softwareEngineer.baseID] ?? [])
        )

        let allTools = ToolDefinitionRecord.defaultDefinitions()

        // When
        let prompt = PromptBuilder.buildSystemPromptPreview(
            roleDefinition: role,
            toolDefinitions: allTools,
            team: nil
        )

        // Then - tool hints should be present for engineer tools
        XCTAssertFalse(prompt.isEmpty, "Should produce non-empty prompt")
    }
}
