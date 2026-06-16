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

    // MARK: - Supervisor Goal header (Autovisor) — GAP3

    func testBuildSupervisorTaskSection_customHeader_rendersIt() {
        let result = PromptBuilder.buildSupervisorTaskSection(
            supervisorTask: "Advance the parser", header: "Supervisor Goal")
        XCTAssertEqual(result, "## Supervisor Goal\n\nAdvance the parser")
    }

    func testBuildChatMessages_autovisorTeam_usesSupervisorGoalHeader() {
        let team = TeamTemplateFactory.autovisor()
        let task = NTMSTask(id: 0, title: "FM", supervisorTask: "Keep the folder healthy", runs: [Run(id: 0, steps: [])])
        let context = makeContext(task: task, activeTeam: team)

        let messages = PromptBuilder.buildChatMessages(context: context, tools: [])
        let joined = messages.compactMap(\.content).joined(separator: "\n")

        XCTAssertTrue(joined.contains("## Supervisor Goal"),
                      "Autovisor renders its brief as '## Supervisor Goal'")
        XCTAssertFalse(joined.contains("## Supervisor Task"),
                       "Autovisor must NOT show the generic '## Supervisor Task' header")
    }

    func testBuildChatMessages_nonManagerTeam_keepsSupervisorTaskHeader() {
        let context = makeContext(activeTeam: defaultTeam)  // not Autovisor

        let messages = PromptBuilder.buildChatMessages(context: context, tools: [])
        let joined = messages.compactMap(\.content).joined(separator: "\n")

        XCTAssertTrue(joined.contains("## Supervisor Task"),
                      "non-manager teams keep the default '## Supervisor Task' header")
        XCTAssertFalse(joined.contains("## Supervisor Goal"))
    }

    // MARK: - Revision feedback in stateless rebuild

    /// The stateless conversation rebuild relays revision feedback from the single
    /// prefixed `StepMessage` in `step.messages` — `revisionComment` (now reliably
    /// populated for the whole revision lifetime) must NOT be independently injected,
    /// or every stateless rebuild would carry the feedback twice.
    func testBuildChatMessages_revisionStep_feedbackAppearsExactlyOnce() {
        let rawComment = "Fix the restart bug in section 3."
        var step = StepExecution(
            id: "swe_revision", role: .softwareEngineer, title: "SWE",
            status: .running
        )
        step.messages = [
            StepMessage(role: .softwareEngineer, content: "Earlier work output"),
            StepMessage(
                role: .supervisor,
                content: MessageSourceContext.supervisorFeedbackPrefix + rawComment
            ),
        ]
        step.revisionComment = rawComment
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "T", supervisorTask: "Goal", runs: [run])
        let context = makeContext(task: task, step: step, run: run, activeTeam: defaultTeam)

        let messages = PromptBuilder.buildChatMessages(context: context, tools: [])
        let joined = messages.compactMap(\.content).joined(separator: "\n")

        XCTAssertEqual(
            joined.components(separatedBy: rawComment).count, 2,
            "Feedback text must appear exactly once in the stateless rebuild")
        XCTAssertEqual(
            joined.components(separatedBy: "Supervisor Feedback:").count, 2,
            "Exactly one attribution prefix in the stateless rebuild")
    }

    // MARK: - buildWorkFolderContextMessage

    func testBuildWorkFolderContextMessage_withProject_includesNameAndContext() {
        let wf = WorkFolderProjection(
            state: WorkFolderState(name: "MyApp"),
            settings: ProjectSettings(context: "An iOS application for task management"),
            teams: []
        )

        let result = PromptBuilder.buildWorkFolderContextMessage(workFolder: wf)

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("MyApp"), "Should include work folder name (bold)")
        XCTAssertTrue(result!.contains("An iOS application for task management"), "Should include work folder context")
        XCTAssertFalse(result!.contains("## Work folder"),
                       "Chip body must NOT include the `## Work folder` header — template owns it (2026-05 chip-format contract)")
    }

    func testBuildWorkFolderContextMessage_nilProject_returnsNil() {
        let result = PromptBuilder.buildWorkFolderContextMessage(workFolder: nil)

        XCTAssertNil(result)
    }

    func testBuildWorkFolderContextMessage_emptyContext_returnsNil() {
        let wf = WorkFolderProjection(
            state: WorkFolderState(name: "EmptyProject"),
            settings: ProjectSettings(context: ""),
            teams: []
        )

        let result = PromptBuilder.buildWorkFolderContextMessage(workFolder: wf)

        XCTAssertNil(result, "Should return nil when work folder has no context")
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

    // Regression for Run 14: UX Researcher drifted 67k+76k chars of thinking
    // reasoning about `Step 1 — Product Manager: Product Requirements — Status: running`
    // (parallel branch, not a dependency for UXR). With the filter active, in-progress
    // parallel steps whose artifacts aren't required by the current role are omitted.
    func testBuildPipelineContext_filter_inProgressNonDependency_omitted() {
        // Step 0: parallel PM still running; its artifact is NOT required by the current role.
        let pmStep = StepExecution(
            id: "pm_step",
            role: .productManager,
            title: "Product Requirements",
            status: .running,
            artifacts: [Artifact(name: "Product Requirements")]
        )
        let uxrStep = StepExecution(id: "uxr_step", role: .uxResearcher, title: "UXR Step")
        let run = Run(id: 0, steps: [pmStep, uxrStep])

        // With filter: PM's in-progress step is skipped (UXR doesn't require "Product Requirements").
        let filtered = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil },
            requiredArtifactNames: ["Supervisor Task"]
        )
        XCTAssertFalse(
            filtered.contains("Product Manager"),
            "In-progress non-dependency step must be omitted. Got: \(filtered)"
        )

        // Without filter (legacy / supervisor auto-answer path): PM still appears.
        let unfiltered = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil }
        )
        XCTAssertTrue(
            unfiltered.contains("Product Manager"),
            "No filter passed (nil) must preserve legacy behavior. Got: \(unfiltered)"
        )
    }

    // Done steps are always shown regardless of dependency — their artifacts
    // might be useful context even if not strictly required.
    func testBuildPipelineContext_filter_doneNonDependency_stillShown() {
        let pmStep = StepExecution(
            id: "pm_step",
            role: .productManager,
            title: "Product Requirements",
            status: .done,
            artifacts: [Artifact(name: "Product Requirements")]
        )
        let uxrStep = StepExecution(id: "uxr_step", role: .uxResearcher, title: "UXR Step")
        let run = Run(id: 0, steps: [pmStep, uxrStep])

        let result = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil },
            requiredArtifactNames: ["Supervisor Task"]
        )
        XCTAssertTrue(
            result.contains("Product Manager"),
            "Done steps must still be shown even if non-dependency. Got: \(result)"
        )
    }

    // The handoff path shown for a non-supervisor artifact MUST be one the file tools
    // accept — i.e. carry the .nanoteams/ prefix. The stored relativePath is prefix-less
    // (relative to .nanoteams/), so emitting it verbatim made read_file fail with
    // FILE_NOT_FOUND. Regression: the bare-path leak.
    func testBuildPipelineContext_nonSupervisorArtifact_pathCarriesNanoteamsPrefix() {
        let pmStep = StepExecution(
            id: "pm_step",
            role: .productManager,
            title: "Product Requirements",
            status: .done,
            artifacts: [Artifact(
                name: "Product Requirements",
                relativePath: "tasks/1/runs/0/roles/pm/artifact_product_requirements.md"
            )]
        )
        let uxrStep = StepExecution(id: "uxr_step", role: .uxResearcher, title: "UXR Step")
        let run = Run(id: 0, steps: [pmStep, uxrStep])

        let result = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil }
        )
        XCTAssertTrue(
            result.contains("(path: .nanoteams/tasks/1/runs/0/roles/pm/artifact_product_requirements.md)"),
            "Handoff artifact path must carry the .nanoteams/ prefix the file tools resolve against. Got: \(result)"
        )
        XCTAssertFalse(
            result.contains("(path: tasks/1/"),
            "The prefix-less path must NOT be emitted (read_file would FILE_NOT_FOUND). Got: \(result)"
        )
    }

    // An internal (.nanoteams/internal/…) artifact is sandbox-blocked, so the handoff
    // must NOT advertise a path the model can't read.
    func testBuildPipelineContext_internalArtifact_omitsPath() {
        let step = StepExecution(
            id: "swe_step",
            role: .softwareEngineer,
            title: "Engineering",
            status: .done,
            artifacts: [Artifact(
                name: "Build Diagnostics",
                relativePath: "internal/tasks/1/runs/0/roles/swe/build_diagnostics.json"
            )]
        )
        let next = StepExecution(id: "cr_step", role: .codeReviewer, title: "Review Step")
        let run = Run(id: 0, steps: [step, next])

        let result = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil }
        )
        XCTAssertTrue(result.contains("Build Diagnostics"), "Artifact is still listed by name. Got: \(result)")
        XCTAssertFalse(
            result.contains("(path:"),
            "Internal artifacts are sandbox-blocked — no (path: …) reference. Got: \(result)"
        )
    }

    // Supervisor is always shown: its Supervisor Task is the universal entry-point
    // context. Filtering would strip the task brief — do not regress.
    func testBuildPipelineContext_filter_supervisorAlwaysShown() {
        let supervisorStep = StepExecution(
            id: "supervisor_step",
            role: .supervisor,
            title: "Supervisor",
            status: .running,
            artifacts: [Artifact(name: "Supervisor Task")]
        )
        let uxrStep = StepExecution(id: "uxr_step", role: .uxResearcher, title: "UXR Step")
        let run = Run(id: 0, steps: [supervisorStep, uxrStep])

        let result = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in "task content" },
            requiredArtifactNames: []  // empty — nothing required, but supervisor stays
        )
        XCTAssertTrue(
            result.contains("Supervisor"),
            "Supervisor step must always appear. Got: \(result)"
        )
    }

    // Regression: failed / blocked upstream MUST always reach the downstream role,
    // even when not a strict dependency. Silently dropping a failed parallel step
    // would hide real run problems from later roles. Only `.pending` / `.running`
    // count as "in flight noise" — `.failed`, `.needsSupervisorInput`, `.paused`,
    // `.needsApproval` are blocked / terminal and remain visible.
    func testBuildPipelineContext_filter_failedNonDependency_stillShown() {
        let pmStep = StepExecution(
            id: "pm_step",
            role: .productManager,
            title: "Product Requirements",
            status: .failed,
            artifacts: []  // failed before producing the artifact
        )
        let uxrStep = StepExecution(id: "uxr_step", role: .uxResearcher, title: "UXR Step")
        let run = Run(id: 0, steps: [pmStep, uxrStep])

        let result = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil },
            requiredArtifactNames: ["Supervisor Task"]  // UXR doesn't depend on PR
        )
        XCTAssertTrue(
            result.contains("Product Manager"),
            "Failed steps must always be shown so downstream sees real upstream problems. Got: \(result)"
        )
        XCTAssertTrue(
            result.contains("failed"),
            "Status line must surface the failure. Got: \(result)"
        )
    }

    // Same invariant for blocked statuses that are neither in-flight nor done.
    func testBuildPipelineContext_filter_needsSupervisorInputNonDependency_stillShown() {
        let pmStep = StepExecution(
            id: "pm_step",
            role: .productManager,
            title: "Product Requirements",
            status: .needsSupervisorInput,
            artifacts: []
        )
        let uxrStep = StepExecution(id: "uxr_step", role: .uxResearcher, title: "UXR Step")
        let run = Run(id: 0, steps: [pmStep, uxrStep])

        let result = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil },
            requiredArtifactNames: ["Supervisor Task"]
        )
        XCTAssertTrue(
            result.contains("Product Manager"),
            "needsSupervisorInput steps must remain visible to downstream roles. Got: \(result)"
        )
    }

    // In-progress step is shown when it DOES produce a required artifact
    // (e.g. downstream role waiting on upstream in-progress work).
    func testBuildPipelineContext_filter_inProgressDependency_shown() {
        let pmStep = StepExecution(
            id: "pm_step",
            role: .productManager,
            title: "Product Requirements",
            status: .running,
            artifacts: [Artifact(name: "Product Requirements")]
        )
        let tlStep = StepExecution(id: "tl_step", role: .techLead, title: "TL Step")
        let run = Run(id: 0, steps: [pmStep, tlStep])

        let result = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil },
            requiredArtifactNames: ["Product Requirements"]  // TL requires PR
        )
        XCTAssertTrue(
            result.contains("Product Manager"),
            "In-progress dependency step must be shown. Got: \(result)"
        )
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
        XCTAssertTrue(supervisorTaskMessage?.content?.contains("## Clipped Text") == true)
        XCTAssertTrue(supervisorTaskMessage?.content?.contains("Selected API response") == true)
        XCTAssertTrue(supervisorTaskMessage?.content?.contains("## Attached Files") == true)
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
            settings: ProjectSettings(context: "Unique context string for placement check"),
            teams: []
        )
        let context = makeContext(workFolder: wf)

        let messages = PromptBuilder.buildChatMessages(context: context, tools: [])

        let systemMessage = messages.first { $0.role == .system }
        XCTAssertNotNil(systemMessage)
        XCTAssertTrue(systemMessage?.content?.contains("PlacementProbe") == true,
                       "Work folder name must appear in the system prompt")
        XCTAssertTrue(systemMessage?.content?.contains("Unique context string for placement check") == true,
                       "Work folder context must appear in the system prompt")

        let userMessagesWithWorkFolderHeader = messages.filter { msg in
            msg.role == .user && msg.content?.contains("## Work folder") == true
        }
        XCTAssertTrue(userMessagesWithWorkFolderHeader.isEmpty,
                      "Work folder context must not be re-broadcast as a user message")
    }

    // MARK: - buildConversationMechanicsGuidance branches
    //
    // After the 2026-05 chip-format contract change, this builder returns the
    // BARE BODY — the `## Conversation mechanics` header lives in the template,
    // not in the chip's resolved value.

    func testBuildConversationMechanicsGuidance_withFileReadTools_includesResourceTracking() {
        let guidance = PromptBuilder.buildConversationMechanicsGuidance(hasFileReadTools: true)

        XCTAssertFalse(guidance.hasPrefix("## "),
                       "guidance must be bare body — the `## Conversation mechanics` header is in the template")
        XCTAssertTrue(guidance.contains("<§R1§>"),
                      "file-read roles must get the tag legend")
        XCTAssertTrue(guidance.contains("instead of re-quoting"),
                      "the sentence must steer the model to reference a prior result via its tag instead of re-pasting its content (re-reading a changed resource stays allowed)")
        // The unchanged-read envelope is intentionally NOT pre-explained in the
        // prompt — its own `_hint` carries the dedup instruction at point of use,
        // so the sentence must not restate the `{"status":"unchanged"}` shape, and
        // must not name a "Memories" index (injection is gated off via
        // `LLMExecutionService.isMemoriesInjectionEnabled`).
        XCTAssertFalse(guidance.contains("\"status\":\"unchanged\""),
                       "the cached system prompt must not duplicate the unchanged envelope — the per-result _hint covers it")
        XCTAssertFalse(guidance.contains("Memories"),
                       "while Memories injection is disabled, the prompt must not point at an index that won't appear")
    }

    func testBuildConversationMechanicsGuidance_withoutFileReadTools_omitsResourceTracking() {
        let guidance = PromptBuilder.buildConversationMechanicsGuidance(hasFileReadTools: false)

        XCTAssertFalse(guidance.hasPrefix("## "),
                       "guidance must be bare body — the `## Conversation mechanics` header is in the template")
        XCTAssertFalse(guidance.contains("<§R1§>"),
                       "non-file-reading roles must not see the tag legend")
        XCTAssertFalse(guidance.contains("Memories"),
                       "non-file-reading roles must not be told about the Memories index — they never produce tags")
        XCTAssertFalse(guidance.isEmpty,
                       "the Supervisor-task-awareness sentence still runs for every role")
    }

    // MARK: - renderToolListPlaceholder (deprecated 2026-05; always empty)

    func testRenderToolListPlaceholder_deprecated_alwaysEmpty() {
        // After 2026-05 merge, `{toolList}` is deprecated — the no-tools notice
        // and the Harmony tool catalog live together in `{toolCalling}`. Legacy
        // stored templates with `## Tools\n{toolList}` get their orphan header
        // stripped by `TemplateResolver.stripOrphanHeaders`.
        XCTAssertEqual(PromptBuilder.renderToolListPlaceholder(toolNames: []), "")
        XCTAssertEqual(PromptBuilder.renderToolListPlaceholder(toolNames: ["read_file"]), "")
    }

    func testBuildChatMessages_emptyTools_systemPromptContainsNoToolsNotice() {
        // No-tools branch ships through the merged `{toolCalling}` chip: when
        // the role has no tools, the chip resolves to "None available — respond
        // directly..." (no `## Tools` header — that lives in the template's
        // `## Tool Calling\n{toolCalling}` block).
        let context = makeContext()
        let messages = PromptBuilder.buildChatMessages(context: context, tools: [])
        let system = messages.first { $0.role == .system }
        XCTAssertNotNil(system)
        XCTAssertTrue(system?.content?.contains("None available") == true,
                      "no-tools branch must say `None available` (via {toolCalling} chip resolution)")
        XCTAssertTrue(system?.content?.contains("## Tool Calling") == true,
                      "template's `## Tool Calling` header wraps the chip")
    }

    func testBuildChatMessages_withTools_emitsHarmonyBlockNotNoToolsNotice() {
        let tools = [ToolSchema(name: "read_file", description: "Read file", parameters: JSONSchema(type: "object"))]
        let context = makeContext()
        let messages = PromptBuilder.buildChatMessages(context: context, tools: tools)
        let system = messages.first { $0.role == .system }
        XCTAssertNotNil(system)
        XCTAssertFalse(system?.content?.contains("None available — respond directly") == true,
                       "roles with tools must not see the no-tools notice")
        XCTAssertTrue(system?.content?.contains("Call tools using this Harmony format") == true,
                      "roles with tools must see the Harmony format preamble")
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

    // MARK: - Global Context Injection

    func testAppendingSeparator_emptySuffix_returnsTextUnchanged() {
        let result = TemplateResolver.appendingSeparator("", to: "Base prompt.")
        XCTAssertEqual(result, "Base prompt.")
    }

    func testAppendingSeparator_whitespaceOnlySuffix_returnsTextUnchanged() {
        let result = TemplateResolver.appendingSeparator("   \n\t  ", to: "Base prompt.")
        XCTAssertEqual(result, "Base prompt.")
    }

    func testAppendingSeparator_nonEmptySuffix_appendsAsGlobalGuidanceSection() {
        let result = TemplateResolver.appendingSeparator("Rule X.", to: "Base prompt.")
        XCTAssertEqual(result, "Base prompt.\n\n## Global guidance\n\nRule X.")
    }

    func testAppendingSeparator_trimsSurroundingWhitespace() {
        let result = TemplateResolver.appendingSeparator("\n  Rule X.  \n", to: "Base prompt.")
        XCTAssertEqual(result, "Base prompt.\n\n## Global guidance\n\nRule X.")
    }

    func testBuildChatMessages_withNonEmptyGlobalContext_systemEndsWithSeparator() {
        let context = makeContext()
        let withGlobal = PromptBuilder.Context(
            task: context.task,
            step: context.step,
            stepIndex: context.stepIndex,
            run: context.run,
            workFolder: context.workFolder,
            artifactReader: context.artifactReader,
            activeTeam: context.activeTeam,
            roleDefinition: context.roleDefinition,
            globalContext: "RULE_X"
        )
        let messages = PromptBuilder.buildChatMessages(context: withGlobal, tools: [])
        guard let system = messages.first(where: { $0.role == .system })?.content else {
            XCTFail("expected a system message")
            return
        }
        // Built-in templates wrap globalContext as `## Global guidance\n{globalContext}`
        // — single `\n` between header and value (Swift multi-line literal indentation;
        // matches the template's own style for other sections like `## Role\n{roleName}`).
        // After 2026-05 contract: globalContext is one section among many — its
        // position varies per template but is always BEFORE `## Tool Calling`,
        // which is in turn before the literal-last `## Final reminder`. Assert
        // presence/value here; FR-is-last invariant is pinned in
        // `SystemTemplatesSectionPinTests.testEveryStepTemplate_finalReminderIsLastH2Section`.
        XCTAssertTrue(system.contains("## Global guidance\nRULE_X"),
                       "system prompt should include the `## Global guidance` section "
                       + "(template owns the header; chip resolves to the bare value)")
    }

    func testBuildChatMessages_withEmptyGlobalContext_systemHasNoSeparator() {
        let messages = PromptBuilder.buildChatMessages(context: makeContext(), tools: [])
        guard let system = messages.first(where: { $0.role == .system })?.content else {
            XCTFail("expected a system message")
            return
        }
        XCTAssertFalse(system.contains("## Global guidance"),
                       "empty global context must not emit a `## Global guidance` section")
    }

    // MARK: - buildTeamDescriptionLine

    /// 2026-05 chip-rendering refactor: the `Team purpose:` label moved out of
    /// the helper's return value and into the consuming template, so the
    /// preview can colour the value only (matching `Members: {teamRoles}.`).
    /// The helper now returns the trimmed description verbatim.
    func testBuildTeamDescriptionLine_nonEmpty_returnsDescriptionOnly() {
        var team = Team(name: "Test Team")
        team.description = "  Lean engineering pipeline.  "
        let result = PromptBuilder.buildTeamDescriptionLine(team: team)
        XCTAssertEqual(result, "Lean engineering pipeline.")
        XCTAssertFalse(result.contains("Team purpose:"),
                       "label must live in the consuming template, not the helper's value")
        XCTAssertFalse(result.hasPrefix("\n"),
                       "leading newline must not be baked into the value")
    }

    /// Empty / whitespace-only description returns `""` so the consuming
    /// template's `Team purpose: ` line becomes an orphan that
    /// `TemplateResolver.stripOrphanInlineLabels` collapses.
    func testBuildTeamDescriptionLine_empty_returnsEmpty() {
        let team = Team(name: "Test Team")  // description defaults to ""
        XCTAssertEqual(PromptBuilder.buildTeamDescriptionLine(team: team), "")
    }

    func testBuildTeamDescriptionLine_whitespaceOnly_returnsEmpty() {
        var team = Team(name: "Test Team")
        team.description = "   \n  \t  "
        XCTAssertEqual(PromptBuilder.buildTeamDescriptionLine(team: team), "")
    }

    func testBuildTeamDescriptionLine_nilTeam_returnsEmpty() {
        XCTAssertEqual(PromptBuilder.buildTeamDescriptionLine(team: nil), "")
    }
}
