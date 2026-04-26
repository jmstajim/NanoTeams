import XCTest

@testable import NanoTeams

/// E2E tests for the prompt assembly pipeline:
/// team template → placeholder resolution → artifact injection → tool hints → ChatMessage[].
@MainActor
final class EndToEndPromptPipelineTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: FAANG Engineer full assembly

    func testPromptPipeline_faangEngineer_fullAssembly() {
        let team = makeFAANGTeam()

        let engineerRole = team.roles.first { $0.name == "Software Engineer" }!

        // Create prior PM step with artifact
        let pmStep = StepExecution(
            id: "test_step",
            role: .productManager,
            title: "Product Requirements",
            expectedArtifacts: ["Product Requirements"],
            status: .done,
            artifacts: [Artifact(name: "Product Requirements", description: "The requirements")]
        )

        let engineerStep = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Engineering Notes",
            expectedArtifacts: ["Engineering Notes"],
            status: .pending
        )

        let run = Run(id: 0, steps: [pmStep, engineerStep])
        let task = NTMSTask(id: 0, title: "Build feature", supervisorTask: "Implement login", runs: [run])

        let tools = [
            ToolSchema(name: "read_file", description: "Read a file", parameters: JSONSchema(type: "object")),
            ToolSchema(name: "write_file", description: "Write a file", parameters: JSONSchema(type: "object")),
            ToolSchema(name: "ask_supervisor", description: "Ask", parameters: JSONSchema(type: "object")),
            ToolSchema(name: "create_artifact", description: "Create", parameters: JSONSchema(type: "object")),
        ]

        let context = PromptBuilder.Context(
            task: task,
            step: engineerStep,
            stepIndex: 1,
            run: run,

            workFolder: nil,
            artifactReader: { artifact in
                artifact.name == "Product Requirements" ? "Requirements content here" : nil
            },
            activeTeam: team,
            roleDefinition: engineerRole
        )

        let messages = PromptBuilder.buildChatMessages(context: context, tools: tools)

        // System prompt should be first
        XCTAssertEqual(messages[0].role, MessageRole.system)
        let systemContent = messages[0].content ?? ""

        // Should contain resolved role name
        XCTAssertTrue(systemContent.contains("Software Engineer"),
                      "System prompt should contain role name")

        // Should contain team or role context
        XCTAssertFalse(systemContent.isEmpty, "System prompt should not be empty")

        // Supervisor Task should be present
        let hasSupervisorTask = messages.contains { ($0.content ?? "").contains("Implement login") }
        XCTAssertTrue(hasSupervisorTask, "Should include supervisor task")


        // Prior step context should be present (via pipeline context or required artifacts)
        let hasPriorContext = messages.contains {
            ($0.content ?? "").contains("Product Requirements") || ($0.content ?? "").contains("previous steps")
        }
        XCTAssertTrue(hasPriorContext, "Should include context from prior PM step")

        // Should have at least system + supervisor task + context
        XCTAssertGreaterThanOrEqual(messages.count, 3)
    }

    // MARK: - Test 2: Custom team with custom template

    func testPromptPipeline_customTeam_customTemplate() {
        let customTemplate = """
        You are {roleName} on team {teamName}.

        {roleGuidance}

        Tools: {toolList}
        """

        var team = Team(
            name: "Custom Squad",
            roles: [
                TeamRoleDefinition(
                    id: "custom-dev",
                    name: "Dev",
                    prompt: "Focus on clean code and testing.",
                    toolIDs: ["read_file"],
                    usePlanningPhase: false,
                    dependencies: RoleDependencies(
                        requiredArtifacts: ["Supervisor Task"],
                        producesArtifacts: ["Code"]
                    )
                ),
            ],
            artifacts: [],
            settings: TeamSettings.default,
            graphLayout: TeamGraphLayout()
        )
        team.systemPromptTemplate = customTemplate

        let roleDef = team.roles[0]
        let step = StepExecution(
            id: "test_step",
            role: .custom(id: "custom-dev"),
            title: "Code",
            expectedArtifacts: ["Code"],
            status: .pending
        )
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "Custom Task", supervisorTask: "Build it", runs: [run])

        let context = PromptBuilder.Context(
            task: task,
            step: step,
            stepIndex: 0,
            run: run,

            workFolder: nil,
            artifactReader: { _ in nil },
            activeTeam: team,
            roleDefinition: roleDef
        )

        let messages = PromptBuilder.buildChatMessages(context: context, tools: [])

        let systemContent = messages[0].content ?? ""

        // Custom template should be resolved
        XCTAssertTrue(systemContent.contains("Dev"), "Should resolve {roleName}")
        XCTAssertTrue(systemContent.contains("Custom Squad"), "Should resolve {teamName}")
        XCTAssertTrue(systemContent.contains("clean code"), "Should inject {roleGuidance}")
    }

    // MARK: - Test 3: Tool schema descriptions contain usage guidance

    func testPromptPipeline_toolSchemaDescriptions_containGuidance() {
        let schemas = ToolHandlerRegistry.allSchemas
        let scratchpad = schemas.first { $0.name == "update_scratchpad" }
        XCTAssertNotNil(scratchpad)
        XCTAssertTrue(scratchpad!.description.contains("2 calls per step"),
                      "update_scratchpad description should contain usage limit")

        let meeting = schemas.first { $0.name == "request_team_meeting" }
        XCTAssertNotNil(meeting)
        XCTAssertTrue(meeting!.description.contains("ONCE"),
                      "request_team_meeting description should contain call-once guidance")
    }

    // MARK: - Test 4: Pipeline context includes prior steps

    func testPromptPipeline_pipelineContext_includesPriorSteps() {
        let team = makeFAANGTeam()
        let pmRole = team.roles.first { $0.name == "Product Manager" }!
        let tlRole = team.roles.first { $0.name == "Tech Lead" }!

        let pmStep = StepExecution(
            id: "test_step",
            role: .productManager,
            title: "Product Requirements",
            expectedArtifacts: ["Product Requirements"],
            status: .done,
            artifacts: [Artifact(name: "Product Requirements")]
        )

        let tlStep = StepExecution(
            id: "test_step",
            role: .techLead,
            title: "Implementation Plan",
            expectedArtifacts: ["Implementation Plan"],
            status: .pending
        )

        let run = Run(id: 0, steps: [pmStep, tlStep])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])

        let context = PromptBuilder.Context(
            task: task,
            step: tlStep,
            stepIndex: 1,
            run: run,

            workFolder: nil,
            artifactReader: { _ in "artifact content" },
            activeTeam: team,
            roleDefinition: tlRole
        )

        let messages = PromptBuilder.buildChatMessages(context: context, tools: [])

        // Should have more than just system + "Start the step"
        // because there's a prior step with artifacts
        XCTAssertGreaterThan(messages.count, 2,
                             "Should include context from prior PM step")
    }

    // MARK: - Test 5: Empty team graceful degradation

    func testPromptPipeline_emptyTeam_gracefulDegradation() {
        let emptyTeam = Team(
            name: "Empty",
            roles: [],
            artifacts: [],
            settings: TeamSettings.default,
            graphLayout: TeamGraphLayout()
        )

        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "work",
            status: .pending
        )
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])

        let context = PromptBuilder.Context(
            task: task,
            step: step,
            stepIndex: 0,
            run: run,

            workFolder: nil,
            artifactReader: { _ in nil },
            activeTeam: emptyTeam,
            roleDefinition: nil
        )

        // Should not crash with empty team
        let messages = PromptBuilder.buildChatMessages(context: context, tools: [])

        XCTAssertFalse(messages.isEmpty, "Should produce at least system message")
        XCTAssertEqual(messages[0].role, MessageRole.system)
    }

    // MARK: - Helpers

    private func makeFAANGTeam() -> Team {
        let supervisorRole = TeamRoleDefinition(
            id: "supervisor",
            name: "Supervisor",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Release Notes"],
                producesArtifacts: ["Supervisor Task"]
            ),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )

        let pmRole = TeamRoleDefinition(
            id: "pm-role",
            name: "Product Manager",
            prompt: "You manage the product.",
            toolIDs: ["read_file", "ask_supervisor"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Supervisor Task"],
                producesArtifacts: ["Product Requirements"]
            ),
            isSystemRole: true,
            systemRoleID: "productManager"
        )

        let tlRole = TeamRoleDefinition(
            id: "tl-role",
            name: "Tech Lead",
            prompt: "You lead technical decisions.",
            toolIDs: ["read_file", "ask_supervisor"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Product Requirements"],
                producesArtifacts: ["Implementation Plan"]
            ),
            isSystemRole: true,
            systemRoleID: "techLead"
        )

        let sweRole = TeamRoleDefinition(
            id: "swe-role",
            name: "Software Engineer",
            prompt: "You write code.",
            toolIDs: ["read_file", "write_file", "edit_file"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Implementation Plan"],
                producesArtifacts: ["Engineering Notes"]
            ),
            isSystemRole: true,
            systemRoleID: "softwareEngineer"
        )

        return Team(
            name: "FAANG Team",
            roles: [supervisorRole, pmRole, tlRole, sweRole],
            artifacts: [],
            settings: TeamSettings.default,
            graphLayout: TeamGraphLayout()
        )
    }
}
