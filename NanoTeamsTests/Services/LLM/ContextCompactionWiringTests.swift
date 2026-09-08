import XCTest

@testable import NanoTeams

/// The in-loop compaction epoch, end to end at the service seam: what is sent, what the wire
/// becomes, what the user sees, and what happens when the epoch is interrupted.
///
/// The interruption cases carry most of the weight. An epoch discards a conversation, so a
/// path that writes on cancellation destroys work the user asked to keep — and the failure is
/// silent, because the compacted wire is a perfectly valid conversation that simply no longer
/// contains what the model did.
@MainActor
final class ContextCompactionWiringTests: XCTestCase {

    var sut: LLMExecutionService!
    var delegate: MockLLMExecutionDelegate!

    private let stepID = "engineer"
    private let taskID = 3
    private let config = LLMConfig(baseURLString: "http://127.0.0.1:1234", modelName: "m")

    override func setUp() async throws {
        try await super.setUp()
        sut = LLMExecutionService(repository: NTMSRepository(), prefixLedger: PromptPrefixLedger())
        delegate = MockLLMExecutionDelegate()
        delegate.taskToMutate = makeTask()
        sut.attach(delegate: delegate)
        sut._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    override func tearDown() async throws {
        sut = nil
        delegate = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeTask() -> NTMSTask {
        var task = NTMSTask(id: taskID, title: "T", supervisorTask: "brief")
        var run = Run(id: 0, teamID: NTMSID.from(name: "Team"))
        run.steps = [StepExecution(id: stepID, role: .softwareEngineer, title: "work")]
        task.runs = [run]
        return task
    }

    private func wire() -> [ChatMessage] {
        [
            ChatMessage(role: .system, content: "You are an engineer."),
            ChatMessage(role: .user, content: "## Supervisor Task\nBuild it."),
            ChatMessage(role: .assistant, content: "Reading."),
            ChatMessage(role: .tool, content: #"{"ok":true}"#),
            ChatMessage(role: .user, content: MessageSourceContext.supervisorMessagePrefix
                + "Never touch Storage/."),
            ChatMessage(role: .assistant, content: "Understood."),
        ]
    }

    /// The same task, plus a team whose role for this step has the planning phase ON. Eligibility
    /// is read from the TEAM (`resolveTeam` → `findRole(byIdentifier:)`), not from the step, so
    /// without this the wire's brief decides `.closeWithoutRebuild` and the gate under test is
    /// never armed. Shape borrowed from `ToolLoopIterationScanWorkTests.seedTask`.
    private func planningTask() -> NTMSTask {
        var task = makeTask()
        let engineer = TeamRoleDefinition(
            id: stepID, name: "Software Engineer", prompt: "",
            toolIDs: [ToolNames.updateScratchpad], usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: [], producesArtifacts: ["Engineering Notes"]),
            systemRoleID: "softwareEngineer")
        task.adoptGeneratedTeam(Team(
            id: "compaction-planning-team", name: "Planning", roles: [engineer], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()))
        return task
    }

    private func step(scratchpad: String? = nil) -> StepExecution {
        StepExecution(id: stepID, role: .softwareEngineer, title: "work", scratchpad: scratchpad)
    }

    // MARK: - Happy path

    func testEpoch_replacesTheWireWithHeadPlusSeed() async {
        let client = ScriptedSummaryClient(summary: "Read three files; nothing written yet.")
        var conversation = wire()
        let did = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .budgetExceeded, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        XCTAssertTrue(did)
        XCTAssertEqual(conversation.count, 3)
        XCTAssertEqual(Array(conversation[..<2]), Array(wire()[..<2]),
                       "the pinned head must be byte-identical")
        XCTAssertEqual(conversation.last?.role, .user)
        XCTAssertTrue(conversation.last?.content?.contains(
            "Read three files; nothing written yet.") == true)
    }

    /// R3.9.5: the Supervisor's own words cross the epoch verbatim, not as the model's
    /// paraphrase of them.
    func testEpoch_carriesTheSupervisorRecordIntoTheSeed() async {
        let client = ScriptedSummaryClient(summary: "Work so far.")
        var conversation = wire()
        _ = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .manual, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)
        let seed = conversation.last?.content ?? ""
        XCTAssertEqual(
            CompactionPolicy.recordedSupervisorMessages(in: seed), ["Never touch Storage/."])
    }

    /// The request is the wire plus the rubric, with NO tools: a summary reply that resolved a
    /// tool call would be dispatched by nobody, and advertising the catalog is what makes a
    /// model reach for it.
    func testEpoch_sendsTheWirePlusTheRubric_withNoTools() async {
        let client = ScriptedSummaryClient(summary: "Summary.")
        var conversation = wire()
        _ = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .manual, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        XCTAssertEqual(client.sentToolCounts, [0])
        XCTAssertEqual(client.sentMessages.first?.count, wire().count + 1)
        XCTAssertEqual(
            client.sentMessages.first?.last?.content, CompactionPolicy.summaryRequestTurn())
        XCTAssertEqual(Array(client.sentMessages.first?.dropLast() ?? []), wire(),
                       "the wire is sent unchanged — the rubric never joins it")
    }

    /// The checklist the planning boundary runs, for the same reasons: every latch and
    /// baseline described the array that no longer exists, and the ring must be re-derived
    /// from the one that does.
    func testEpoch_resetsConversationScopedStateAndArmsThePrefixExemption() async {
        sut._testSetPrefixCacheState(
            stepID: stepID, taskID: taskID, didWarnContextOverflow: true)
        sut._testSetCompactionState(
            stepID: stepID, taskID: taskID, lastServerPromptTokens: 9000)
        let client = ScriptedSummaryClient(summary: "Summary.")
        var conversation = wire()
        _ = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .budgetExceeded, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        XCTAssertEqual(sut._testDidWarnContextOverflow(stepID: stepID, taskID: taskID), false)
        XCTAssertEqual(sut._testExpectedPrefixResetPending(stepID: stepID, taskID: taskID), true)
        XCTAssertEqual(sut._testCompactionsThisEntry(stepID: stepID, taskID: taskID), 1)
        XCTAssertEqual(
            sut._testMessageLoopRing(stepID: stepID, taskID: taskID),
            ConversationRepairService.recentNoToolAssistantContents(in: conversation),
            "the ring must describe the array that now exists")
    }

    /// The flag is one-shot: leaving it set would compact again on the very next iteration,
    /// against a conversation that is now three messages long.
    func testEpoch_consumesTheRequestFlag() async {
        sut._testSetCompactionState(stepID: stepID, taskID: taskID, compactRequested: .manual)
        let client = ScriptedSummaryClient(summary: "Summary.")
        var conversation = wire()
        _ = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .manual, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)
        XCTAssertNil(sut._testCompactRequested(stepID: stepID, taskID: taskID))
    }

