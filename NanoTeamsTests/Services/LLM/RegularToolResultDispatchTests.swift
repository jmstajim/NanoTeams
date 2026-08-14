import XCTest
@testable import NanoTeams

/// Coverage for the two dispatch entry points in
/// `LLMExecutionService+ToolResultDispatching.swift`.
///
/// **`processRegularToolResult`** is the path EVERY ordinary (non-collaboration)
/// tool result takes, and it was entirely unreached by tests. It does five things
/// that can each regress silently:
///   1. runs the result through `MemoryTagStore` and sends the model the
///      TAGGED / REFERENCE form (`<§R1§>`), while persisting the RAW envelope
///      into the feed — an asymmetry with no other pin;
///   2. appends exactly one `.tool` message carrying `result.providerID` (the
///      chain-protocol pairing with the assistant's tool_call);
///   3. fans out to the scratchpad / artifact side effects;
///   4. appends `buildToolErrorGuidance` on an error, to BOTH the live
///      conversation and the persisted history;
///   5. merges `ask_supervisor` questions into `outcome` (first provider id wins,
///      later questions concatenate, blank questions are ignored).
///
/// **`appendCollaborationResult`**'s attribution failure arm, its not-live drop
/// and the consultation/meeting/change-request halves are already pinned by
/// `ConsultationResultRenderingTests`, `CollaborationToolCallErrorRenderingTests`
/// and `AutovisorCardReflectTests` (which drive `list_tasks` / `task_status`).
/// What is NOT covered there is the `reflectEnvelope` path for the seven manager
/// WRITE signals, and the two `commitCollaborationOutcome` arms that only those
/// paths take: `bubbleMsg == nil` (no attribution role) and `cardJSON == nil`
/// (delegation success leaves the placeholder alone but still persists the tool
/// message). Those are what this file adds.
@MainActor
final class RegularToolResultDispatchTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var memoryStore: MemoryTagStore!
    private var tempDir: URL!

    private let stepID = "team_software_engineer"
    private let taskID = 11
    /// A step id that is deliberately never registered, so `isExecutionLive`
    /// answers `false` for it (the post-teardown write barrier).
    private let deadStepID = "torn_down_step"

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("regular-tool-dispatch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mockDelegate.workFolderURL = tempDir
        // `nil` work-folder root = the documented path-agnostic store mode: raw
        // paths, no canonicalisation. Everything under test here (dedup keys,
        // tag issuing, invalidation) is identical either way.
        memoryStore = MemoryTagStore()
        mockDelegate.taskToMutate = makeTask()
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        memoryStore = nil
        mockDelegate = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Passthrough: a tool no processor claims

    /// `list_files` is claimed by no `ToolResultProcessor`, so `processToolResult`
    /// returns `.passthrough` and the model must see the envelope VERBATIM. The
    /// persisted feed entry is the `[CALL]…[RESULT]` block carrying the same raw
    /// envelope, and `toolCallID` must be the provider id so the assistant's
    /// tool_call has its matching result.
    func testPassthroughTool_modelSeesRawEnvelope_andCallResultIsPersisted() async {
        let output = #"{"ok":true,"data":{"path":".","count":1,"files":["a.swift"],"dirs":[]}}"#
        let result = ToolExecutionResult(
            providerID: "tc_ls",
            toolName: ToolNames.listFiles,
            argumentsJSON: #"{"path":"."}"#,
            outputJSON: output,
            isError: false
        )

        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        await runRegular(result, into: &conversation, outcome: &outcome)

        XCTAssertEqual(conversation.count, 1,
            "A clean, non-error, non-signal result appends exactly one tool message.")
        XCTAssertEqual(conversation[0].role, .tool)
        XCTAssertEqual(conversation[0].content, output,
            "Passthrough must hand the model the envelope byte-for-byte.")
        XCTAssertEqual(conversation[0].toolCallID, "tc_ls",
            "The tool result must carry the provider id, or the chain has an unanswered tool_call.")

        let persisted = persistedConversation().last
        XCTAssertEqual(persisted?.role, .tool)
        XCTAssertTrue(persisted?.content.contains("[CALL] \(ToolNames.listFiles)") ?? false,
            "got: \(persisted?.content ?? "nil")")
        XCTAssertTrue(persisted?.content.contains(#"Arguments: {"path":"."}"#) ?? false,
            "got: \(persisted?.content ?? "nil")")
        XCTAssertTrue(persisted?.content.contains(output) ?? false,
            "The persisted [RESULT] block is the RAW envelope. got: \(persisted?.content ?? "nil")")

        XCTAssertNil(outcome.supervisorQuestion)
        XCTAssertFalse(outcome.shouldStopForSupervisor)
    }

    // MARK: - MemoryTagStore: tagged first read, raw envelope in the feed

    /// A first `read_file` is `.tagged`: the model gets the compact
    /// `{"tag":"<§R1§>",…}` form while the feed keeps the raw envelope. Pins the
    /// asymmetry — a refactor that persists `contentForConversation` instead of
    /// `result.outputJSON` would fill the activity feed with `<§Rn§>` pointers.
    func testReadFile_firstRead_modelSeesTag_feedKeepsRawEnvelope() async {
        let output = readEnvelope(path: "src/Foo.swift", content: "let answer = 42")
        let result = readResult(output: output)

        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        await runRegular(result, into: &conversation, outcome: &outcome)

        let modelSaw = conversation[0].content ?? ""
        XCTAssertTrue(modelSaw.contains(#""tag":"<§R1§>""#),
            "First read must be tagged R1. got: \(modelSaw)")
        XCTAssertTrue(modelSaw.contains("let answer = 42"),
            "A first read still carries the full content. got: \(modelSaw)")

        let persisted = persistedConversation().last?.content ?? ""
        XCTAssertTrue(persisted.contains(output),
            "The feed must show the raw tool envelope, not the tagged form.")
        XCTAssertFalse(persisted.contains("<§R1§>"),
            "Tags are a wire-compaction device; they must not leak into the persisted feed entry.")
    }

    /// The anti-dedup contract at the dispatcher level: an identical repeat read
    /// gets a FRESH tag and the FULL body again — there is no unchanged-reference
    /// collapse (simplified 2026-08-11).
    ///
    /// RED: reintroduce an unchanged-detection branch in the tag store → the
    /// second turn stops carrying the body and this fails.
    func testReadFile_identicalRepeat_getsFreshTagAndFullBody() async {
        let output = readEnvelope(path: "src/Foo.swift", content: "let answer = 42")

        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        await runRegular(readResult(output: output),
                       into: &conversation, outcome: &outcome)
        await runRegular(readResult(output: output, providerID: "tc_read_2"),
                       into: &conversation, outcome: &outcome)

        XCTAssertEqual(conversation.count, 2)
        let second = conversation[1].content ?? ""
        XCTAssertTrue(second.contains(#""tag":"<§R2§>""#),
            "The repeat mints its own tag. got: \(second)")
        XCTAssertTrue(second.contains("let answer = 42"),
            "The repeat carries the full body again. got: \(second)")
        XCTAssertEqual(conversation[1].toolCallID, "tc_read_2",
            "Every result must answer its own tool_call.")

        // Both raw envelopes persist to the feed.
        let toolEntries = persistedConversation().filter { $0.role == .tool }
        XCTAssertEqual(toolEntries.count, 2,
            "Both reads are real calls and both belong in the feed.")
    }

    /// A read → edit → read sequence: each action gets its own tag in its own
    /// series, and the re-read carries the body.
    func testReadEditRead_eachActionGetsItsOwnTag() async {
        let output = readEnvelope(path: "src/Foo.swift", content: "let answer = 42")

        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        await runRegular(readResult(output: output),
                       into: &conversation, outcome: &outcome)
        await runRegular(editResult(path: "src/Foo.swift"),
                       into: &conversation, outcome: &outcome)
        await runRegular(readResult(output: output, providerID: "tc_read_3"),
                       into: &conversation, outcome: &outcome)

        let editSaw = conversation[1].content ?? ""
        XCTAssertTrue(editSaw.contains(#""tag":"<§E1§>""#),
            "A successful edit is tagged in the E series. got: \(editSaw)")
        XCTAssertTrue(editSaw.contains(#""status":"success""#), "got: \(editSaw)")

        let rereadSaw = conversation[2].content ?? ""
        XCTAssertTrue(rereadSaw.contains(#""tag":"<§R2§>""#),
            "The re-read gets the next read tag. got: \(rereadSaw)")
        XCTAssertTrue(rereadSaw.contains("let answer = 42"),
            "The re-read must carry the body.")
    }

    /// `git_status` rides a different processor (`BuildGitToolProcessor`) —
    /// every call is tagged in the G series, repeats included.
    func testGitStatus_everyCallTagged() async {
        let output = #"{"ok":true,"data":{"branch":"main","clean":true,"paths":[]}}"#
        let call = ToolExecutionResult(
            providerID: "tc_git",
            toolName: ToolNames.gitStatus,
            argumentsJSON: "{}",
            outputJSON: output,
            isError: false
        )

        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        await runRegular(call, into: &conversation, outcome: &outcome)
        await runRegular(call, into: &conversation, outcome: &outcome)

        let first = conversation[0].content ?? ""
        XCTAssertTrue(first.contains(#""tag":"<§G1§>""#),
            "git_status is tagged in the G series. got: \(first)")

        let second = conversation[1].content ?? ""
        XCTAssertTrue(second.contains(#""tag":"<§G2§>""#),
            "the repeat mints its own tag. got: \(second)")
        // A valid-JSON body is spliced in raw, so the payload reads unescaped.
        XCTAssertTrue(second.contains(#""branch":"main""#),
            "the full status payload ships every time, nested raw. got: \(second)")
    }

    // MARK: - Error results: guidance in the conversation AND the feed

    /// An error result must (a) bypass tag compaction entirely (`.passthrough` —
    /// every file processor guards on `!isError`), and (b) append a `.user`
    /// guidance turn to BOTH the live conversation and the persisted history. The
    /// persisted half is what lets the human see why the model changed course.
    func testErrorResult_bypassesTagging_andAppendsGuidanceToBothSurfaces() async {
        let output = #"{"ok":false,"error":{"code":"FILE_NOT_FOUND","message":"File not found: missing.swift"}}"#
        let result = ToolExecutionResult(
            providerID: "tc_err",
            toolName: ToolNames.readFile,
            argumentsJSON: #"{"path":"missing.swift"}"#,
            outputJSON: output,
            isError: true
        )

        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        await runRegular(result, into: &conversation, outcome: &outcome)

        XCTAssertEqual(conversation.count, 2,
            "An error appends the tool result AND a guidance turn.")
        XCTAssertEqual(conversation[0].content, output,
            "An errored read is never tagged — the tag store passes it through untouched.")

        XCTAssertEqual(conversation[1].role, .user,
            "Guidance rides the user channel (a mid-conversation system turn would corrupt stateless rebuilds).")
        let guidance = conversation[1].content ?? ""
        XCTAssertTrue(guidance.contains("[FILE_NOT_FOUND]"),
            "Guidance must surface the typed code so the model can pick a recovery. got: \(guidance)")
        XCTAssertTrue(guidance.contains("File not found: missing.swift"), "got: \(guidance)")

        let persisted = persistedConversation()
        XCTAssertEqual(persisted.last?.role, .user)
        XCTAssertEqual(persisted.last?.content, guidance,
            "The guidance the model received must also be the guidance the human sees.")
        XCTAssertEqual(persisted.filter({ $0.role == .tool }).count, 1,
            "Exactly one [CALL]…[RESULT] entry for one call.")
    }

    /// The `tool_not_authorized` arm: the envelope carries the code as a TOP-LEVEL
    /// string (executor-emitted), not the nested handler shape, and the guidance
    /// must say "do not retry" rather than the generic fix-your-arguments advice.
    func testErrorResult_toolNotAuthorized_guidanceSaysDoNotRetryThatTool() async {
        let result = ToolExecutionResult(
            providerID: "tc_denied",
            toolName: ToolNames.gitCommit,
            argumentsJSON: #"{"message":"wip"}"#,
            outputJSON: #"{"ok":false,"error":"tool_not_authorized","tool":"git_commit","message":"Tool 'git_commit' is not available for this role."}"#,
            isError: true
        )

        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        await runRegular(result, into: &conversation, outcome: &outcome)

        let guidance = conversation.last?.content ?? ""
        XCTAssertTrue(guidance.contains("is not available for this role"),
            "The executor's scope-specific message must survive into the guidance. got: \(guidance)")
        XCTAssertTrue(guidance.contains("do not retry 'git_commit'"),
            "An unauthorised tool is a schema fact, not an argument bug — the model must be told to stop. got: \(guidance)")
    }

    // MARK: - Supervisor question merging

    func testSupervisorQuestion_recordsQuestionProviderIDAndStop() async {
        let result = supervisorResult(question: "  Which database?  ", providerID: "tc_ask_1")

        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        let returned = await runRegular(result, into: &conversation, outcome: &outcome)

        XCTAssertEqual(outcome.supervisorQuestion, "Which database?",
            "The question is trimmed before it reaches the Supervisor surfaces.")
        XCTAssertEqual(outcome.supervisorToolCallProviderIDs.first, "tc_ask_1")
        XCTAssertTrue(outcome.shouldStopForSupervisor)
        XCTAssertFalse(returned,
            "The stop rides `outcome.shouldStopForSupervisor`; the return value is not a stop signal.")
        XCTAssertEqual(conversation.count, 1,
            "A supervisor question still appends its own tool result (chain protocol).")
    }

    /// Two `ask_supervisor` calls in one batch merge into one question separated by
    /// a blank line, and the provider id stays pinned to the FIRST call — the id
    /// the answer is delivered against.
    func testTwoSupervisorQuestions_mergeWithBlankLine_andKeepFirstProviderID() async {
        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        await runRegular(supervisorResult(question: "First?", providerID: "tc_ask_1"),
                       into: &conversation, outcome: &outcome)
        await runRegular(supervisorResult(question: "Second?", providerID: "tc_ask_2"),
                       into: &conversation, outcome: &outcome)

        XCTAssertEqual(outcome.supervisorQuestion, "First?\n\nSecond?")
        XCTAssertEqual(outcome.supervisorToolCallProviderIDs.first, "tc_ask_1",
            "The first non-empty question owns the provider id the answer is routed to.")
        XCTAssertTrue(outcome.shouldStopForSupervisor)
    }

    /// A whitespace-only question is dropped entirely — no question, no stop. The
    /// guard exists so an empty `ask_supervisor` can't wedge the run at a blank
    /// prompt the human cannot answer.
    func testSupervisorQuestion_whitespaceOnly_isIgnoredEntirely() async {
        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        await runRegular(supervisorResult(question: "   \n\t ", providerID: "tc_blank"),
                       into: &conversation, outcome: &outcome)

        XCTAssertNil(outcome.supervisorQuestion)
        XCTAssertNil(outcome.supervisorToolCallProviderIDs.first)
        XCTAssertFalse(outcome.shouldStopForSupervisor,
            "A blank question must not park the run.")
        XCTAssertEqual(conversation.count, 1,
            "The tool result is still appended — the assistant's tool_call needs an answer either way.")
    }

    /// A blank question followed by a real one: the real one still lands, and it —
    /// not the discarded blank — owns the provider id.
    func testSupervisorQuestion_blankThenReal_realOneOwnsTheProviderID() async {
        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        await runRegular(supervisorResult(question: "  ", providerID: "tc_blank"),
                       into: &conversation, outcome: &outcome)
        await runRegular(supervisorResult(question: "Real?", providerID: "tc_real"),
                       into: &conversation, outcome: &outcome)

        XCTAssertEqual(outcome.supervisorQuestion, "Real?",
            "A discarded blank must not become a leading empty line of the merged question.")
        XCTAssertEqual(outcome.supervisorToolCallProviderIDs.first, "tc_real")
        XCTAssertTrue(outcome.shouldStopForSupervisor)
    }

    // MARK: - Scratchpad side effect reached through the regular path

    /// `update_scratchpad` is not tag-compacted by the regular dispatcher itself —
    /// it fans out to `processScratchpadResult`, which writes the step's scratchpad
    /// and appends exactly ONE acknowledgement. Pins the fan-out wiring.
    func testUpdateScratchpad_writesScratchpad_andAppendsSingleAck() async {
        let result = ToolExecutionResult(
            providerID: "tc_plan",
            toolName: ToolNames.updateScratchpad,
            argumentsJSON: #"{"content":"1. read 2. edit 3. build"}"#,
            outputJSON: #"{"ok":true,"data":{"status":"saved"}}"#,
            isError: false
        )

        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        await runRegular(result, into: &conversation, outcome: &outcome)

        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].steps[0].scratchpad,
                       "1. read 2. edit 3. build",
            "The plan must land on the step, not just in the transcript.")

        XCTAssertEqual(conversation.count, 2,
            "Tool result + exactly one acknowledgement — the plan itself is never echoed back.")
        XCTAssertEqual(conversation[1].role, .user)
        XCTAssertEqual(conversation[1].content,
                       PlanningPhasePolicy.scratchpadAck(isPlanningWire: false),
            "A non-planning wire gets the plain ack, not the phase-transition wording.")
    }

    // MARK: - Post-teardown write barrier

    /// Mirror of the collaboration path's asymmetry: once the step's execution
    /// state is gone (`isExecutionLive == false`), nothing may be persisted — but
    /// the in-memory tool result is still appended so the live iteration's
    /// assistant tool_call keeps a matching answer.
    func testNotLiveStep_appendsInMemoryToolResult_butPersistsNothing() async {
        let result = ToolExecutionResult(
            providerID: "tc_ls",
            toolName: ToolNames.listFiles,
            argumentsJSON: #"{"path":"."}"#,
            outputJSON: #"{"ok":true,"data":{"path":".","count":0,"files":[],"dirs":[]}}"#,
            isError: false
        )

        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        // `deadStepID` was never registered → the write barrier is closed.
        await service.processRegularToolResult(
            result: result,
            stepID: deadStepID,
            taskID: taskID,
            memoryStore: memoryStore,
            conversationMessages: &conversation,
            outcome: &outcome
        )

        XCTAssertEqual(conversation.count, 1,
            "Chain protocol: the tool result is unconditional even after teardown.")
        XCTAssertFalse(mockDelegate.eventLog.contains(where: { $0.hasPrefix("mutate-begin") }),
            "A torn-down step must not write into whatever currently answers to that task id.")
    }

    /// Same barrier, error variant: the guidance turn reaches the model (so it can
    /// recover this iteration) but is not persisted.
    func testNotLiveStep_errorGuidance_reachesModelButIsNotPersisted() async {
        let result = ToolExecutionResult(
            providerID: "tc_err",
            toolName: ToolNames.readFile,
            argumentsJSON: #"{"path":"missing.swift"}"#,
            outputJSON: #"{"ok":false,"error":{"code":"FILE_NOT_FOUND","message":"File not found: missing.swift"}}"#,
            isError: true
        )

        var conversation: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        await service.processRegularToolResult(
            result: result,
            stepID: deadStepID,
            taskID: taskID,
            memoryStore: memoryStore,
            conversationMessages: &conversation,
            outcome: &outcome
        )

        XCTAssertEqual(conversation.count, 2,
            "Tool result + guidance still reach the in-flight conversation.")
        XCTAssertEqual(conversation[1].role, .user)
        XCTAssertFalse(mockDelegate.eventLog.contains(where: { $0.hasPrefix("mutate-begin") }),
            "Nothing may be persisted for a torn-down step.")
    }

    // MARK: - appendCollaborationResult: manager WRITE signals (reflectEnvelope)

    /// The seven Autovisor write signals all funnel through
    /// `applyAutovisorAction` → `reflectEnvelope`. On success the card must show
    /// the real `{"ok":true,…,"status":"ok"}` envelope (the manager's feed is its
    /// only surface), and the signal must have been translated into the matching
    /// `AutovisorAction` for the single delegate hook.
    func testAutovisorWriteSignals_successEnvelopeReflectsOntoGreenCard() async {
        mockDelegate.autovisorActionResult = .success("did the thing")

        for (toolName, signal) in autovisorWriteCases() {
            let toolCallID = UUID()
            mockDelegate.taskToMutate = makeTaskWithToolCall(toolCallID: toolCallID, toolName: toolName)
            mockDelegate.autovisorActions.removeAll()
            service._testRegisterStepTask(stepID: stepID, taskID: taskID)

            var conversation: [ChatMessage] = []
            await dispatchCollaboration(
                collaborationResult(toolName: toolName, signal: signal),
                toolCallID: toolCallID,
                into: &conversation
            )

            let card = persistedCard(toolCallID)
            XCTAssertEqual(card?.isError, false,
                "\(toolName): a successful manager write must keep the card green.")
            XCTAssertTrue(card?.resultJSON?.contains("did the thing") ?? false,
                "\(toolName): the card must carry the action's real message. got: \(card?.resultJSON ?? "nil")")
            XCTAssertFalse(card?.resultJSON?.contains(#""status":"pending""#) ?? true,
                "\(toolName): the synchronous placeholder must be replaced.")
            XCTAssertEqual(mockDelegate.autovisorActions.count, 1,
                "\(toolName): the signal must translate into exactly one AutovisorAction.")
            XCTAssertTrue(conversation.last?.content?.contains("did the thing") ?? false,
                "\(toolName): the LLM sees the same single envelope as the card.")
        }
    }

    /// The failure half of `reflectEnvelope` for the same seven signals: a rejected
    /// action must flip the card red and surface the reason, not leave it green.
    /// Guards against a refactor that hardcodes `isError` inside the manager branch.
    func testAutovisorWriteSignals_failureEnvelopeFlipsCardRed() async {
        mockDelegate.autovisorActionResult = .failure("task 42 is not paused")

        for (toolName, signal) in autovisorWriteCases() {
            let toolCallID = UUID()
            mockDelegate.taskToMutate = makeTaskWithToolCall(toolCallID: toolCallID, toolName: toolName)
            service._testRegisterStepTask(stepID: stepID, taskID: taskID)

            var conversation: [ChatMessage] = []
            await dispatchCollaboration(
                collaborationResult(toolName: toolName, signal: signal),
                toolCallID: toolCallID,
                into: &conversation
            )

            let card = persistedCard(toolCallID)
            XCTAssertEqual(card?.isError, true,
                "\(toolName): a rejected manager write must render red.")
            XCTAssertTrue(card?.resultJSON?.contains(#""ok":false"#) ?? false,
                "\(toolName): got \(card?.resultJSON ?? "nil")")
            XCTAssertTrue(card?.resultJSON?.contains("task 42 is not paused") ?? false,
                "\(toolName): the rejection reason must reach the human. got: \(card?.resultJSON ?? "nil")")
        }
    }

    /// `commitCollaborationOutcome`'s `bubbleMsg == nil` arm. Manager signals set no
    /// `attributionRole`/`attributionContext`, so the commit writes card + tool
    /// message and NO attribution bubble — all inside one `mutateTask`.
    func testAutovisorWrite_commitsCardAndToolMessage_inOneMutation_withNoAttributionBubble() async {
        mockDelegate.autovisorActionResult = .success("scheduled")
        let toolCallID = UUID()
        mockDelegate.taskToMutate = makeTaskWithToolCall(
            toolCallID: toolCallID, toolName: ToolNames.scheduleTask)
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)

        var conversation: [ChatMessage] = []
        await dispatchCollaboration(
            collaborationResult(toolName: ToolNames.scheduleTask,
                                signal: .scheduleTask(taskID: 42, intervalMinutes: 30)),
            toolCallID: toolCallID,
            into: &conversation
        )

        let commits = mockDelegate.eventLog.filter { $0 == "mutate-begin:\(taskID)" }.count
        XCTAssertEqual(commits, 1,
            "Card + tool message must land in ONE atomic mutateTask (no partial-persist window).")

        let persisted = persistedConversation()
        XCTAssertEqual(persisted.count, 1,
            "A manager result has no role to attribute, so only the [CALL]…[RESULT] entry is written.")
        guard let entry = persisted.first else {
            XCTFail("Expected the [CALL]…[RESULT] entry to be persisted")
            return
        }
        XCTAssertEqual(entry.role, .tool)
        XCTAssertTrue(entry.content.contains("[CALL] \(ToolNames.scheduleTask)"),
            "got: \(entry.content)")
        XCTAssertNil(entry.sourceContext,
            "The tool entry is not an attribution bubble.")
        XCTAssertNil(entry.sourceRole,
            "A manager result is not attributed to any role.")
    }

    /// Delegation SUCCESS reflects onto the card, persists the tool message, and writes no bubble
    /// (delegation carries no single role's voice).
    ///
    /// The card assertion here used to require the placeholder to survive, justified by "its output
    /// renders in the stacked graph layers". `GraphPanelView.resolveDelegationLayers()` gates on
    /// `step.activeDelegationChildID != nil`, and every delegation arm that resolves — this
    /// cancellation included — calls `clearDelegationFields` BEFORE returning its envelope, so
    /// those layers are gone by the time the card is written. The assertion was pinning a card
    /// that reported a finished delegation as pending, green, permanently.
    func testDelegationSuccess_reflectsOntoCard_andPersistsToolMessage() async {
        let toolCallID = UUID()
        mockDelegate.taskToMutate = makeTaskWithToolCall(
            toolCallID: toolCallID, toolName: ToolNames.cancelDelegation)
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        // Registering the active child makes `handleCancelDelegation` succeed.
        mockDelegate.activeDelegationChildStub["\(taskID):\(stepID)"] = 999

        var conversation: [ChatMessage] = []
        await dispatchCollaboration(
            collaborationResult(toolName: ToolNames.cancelDelegation,
                                signal: .cancelDelegation(childTaskID: 999, reason: nil)),
            toolCallID: toolCallID,
            into: &conversation
        )

        let card = persistedCard(toolCallID)
        XCTAssertEqual(card?.isError, false)
        XCTAssertFalse(card?.resultJSON?.contains("\"status\":\"pending\"") ?? true,
            "The card is the only durable record of a resolved delegation — the graph layers are torn down by the same path — so it must carry the real envelope. Got: \(card?.resultJSON ?? "nil")")
        XCTAssertTrue(card?.resultJSON?.contains(#""status":"cancelled""#) ?? false,
            "got: \(card?.resultJSON ?? "nil")")

        let persisted = persistedConversation()
        let callMarker = "[CALL] \(ToolNames.cancelDelegation)"
        XCTAssertTrue(
            persisted.contains(where: { $0.role == .tool && $0.content.contains(callMarker) }),
            "The card reflect must NOT displace the persisted tool message. got: \(persisted.map(\.content))")
        XCTAssertFalse(persisted.contains(where: { $0.sourceContext != nil }),
            "Delegation has no attribution bubble.")
        XCTAssertTrue(conversation.last?.content?.contains(#""status":"cancelled""#) ?? false,
            "The LLM still receives the real envelope. got: \(conversation.last?.content ?? "nil")")
    }

    // MARK: - Helpers

    @discardableResult
    private func runRegular(
        _ result: ToolExecutionResult,
        into conversation: inout [ChatMessage],
        outcome: inout LLMExecutionService.ToolResultsOutcome
    ) async -> Bool {
        await service.processRegularToolResult(
            result: result,
            stepID: stepID,
            taskID: taskID,
            memoryStore: memoryStore,
            conversationMessages: &conversation,
            outcome: &outcome
        )
    }

    private func dispatchCollaboration(
        _ result: ToolExecutionResult,
        toolCallID: UUID,
        into conversation: inout [ChatMessage]
    ) async {
        guard let task = mockDelegate.taskToMutate else {
            XCTFail("A task must be installed before dispatching a collaboration result")
            return
        }
        await service.appendCollaborationResult(
            result: result,
            toolCallID: toolCallID,
            roleForMessage: .softwareEngineer,
            stepID: stepID,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: NeverStreamingStubClient(),
            config: LLMConfig(),
            networkLogger: nil,
            conversationMessages: &conversation
        )
    }

    /// The seven Autovisor WRITE signals — every `reflectEnvelope` case that
    /// `AutovisorCardReflectTests` (which drives the two READ tools) leaves
    /// unexercised through the dispatcher.
    private func autovisorWriteCases() -> [(String, ToolSignal)] {
        [
            (ToolNames.createManagedTask, .createManagedTask(title: "t", brief: "b", teamID: nil)),
            (ToolNames.controlTask, .controlTask(taskID: 42, verb: .stop)),
            (ToolNames.manageRole, .manageRole(taskID: 42, roleID: "r", verb: .accept)),
            (ToolNames.answerTaskQuestion, .answerTaskQuestion(taskID: 42, answer: "yes")),
            (ToolNames.messageTask, .messageTask(taskID: 42, text: "hi", roleID: nil)),
            (ToolNames.scheduleTask, .scheduleTask(taskID: 42, intervalMinutes: 30)),
            (ToolNames.setWorkFolderContext, .setWorkFolderContext(content: "ctx")),
        ]
    }

    private func collaborationResult(toolName: String, signal: ToolSignal) -> ToolExecutionResult {
        ToolExecutionResult(
            providerID: "tc_1",
            toolName: toolName,
            argumentsJSON: "{}",
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false,
            signal: signal
        )
    }

    private func readEnvelope(path: String, content: String) -> String {
        // Single-line content keeps the fixture free of JSON escaping, and a
        // 1..1 range still exercises the range-key + coverage machinery.
        #"{"ok":true,"data":{"path":"\#(path)","content":"\#(content)","start_line":1,"end_line":1,"total_lines":1}}"#
    }

    private func readResult(output: String, providerID: String = "tc_read") -> ToolExecutionResult {
        ToolExecutionResult(
            providerID: providerID,
            toolName: ToolNames.readFile,
            argumentsJSON: #"{"path":"src/Foo.swift"}"#,
            outputJSON: output,
            isError: false
        )
    }

    private func editResult(path: String) -> ToolExecutionResult {
        ToolExecutionResult(
            providerID: "tc_edit",
            toolName: ToolNames.editFile,
            argumentsJSON: #"{"path":"\#(path)","old_text":"42","new_text":"43"}"#,
            outputJSON: #"{"ok":true,"data":{"path":"\#(path)","replacements":1}}"#,
            isError: false
        )
    }

    private func supervisorResult(question: String, providerID: String) -> ToolExecutionResult {
        ToolExecutionResult(
            providerID: providerID,
            toolName: ToolNames.askSupervisor,
            argumentsJSON: "{}",
            outputJSON: #"{"ok":true,"data":{"status":"waiting"}}"#,
            isError: false,
            signal: .supervisorQuestion(question)
        )
    }

    private func makeTask() -> NTMSTask {
        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "SWE", status: .running)
        return NTMSTask(id: taskID, title: "T", supervisorTask: "brief",
                        runs: [Run(id: 0, steps: [step])])
    }

    private func makeTaskWithToolCall(toolCallID: UUID, toolName: String) -> NTMSTask {
        let placeholder = StepToolCall(
            id: toolCallID,
            providerID: "tc_1",
            name: toolName,
            argumentsJSON: "{}",
            resultJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false
        )
        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "SWE",
                                 status: .running, toolCalls: [placeholder])
        return NTMSTask(id: taskID, title: "T", supervisorTask: "brief",
                        runs: [Run(id: 0, steps: [step])])
    }

    private func persistedConversation() -> [LLMMessage] {
        mockDelegate.taskToMutate?.runs[0].steps[0].llmConversation ?? []
    }

    private func persistedCard(_ toolCallID: UUID) -> StepToolCall? {
        mockDelegate.taskToMutate?.runs[0].steps[0].toolCalls.first { $0.id == toolCallID }
    }
}

// MARK: - Stub LLM client

/// None of the paths driven here reach the model: regular tool results never
/// stream, and the manager / delegation handlers resolve through the delegate.
private final class NeverStreamingStubClient: LLMClient, @unchecked Sendable {
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
