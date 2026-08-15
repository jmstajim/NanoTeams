import XCTest

@testable import NanoTeams

/// What the planning phase OWES the implementation phase, and what it must not swallow.
///
/// The contract is semantic, not byte-level: the implementation wire must carry the original
/// task statement and the recorded scratchpad, and must not carry the exploration transcript. The
/// byte-exact head slice is one valid implementation of that contract — the cheapest one,
/// because it keeps segment 0 and the task turn cached — but the two phases' full composed
/// messages are allowed to differ, so the pins below assert the contract rather than the slice.
///
/// The other half is that closing the phase is TERMINAL. `.closeWithoutRebuild` retires the
/// brief's instruction while leaving the brief on the wire, which used to mean the branch was a
/// one-iteration reprieve: it re-appended its closing turn every iteration, and the moment a
/// plan appeared it fell through to `.crossBoundary`, whose slice dropped the very revision turn
/// the branch existed to protect.
@MainActor
final class PlanningPhaseBoundaryContractTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    private let systemPrompt = "You are Software Engineer."
    private let tools: [ToolSchema] = [
        ToolSchema(name: ToolNames.updateScratchpad, description: "S", parameters: .object(properties: [:])),
        ToolSchema(name: ToolNames.search, description: "S", parameters: .object(properties: [:])),
        ToolSchema(name: ToolNames.createArtifact, description: "A", parameters: .object(properties: [:])),
    ]

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "N", status: .running)
        stepID = step.id
        task = NTMSTask(id: 0, title: "T", supervisorTask: "goal", runs: [Run(id: 0, steps: [step])])
        delegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() async throws {
        service = nil; delegate = nil; task = nil; stepID = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func role() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "test_step", name: "Software Engineer", prompt: "", toolIDs: [],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: [], producesArtifacts: ["Engineering Notes"]))
    }

    private func freshStep() -> StepExecution {
        StepExecution(id: "test_step", role: .softwareEngineer, title: "N", status: .running)
    }

    private func stepWithPlan(_ plan: String = "read the parser, patch it") -> StepExecution {
        var step = freshStep()
        step.scratchpad = plan
        return step
    }

    private func stepInRevision() -> StepExecution {
        var step = freshStep()
        step.revisionComment = "the supervisor wants the parser handled first"
        return step
    }

    private func baseConversation() -> [ChatMessage] {
        [ChatMessage(role: .system, content: systemPrompt),
         ChatMessage(role: .user, content: "## Supervisor Task\n\nBuild the thing")]
    }

    @discardableResult
    private func apply(
        _ step: StepExecution, into conversation: inout [ChatMessage]
    ) async -> PlanningPhasePolicy.Authorization {
        await service.applyPlanningPhase(
            stepID: stepID, taskID: task.id, tools: tools, step: step, team: nil,
            conversationMessages: &conversation,
            roleDefinition: role())
    }

    private func contents(_ conversation: [ChatMessage]) -> String {
        conversation.compactMap(\.content).joined(separator: "\n")
    }

    // MARK: - The boundary's semantic contract

    func testImplementationWire_carriesTheOriginalTaskStatement() async {
        var wire = baseConversation()
        await apply(freshStep(), into: &wire)
        wire.append(ChatMessage(role: .assistant, content: "reading files"))
        await apply(stepWithPlan(), into: &wire)

        XCTAssertTrue(
            contents(wire).contains("## Supervisor Task"),
            "what needs to be done must survive the phase — it is half the phase's output")
    }

    func testImplementationWire_carriesTheRecordedScratchpad() async {
        var wire = baseConversation()
        await apply(freshStep(), into: &wire)
        await apply(stepWithPlan("read the parser, patch it"), into: &wire)

        let text = contents(wire)
        XCTAssertTrue(text.contains(PlanningPhasePolicy.seedMarker))
        XCTAssertTrue(
            text.contains("read the parser, patch it"),
            "the scratchpad is the other half of the phase's output")
    }

    func testImplementationWire_carriesNoPlanningTranscript() async {
        var wire = baseConversation()
        await apply(freshStep(), into: &wire)
        wire.append(ChatMessage(role: .assistant, content: "let me look around"))
        wire.append(ChatMessage(role: .tool, content: #"{"ok":true,"content":"secret"}"#))
        wire.append(ChatMessage(role: .user, content: "engine nudge"))
        await apply(stepWithPlan(), into: &wire)

        let text = contents(wire)
        XCTAssertFalse(text.contains(PlanningPhasePolicy.briefMarker), "the brief is retired")
        XCTAssertFalse(text.contains("let me look around"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("engine nudge"))
    }

    func testImplementationWire_leavesTheSystemPromptUntouched() async {
        var wire = baseConversation()
        await apply(freshStep(), into: &wire)
        await apply(stepWithPlan(), into: &wire)

        XCTAssertEqual(
            wire.first(where: { $0.role == .system })?.content, systemPrompt,
            "segment 0 carries the tool catalog; changing it is a total prefix loss")
    }

    /// The byte-exact head slice is an implementation choice, not the contract. If a future
    /// change composes a phase-specific opening turn, THIS pin should fail and the four above
    /// should not — that is the signal that the contract still holds.
    func testTheByteSliceIsOneValidImplementation_notTheContract() async {
        let head = baseConversation()
        var wire = head
        await apply(freshStep(), into: &wire)
        await apply(stepWithPlan(), into: &wire)

        XCTAssertEqual(
            Array(wire.dropLast()), head,
            "current implementation: the head is reused byte-for-byte, so the server keeps it")
    }

    // MARK: - Closing the phase is terminal

    func testCloseWithoutRebuild_appendsItsTurnExactlyOnce() async {
        var wire = baseConversation()
        await apply(freshStep(), into: &wire)

        for _ in 0..<3 { await apply(stepInRevision(), into: &wire) }

        let closings = wire.filter {
            $0.content?.contains(PlanningPhasePolicy.closedMarker) ?? false
        }
        XCTAssertEqual(
            closings.count, 1,
            "re-appending an identical turn every iteration is unbounded prompt growth")
    }

    /// The headline defect: after a close, a plan appearing later must NOT trigger a boundary,
    /// because the slice would drop the revision turn the close was protecting.
    func testAfterClose_theBoundaryIsUnreachable_soTheProtectedTurnSurvives() async {
        var wire = baseConversation()
        await apply(freshStep(), into: &wire)
        wire.append(ChatMessage(role: .user, content: "Supervisor: handle the parser first"))
        await apply(stepInRevision(), into: &wire)

        // The model later records a plan — before the close was terminal this reached
        // `.crossBoundary` and sliced at the brief.
        var revised = stepInRevision()
        revised.scratchpad = "a plan recorded after the close"
        await apply(revised, into: &wire)

        XCTAssertTrue(
            contents(wire).contains("Supervisor: handle the parser first"),
            "the turn `.closeWithoutRebuild` exists to protect must not be sliced away later")
        XCTAssertFalse(
            contents(wire).contains(PlanningPhasePolicy.seedMarker),
            "no boundary may fire after the phase has been closed")
    }

    func testIsMidPlanning_truthTable() {
        let brief = ChatMessage(
            role: .user,
            content: PlanningPhasePolicy.planningBrief(
                exploreToolNames: [ToolNames.search], expectedArtifacts: []))
        let closed = ChatMessage(role: .user, content: PlanningPhasePolicy.planningClosedTurn)
        let plain = ChatMessage(role: .user, content: "hello")

        XCTAssertTrue(PlanningPhasePolicy.isMidPlanning([brief]))
        XCTAssertFalse(PlanningPhasePolicy.isMidPlanning([brief, closed]))
        XCTAssertFalse(PlanningPhasePolicy.isMidPlanning([closed]))
        XCTAssertFalse(PlanningPhasePolicy.isMidPlanning([plain]))
        XCTAssertFalse(PlanningPhasePolicy.isMidPlanning([]))
    }

    // MARK: - The pre-rename headers are still recognised

    /// The phase was briefly called "research" (1.7.3–1.7.5), and phase state is DERIVED from
    /// the wire. A step suspended mid-phase under one of those builds replays a `wireTranscript`
    /// carrying the old header, so the matchers must still see it.
    ///
    /// Without this, `wireCarriesBrief` reads false on resume, `decide` returns `.enterPlanning`,
    /// and a SECOND brief is appended — after which the boundary slices at the new one and hands
    /// the implementation phase the entire exploration transcript it exists to keep out. Nothing
    /// goes red; the failure is silent and only at runtime. RED-verify by deleting
    /// `legacyBriefMarker` from `briefIndex`.
    func testLegacyResearchHeaders_areStillRecognisedOnTheWire() {
        let legacyBrief = ChatMessage(role: .user, content: "## Research phase\nexplore first")
        let legacyClosed = ChatMessage(
            role: .user, content: "## Research phase closed — your full toolset is available now.")
        let task = ChatMessage(role: .user, content: "## Supervisor Task\nship it")

        XCTAssertTrue(PlanningPhasePolicy.wireCarriesBrief([task, legacyBrief]),
                      "a pre-rename brief must still be found")
        XCTAssertEqual(PlanningPhasePolicy.briefIndex(in: [task, legacyBrief]), 1)
        XCTAssertTrue(PlanningPhasePolicy.isMidPlanning([task, legacyBrief]),
                      "so re-entry continues the phase instead of appending a second brief")

        XCTAssertTrue(PlanningPhasePolicy.wireCarriesClosedMarker([task, legacyBrief, legacyClosed]))
        XCTAssertFalse(PlanningPhasePolicy.isMidPlanning([task, legacyBrief, legacyClosed]),
                       "a pre-rename close is still terminal")

        // The boundary slices a legacy wire at the legacy brief, exactly as it would a current one.
        let wire = PlanningPhasePolicy.implementationWire(
            from: [task, legacyBrief], seedTurn: "seed")
        XCTAssertEqual(wire.count, 2)
        XCTAssertEqual(wire.first?.content, task.content)
        XCTAssertEqual(wire.last?.content, "seed")
    }

    func testDecide_closedMarkerDominatesEverythingBelowEligibility() {
        for hasBrief in [true, false] {
            for scratchpadIsNil in [true, false] {
                XCTAssertEqual(
                    PlanningPhasePolicy.decide(
                        isEligible: false, wireCarriesBrief: hasBrief,
                        scratchpadIsNil: scratchpadIsNil, wireCarriesClosedMarker: true),
                    .execution,
                    "closed is closed — brief \(hasBrief), scratchpadNil \(scratchpadIsNil)")
            }
        }
        // Eligibility still wins above it, though it is unreachable in practice: a step that has
        // been closed carries a revision or a supervisor answer, both of which fail `isEligible`.
        XCTAssertEqual(
            PlanningPhasePolicy.decide(
                isEligible: true, wireCarriesBrief: true, scratchpadIsNil: true,
                wireCarriesClosedMarker: true),
            .continuePlanning)
    }

    // MARK: - The Supervisor queue: delivered immediately, re-queued at the boundary

    private var supervisorTurn: ChatMessage {
        ChatMessage(
            role: .user,
            content: MessageSourceContext.supervisorMessagePrefix + "look at the parser")
    }

    /// Steering the exploration is what the queue is FOR, so a message arriving mid-planning
    /// reaches the model on the very next turn rather than being held until the phase ends.
    func testASupervisorTurnDeliveredMidPlanning_reachesTheModelImmediately() async {
        var wire = baseConversation()
        await apply(freshStep(), into: &wire)
        XCTAssertTrue(PlanningPhasePolicy.isMidPlanning(wire))

        wire.append(supervisorTurn)
        XCTAssertTrue(
            contents(wire).contains("look at the parser"),
            "the model must see it during the exploration it is meant to redirect")
    }

    /// …and because the boundary then discards it, it is handed back to the queue. Without that
    /// the message is gone for good: `consumeQueuedSupervisorMessage` already popped it.
    func testASupervisorTurnDiscardedByTheBoundary_isRequeuedAtTheHead() async {
        var wire = baseConversation()
        await apply(freshStep(), into: &wire)
        wire.append(supervisorTurn)
        wire.append(ChatMessage(role: .assistant, content: "looking"))

        await apply(stepWithPlan(), into: &wire)

        XCTAssertFalse(
            contents(wire).contains("look at the parser"),
            "the slice keeps only the task statement and the scratchpad")
        XCTAssertEqual(
            delegate.requeuedSupervisorMessages.map(\.text), ["look at the parser"],
            "…so the message comes back to the queue, without its attribution prefix")
        XCTAssertEqual(delegate.requeuedSupervisorMessages.first?.roleID, stepID)
        XCTAssertEqual(delegate.requeuedSupervisorMessages.first?.taskID, task.id)
    }

    func testEngineTurnsDiscardedByTheBoundary_areNotRequeued() async {
        var wire = baseConversation()
        await apply(freshStep(), into: &wire)
        wire.append(ChatMessage(role: .user, content: "engine nudge"))
        wire.append(ChatMessage(role: .tool, content: "{}"))
        wire.append(ChatMessage(role: .assistant, content: "reading"))

        await apply(stepWithPlan(), into: &wire)

        XCTAssertTrue(
            delegate.requeuedSupervisorMessages.isEmpty,
            "only human-originated turns come back — engine scaffolding is meant to die")
    }

    func testTwoSupervisorTurns_bothComeBackInOrder() async {
        var wire = baseConversation()
        await apply(freshStep(), into: &wire)
        wire.append(supervisorTurn)
        wire.append(ChatMessage(
            role: .user,
            content: MessageSourceContext.supervisorMessagePrefix + "and the lexer"))

        await apply(stepWithPlan(), into: &wire)

        XCTAssertEqual(
            delegate.requeuedSupervisorMessages.map(\.text),
            ["look at the parser", "and the lexer"])
    }

    /// `.closeWithoutRebuild` does not slice, so nothing is discarded and nothing is re-queued —
    /// keeping that turn on the wire is the whole reason the branch exists.
    func testCloseWithoutRebuild_requeuesNothingBecauseItDiscardsNothing() async {
        var wire = baseConversation()
        await apply(freshStep(), into: &wire)
        wire.append(supervisorTurn)

        await apply(stepInRevision(), into: &wire)

        XCTAssertTrue(delegate.requeuedSupervisorMessages.isEmpty)
        XCTAssertTrue(contents(wire).contains("look at the parser"))
    }

    func testDiscardedSupervisorMessages_ignoresTurnsBeforeTheBrief() {
        let wire = [
            ChatMessage(role: .system, content: "s"),
            ChatMessage(
                role: .user,
                content: MessageSourceContext.supervisorMessagePrefix + "before the phase"),
            ChatMessage(
                role: .user,
                content: PlanningPhasePolicy.planningBrief(
                    exploreToolNames: [ToolNames.search], expectedArtifacts: [])),
            ChatMessage(
                role: .user,
                content: MessageSourceContext.supervisorMessagePrefix + "during the phase"),
        ]
        XCTAssertEqual(
            PlanningPhasePolicy.discardedSupervisorMessages(in: wire), ["during the phase"],
            "a turn the slice KEEPS must not be re-queued — that would duplicate it")
    }

    func testDiscardedSupervisorMessages_withNoBrief_isEmpty() {
        XCTAssertTrue(
            PlanningPhasePolicy.discardedSupervisorMessages(in: [supervisorTurn]).isEmpty,
            "no brief means no boundary, so nothing is being discarded")
        XCTAssertTrue(PlanningPhasePolicy.discardedSupervisorMessages(in: []).isEmpty)
    }
}