    func testEpoch_writesACollapsedFeedNotice() async {
        let client = ScriptedSummaryClient(summary: "Summary body.")
        var conversation = wire()
        _ = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .budgetExceeded, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        let notices = delegate.taskToMutate?.runs[0].steps[0].llmConversation
            .filter { $0.sourceContext == .compaction } ?? []
        XCTAssertEqual(notices.count, 1)
        XCTAssertNotNil(
            SystemNoticePresentation.resolve(context: .compaction, content: notices[0].content),
            "the row must collapse — a full-width summary bubble is what the wire is for")
        XCTAssertTrue(notices[0].content.contains("budget exceeded"))
    }

    // MARK: - The live bubble

    /// The delegate trace, in order. The bubble exists so the user can watch the summary being
    /// written; it is DISCARDED rather than committed, because the model never took this turn
    /// and a committed copy would be a message nobody sent.
    func testEpoch_drivesALiveBubble_andAlwaysDiscardsIt() async {
        let client = ScriptedSummaryClient(
            summary: "Summary.", thinking: "Let me re-read what I did.")
        var conversation = wire()
        _ = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .manual, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        XCTAssertEqual(delegate.beginStreamingCalls.count, 1)
        XCTAssertEqual(delegate.beginStreamingCalls.first?.isCompacting, true,
                       "the mark is a birth property of the stream — raised afterwards it "
                           + "leaves a tick in which the epoch's only row reads \"Waiting…\"")
        XCTAssertEqual(delegate.compactionMarks.map(\.1), [false],
                       "and lowered exactly once, at the end")
        XCTAssertFalse(delegate.appendStreamingThinkingCalls.isEmpty,
                       "reasoning belongs under the same expander as any other turn's")
        XCTAssertTrue(delegate.appendStreamingPreviewCalls.isEmpty,
                      "the summary is never printed as prose — the bubble's content stays "
                          + "empty for the epoch's whole life")
        XCTAssertEqual(delegate.discardStreamingCalls.count, 1)
        XCTAssertTrue(delegate.commitStreamingCalls.isEmpty,
                      "committing would put a turn in the conversation the model never sent")
        XCTAssertEqual(delegate.beginStreamingCalls.first?.messageID,
                       delegate.discardStreamingCalls.first?.messageID,
                       "the discarded placeholder must be the one that was created")
    }

