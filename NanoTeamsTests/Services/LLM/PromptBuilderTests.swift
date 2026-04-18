import XCTest
@testable import NanoTeams

@MainActor
final class PromptBuilderTests: XCTestCase {

    // MARK: - Properties

    var defaultTeam: Team!

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        defaultTeam = Team.default
    }

    override func tearDown() {
        defaultTeam = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeContext(
        task: NTMSTask? = nil,
        step: StepExecution? = nil,
        stepIndex: Int = 0,
        run: Run? = nil,
        workFolder: WorkFolderProjection? = nil,
        artifactReader: ((Artifact) -> String?)? = nil,
        activeTeam: Team? = nil,
        roleDefinition: TeamRoleDefinition? = nil
    ) -> PromptBuilder.Context {
        let defaultStep = step ?? StepExecution(id: "test_step", role: .productManager, title: "Test Step")
        let defaultRun = run ?? Run(id: 0, steps: [defaultStep])
        let defaultTask = task ?? NTMSTask(id: 0, title: "Test Task", supervisorTask: "Build a feature", runs: [defaultRun])

        return PromptBuilder.Context(
            task: defaultTask,
            step: defaultStep,
            stepIndex: stepIndex,
            run: defaultRun,
            workFolder: workFolder,
            artifactReader: artifactReader ?? { _ in nil },
            activeTeam: activeTeam,
            roleDefinition: roleDefinition
        )
    }

    // MARK: - buildSupervisorTaskSection

    func testBuildSupervisorTaskSection_withContent_returnsFormattedSection() {
        let result = PromptBuilder.buildSupervisorTaskSection(supervisorTask: "Build a login page")

        XCTAssertNotNil(result)
        XCTAssertEqual(result, "## Supervisor Task\n\nBuild a login page")
    }

    func testBuildSupervisorTaskSection_empty_returnsNil() {
        let result = PromptBuilder.buildSupervisorTaskSection(supervisorTask: "")

        XCTAssertNil(result)
    }

    func testBuildSupervisorTaskSection_whitespaceOnly_returnsNil() {
        let result = PromptBuilder.buildSupervisorTaskSection(supervisorTask: "   \n\t  ")

        XCTAssertNil(result)
    }

    // MARK: - buildWorkFolderContextMessage

    func testBuildWorkFolderContextMessage_withProject_includesNameAndDescription() {
        let wf = WorkFolderProjection(
            state: WorkFolderState(name: "MyApp"),
            settings: ProjectSettings(description: "An iOS application for task management"),
            teams: []
        )

        let result = PromptBuilder.buildWorkFolderContextMessage(workFolder: wf)

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("MyApp"), "Should include project name")
        XCTAssertTrue(result!.contains("An iOS application for task management"), "Should include project description")
        XCTAssertTrue(result!.contains("Work folder context:"), "Should include header")
    }

    func testBuildWorkFolderContextMessage_nilProject_returnsNil() {
        let result = PromptBuilder.buildWorkFolderContextMessage(workFolder: nil)

        XCTAssertNil(result)
    }

    func testBuildWorkFolderContextMessage_emptyDescription_returnsNil() {
        let wf = WorkFolderProjection(
            state: WorkFolderState(name: "EmptyProject"),
            settings: ProjectSettings(description: ""),
            teams: []
        )

        let result = PromptBuilder.buildWorkFolderContextMessage(workFolder: wf)

        XCTAssertNil(result, "Should return nil when project has no description")
    }

    // MARK: - buildPipelineContext

    func testBuildPipelineContext_stepIndexZero_returnsEmpty() {
        let step = StepExecution(id: "test_step", role: .productManager, title: "PM Step")
        let run = Run(id: 0, steps: [step])

        let result = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 0,
            artifactReader: { _ in nil }
        )

        XCTAssertTrue(result.isEmpty, "Pipeline context for first step should be empty")
    }

    func testBuildPipelineContext_withPriorSteps_includesStepInfo() {
        let step0 = StepExecution(id: "test_step", role: .productManager, title: "PM Step", status: .done)
        let step1 = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer Step")
        let run = Run(id: 0, steps: [step0, step1])

        let result = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil }
        )

        XCTAssertFalse(result.isEmpty, "Pipeline context should not be empty when prior steps exist")
        XCTAssertTrue(result.contains("Step 1"), "Should reference step number")
        XCTAssertTrue(result.contains("Product Manager"), "Should include role display name")
        XCTAssertTrue(result.contains("done"), "Should include step status")
        XCTAssertTrue(result.contains("Context from previous steps"), "Should include header")
    }

    func testBuildPipelineContext_excludesSpecifiedArtifacts() {
        let artifact = Artifact(name: "Product Requirements", relativePath: "reqs.md")
        let step0 = StepExecution(
            id: "test_step",
            role: .productManager,
            title: "PM Step",
            status: .done,
            artifacts: [artifact]
        )
        let step1 = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer Step")
        let run = Run(id: 0, steps: [step0, step1])

        // Without exclusion: artifact should be present
        let resultWithArtifact = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil }
        )
        XCTAssertTrue(resultWithArtifact.contains("Product Requirements"), "Artifact should be in context without exclusion")

        // With exclusion: artifact should be absent
        let resultExcluded = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil },
            excludeArtifactNames: Set(["Product Requirements"])
        )
        XCTAssertFalse(resultExcluded.contains("Product Requirements"), "Excluded artifact should not appear in context")
    }

    /// Scratchpad is private to the authoring role — downstream roles get the
    /// finished artifact, not the author's planning trace. This test locks in
    /// that exclusion.
    func testBuildPipelineContext_excludesScratchpad() {
        let step0 = StepExecution(
            id: "test_step",
            role: .productManager,
            title: "PM Step",
            status: .done,
            scratchpad: "1. Draft requirements\n2. Review with UX"
        )
        let step1 = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer Step")
        let run = Run(id: 0, steps: [step0, step1])

        let result = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil }
        )

        XCTAssertFalse(result.contains("Scratchpad"),
                       "Downstream roles must not see upstream role's scratchpad")
        XCTAssertFalse(result.contains("Draft requirements"))
    }

    func testBuildPipelineContext_includesSupervisorQA() {
        let step0 = StepExecution(
            id: "test_step",
            role: .productManager,
            title: "PM Step",
            status: .done,
            supervisorQuestion: "What is the target audience?",
            supervisorAnswer: "Enterprise customers"
        )
        let step1 = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer Step")
        let run = Run(id: 0, steps: [step0, step1])

        let result = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil }
        )

        XCTAssertTrue(result.contains("Supervisor Q: What is the target audience?"), "Should include Supervisor question")
        XCTAssertTrue(result.contains("Supervisor A: Enterprise customers"), "Should include Supervisor answer")
    }

    // MARK: - buildChatMessages

    func testBuildChatMessages_firstMessageIsSystem() {
        let context = makeContext()
        let tools: [ToolSchema] = []

        let messages = PromptBuilder.buildChatMessages(context: context, tools: tools)

        XCTAssertFalse(messages.isEmpty, "Should produce at least one message")
        XCTAssertEqual(messages[0].role, .system, "First message should be system role")
    }

    func testBuildChatMessages_includesSupervisorTask() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Implement dark mode toggle")
        let step = StepExecution(id: "test_step", role: .productManager, title: "PM Step")
        let run = Run(id: 0, steps: [step])
        let context = makeContext(task: task, step: step, run: run)
        let tools: [ToolSchema] = []

        let messages = PromptBuilder.buildChatMessages(context: context, tools: tools)

        let supervisorTaskMessage = messages.first { $0.content?.contains("## Supervisor Task") == true }
        XCTAssertNotNil(supervisorTaskMessage, "Should include a Supervisor Task message")
        XCTAssertTrue(supervisorTaskMessage!.content!.contains("Implement dark mode toggle"), "Supervisor Task message should contain the task text")
        XCTAssertEqual(supervisorTaskMessage!.role, .user, "Supervisor Task message should have user role")
    }

    func testBuildChatMessages_usesEffectiveSupervisorBriefForQuickCaptureInput() {
        let task = NTMSTask(id: 0, title: "Test",
            supervisorTask: "Implement import flow",
            clippedTexts: ["Selected API response"],
            attachmentPaths: [".nanoteams/tasks/abc/attachments/spec.pdf"]
        )
        let step = StepExecution(id: "test_step", role: .productManager, title: "PM Step")
        let run = Run(id: 0, steps: [step])
        let context = makeContext(task: task, step: step, run: run)

        let messages = PromptBuilder.buildChatMessages(context: context, tools: [])

        let supervisorTaskMessage = messages.first { $0.content?.contains("## Supervisor Task") == true }
        XCTAssertNotNil(supervisorTaskMessage)
        XCTAssertTrue(supervisorTaskMessage?.content?.contains("Implement import flow") == true)
        XCTAssertTrue(supervisorTaskMessage?.content?.contains("--- Clipped Text ---") == true)
        XCTAssertTrue(supervisorTaskMessage?.content?.contains("Selected API response") == true)
        XCTAssertTrue(supervisorTaskMessage?.content?.contains("--- Attached Files ---") == true)
        XCTAssertTrue(supervisorTaskMessage?.content?.contains(".nanoteams/tasks/abc/attachments/spec.pdf") == true)
    }

    func testBuildChatMessages_minimalContext_addsStartPrompt() {
        // Create a context with empty Supervisor task so no Supervisor task message is added,
        // no project, no prior steps, and no step messages — only system message.
        let task = NTMSTask(id: 0, title: "Empty", supervisorTask: "", runs: [])
        let step = StepExecution(id: "test_step", role: .productManager, title: "Step")
        let run = Run(id: 0, steps: [step])

        let context = PromptBuilder.Context(
            task: task,
            step: step,
            stepIndex: 0,
            run: run,
            workFolder: nil,
            artifactReader: { _ in nil },
            activeTeam: nil,
            roleDefinition: nil
        )

        let messages = PromptBuilder.buildChatMessages(context: context, tools: [])

        // With no Supervisor task, no project context, no pipeline context, and no step messages,
        // buildChatMessages should have only system + "Start the step."
        XCTAssertEqual(messages.count, 2, "Should have system message and start prompt")
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[1].role, .user)
        XCTAssertEqual(messages[1].content, "Start the step.")
    }

    // MARK: - buildRequiredArtifactsSection

    func testBuildRequiredArtifactsSection_emptyArtifacts_returnsNil() {
        let result = PromptBuilder.buildRequiredArtifactsSection(
            artifacts: [],
            artifactReader: { _ in nil }
        )
        XCTAssertNil(result)
    }

    func testBuildRequiredArtifactsSection_includesFullContent() {
        let artifact = Artifact(name: "World Compendium", relativePath: "world.md")
        let content = "Full artifact content here"

        let result = PromptBuilder.buildRequiredArtifactsSection(
            artifacts: [artifact],
            artifactReader: { _ in content }
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("World Compendium"), "Should include artifact name")
        XCTAssertTrue(result!.contains(content), "Should include full content")
    }

    func testBuildRequiredArtifactsSection_longContent_notTruncated() {
        let artifact = Artifact(name: "World Compendium", relativePath: "world.md")
        // Content well over 2000 chars — must NOT be truncated
        let longContent = String(repeating: "The ancient kingdom of Eldara spans vast forests and mountain ranges. ", count: 100)
        XCTAssertGreaterThan(longContent.count, 5000, "Precondition: content must exceed old 2000 char limit")

        let result = PromptBuilder.buildRequiredArtifactsSection(
            artifacts: [artifact],
            artifactReader: { _ in longContent }
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains(longContent.trimmingCharacters(in: .whitespacesAndNewlines)),
                       "Full content must be present without truncation")
        XCTAssertFalse(result!.contains("truncated"), "Must not contain truncation marker")
    }

    func testBuildRequiredArtifactsSection_multipleArtifacts_allFullContent() {
        let a1 = Artifact(name: "NPC Roster", relativePath: "npcs.md")
        let a2 = Artifact(name: "Encounter Tables", relativePath: "encounters.md")
        let content1 = String(repeating: "NPC data line. ", count: 200)
        let content2 = String(repeating: "Encounter entry. ", count: 200)

        let result = PromptBuilder.buildRequiredArtifactsSection(
            artifacts: [a1, a2],
            artifactReader: { artifact in
                artifact.name == "NPC Roster" ? content1 : content2
            }
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("NPC Roster"))
        XCTAssertTrue(result!.contains("Encounter Tables"))
        XCTAssertTrue(result!.contains(content1.trimmingCharacters(in: .whitespacesAndNewlines)),
                       "First artifact content must be complete")
        XCTAssertTrue(result!.contains(content2.trimmingCharacters(in: .whitespacesAndNewlines)),
                       "Second artifact content must be complete")
        XCTAssertFalse(result!.contains("truncated"))
    }

    // MARK: - buildPipelineContext — Supervisor artifact full content

    func testBuildPipelineContext_supervisorArtifact_notTruncated() {
        let longGoal = String(repeating: "Build a comprehensive system with many features. ", count: 100)
        XCTAssertGreaterThan(longGoal.count, 4000, "Precondition: content exceeds old 2000 char limit")

        let supervisorArtifact = Artifact(name: "Supervisor Task", relativePath: "task.md")
        let step0 = StepExecution(
            id: "test_step",
            role: .supervisor,
            title: "Supervisor",
            status: .done,
            artifacts: [supervisorArtifact]
        )
        let step1 = StepExecution(id: "test_step", role: .productManager, title: "PM Step")
        let run = Run(id: 0, steps: [step0, step1])

        let result = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in longGoal }
        )

        XCTAssertTrue(result.contains(longGoal), "Supervisor artifact must be included in full")
        XCTAssertFalse(result.contains("truncated"), "Must not contain truncation marker")
    }

    // MARK: - buildChatMessages (continued)

    func testBuildChatMessages_includesStepMessages() {
        let step = StepExecution(
            id: "test_step",
            role: .productManager,
            title: "PM Step",
            messages: [
                StepMessage(role: .productManager, content: "I will draft the requirements."),
                StepMessage(role: .supervisor, content: "Please focus on mobile experience.")
            ]
        )
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Build mobile app", runs: [run])
        let context = makeContext(task: task, step: step, run: run)
        let tools: [ToolSchema] = []

        let messages = PromptBuilder.buildChatMessages(context: context, tools: tools)

        // Step messages from non-Supervisor role should be "assistant", Supervisor should be "user"
        let assistantMessages = messages.filter { $0.role == .assistant }
        let userMessages = messages.filter { $0.role == .user }

        XCTAssertFalse(assistantMessages.isEmpty, "Should include assistant messages from role")
        XCTAssertTrue(
            assistantMessages.contains(where: { $0.content == "I will draft the requirements." }),
            "Should include the role's message content"
        )
        XCTAssertTrue(
            userMessages.contains(where: { $0.content == "Please focus on mobile experience." }),
            "Should include the Supervisor's message content as user role"
        )
    }

    // MARK: - {workFolderContext} placement

    /// Work folder context lives inside the system prompt (see `{workFolderContext}`
    /// placeholder) so it persists in the stateful response chain. A regression
    /// would re-broadcast it as a separate `.user` message on every continuation,
    /// doubling tokens on long-running steps.
    func testBuildChatMessages_workFolderContext_goesIntoSystemPromptNotUserMessage() {
        let wf = WorkFolderProjection(
            state: WorkFolderState(name: "PlacementProbe"),
            settings: ProjectSettings(description: "Unique description string for placement check"),
            teams: []
        )
        let context = makeContext(workFolder: wf)

        let messages = PromptBuilder.buildChatMessages(context: context, tools: [])

        let systemMessage = messages.first { $0.role == .system }
        XCTAssertNotNil(systemMessage)
        XCTAssertTrue(systemMessage?.content?.contains("PlacementProbe") == true,
                       "Work folder name must appear in the system prompt")
        XCTAssertTrue(systemMessage?.content?.contains("Unique description string for placement check") == true,
                       "Work folder description must appear in the system prompt")

        let userMessagesWithWorkFolderHeader = messages.filter { msg in
            msg.role == .user && msg.content?.contains("Work folder context:") == true
        }
        XCTAssertTrue(userMessagesWithWorkFolderHeader.isEmpty,
                      "Work folder context must not be re-broadcast as a user message")
    }

    // MARK: - buildContextAwarenessGuidance branches

    func testBuildContextAwarenessGuidance_withFileReadTools_includesResourceTracking() {
        let guidance = PromptBuilder.buildContextAwarenessGuidance(hasFileReadTools: true)

        XCTAssertTrue(guidance.contains("<§R1§>"),
                      "file-read roles must get the tag legend")
        XCTAssertTrue(guidance.contains("MEMORIES"),
                      "file-read roles must be pointed at the MEMORIES index")
    }

    func testBuildContextAwarenessGuidance_withoutFileReadTools_omitsResourceTracking() {
        let guidance = PromptBuilder.buildContextAwarenessGuidance(hasFileReadTools: false)

        XCTAssertFalse(guidance.contains("<§R1§>"),
                       "non-file-reading roles must not see the tag legend")
        XCTAssertFalse(guidance.contains("MEMORIES"),
                       "non-file-reading roles must not be told about MEMORIES — they never produce tags")
        XCTAssertFalse(guidance.isEmpty,
                       "the Supervisor-task-awareness sentence still runs for every role")
    }

    // MARK: - getRequiredArtifactNames (Round 2 regression)

    func testGetRequiredArtifactNames_customRole_usesTeamDefinition() {
        let customID = UUID().uuidString
        let customRole = TeamRoleDefinition(
            id: customID,
            name: "Custom Backend",
            prompt: "Backend prompt",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Design Spec"],
                producesArtifacts: ["API Implementation"]
            )
        )

        let team = Team(
            name: "Custom Team",
            roles: [customRole],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )
        XCTAssertEqual(team.roles.count, 1)

        let role = Role.custom(id: customID)
        let names = PromptBuilder.getRequiredArtifactNames(role: role, team: team)

        XCTAssertEqual(names, ["Design Spec"],
                       "Should find custom role via findRole(byIdentifier:) and return its requiredArtifacts")
    }
}
