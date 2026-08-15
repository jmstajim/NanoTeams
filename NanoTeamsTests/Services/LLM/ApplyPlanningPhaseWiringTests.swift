import XCTest

@testable import NanoTeams

/// Integration wiring for `PlanningPhasePolicy` inside
/// `LLMExecutionService.applyPlanningPhase`. `PlanningPhasePolicyTests` pins the
/// pure decisions in isolation; this proves they are wired into the @MainActor
/// orchestration — entry, the no-enter gates, and the boundary.
///
/// The headline assertion is INVERTED from the suite this replaces: the old
/// planning phase asserted the system message had been swapped for a PLANNING
/// PHASE prompt, and the whole point of the rewrite is that it must now be
/// byte-identical across both phases. That is what keeps the provider's
/// prompt-prefix cache alive, since the tool catalog is rendered INTO the system
/// prompt.
@MainActor
final class ApplyPlanningPhaseWiringTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    private let fullTools: [ToolSchema] = [
        ToolSchema(name: ToolNames.updateScratchpad, description: "Scratchpad", parameters: .object(properties: [:])),
        ToolSchema(name: ToolNames.search, description: "Search", parameters: .object(properties: [:])),
        ToolSchema(name: ToolNames.runXcodebuild, description: "Build", parameters: .object(properties: [:])),
        ToolSchema(name: ToolNames.writeFile, description: "Write", parameters: .object(properties: [:])),
        ToolSchema(name: ToolNames.createArtifact, description: "Artifact", parameters: .object(properties: [:])),
    ]
    private let systemPrompt = "You are Software Engineer."

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Notes", status: .running)
        stepID = step.id
        task = NTMSTask(id: 0, title: "Test", supervisorTask: "goal", runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() async throws {
        mockDelegate = nil; service = nil; task = nil; stepID = nil
        try await super.tearDown()
    }

    private func role(usePlanning: Bool) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "test_step", name: "Software Engineer", prompt: "", toolIDs: [],
            usePlanningPhase: usePlanning,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Engineering Notes"]))
    }

    /// scratchpad nil + revisionComment nil + empty llmConversation ⇒ fresh step.
    private func freshStep() -> StepExecution {
        StepExecution(id: "test_step", role: .softwareEngineer, title: "Notes", status: .running)
    }

    private func baseConversation() -> [ChatMessage] {
        [ChatMessage(role: .system, content: systemPrompt),
         ChatMessage(role: .user, content: "Build the thing")]
    }

    private func systemContent(_ conversation: [ChatMessage]) -> String {
        conversation.first(where: { $0.role == .system })?.content ?? ""
    }

    private func apply(
        step: StepExecution, role roleDef: TeamRoleDefinition?, team: Team? = nil,
        into conversation: inout [ChatMessage], tools: [ToolSchema]? = nil
    ) async -> PlanningPhasePolicy.Authorization {
        await service.applyPlanningPhase(
            stepID: stepID, taskID: task.id, tools: tools ?? fullTools, step: step,
            team: team,
            conversationMessages: &conversation, roleDefinition: roleDef)
    }

    // MARK: - Entry

    func testEntry_appendsBrief_narrowsAuthorization_leavesSystemPromptAlone() async {
        var conversation = baseConversation()
        let auth = await apply(step: freshStep(), role: role(usePlanning: true), into: &conversation)

        XCTAssertEqual(systemContent(conversation), systemPrompt,
                       "The system message must be byte-identical — it carries the tool catalog, "
                           + "and changing it is what broke the prefix cache")
        XCTAssertTrue(conversation.last?.content?.contains(PlanningPhasePolicy.briefMarker) ?? false,
                      "The brief rides as a trailing user turn on the wire")
        XCTAssertEqual(auth.allowed,
                       [ToolNames.updateScratchpad, ToolNames.search, ToolNames.runXcodebuild],
                       "everything that can neither suspend the step nor mutate source, "
                           + "plus the exit channel")
        XCTAssertEqual(auth.withheldByPhase, [ToolNames.writeFile, ToolNames.createArtifact])
    }

    // MARK: - Bash admission

    /// A separate array on purpose: `fullTools` has no `bash`, and adding one there would make
    /// every other assertion in this suite depend on the bash policy.
    private var toolsWithBash: [ToolSchema] {
        fullTools + [ToolSchema(name: ToolNames.bash, description: "Shell",
                                parameters: .object(properties: [:]))]
    }

    /// The admission table, end to end through the @MainActor half. Both terms are read from
    /// the LIVE policy each iteration, so this is also what pins that a user who turns either
    /// one off mid-phase gets `bash` withheld on the very next iteration.
    ///
    /// RED: hardcode `bashAdmitted: true` → the four withheld rows fire.
    /// RED: drop the `allowsUnattendedCommands` term → the `.manual` and `.off` rows fire.
    /// RED: drop the `sandboxEnabled` term → the sandbox-off row fires.
    func testBashAdmission_requiresBothTheSandboxAndAnUnattendedMode() async {
        let table: [(mode: BashExecutionMode, sandbox: Bool, admitted: Bool)] = [
            (.auto, true, true),
            (.semiAutomatic, true, true),
            (.manual, true, false),
            (.off, true, false),
            (.auto, false, false),
            (.semiAutomatic, false, false),
        ]
        for row in table {
            mockDelegate.bashPolicy = BashPolicy(mode: row.mode, sandboxEnabled: row.sandbox)
            var conversation = baseConversation()
            let auth = await apply(step: freshStep(), role: role(usePlanning: true),
                                   into: &conversation, tools: toolsWithBash)
            let ctx = "mode=\(row.mode) sandbox=\(row.sandbox)"

            XCTAssertEqual(auth.allowed.contains(ToolNames.bash), row.admitted, ctx)
            // Never merely absent: a withheld tool must be ATTRIBUTED to the phase, which is
            // what turns the rejection into `plan_required` instead of "not in your role".
            XCTAssertEqual(auth.withheldByPhase.contains(ToolNames.bash), !row.admitted, ctx)
            // And the brief must agree with the authorization — advertising a tool the same
            // iteration refuses is the failure mode this whole seam exists to avoid.
            let brief = conversation.last?.content ?? ""
            XCTAssertEqual(brief.contains(ToolNames.bash), row.admitted, ctx)
        }
    }

    /// No delegate ⇒ no policy ⇒ no enforcement ⇒ do not advertise.
    ///
    /// RED: change the `?? false` coalescing at the call site to `?? true` → `bash` lands in
    /// `allowed` and both assertions fail.
    func testBashAdmission_withNoDelegate_isWithheld() async {
        service.delegate = nil
        var conversation = baseConversation()
        let auth = await apply(step: freshStep(), role: role(usePlanning: true),
                               into: &conversation, tools: toolsWithBash)

        XCTAssertFalse(auth.allowed.contains(ToolNames.bash))
        XCTAssertTrue(auth.withheldByPhase.contains(ToolNames.bash))
    }

    /// `isPlanningPhase` must reach the authorization the tool layer reads — it is what makes
    /// `BashTool` narrow its sandbox and what tells the gate which confinement to describe.
    func testAuthorization_carriesThePhaseFlagAcrossTheBoundary() async {
        mockDelegate.bashPolicy = BashPolicy(mode: .auto, sandboxEnabled: true)
        var conversation = baseConversation()
        let entering = await apply(step: freshStep(), role: role(usePlanning: true),
                                   into: &conversation, tools: toolsWithBash)
        XCTAssertTrue(entering.isPlanningPhase)

        var planned = freshStep()
        planned.scratchpad = "1. do the thing"
        let crossing = await apply(step: planned, role: role(usePlanning: true),
                                   into: &conversation, tools: toolsWithBash)
        XCTAssertFalse(crossing.isPlanningPhase,
                       "the boundary hands back the full toolset — and an unnarrowed sandbox")
    }

    /// The brief must name what actually runs. With the system prompt untouched
    /// it still advertises the FULL catalog, so without this the model would burn
    /// turns getting denied.
    func testEntry_briefNamesTheToolsThatActuallyRun() async {
        var conversation = baseConversation()
        _ = await apply(step: freshStep(), role: role(usePlanning: true), into: &conversation)
        let brief = conversation.last?.content ?? ""

        XCTAssertTrue(brief.contains(ToolNames.search))
        XCTAssertTrue(brief.contains(ToolNames.runXcodebuild),
                      "the brief is derived from `authorization.allowed`, so a tool admitted to "
                          + "the phase is advertised by construction — never a second literal")
        XCTAssertTrue(brief.contains(ToolNames.updateScratchpad),
                      "the exit channel must be named — it is what the code detects")
        XCTAssertFalse(brief.contains(ToolNames.writeFile))
    }

    /// The brief is wire-only: `ActivityFeedBuilder` renders every `.user`
    /// message as a bubble, so persisting it would put engine scaffolding in the
    /// user's activity feed.
    func testEntry_briefNeverEntersTheDisplayRecord() async {
        var conversation = baseConversation()
        _ = await apply(step: freshStep(), role: role(usePlanning: true), into: &conversation)

        let persisted = mockDelegate.taskToMutate!.runs[0].steps[0].llmConversation
        XCTAssertFalse(persisted.contains { $0.content.contains(PlanningPhasePolicy.briefMarker) },
                       "the brief is machinery, not conversation")
        XCTAssertFalse(persisted.isEmpty, "…but the base conversation IS seeded")
    }

    // MARK: - No entry

    func testNoEntry_whenRoleOptedOut() async {
        var conversation = baseConversation()
        let auth = await apply(step: freshStep(), role: role(usePlanning: false), into: &conversation)

        XCTAssertEqual(auth.allowed.count, fullTools.count,
                       "unrestricted means everything PASSED IN — derived, so growing the "
                           + "fixture can never silently weaken this")
        XCTAssertTrue(auth.withheldByPhase.isEmpty)
        XCTAssertFalse(PlanningPhasePolicy.wireCarriesBrief(conversation))
    }

    func testNoEntry_whenScratchpadToolAbsent() async {
        var conversation = baseConversation()
        let toolsWithoutScratchpad = fullTools.filter { $0.name != ToolNames.updateScratchpad }
        let auth = await apply(step: freshStep(), role: role(usePlanning: true),
                               into: &conversation, tools: toolsWithoutScratchpad)

        XCTAssertEqual(auth.allowed.count, toolsWithoutScratchpad.count, "no exit channel ⇒ no phase")
        XCTAssertFalse(PlanningPhasePolicy.wireCarriesBrief(conversation))
    }

    func testNoEntry_underRevision() async {
        var step = freshStep()
        step.revisionComment = "Fix the naming"
        var conversation = baseConversation()
        let auth = await apply(step: step, role: role(usePlanning: true), into: &conversation)

        XCTAssertTrue(auth.withheldByPhase.isEmpty)
        XCTAssertFalse(PlanningPhasePolicy.wireCarriesBrief(conversation))
    }

    /// The manager has no file-read tools, its `update_scratchpad` is MEMORY
    /// rather than a plan, and `wait_for_events` — its only way to end a pass —
    /// would be withheld. The gate is structural, not a matter of its flag.
    func testNoEntry_forTheAutovisorEvenWithTheFlagOn() async {
        var manager = Team(
            id: "autovisor", name: "Autovisor", roles: [], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout())
        manager.templateID = AutovisorConstants.teamTemplateID
        var conversation = baseConversation()
        let auth = await apply(step: freshStep(), role: role(usePlanning: true),
                               team: manager, into: &conversation)

        XCTAssertTrue(auth.withheldByPhase.isEmpty)
        XCTAssertFalse(PlanningPhasePolicy.wireCarriesBrief(conversation))
    }

    // MARK: - Boundary

    func testBoundary_slicesTheBrief_seedsThePlan_authorizesEverything() async {
        var conversation = baseConversation()
        _ = await apply(step: freshStep(), role: role(usePlanning: true), into: &conversation)
        conversation.append(ChatMessage(role: .assistant, content: "read some files"))

        var planned = freshStep()
        planned.scratchpad = "Findings: Foo.swift\nPlan:\n1. Edit Foo"
        let auth = await apply(step: planned, role: role(usePlanning: true), into: &conversation)

        XCTAssertTrue(auth.withheldByPhase.isEmpty)
        XCTAssertEqual(systemContent(conversation), systemPrompt,
                       "still byte-identical across the boundary")
        XCTAssertEqual(conversation.count, 3, "base 2 turns + the seed")
        XCTAssertTrue(conversation.last?.content?.contains("Findings: Foo.swift") ?? false,
                      "the notes are the ONLY thing that survives — nothing else injects them")
        XCTAssertFalse(PlanningPhasePolicy.wireCarriesBrief(conversation))
    }

    /// The boundary is self-clearing: it requires the brief and removes it. A
    /// second apply on the rebuilt wire must be inert, or a pause/resume would
    /// re-slice an already-sliced conversation.
    func testBoundary_isIdempotent() async {
        var conversation = baseConversation()
        _ = await apply(step: freshStep(), role: role(usePlanning: true), into: &conversation)

        var planned = freshStep()
        planned.scratchpad = "Plan:\n1. Edit Foo"
        _ = await apply(step: planned, role: role(usePlanning: true), into: &conversation)
        let afterFirst = conversation

        _ = await apply(step: planned, role: role(usePlanning: true), into: &conversation)
        XCTAssertEqual(conversation, afterFirst, "the second pass must change nothing")
    }

    /// Re-entry mid-planning replays a `wireTranscript` that already carries the
    /// brief, against a FRESH in-memory `StepExecutionState`. Deriving the phase
    /// from the wire is what makes that idempotent — a stored flag would have
    /// appended a second brief.
    func testReEntryMidPlanning_appendsNoSecondBrief() async {
        var conversation = baseConversation()
        _ = await apply(step: freshStep(), role: role(usePlanning: true), into: &conversation)
        let replayed = conversation

        var resumed = conversation
        let auth = await apply(step: freshStep(), role: role(usePlanning: true), into: &resumed)

        XCTAssertEqual(resumed, replayed, "resuming mid-planning must not touch the wire")
        XCTAssertEqual(
            resumed.filter { $0.content?.contains(PlanningPhasePolicy.briefMarker) ?? false }.count,
            1)
        XCTAssertEqual(auth.allowed,
                       [ToolNames.updateScratchpad, ToolNames.search, ToolNames.runXcodebuild],
                       "…and it is still the planning phase")
    }
}