    /// The composer's indicator is a separate surface from the feed's bubble: a PARKED step
    /// has no bubble on screen, and the indicator is the only thing that can say the epoch is
    /// running. Both are raised and lowered.
    func testEpoch_marksTheComposerIndicatorForItsDuration() async {
        let client = ScriptedSummaryClient(summary: "Summary.")
        var conversation = wire()
        _ = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .manual, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)
        XCTAssertEqual(delegate.contextCompactingMarks.map(\.isCompacting), [true, false])
    }

    /// The epoch's ONLY visible output is the disclosure — the buffer the collapsed
    /// "Compacting…" row opens. Prose in the bubble would be a turn the model never took,
    /// standing in the feed beside the turns it did.
    func testEpoch_writesTheDisclosureInArrivalOrder_andNeverThePose() async {
        let client = ScriptedSummaryClient(summary: "S.", thinking: "R.")
        var conversation = wire()
        _ = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .manual, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        XCTAssertTrue(delegate.appendStreamingPreviewCalls.isEmpty)
        XCTAssertTrue(delegate.replaceStreamingPreviewCalls.isEmpty)
        XCTAssertEqual(delegate.appendStreamingThinkingCalls.map(\.1).joined(), "R.\n\nS.",
                       "reasoning, one blank line at the channel flip, then the summary")
    }

    /// A model that writes the summary on the content channel only: no leading blank line —
    /// the separator marks a FLIP, and nothing flipped.
    func testEpoch_contentOnly_hasNoLeadingSeparator() async {
        let client = ScriptedSummaryClient(summary: "S.", thinking: "")
        var conversation = wire()
        _ = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .manual, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        XCTAssertEqual(delegate.appendStreamingThinkingCalls.map(\.1).joined(), "S.")
        XCTAssertTrue(delegate.appendStreamingPreviewCalls.isEmpty)
    }

    /// A reasoning model that leaves `content` empty. The step's notes carry the fold, so this
    /// exercises the disclosure rather than `hasSeedMaterial`.
    func testEpoch_reasoningOnly_reachesTheDisclosure() async {
        let client = ScriptedSummaryClient(summary: "", thinking: "R.")
        var conversation = wire()
        _ = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .manual,
            step: step(scratchpad: "Read three files."),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        XCTAssertEqual(delegate.appendStreamingThinkingCalls.map(\.1).joined(), "R.")
        XCTAssertTrue(delegate.appendStreamingPreviewCalls.isEmpty)
    }

    /// A silent stream still opens and closes the bubble cleanly. This is the state in which
    /// the status row carries "Compacting…" for the whole epoch, so the placeholder has to
    /// exist for its whole duration and be gone afterwards.
    func testEpoch_silentStream_stillOpensAndDiscardsTheBubble() async {
        let client = ScriptedSummaryClient(summary: "", thinking: "")
        var conversation = wire()
        _ = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .manual, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        XCTAssertTrue(delegate.appendStreamingThinkingCalls.isEmpty)
        XCTAssertTrue(delegate.appendStreamingPreviewCalls.isEmpty)
        XCTAssertEqual(delegate.beginStreamingCalls.count, 1)
        XCTAssertEqual(delegate.discardStreamingCalls.count, 1)
        XCTAssertTrue(delegate.commitStreamingCalls.isEmpty)
    }

    /// The epoch token is now the ONLY thing between a superseded epoch and the live
    /// disclosure — the content path it used to guard as well is gone.
    func testSupersededEpoch_stopsFeedingTheDisclosure() async {
        let client = SupersedingSummaryClient(
            first: "first.",
            second: "second.",
            consumed: { [weak self] in
                (self?.delegate.appendStreamingThinkingCalls.isEmpty == false)
            },
            supersede: { [weak self] in
                guard let self else { return }
                self.sut._testSetCompactionEpochToken(stepID: self.stepID, taskID: self.taskID)
            })
        var conversation = wire()
        _ = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .manual, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        let fed = delegate.appendStreamingThinkingCalls.map(\.1).joined()
        XCTAssertTrue(fed.contains("first."))
        XCTAssertFalse(fed.contains("second."),
                       "a superseded epoch must not keep writing into a bubble it no longer owns")
    }

    /// The disclosure is keyed by `(taskID, stepID)`, and it is now the epoch's only visible
    /// output — a mis-key would be silent rather than obvious.
    func testEpoch_feedsOnlyItsOwnTask() async {
        let client = ScriptedSummaryClient(summary: "S.", thinking: "R.")
        var conversation = wire()
        _ = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .manual, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        let thinkingHops = delegate.streamingTaskIDTrace
            .filter { $0.0 == "appendStreamingThinking" }
        XCTAssertFalse(thinkingHops.isEmpty)
        XCTAssertTrue(thinkingHops.allSatisfy { $0.1 == stepID && $0.2 == taskID })
    }

    /// What a verdict costs if it reaches a wire that has already shrunk: the head IS the
    /// conversation, so there is nothing to fold, and the step latches OFF for good. Correct
    /// in itself — no further epoch could help — which is exactly why the planning boundary
    /// must not hand this function a verdict earned against the wire it just replaced
    /// (`PlanningBoundaryStateResetCoverageTests.testTheResetClearsAPendingCompactionVerdict`).
    func testAHeadOnlyWireLatchesTheStepOff() async {
        let client = ScriptedSummaryClient(summary: "Summary.")
        // The shape a planning boundary leaves behind: system prompt, task brief, notes seed —
        // no assistant turn anywhere, so `headEnd` runs off the end and `plan` returns nil.
        var conversation = [
            ChatMessage(role: .system, content: "You are an engineer."),
            ChatMessage(role: .user, content: "## Supervisor Task\nBuild it."),
            ChatMessage(role: .user, content: "## Planning notes\nRead three files."),
        ]
        let did = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .budgetExceeded, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        XCTAssertFalse(did)
        XCTAssertEqual(conversation.count, 3, "nothing folded — the wire is untouched")
        XCTAssertTrue(client.sentMessages.isEmpty, "and no request was spent finding that out")
        XCTAssertEqual(sut._testAutoCompactExhausted(stepID: stepID, taskID: taskID), true)
        XCTAssertTrue(delegate.beginStreamingCalls.isEmpty, "no bubble for a no-op epoch")
    }

    // MARK: - Interruption

    /// A Pause is not a failure. The conversation must be found exactly as it was left, no
    /// bubble may survive, and no banner may claim anything happened.
    ///
    /// RED: make the cancellation path fall through to `applyEpoch` → this fails, and pausing
    /// during a compaction silently discards the step's whole conversation.
    func testCancelledSummary_leavesTheWireUntouched() async {
        let client = ScriptedSummaryClient(summary: "", failure: CancellationError())
        var conversation = wire()
        let did = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .manual, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        XCTAssertFalse(did)
        XCTAssertEqual(conversation, wire())
        XCTAssertEqual(delegate.discardStreamingCalls.count, 1)
        XCTAssertEqual(delegate.beginStreamingCalls.first?.isCompacting, true)
        XCTAssertEqual(delegate.compactionMarks.map(\.1), [false])
        XCTAssertTrue(delegate.appendStreamingPreviewCalls.isEmpty)
        XCTAssertTrue(
            delegate.taskToMutate?.runs[0].steps[0].llmConversation.isEmpty == true,
            "a cancelled epoch records nothing")
    }

    /// A transport failure is not a cancellation: nothing was summarised, so nothing may be
    /// folded — but the step's own notes and the Supervisor record are still material, and the
    /// epoch proceeds on them rather than throwing the conversation away for nothing.
    func testFailedSummary_stillCompactsFromNotesAndRecord() async {
        let client = ScriptedSummaryClient(
            summary: "", failure: LLMClientError.providerError("boom"))
        var conversation = wire()
        let did = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .manual,
            step: step(scratchpad: "Findings: the parser lives in Parser.swift"),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        XCTAssertTrue(did)
        let seed = conversation.last?.content ?? ""
        XCTAssertTrue(seed.contains("Parser.swift"))
        XCTAssertEqual(
            CompactionPolicy.recordedSupervisorMessages(in: seed), ["Never touch Storage/."])
    }

    /// Nothing to say: no summary, no notes, no Supervisor turn. Replacing the conversation
    /// with an empty seed is strictly worse than the overflow it was answering, so the epoch
    /// refuses and latches.
    func testNoSeedMaterial_refusesAndLatches() async {
        let client = ScriptedSummaryClient(summary: "   ")
        var conversation = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .assistant, content: "hi"),
        ]
        let did = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .budgetExceeded, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        XCTAssertFalse(did)
        XCTAssertEqual(conversation.count, 2)
        XCTAssertEqual(sut._testAutoCompactExhausted(stepID: stepID, taskID: taskID), true)
    }

    /// A conversation that is only its pinned prefix has nothing to fold, and asking a model to
    /// summarise it would spend a request to learn that.
    func testHeadOnlyWire_refusesWithoutAnLLMCall() async {
        let client = ScriptedSummaryClient(summary: "unused")
        var conversation = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "task"),
        ]
        let did = await sut._testCompactConversationInLoop(
            stepID: stepID, taskID: taskID, reason: .budgetExceeded, step: step(),
            client: client, config: config, roleForMessage: .softwareEngineer,
            conversationMessages: &conversation)

        XCTAssertFalse(did)
        XCTAssertTrue(client.sentMessages.isEmpty, "no request may be spent to learn this")
        XCTAssertTrue(delegate.beginStreamingCalls.isEmpty, "and no bubble may appear")
        XCTAssertEqual(sut._testAutoCompactExhausted(stepID: stepID, taskID: taskID), true)
    }

    // MARK: - The refusal arm

    /// The server refused the prompt as an overflow. Asking the model to summarise would send
    /// the SAME conversation and be refused for the same reason — so this arm never opens a
    /// request.
    func testServerRefusalCompaction_spendsNoLLMCall() async {
        var conversation = wire()
        let did = await sut._testCompactAfterServerRefusal(
            stepID: stepID, taskID: taskID,
            step: step(scratchpad: "Findings: X"),
            conversationMessages: &conversation)

        XCTAssertTrue(did)
        XCTAssertTrue(delegate.beginStreamingCalls.isEmpty)
        XCTAssertEqual(conversation.count, 3)
        XCTAssertTrue(conversation.last?.content?.contains("Findings: X") == true)
    }

    /// Bounded to one attempt per response: a second refusal means the pinned head does not
    /// fit on its own, which no epoch can fix.
    func testServerRefusalCompaction_refusesASecondAttemptForTheSameResponse() async {
        var conversation = wire()
        _ = await sut._testCompactAfterServerRefusal(
            stepID: stepID, taskID: taskID, step: step(scratchpad: "X"),
            conversationMessages: &conversation)
        let second = await sut._testCompactAfterServerRefusal(
            stepID: stepID, taskID: taskID, step: step(scratchpad: "X"),
            conversationMessages: &conversation)
        XCTAssertFalse(second)
    }

    func testServerRefusalCompaction_isSkippedWhenAutoCompactIsOff() async {
        delegate.autoCompactEnabled = false
        var conversation = wire()
        let did = await sut._testCompactAfterServerRefusal(
            stepID: stepID, taskID: taskID, step: step(scratchpad: "X"),
            conversationMessages: &conversation)
        XCTAssertFalse(did)
        XCTAssertEqual(conversation, wire())
    }

    // MARK: - Manual request

    func testRequestCompaction_armsARunningStep_andRefusesASuspendedOne() {
        XCTAssertFalse(
            sut.requestCompaction(stepID: stepID, taskID: taskID),
            "an entry with no running task is a suspended step — a different mechanism")
        sut._testInjectRunningTask(
            stepID: stepID, taskID: taskID, runningTask: Task { try? await Task.sleep(for: .seconds(60)) })
        XCTAssertTrue(sut.requestCompaction(stepID: stepID, taskID: taskID))
        XCTAssertEqual(sut._testCompactRequested(stepID: stepID, taskID: taskID), .manual)
        sut.cancelExecutions(forTaskID: taskID)
    }
    // MARK: - The loop consumes the flag

    /// The epoch is armed by a trigger and CONSUMED at the top of an iteration — this drives
    /// the real `runOneLLMToolIteration`, so the placement (after the planning phase, before
    /// the queued-message injection, never inside the tool-result batch) is exercised rather
    /// than assumed.
    func testArmedEpoch_isConsumedByTheNextIteration() async throws {
        sut._testSetCompactionState(
            stepID: stepID, taskID: taskID, compactRequested: .budgetExceeded)
        let client = ScriptedSummaryClient(summary: "Folded work.")
        var conversation = wire()
        var usage = TokenUsage()

        _ = try await sut.runOneLLMToolIteration(
            stepID: stepID,
            roleForMessage: .softwareEngineer,
            client: client,
            config: config,
            tools: [],
            runtime: ToolRegistry.defaultRegistry(
                workFolderRoot: FileManager.default.temporaryDirectory,
                toolCallsLogURL: nil).runtime,
            task: delegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            supervisorMode: .manual,
            conversationMessages: &conversation,
            tracker: ToolCallTracker(),
            memoryStore: MemoryTagStore(workFolderRoot: FileManager.default.temporaryDirectory),
            cumulativeUsage: &usage)

        XCTAssertNil(sut._testCompactRequested(stepID: stepID, taskID: taskID))
        XCTAssertTrue(
            conversation.contains { CompactionPolicy.isCompactionSeed($0) },
            "the iteration must have folded the wire before sending it")
        XCTAssertEqual(Array(conversation[..<2]), Array(wire()[..<2]))
    }

    /// Mid-planning the phase owns the wire: its boundary slices at the brief, and an epoch
    /// that folded the brief away first would leave the slice with nothing to cut at.
    func testArmedEpoch_waitsWhileTheWireIsMidPlanning() async throws {
        delegate.taskToMutate = planningTask()
        sut._testSetCompactionState(stepID: stepID, taskID: taskID, compactRequested: .manual)
        let client = ScriptedSummaryClient(summary: "unused")
        var conversation: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "task"),
            ChatMessage(role: .user, content: PlanningPhasePolicy.planningBrief(
                exploreToolNames: [ToolNames.readFile], expectedArtifacts: [])),
            ChatMessage(role: .assistant, content: "exploring"),
        ]
        let before = conversation
        var usage = TokenUsage()

        _ = try await sut.runOneLLMToolIteration(
            stepID: stepID,
            roleForMessage: .softwareEngineer,
            client: client,
            config: config,
            tools: [ToolSchema(
                name: ToolNames.updateScratchpad, description: "notes",
                parameters: .object(properties: [:]))],
            runtime: ToolRegistry.defaultRegistry(
                workFolderRoot: FileManager.default.temporaryDirectory,
                toolCallsLogURL: nil).runtime,
            task: delegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            supervisorMode: .manual,
            conversationMessages: &conversation,
            tracker: ToolCallTracker(),
            memoryStore: MemoryTagStore(workFolderRoot: FileManager.default.temporaryDirectory),
            cumulativeUsage: &usage)

        XCTAssertEqual(
            sut._testCompactRequested(stepID: stepID, taskID: taskID), .manual,
            "the request must still be owed — deferred, not dropped")
        XCTAssertEqual(
            Array(conversation.prefix(before.count)), before,
            "nothing before the model's own new turn may have been folded")
    }
}

