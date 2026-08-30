import XCTest

@testable import NanoTeams

/// Drives `LLMExecutionService.processToolResults(...)` — the per-iteration fan-out that
/// (1) writes each tool result onto its persisted `StepToolCall`, (2) records the batch in
/// the loop-detector's tracker, and (3) dispatches each result to either the deferred
/// collaboration handler or `processRegularToolResult`.
///
/// The function was entirely unreached by tests. These drive the REAL entry point with
/// hand-built `ToolExecutionResult` values and assert what lands on the step
/// (`toolCalls`, `llmConversation`, `artifacts`, `scratchpad`) plus the returned
/// `ToolResultsOutcome`. Only signals reachable without a network hop are exercised:
/// `.artifact`, `.supervisorQuestion`, `.teamCreation`, `.cancelDelegation` (whose
/// no-active-child arm fails instantly with `INVALID_ARGS`), and plain / error results.
///
/// `installTask` registering the step's execution state is mandatory, not incidental:
/// `updateToolCallResult`, `appendLLMMessage` and `commitCollaborationOutcome` are all
/// gated on `isExecutionLive`, so without it nothing would persist and every assertion
/// below would pass or fail for the wrong reason.
@MainActor
final class ProcessToolResultsTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    // Value types only — a stored property holding a freshly constructed class would be
    // built when XCTest instantiates every test class upfront.
    private let stepID = "startup_software_engineer"
    private let taskID = 7

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessToolResultsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        mockDelegate = nil
        service = nil
        MonotonicClock.shared.reset()
        try await super.tearDown()
    }

    // MARK: - Group A: empty / degenerate batches

    /// An empty batch must be a total no-op: no card writes, no tracker records,
    /// no conversation turns, and a clean outcome. Covers every loop's zero-iteration arm.
    func testProcessToolResults_emptyResults_isATotalNoOp() async {
        let task = makeTask(toolCalls: [])
        installTask(task)

        let tracker = ToolCallTracker()
        var conversation: [ChatMessage] = []
        let outcome = await drive(
            calls: [], results: [], task: task,
            conversation: &conversation, tracker: tracker
        )

        XCTAssertFalse(outcome.shouldStopForSupervisor)
        XCTAssertNil(outcome.supervisorQuestion)
        XCTAssertNil(outcome.supervisorToolCallProviderIDs.first)
        XCTAssertTrue(conversation.isEmpty, "No results ⇒ no wire turns appended")
        XCTAssertTrue(tracker.recentCalls(limit: .max).isEmpty,
                      "No results ⇒ nothing enters the loop-detector snapshot")
        XCTAssertEqual(currentStep()?.llmConversation.count, 0,
                       "No results ⇒ nothing persisted to the step")
    }

    /// The first two loops `zip` calls with results, so a batch whose results array is
    /// SHORTER than the calls array processes only the common prefix. Reachable in
    /// production: `+ToolIteration` builds `toolResults` by appending at most one entry
    /// per resolved call, so a dropped executor result yields exactly this shape.
    /// The untouched trailing call must keep its un-executed (`nil`) result.
    func testProcessToolResults_fewerResultsThanCalls_processesOnlyTheZippedPrefix() async {
        let firstID = UUID()
        let secondID = UUID()
        let calls = [
            makeCall(id: firstID, providerID: "tc_0", name: ToolNames.listFiles,
                     argumentsJSON: #"{"path":"."}"#),
            makeCall(id: secondID, providerID: "tc_1", name: ToolNames.gitLog,
                     argumentsJSON: "{}"),
        ]
        let task = makeTask(toolCalls: calls)
        installTask(task)

        let onlyResult = makeResult(
            providerID: "tc_0", toolName: ToolNames.listFiles,
            argumentsJSON: #"{"path":"."}"#,
            outputJSON: #"{"ok":true,"data":{"count":0,"files":[],"dirs":[]}}"#
        )

        let tracker = ToolCallTracker()
        var conversation: [ChatMessage] = []
        _ = await drive(
            calls: calls, results: [onlyResult], task: task,
            conversation: &conversation, tracker: tracker
        )

        // Explicit `String?` annotations: `?? nil` on a `String??` is only unambiguously
        // the flattening overload when the binding states the result type.
        let firstResult: String? = card(firstID)?.resultJSON ?? nil
        let secondResult: String? = card(secondID)?.resultJSON ?? nil
        XCTAssertNotNil(card(secondID), "precondition: the second call is still on the step")
        XCTAssertEqual(firstResult, onlyResult.outputJSON,
                       "The zipped prefix must be written through")
        XCTAssertNil(secondResult,
                     "A call with no matching result must stay un-executed, not inherit a neighbour's result")
        XCTAssertEqual(tracker.recentCalls(limit: .max).count, 1,
                       "Tracker records one entry per (call, result) pair, not per call")
        XCTAssertEqual(conversation.count, 1)
    }

    // MARK: - Group B: plain (non-signal) result

    /// The commonest path end to end: card write-through, tracker record, the in-memory
    /// `.tool` wire turn keyed by the provider's `tool_call_id`, and the durable
    /// `[CALL] … [RESULT]` message on `step.llmConversation`.
    ///
    /// `list_files` is chosen deliberately: `FileToolProcessor` claims it via
    /// `allFileTools` but returns `.passthrough` for it, so `contentForConversation`
    /// is exactly `result.outputJSON` and the assertion is unambiguous.
    func testProcessToolResults_plainResult_writesCard_recordsTracker_andAppendsBothTurns() async {
        let callID = UUID()
        let call = makeCall(id: callID, providerID: "tc_0", name: ToolNames.listFiles,
                            argumentsJSON: #"{"path":"Sources"}"#)
        let task = makeTask(toolCalls: [call])
        installTask(task)

        let output = #"{"ok":true,"data":{"path":"Sources","count":1,"files":["Sources/A.swift"],"dirs":[]}}"#
        let result = makeResult(
            providerID: "tc_0", toolName: ToolNames.listFiles,
            argumentsJSON: #"{"path":"Sources"}"#, outputJSON: output
        )

        let tracker = ToolCallTracker()
        var conversation: [ChatMessage] = []
        let outcome = await drive(
            calls: [call], results: [result], task: task,
            conversation: &conversation, tracker: tracker
        )

        // Outcome untouched — a plain result never stops the loop.
        XCTAssertFalse(outcome.shouldStopForSupervisor)
        XCTAssertNil(outcome.supervisorQuestion)

        // 1. Card.
        XCTAssertEqual(card(callID)?.resultJSON ?? nil, output)
        XCTAssertEqual(card(callID)?.isError ?? nil, false)

        // 2. Tracker (loop-detector input).
        let tracked = tracker.recentCalls(limit: .max)
        XCTAssertEqual(tracked.count, 1)
        XCTAssertEqual(tracked.first?.toolName, ToolNames.listFiles)
        XCTAssertEqual(tracked.first?.wasSuccessful, true)

        // 3. In-memory wire turn, correlated by provider tool_call_id.
        XCTAssertEqual(conversation.count, 1, "Exactly one .tool turn per plain result")
        guard conversation.count == 1 else { return }
        XCTAssertEqual(conversation[0].role, .tool)
        XCTAssertEqual(conversation[0].content, output,
                       "list_files is a passthrough in MemoryTagStore ⇒ raw outputJSON on the wire")
        XCTAssertEqual(conversation[0].toolCallID, "tc_0",
                       "The tool turn must carry the provider id so the assistant tool_call resolves")

        // 4. Durable step record.
        let persisted = currentStep()?.llmConversation ?? []
        XCTAssertEqual(persisted.count, 1)
        guard persisted.count == 1 else { return }
        XCTAssertEqual(persisted[0].role, .tool)
        XCTAssertTrue(persisted[0].content.contains("[CALL] \(ToolNames.listFiles)"))
        XCTAssertTrue(persisted[0].content.contains("[RESULT]"))
        XCTAssertTrue(persisted[0].content.contains(output))
    }

    // MARK: - Group C: error results

    /// An error result flips the card red, records an unsuccessful tracker entry, and
    /// appends a `.user` guidance turn AFTER the `.tool` turn — on the wire and on the
    /// step. `INVALID_ARGS` takes `ToolErrorNotePolicy.direction`'s `default` arm, which must
    /// prefix the typed code and steer toward fixing arguments.
    func testProcessToolResults_errorResult_flipsCardAndAppendsTypedGuidance() async {
        let callID = UUID()
        let call = makeCall(id: callID, providerID: "tc_0", name: ToolNames.listFiles,
                            argumentsJSON: "{}")
        let task = makeTask(toolCalls: [call])
        installTask(task)

        let errorEnvelope =
            #"{"ok":false,"error":{"code":"INVALID_ARGS","message":"Missing required argument: path"}}"#
        let result = makeResult(
            providerID: "tc_0", toolName: ToolNames.listFiles,
            argumentsJSON: "{}", outputJSON: errorEnvelope, isError: true
        )

        let tracker = ToolCallTracker()
        var conversation: [ChatMessage] = []
        _ = await drive(
            calls: [call], results: [result], task: task,
            conversation: &conversation, tracker: tracker
        )

        XCTAssertEqual(card(callID)?.isError ?? nil, true)
        XCTAssertEqual(card(callID)?.resultJSON ?? nil, errorEnvelope)
        XCTAssertEqual(tracker.recentCalls(limit: .max).first?.wasSuccessful, false)

        XCTAssertEqual(conversation.count, 2,
                       "An error result appends the tool turn AND a guidance turn")
        guard conversation.count == 2 else { return }
        XCTAssertEqual(conversation[0].role, .tool)
        XCTAssertEqual(conversation[1].role, .user)
        let guidance = conversation[1].content ?? ""
        XCTAssertTrue(guidance.contains("[INVALID_ARGS]"),
                      "Typed code must be surfaced so the model can pick a recovery. Got: \(guidance)")
        XCTAssertTrue(guidance.contains("Fix the arguments and retry."),
                      "INVALID_ARGS is the one family where arguments ARE the cause. Got: \(guidance)")

        let persisted = currentStep()?.llmConversation ?? []
        XCTAssertEqual(persisted.count, 2, "Guidance must be durable, not wire-only")
        guard persisted.count == 2 else { return }
        XCTAssertEqual(persisted[1].role, .user)
        XCTAssertEqual(persisted[1].content, guidance)
        // Durable but deliberately INVISIBLE, and the two are independent: it is persisted
        // because `rebuildFromDisplayRecord` and `DelegatedSupervisorAnswerService.buildSeed`
        // read the display record rather than the wire; it is unattributed because
        // `ActivityFeedBuilder` drops `.user` turns with neither a source role nor a context,
        // which is what keeps a `system: retry` row from restating the card directly above
        // it. Every arm is a constant keyed on the error code, so the row carried nothing the
        // card does not. See the `feed-invisible-by-design:` note at the call site.
        XCTAssertNil(persisted[1].sourceContext,
                     "The direction comments on the failed call's own card — attributing it "
                         + "puts the same sentence on screen twice for one event")
    }

    /// End-to-end, on the surface the Supervisor actually looks at: a failed call
    /// produces its card and NOTHING underneath it.
    ///
    /// The two assertions above are about a field; this is about the screen, and it
    /// is the one that states the defect. The reported shape was a red card reading
    /// "This command needs human approval …, but no human is available to review it.
    /// Ask the supervisor to allow unattended command approval." with a dim
    /// `system: retry` row beneath it reading "Do NOT retry this command — the block
    /// is set by policy…" — the same sentence twice, for one event.
    ///
    /// Driven through the real `processToolResults` rather than a hand-built
    /// `LLMMessage`, because the defect was in the ATTRIBUTION the dispatcher chose,
    /// which a hand-built fixture would simply restate. Anti-vacuity is the card
    /// assertion: if the walk found no items at all, "no notice row" would pass
    /// against an empty feed.
    func testProcessToolResults_errorResult_rendersOneCardAndNoNoticeRowUnderIt() async {
        let callID = UUID()
        let call = makeCall(id: callID, providerID: "tc_0", name: ToolNames.bash,
                            argumentsJSON: #"{"command":"xcodebuild test"}"#)
        let task = makeTask(toolCalls: [call])
        installTask(task)

        // The reported envelope, verbatim from `+BashGate`'s no-human arm.
        let denied = #"{"ok":false,"error":{"code":"BASH_DENIED","message":"This command needs human approval (Manual mode — every command is reviewed individually.), but no human is available to review it. Ask the supervisor to allow unattended command approval."}}"#
        let result = makeResult(
            providerID: "tc_0", toolName: ToolNames.bash,
            argumentsJSON: #"{"command":"xcodebuild test"}"#, outputJSON: denied, isError: true
        )

        var conversation: [ChatMessage] = []
        _ = await drive(
            calls: [call], results: [result], task: task,
            conversation: &conversation, tracker: ToolCallTracker()
        )

        guard let step = currentStep() else { return XCTFail("step vanished") }
        let items = ActivityFeedBuilder.buildTimelineItems(
            steps: [step], run: Run(id: 0, steps: [step]),
            stepArtifactContentCache: [:], debugModeEnabled: false,
            isStreaming: { _ in false }
        )

        let cards = items.compactMap { tagged -> StepToolCall? in
            if case .toolCall(let c, _, _, _) = tagged.item { return c }
            return nil
        }
        XCTAssertEqual(cards.count, 1, "The failed call must be on screen — this is the anti-vacuity floor")
        XCTAssertEqual(cards.first?.isError, true)

        // `SystemNoticePresentation.resolve` is the exact predicate the bubble uses to
        // pick the `system: …` row, so asking it is asking the view.
        let notices = items.compactMap { tagged -> SystemNoticePresentation.Notice? in
            guard case .llmMessage(let message, _, _, _) = tagged.item else { return nil }
            return SystemNoticePresentation.resolve(
                context: message.sourceContext, content: message.content)
        }
        XCTAssertTrue(notices.isEmpty,
                      "The card already carries the reason; a notice under it restates it. Got: "
                          + notices.map(\.rowLabel).joined(separator: ", "))

        // Half two of the contract, and it belongs in the same test: the model must
        // still be steered, or a later "the row is noise" cleanup deletes the steering
        // with it and nothing turns red.
        XCTAssertEqual(conversation.count, 2, "tool turn + direction")
        XCTAssertTrue((conversation.last?.content ?? "").contains("Do NOT retry this command"),
                      "Got: \(conversation.last?.content ?? "")")
    }

    /// The executor-emitted envelope shape stores the code as a TOP-LEVEL string
    /// (`"error":"tool_not_authorized"`), unlike the handler shape's nested object.
    /// That branch must produce don't-retry steering naming the offending tool —
    /// the generic "fix your arguments" suffix is what makes weaker models loop.
    func testProcessToolResults_toolNotAuthorizedError_guidanceSaysDoNotRetry() async {
        let callID = UUID()
        let args = #"{"path":"a.swift","content":"x"}"#
        let call = makeCall(id: callID, providerID: "tc_0", name: ToolNames.writeFile,
                            argumentsJSON: args)
        let task = makeTask(toolCalls: [call])
        installTask(task)

        let envelope = """
        {"ok":false,"error":"tool_not_authorized","tool":"write_file",\
        "message":"Tool 'write_file' is not available for this role."}
        """
        let result = makeResult(
            providerID: "tc_0", toolName: ToolNames.writeFile,
            argumentsJSON: args, outputJSON: envelope, isError: true
        )

        var conversation: [ChatMessage] = []
        _ = await drive(
            calls: [call], results: [result], task: task,
            conversation: &conversation, tracker: ToolCallTracker()
        )

        XCTAssertEqual(conversation.count, 2)
        guard conversation.count == 2 else { return }
        let guidance = conversation[1].content ?? ""
        XCTAssertTrue(guidance.contains("do not retry 'write_file'"),
                      "Policy rejections must steer away from the tool, not toward new arguments. Got: \(guidance)")
        XCTAssertFalse(guidance.contains("Fix the arguments and retry."),
                       "Arguments are not the cause of a not-authorized rejection")
    }

    // MARK: - Group D: supervisor questions

    /// `.supervisorQuestion` records into the outcome (it does NOT interrupt the loop
    /// mid-batch) and pins the asking call's provider id so the answer can be routed back.
    func testProcessToolResults_supervisorQuestion_setsOutcomeAndProviderID() async {
        let callID = UUID()
        let args = #"{"question":"Which database?"}"#
        let call = makeCall(id: callID, providerID: "tc_ask", name: ToolNames.askSupervisor,
                            argumentsJSON: args)
        let task = makeTask(toolCalls: [call])
        installTask(task)

        let result = makeResult(
            providerID: "tc_ask", toolName: ToolNames.askSupervisor,
            argumentsJSON: args,
            outputJSON: #"{"ok":true,"data":{"question":"Which database?","status":"waiting"}}"#,
            signal: .supervisorQuestion("Which database?")
        )

        var conversation: [ChatMessage] = []
        let outcome = await drive(
            calls: [call], results: [result], task: task,
            conversation: &conversation, tracker: ToolCallTracker()
        )

        XCTAssertTrue(outcome.shouldStopForSupervisor)
        XCTAssertEqual(outcome.supervisorQuestion, "Which database?")
        XCTAssertEqual(outcome.supervisorToolCallProviderIDs.first, "tc_ask")
        XCTAssertEqual(conversation.count, 1,
                       "A supervisor question still gets its ordinary tool turn (chain protocol)")
        XCTAssertEqual(card(callID)?.isError ?? nil, false)
    }

    /// Two `ask_supervisor` calls in one batch merge into one blank-line-separated
    /// question, and the provider id stays the FIRST one — the answer is delivered
    /// against a single tool_call, so a later id would resolve the wrong call.
    func testProcessToolResults_twoSupervisorQuestions_mergeAndKeepFirstProviderID() async {
        let a = UUID()
        let b = UUID()
        let calls = [
            makeCall(id: a, providerID: "tc_a", name: ToolNames.askSupervisor,
                     argumentsJSON: #"{"question":"Q1"}"#),
            makeCall(id: b, providerID: "tc_b", name: ToolNames.askSupervisor,
                     argumentsJSON: #"{"question":"Q2"}"#),
        ]
        let task = makeTask(toolCalls: calls)
        installTask(task)

        let results = [
            makeResult(providerID: "tc_a", toolName: ToolNames.askSupervisor,
                       argumentsJSON: #"{"question":"Q1"}"#,
                       outputJSON: #"{"ok":true,"data":{"status":"waiting"}}"#,
                       signal: .supervisorQuestion("Q1")),
            makeResult(providerID: "tc_b", toolName: ToolNames.askSupervisor,
                       argumentsJSON: #"{"question":"Q2"}"#,
                       outputJSON: #"{"ok":true,"data":{"status":"waiting"}}"#,
                       signal: .supervisorQuestion("Q2")),
        ]

        var conversation: [ChatMessage] = []
        let outcome = await drive(
            calls: calls, results: results, task: task,
            conversation: &conversation, tracker: ToolCallTracker()
        )

        XCTAssertEqual(outcome.supervisorQuestion, "Q1\n\nQ2")
        XCTAssertEqual(outcome.supervisorToolCallProviderIDs.first, "tc_a",
                       "The pinned provider id must be the FIRST non-empty question's")
        XCTAssertTrue(outcome.shouldStopForSupervisor)
        XCTAssertEqual(conversation.count, 2)
    }

    /// A whitespace-only question is not a question. Recording it would park the step
    /// at `.needsSupervisorInput` showing the human a blank prompt with no way forward.
    func testProcessToolResults_whitespaceOnlySupervisorQuestion_isIgnored() async {
        let callID = UUID()
        let args = #"{"question":"   "}"#
        let call = makeCall(id: callID, providerID: "tc_0", name: ToolNames.askSupervisor,
                            argumentsJSON: args)
        let task = makeTask(toolCalls: [call])
        installTask(task)

        let result = makeResult(
            providerID: "tc_0", toolName: ToolNames.askSupervisor,
            argumentsJSON: args,
            outputJSON: #"{"ok":true,"data":{"status":"waiting"}}"#,
            signal: .supervisorQuestion("  \n\t ")
        )

        var conversation: [ChatMessage] = []
        let outcome = await drive(
            calls: [call], results: [result], task: task,
            conversation: &conversation, tracker: ToolCallTracker()
        )

        XCTAssertFalse(outcome.shouldStopForSupervisor,
                       "A blank question must not park the step")
        XCTAssertNil(outcome.supervisorQuestion)
        XCTAssertNil(outcome.supervisorToolCallProviderIDs.first)
        XCTAssertEqual(conversation.count, 1, "The tool turn is still appended (chain protocol)")
    }

    /// Side effects run for EVERY result in the batch, including results that share the
    /// batch with a supervisor question. Pins the documented contract above
    /// `processRegularToolResult`'s side-effect block.
    func testProcessToolResults_supervisorQuestionBesideArtifact_bothAreProcessed() async {
        let askID = UUID()
        let artID = UUID()
        let calls = [
            makeCall(id: askID, providerID: "tc_ask", name: ToolNames.askSupervisor,
                     argumentsJSON: #"{"question":"Ship it?"}"#),
            makeCall(id: artID, providerID: "tc_art", name: ToolNames.createArtifact,
                     argumentsJSON: #"{"name":"Engineering Notes"}"#),
        ]
        let task = makeTask(toolCalls: calls, expectedArtifacts: ["Engineering Notes"])
        installTask(task)

        let results = [
            makeResult(providerID: "tc_ask", toolName: ToolNames.askSupervisor,
                       argumentsJSON: #"{"question":"Ship it?"}"#,
                       outputJSON: #"{"ok":true,"data":{"status":"waiting"}}"#,
                       signal: .supervisorQuestion("Ship it?")),
            makeResult(providerID: "tc_art", toolName: ToolNames.createArtifact,
                       argumentsJSON: #"{"name":"Engineering Notes"}"#,
                       outputJSON: #"{"ok":true,"data":{"name":"Engineering Notes"}}"#,
                       signal: .artifact(name: "Engineering Notes", content: "# Notes", format: nil)),
        ]

        var conversation: [ChatMessage] = []
        let outcome = await drive(
            calls: calls, results: results, task: task,
            conversation: &conversation, tracker: ToolCallTracker()
        )

        XCTAssertTrue(outcome.shouldStopForSupervisor)
        let artifacts = currentStep()?.artifacts ?? []
        XCTAssertEqual(artifacts.count, 1,
                       "The artifact in the same batch as a supervisor question must still persist")
        XCTAssertEqual(artifacts.first?.name, "Engineering Notes")
    }

    // MARK: - Group E: artifact signal

    /// `.artifact` routes through the regular path, whose `processCreateArtifactResult`
    /// side effect resolves the LLM's embellished name against the step's expected
    /// artifacts, writes the markdown to disk, and appends the `Artifact` to the step.
    ///
    /// The embellished name exercises `resolveArtifactName`'s slug-prefix pass:
    /// slugify("Design Spec for Calculator") == "design_spec_for_calculator", which
    /// has the prefix "design_spec".
    func testProcessToolResults_artifactSignal_resolvesNameAndPersistsOntoStep() async {
        let callID = UUID()
        let args = #"{"name":"Design Spec for Calculator"}"#
        let call = makeCall(id: callID, providerID: "tc_0", name: ToolNames.createArtifact,
                            argumentsJSON: args)
        let task = makeTask(toolCalls: [call], expectedArtifacts: ["Design Spec"])
        installTask(task)

        let result = makeResult(
            providerID: "tc_0", toolName: ToolNames.createArtifact,
            argumentsJSON: args,
            outputJSON: #"{"ok":true,"data":{"name":"Design Spec for Calculator"}}"#,
            signal: .artifact(name: "Design Spec for Calculator",
                              content: "# Design\n\nBody.", format: nil)
        )

        var conversation: [ChatMessage] = []
        _ = await drive(
            calls: [call], results: [result], task: task,
            conversation: &conversation, tracker: ToolCallTracker()
        )

        let artifacts = currentStep()?.artifacts ?? []
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts.first?.name, "Design Spec",
                       "The embellished name must be normalised to the expected artifact")
        let relativePath = artifacts.first?.relativePath ?? ""
        XCTAssertTrue(relativePath.contains("artifact_design_spec.md"),
                      "The on-disk slug must follow the RESOLVED name, not the LLM's. Got: \(relativePath)")
        XCTAssertEqual(card(callID)?.isError ?? nil, false)
    }

    /// A FAILED `create_artifact` must not persist an artifact — the guard is
    /// `!result.isError`. A red card that still deposits a deliverable would let a
    /// producing role auto-complete on an artifact the tool never wrote.
    func testProcessToolResults_artifactSignalOnErrorResult_persistsNothing() async {
        let callID = UUID()
        let args = #"{"name":"Design Spec"}"#
        let call = makeCall(id: callID, providerID: "tc_0", name: ToolNames.createArtifact,
                            argumentsJSON: args)
        let task = makeTask(toolCalls: [call], expectedArtifacts: ["Design Spec"])
        installTask(task)

        let result = makeResult(
            providerID: "tc_0", toolName: ToolNames.createArtifact,
            argumentsJSON: args,
            outputJSON: #"{"ok":false,"error":{"code":"INVALID_ARGS","message":"content is required"}}"#,
            isError: true,
            signal: .artifact(name: "Design Spec", content: "", format: nil)
        )

        var conversation: [ChatMessage] = []
        _ = await drive(
            calls: [call], results: [result], task: task,
            conversation: &conversation, tracker: ToolCallTracker()
        )

        let artifacts = currentStep()?.artifacts ?? []
        XCTAssertTrue(artifacts.isEmpty,
                      "A failed create_artifact must not deposit a deliverable")
        XCTAssertEqual(card(callID)?.isError ?? nil, true)
        XCTAssertEqual(conversation.count, 2, "The error still earns a guidance turn")
    }

    // MARK: - Group F: scratchpad side effect

    /// `update_scratchpad` writes the step's scratchpad and — for an ordinary role —
    /// says nothing on either surface.
    ///
    /// The acknowledgement used to ship unconditionally: on the wire, where the
    /// tool's own `{ok:true,…}` envelope already confirms the write, and in the
    /// feed, where the tool card already renders `→ ok`. Neither reader learned
    /// anything from it, and its wording ("Plan updated. Continue with the next
    /// step.") described a planning phase most roles do not have.
    ///
    /// RED: restore the unconditional `conversationMessages.append` → the wire
    /// assertion fails; restore the unconditional `appendLLMMessage` → the feed one does.
    func testProcessToolResults_scratchpadResult_updatesScratchpadAndSaysNothing() async {
        let callID = UUID()
        let args = #"{"content":"1. Read the sources\n2. Edit the parser"}"#
        let call = makeCall(id: callID, providerID: "tc_0", name: ToolNames.updateScratchpad,
                            argumentsJSON: args)
        let task = makeTask(toolCalls: [call])
        installTask(task)

        let result = makeResult(
            providerID: "tc_0", toolName: ToolNames.updateScratchpad,
            argumentsJSON: args, outputJSON: #"{"ok":true,"data":{"status":"saved"}}"#
        )

        var conversation: [ChatMessage] = []
        _ = await drive(
            calls: [call], results: [result], task: task,
            conversation: &conversation, tracker: ToolCallTracker()
        )

        let scratchpad: String? = currentStep()?.scratchpad ?? nil
        XCTAssertEqual(scratchpad, "1. Read the sources\n2. Edit the parser")

        XCTAssertEqual(conversation.count, 1,
                       "tool turn only — the model already has the tool envelope; got: "
                           + "\(conversation.map { $0.content ?? "" })")
        guard conversation.count == 1 else { return }
        XCTAssertEqual(conversation[0].role, .tool)

        // `llmConversation` still carries the tool-call record itself — that is the
        // card the feed renders. What must NOT be there is a note beside it.
        let notes = (currentStep()?.llmConversation ?? [])
            .filter { $0.sourceContext == .toolAcknowledgement }
        XCTAssertTrue(notes.isEmpty,
                      "the tool card already renders `→ ok`; a note would duplicate it. Got: "
                          + "\(notes.map { $0.content })")
    }

    // MARK: - Group G: the explicit `.teamCreation` arm

    /// `create_team` has its own `case` in the dispatcher purely to document that it is
    /// processed as an ORDINARY result: the model sees the envelope, but no team is
    /// installed (installation belongs to `runTeamGeneration`). Reaching this arm at all
    /// means a misconfigured role called a tool `availableToRoles == false` filters out.
    func testProcessToolResults_teamCreationSignal_processedAsRegular_installsNoTeam() async {
        let callID = UUID()
        let args = #"{"team_config":{}}"#
        let call = makeCall(id: callID, providerID: "tc_0", name: ToolNames.createTeam,
                            argumentsJSON: args)
        let task = makeTask(toolCalls: [call])
        installTask(task)
        XCTAssertNil(installedGeneratedTeam(), "precondition: no generated team yet")

        let config = GeneratedTeamConfig(
            name: "Rogue Team",
            description: "Should never be installed from here",
            roles: [GeneratedTeamConfig.RoleConfig(name: "Worker", prompt: "Do the work.")],
            artifacts: [GeneratedTeamConfig.ArtifactConfig(
                name: "Result", description: "The output", icon: nil)],
            supervisorRequires: []
        )
        let output = #"{"ok":true,"data":{"team":"Rogue Team"}}"#
        let result = makeResult(
            providerID: "tc_0", toolName: ToolNames.createTeam,
            argumentsJSON: args, outputJSON: output,
            signal: .teamCreation(config: config)
        )

        var conversation: [ChatMessage] = []
        let outcome = await drive(
            calls: [call], results: [result], task: task,
            conversation: &conversation, tracker: ToolCallTracker()
        )

        XCTAssertNil(installedGeneratedTeam(),
                     "The runtime dispatcher must NEVER install a generated team")
        XCTAssertEqual(conversation.count, 1, "Regular path ⇒ exactly one tool turn")
        guard conversation.count == 1 else { return }
        XCTAssertEqual(conversation[0].content, output,
                       "The model still sees the envelope verbatim")
        XCTAssertEqual(card(callID)?.resultJSON ?? nil, output)
        XCTAssertFalse(outcome.shouldStopForSupervisor)
    }

    // MARK: - Group H: the collaboration-deferred branch (`continue`)

    /// A collaboration signal must be routed to `appendCollaborationResult` and then
    /// `continue` — never fall through to `processRegularToolResult`.
    ///
    /// The discriminator is the `.tool` turn's CONTENT: the regular path would append the
    /// synchronous `{"status":"pending"}` placeholder (the handler's `outputJSON`), while
    /// the deferred path appends the handler's REAL envelope. `cancel_delegation` with no
    /// registered in-flight child fails instantly with `INVALID_ARGS` — no network.
    func testProcessToolResults_collaborationSignal_takesDeferredPath_notTheRegularOne() async {
        let callID = UUID()
        let placeholder = #"{"ok":true,"data":{"status":"pending"}}"#
        let args = #"{"child_task_id":4242}"#
        let call = makeCall(id: callID, providerID: "tc_0", name: ToolNames.cancelDelegation,
                            argumentsJSON: args, resultJSON: placeholder, isError: false)
        let task = makeTask(toolCalls: [call])
        installTask(task)
        // Deliberately NOT registering an active delegation ⇒ instant INVALID_ARGS.

        let result = makeResult(
            providerID: "tc_0", toolName: ToolNames.cancelDelegation,
            argumentsJSON: args, outputJSON: placeholder,
            signal: .cancelDelegation(childTaskID: 4242, reason: nil)
        )

        var conversation: [ChatMessage] = []
        _ = await drive(
            calls: [call], results: [result], task: task,
            conversation: &conversation, tracker: ToolCallTracker()
        )

        XCTAssertEqual(conversation.count, 1)
        guard conversation.count == 1 else { return }
        let wire = conversation[0].content ?? ""
        XCTAssertTrue(wire.contains("INVALID_ARGS"),
                      "The deferred handler's real envelope must reach the model. Got: \(wire)")
        XCTAssertFalse(wire.contains("\"status\":\"pending\""),
                       "The synchronous placeholder must NOT be what the model sees — that would mean the regular path ran")

        // The card is reflected red by `commitCollaborationOutcome`.
        XCTAssertEqual(card(callID)?.isError ?? nil, true)
        let reflected: String? = card(callID)?.resultJSON ?? nil
        XCTAssertTrue(reflected?.contains("INVALID_ARGS") ?? false,
                      "The card must carry the real error envelope. Got: \(reflected ?? "nil")")
    }

    /// Index alignment: the third loop walks `results.enumerated()` and reaches back into
    /// `resolvedToolCalls[idx]` for the persisted row id. Putting the collaboration call
    /// SECOND means an off-by-one would reflect the delegation error onto the `list_files`
    /// card — visible here, invisible in any single-call test.
    func testProcessToolResults_mixedBatch_dispatchesEachResultAgainstItsOwnCall() async {
        let plainID = UUID()
        let collabID = UUID()
        let placeholder = #"{"ok":true,"data":{"status":"pending"}}"#
        let calls = [
            makeCall(id: plainID, providerID: "tc_plain", name: ToolNames.listFiles,
                     argumentsJSON: #"{"path":"."}"#),
            makeCall(id: collabID, providerID: "tc_collab", name: ToolNames.cancelDelegation,
                     argumentsJSON: #"{"child_task_id":99}"#,
                     resultJSON: placeholder, isError: false),
        ]
        let task = makeTask(toolCalls: calls)
        installTask(task)

        let plainOutput = #"{"ok":true,"data":{"count":0,"files":[],"dirs":[]}}"#
        let results = [
            makeResult(providerID: "tc_plain", toolName: ToolNames.listFiles,
                       argumentsJSON: #"{"path":"."}"#, outputJSON: plainOutput),
            makeResult(providerID: "tc_collab", toolName: ToolNames.cancelDelegation,
                       argumentsJSON: #"{"child_task_id":99}"#, outputJSON: placeholder,
                       signal: .cancelDelegation(childTaskID: 99, reason: nil)),
        ]

        let tracker = ToolCallTracker()
        var conversation: [ChatMessage] = []
        _ = await drive(
            calls: calls, results: results, task: task,
            conversation: &conversation, tracker: tracker
        )

        // Plain card keeps its own (successful) result.
        XCTAssertEqual(card(plainID)?.resultJSON ?? nil, plainOutput)
        XCTAssertEqual(card(plainID)?.isError ?? nil, false,
                       "The delegation failure must not be reflected onto the neighbouring call")

        // Collaboration card carries the deferred failure.
        XCTAssertEqual(card(collabID)?.isError ?? nil, true)
        let reflected: String? = card(collabID)?.resultJSON ?? nil
        XCTAssertTrue(reflected?.contains("INVALID_ARGS") ?? false,
                      "Got: \(reflected ?? "nil")")

        // Both branches contributed one wire turn, in emit order.
        XCTAssertEqual(conversation.count, 2)
        guard conversation.count == 2 else { return }
        XCTAssertEqual(conversation[0].toolCallID, "tc_plain")
        XCTAssertEqual(conversation[0].content, plainOutput)
        XCTAssertEqual(conversation[1].toolCallID, "tc_collab")
        XCTAssertTrue(conversation[1].content?.contains("INVALID_ARGS") ?? false)

        // Pre-record loop records BOTH (neither signal is finalized asynchronously).
        XCTAssertEqual(tracker.recentCalls(limit: .max).count, 2)
    }

    // MARK: - Routing predicates used by the loop

    /// The loop's two gating predicates, pinned against the signals these tests drive so a
    /// re-route (e.g. `.artifact` accidentally added to the deferred list) is loud here
    /// rather than showing up as a mysteriously empty step.
    func testRoutingPredicates_matchTheBranchesExercisedAbove() async {
        let cancel: ToolSignal = .cancelDelegation(childTaskID: 1, reason: nil)
        let artifact: ToolSignal = .artifact(name: "A", content: "c", format: nil)
        let question: ToolSignal = .supervisorQuestion("q")
        let vision: ToolSignal = .visionAnalysis(imagePath: "a.png", prompt: "p")

        XCTAssertTrue(LLMExecutionService.isCollaborationDeferredSignal(cancel))
        XCTAssertFalse(LLMExecutionService.isCollaborationDeferredSignal(artifact))
        XCTAssertFalse(LLMExecutionService.isCollaborationDeferredSignal(question))
        XCTAssertFalse(LLMExecutionService.isCollaborationDeferredSignal(nil))

        XCTAssertTrue(LLMExecutionService.shouldRecordInTrackerPreFinalize(signal: nil))
        XCTAssertTrue(LLMExecutionService.shouldRecordInTrackerPreFinalize(signal: question))
        XCTAssertFalse(
            LLMExecutionService.shouldRecordInTrackerPreFinalize(signal: vision),
            "Vision writes an interim placeholder here; its finalizer records the real envelope")
    }

    // MARK: - Harness

    private func makeCall(
        id: UUID,
        providerID: String,
        name: String,
        argumentsJSON: String,
        resultJSON: String? = nil,
        isError: Bool? = nil
    ) -> StepToolCall {
        StepToolCall(
            id: id,
            providerID: providerID,
            name: name,
            argumentsJSON: argumentsJSON,
            resultJSON: resultJSON,
            isError: isError
        )
    }

    private func makeResult(
        providerID: String,
        toolName: String,
        argumentsJSON: String,
        outputJSON: String,
        isError: Bool = false,
        signal: ToolSignal? = nil
    ) -> ToolExecutionResult {
        ToolExecutionResult(
            providerID: providerID,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            outputJSON: outputJSON,
            isError: isError,
            signal: signal
        )
    }

    private func makeTask(
        toolCalls: [StepToolCall],
        expectedArtifacts: [String] = []
    ) -> NTMSTask {
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "Software Engineer",
            expectedArtifacts: expectedArtifacts,
            status: .running,
            toolCalls: toolCalls
        )
        let run = Run(id: 0, steps: [step])
        return NTMSTask(id: taskID, title: "T", supervisorTask: "Build it", runs: [run])
    }

    /// Installs the task on the mock AND registers the step's execution state. Both are
    /// required: every persisting helper on the service is gated on `isExecutionLive`.
    private func installTask(_ task: NTMSTask) {
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    private func currentStep() -> StepExecution? {
        mockDelegate.taskToMutate?.runs.first?.steps.first { $0.id == stepID }
    }

    private func card(_ id: UUID) -> StepToolCall? {
        currentStep()?.toolCalls.first { $0.id == id }
    }

    /// `flatMap`, not `taskToMutate?.generatedTeam ?? nil` — the latter is a `Team??`
    /// whose flattening overload is ambiguous inside `XCTAssertNil`'s `Any?` parameter.
    private func installedGeneratedTeam() -> Team? {
        mockDelegate.taskToMutate.flatMap { $0.generatedTeam }
    }

    private func drive(
        calls: [StepToolCall],
        results: [ToolExecutionResult],
        task: NTMSTask,
        conversation: inout [ChatMessage],
        tracker: ToolCallTracker
    ) async -> LLMExecutionService.ToolResultsOutcome {
        await service.processToolResults(
            resolvedToolCalls: calls,
            results: results,
            stepID: stepID,
            roleForMessage: .softwareEngineer,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            assistantContent: "",
            client: ProcessToolResultsStubClient(),
            config: LLMConfig(),
            tracker: tracker,
            memoryStore: MemoryTagStore(),
            conversationMessages: &conversation,
            networkLogger: nil
        )
    }
}

// MARK: - Stub LLM client
//
// Never reached by any path these tests drive: the only handler invoked is
// `handleCancelDelegation`, whose no-active-child arm returns before any LLM call.
// It exists solely to satisfy the `client:` parameter.

private final class ProcessToolResultsStubClient: LLMClient, @unchecked Sendable {
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

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
    func loadModel(provider _: LLMProvider, modelName _: String, baseURLString _: String) async throws -> String { "" }
    func unloadModel(provider _: LLMProvider, instanceID _: String, baseURLString _: String) async throws {}
    func listLoadedInstances(provider _: LLMProvider, baseURLString _: String) async throws -> LoadedInstanceListing { .listed([]) }
}