// MARK: - Scripted client

/// Emits one summary as content (and optional reasoning), recording what it was sent.
private final class ScriptedSummaryClient: LLMClient, @unchecked Sendable {
    let summary: String
    let thinking: String
    let failure: Error?
    let contextLength: Int?

    /// Every request's messages and tool count, so a test can assert the epoch sends the wire
    /// unchanged and advertises nothing.
    private(set) var sentMessages: [[ChatMessage]] = []
    private(set) var sentToolCounts: [Int] = []

    init(summary: String, thinking: String = "", failure: Error? = nil, contextLength: Int? = nil) {
        self.summary = summary
        self.thinking = thinking
        self.failure = failure
        self.contextLength = contextLength
    }

    func streamChat(
        config _: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        sentMessages.append(messages)
        sentToolCounts.append(tools.count)
        let body = summary
        let reasoning = thinking
        let thrown = failure
        return AsyncThrowingStream { continuation in
            if !reasoning.isEmpty {
                continuation.yield(StreamEvent(thinkingDelta: reasoning))
            }
            if !body.isEmpty {
                continuation.yield(StreamEvent(contentDelta: body))
            }
            continuation.finish(throwing: thrown)
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }

    func modelContextLength(config _: LLMConfig) async -> Int? { contextLength }
}

// MARK: - Superseding client

/// Yields a first delta, waits for the consumer to have processed it, supersedes the epoch,
/// then yields a second. The wait is a bounded yield loop rather than a sleep, so the test
/// stays deterministic without pinning a duration.
private final class SupersedingSummaryClient: LLMClient, @unchecked Sendable {
    let first: String
    let second: String
    let consumed: @MainActor @Sendable () -> Bool
    let supersede: @MainActor @Sendable () -> Void

    init(
        first: String,
        second: String,
        consumed: @escaping @MainActor @Sendable () -> Bool,
        supersede: @escaping @MainActor @Sendable () -> Void
    ) {
        self.first = first
        self.second = second
        self.consumed = consumed
        self.supersede = supersede
    }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let first = first
        let second = second
        let consumed = consumed
        let supersede = supersede
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                continuation.yield(StreamEvent(contentDelta: first))
                for _ in 0..<1000 where !consumed() { await Task.yield() }
                supersede()
                continuation.yield(StreamEvent(contentDelta: second))
                continuation.finish()
            }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }

    func modelContextLength(config _: LLMConfig) async -> Int? { nil }
}
