import XCTest

@testable import NanoTeams

/// Pins that a Supervisor answer reaches the model EXACTLY ONCE.
///
/// Reported 2026-08-02 (`network_log.json`, Startup team, `startup_software_engineer`):
/// the role submitted `create_artifact("Engineering Notes")` twice. The wire of the
/// request at 21:42:42 carried the block
///
///     [Tool Result]
///     {"ok":true,"tool":"ask_supervisor","response":"Approved — run `swift build …`.
///      Report the final build status line in your report."}
///
/// TWICE — once resolving the pending `ask_supervisor`, and again right after the result
/// of the first `create_artifact`. The model read the second copy as a fresh instruction,
/// retried `bash` (denied again) and re-submitted the report.
///
/// Root cause: `LLMExecutionService+StepLifecycle` derived "there is an answer to deliver"
/// from `step.supervisorAnswer`, a DISPLAY field that survives until the next park. Any
/// later re-entry of the same step — an ordinary pause/resume was enough — took the
/// supervisor-continuation branch again and appended the identical envelope.
/// `StepExecution.supervisorAnswerPendingDelivery` now carries that meaning and is
/// consumed inside `persistWireTranscript`.
@MainActor
final class SupervisorAnswerDeliveryOnceTests: XCTestCase {

    var service: LLMExecutionService!
    var mockDelegate: MockLLMExecutionDelegate!
    var stubClient: CapturingStubLLMClient!
    var tempDir: URL!

    private let answerText = "Approved — run `swift build` and report the final status line."

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let stub = CapturingStubLLMClient()
        stubClient = stub
        service = LLMExecutionService(
            repository: NTMSRepository(),
            clientFactory: { stub }
        )
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        mockDelegate.globalLLMConfig = LLMConfig(provider: .lmStudio)
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        stubClient = nil
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: - The reported bug

    /// RED against the pre-fix code: the second entry appends the answer envelope a
    /// second time, so `answerEnvelopeCount(in: wire2)` is 2.
    func testAnswerIsDeliveredOnce_evenWhenTheStepReEntersAfterDoingWork() async throws {
        let taskID = 501
        let stepID = "swe_delivery_once"
        mockDelegate.taskToMutate = makeParkedThenAnsweredTask(taskID: taskID, stepID: stepID)

        // First entry: the parked step is answered and resumed.
        try await runOneEntry(stepID: stepID, taskID: taskID, expectingCallIndex: 0)
        XCTAssertEqual(
            answerEnvelopeCount(in: stubClient.capturedCalls[0].messages), 1,
            "The answer must reach the model on the entry that follows the answer")
        try await waitUntil { self.persistedStep(stepID)?.wireTranscript.isEmpty == false }
        XCTAssertFalse(
            persistedStep(stepID)?.supervisorAnswerPendingDelivery ?? true,
            "persistWireTranscript stores the transcript that already carries the answer, "
                + "so it must consume the delivery flag in the same mutation")

        // The role then did real work (in the reported run: a denied `bash` and a
        // `create_artifact`). That work lands in the transcript the next re-entry replays.
        appendToPersistedTranscript(
            stepID: stepID,
            ChatMessage(
                role: .tool,
                content: #"{"ok":true,"data":{"artifact":"Engineering Notes","status":"created"}}"#))

        // Second entry — a pause/resume, an engine re-start, whatever. Nothing new was
        // asked, so nothing new may be appended.
        try await runOneEntry(stepID: stepID, taskID: taskID, expectingCallIndex: 1)
        let wire2 = stubClient.capturedCalls[1].messages
        XCTAssertEqual(
            answerEnvelopeCount(in: wire2), 1,
            "The already-delivered answer must NOT be appended again — a second copy reads "
                + "as a fresh instruction and the role re-executes it (duplicate create_artifact)")
        XCTAssertTrue(
            wire2.contains { $0.content?.contains("Engineering Notes") == true },
            "The re-entry must still replay the work done after the answer")
    }

    /// The in-loop autonomous path (`handleSupervisorAutoAnswer`) puts the answer into the
    /// live conversation itself and returns `.continueLoop` — the step never suspends, so
    /// the re-entry seam has nothing to hand over. Arming the flag there would make a later
    /// pause/resume inject the answer for the first time, out of nowhere.
    func testAutoAnswerPath_neverArmsDelivery() async throws {
        let taskID = 502
        let stepID = "swe_auto_answer"
        mockDelegate.taskToMutate = makeFreshRunningTask(taskID: taskID, stepID: stepID)

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0)
        try await waitUntil { self.stubClient.capturedCalls.count >= 1 }
        await service.recordAutoSupervisorAnswer(
            stepID: stepID, taskID: taskID,
            question: "Approve running the build?", answer: answerText)

        XCTAssertEqual(persistedStep(stepID)?.supervisorAnswer, answerText)
        XCTAssertFalse(
            persistedStep(stepID)?.supervisorAnswerPendingDelivery ?? true,
            "The in-loop path delivers the answer itself; the re-entry seam must stay disarmed")

        await service.cancelStepExecution(stepID: stepID, taskID: taskID)
        try await waitUntil { self.persistedStep(stepID)?.wireTranscript.isEmpty == false }

        try await runOneEntry(stepID: stepID, taskID: taskID, expectingCallIndex: 1)
        XCTAssertEqual(
            answerEnvelopeCount(in: stubClient.capturedCalls[1].messages), 0,
            "A pause/resume after an in-loop auto-answer must not synthesize an "
                + "`ask_supervisor` result the step never suspended for")
    }

    /// A SECOND round of Q&A must deliver again — including when the new answer is
    /// byte-identical to the previous one. That is why the flag exists instead of a
    /// "is this text already on the wire?" comparison: auto-answer paths repeat themselves.
    func testSecondRound_reArmsDelivery_evenWhenTheAnswerTextRepeats() async throws {
        let taskID = 503
        let stepID = "swe_second_round"
        mockDelegate.taskToMutate = makeParkedThenAnsweredTask(taskID: taskID, stepID: stepID)

        // Entry 1 — round-1 answer delivered; the transcript now carries one envelope.
        try await runOneEntry(stepID: stepID, taskID: taskID, expectingCallIndex: 0)
        try await waitUntil { self.persistedStep(stepID)?.wireTranscript.isEmpty == false }
        XCTAssertFalse(persistedStep(stepID)?.supervisorAnswerPendingDelivery ?? true)

        // Entry 2 — the role asks again and the step parks.
        try await startAndAwaitRequest(stepID: stepID, taskID: taskID, expectingCallIndex: 1)
        let parked = await service.setNeedsSupervisorInput(
            stepID: stepID, taskID: taskID, question: "Approve running the build once more?")
        XCTAssertTrue(parked)
        XCTAssertNil(persistedStep(stepID)?.supervisorAnswer, "a re-park clears the stale answer")
        XCTAssertFalse(persistedStep(stepID)?.supervisorAnswerPendingDelivery ?? true)
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)

        // The Supervisor repeats the exact same words.
        _ = await mockDelegate.mutateTask(taskID: taskID) { task in
            StepMessagingService.answerSupervisorQuestion(
                stepID: stepID, answer: self.answerText, in: &task)
        }
        XCTAssertTrue(
            persistedStep(stepID)?.supervisorAnswerPendingDelivery ?? false,
            "A fresh answer re-arms delivery regardless of matching the previous text")

        // Entry 3 — round-2 answer must be delivered on top of the round-1 envelope
        // already sitting in the replayed transcript.
        try await runOneEntry(stepID: stepID, taskID: taskID, expectingCallIndex: 2)
        XCTAssertEqual(
            answerEnvelopeCount(in: stubClient.capturedCalls[2].messages), 2,
            "Round 2 appends its own envelope on top of the round-1 envelope already in "
                + "the replayed transcript")
    }

    /// `hasRevisionFeedback` used to require `effectiveSupervisorAnswer == nil`, so a step
    /// that had EVER been answered could never take the revision branch — "Request Changes"
    /// replayed the stale answer instead of the feedback.
    func testRevisionAfterAnAnsweredQuestion_deliversTheFeedback() async throws {
        let taskID = 504
        let stepID = "swe_revision_after_answer"
        var task = makeParkedThenAnsweredTask(taskID: taskID, stepID: stepID)
        // The answer already reached the model in a previous entry.
        task.runs[0].steps[0].supervisorAnswerPendingDelivery = false
        task.runs[0].steps[0].wireTranscript = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "## Supervisor Task\n\nImplement M2."),
        ]
        task.runs[0].steps[0].revisionComment = "Cover the empty-history case too."
        mockDelegate.taskToMutate = task

        try await runOneEntry(stepID: stepID, taskID: taskID, expectingCallIndex: 0)
        let wire = stubClient.capturedCalls[0].messages

        XCTAssertEqual(
            answerEnvelopeCount(in: wire), 0,
            "A delivered answer must not outrank a fresh revision")
        XCTAssertEqual(wire.last?.role, .user)
        XCTAssertTrue(
            wire.last?.content?.contains("Cover the empty-history case too.") == true,
            "The revision feedback is the turn the re-entry appends")
    }

    // MARK: - Corners: what arms the flag

    /// An answer can be attachments with no prose — `effectiveSupervisorAnswer` is
    /// non-nil there, so the delivery must arm. Keying the flag on the text alone would
    /// silently drop a file-only answer.
    func testAttachmentOnlyAnswer_armsDelivery() {
        var task = makeParkedTask(taskID: 510, stepID: "swe_attach")
        _ = StepMessagingService.answerSupervisorQuestion(
            stepID: "swe_attach", answer: "", attachmentPaths: ["notes/spec.md"], in: &task)

        let step = task.runs[0].steps[0]
        XCTAssertNil(step.supervisorAnswer, "empty prose still stores nil")
        XCTAssertNotNil(step.effectiveSupervisorAnswer, "…but the attachments are the answer")
        XCTAssertTrue(step.supervisorAnswerPendingDelivery)
    }

    func testEmptyAnswer_doesNotArmDelivery() {
        var task = makeParkedTask(taskID: 511, stepID: "swe_empty")
        _ = StepMessagingService.answerSupervisorQuestion(
            stepID: "swe_empty", answer: "", in: &task)

        XCTAssertFalse(task.runs[0].steps[0].supervisorAnswerPendingDelivery)
    }

    /// A whitespace-only answer trims to empty and stores `nil`; arming on it would leave
    /// the continuation branch believing it had something to deliver forever.
    func testWhitespaceOnlyAnswer_doesNotArmDelivery() {
        var task = makeParkedTask(taskID: 512, stepID: "swe_blank")
        _ = StepMessagingService.answerSupervisorQuestion(
            stepID: "swe_blank", answer: "   \n\t ", in: &task)

        XCTAssertNil(task.runs[0].steps[0].supervisorAnswer)
        XCTAssertFalse(task.runs[0].steps[0].supervisorAnswerPendingDelivery)
    }

    /// The flag is orthogonal to `supervisorAnswerWasAuto`: an Autovisor or delegating
    /// parent answering on the human's behalf still parked the step, so its answer still
    /// has to be handed to the wire on re-entry.
    func testAutomatedButParkedAnswer_armsDelivery() {
        var task = makeParkedTask(taskID: 513, stepID: "swe_auto_parked")
        _ = StepMessagingService.answerSupervisorQuestion(
            stepID: "swe_auto_parked", answer: answerText, isAutoAnswer: true, in: &task)

        let step = task.runs[0].steps[0]
        XCTAssertTrue(step.supervisorAnswerWasAuto)
        XCTAssertTrue(
            step.supervisorAnswerPendingDelivery,
            "`wasAuto` is a badge for the feed, not a statement about wire delivery")
    }

    /// The second writer of `supervisorAnswer` must arm identically — a caller reaching
    /// the answer through `TaskMutationService` instead of `StepMessagingService` cannot
    /// be the one that silently skips delivery.
    func testTaskMutationServiceWriter_armsDelivery() {
        var task = makeParkedTask(taskID: 514, stepID: "swe_tms")
        TaskMutationService.setSupervisorAnswer(answerText, stepID: "swe_tms", in: &task)
        XCTAssertTrue(task.runs[0].steps[0].supervisorAnswerPendingDelivery)

        TaskMutationService.setSupervisorAnswer("", stepID: "swe_tms", in: &task)
        XCTAssertFalse(task.runs[0].steps[0].supervisorAnswerPendingDelivery)
    }

    // MARK: - Corners: what consumes it

    /// A step with nothing to replay falls back to the freshly built conversation, where
    /// `PromptBuilder` renders the Q&A itself — the answer DID reach the model, just not
    /// as an envelope. The flag must be consumed anyway, or the next re-entry (which by
    /// then has a transcript) would append the envelope on top.
    func testFreshStepWithNoHistory_stillConsumesTheFlag() async throws {
        let taskID = 520
        let stepID = "swe_no_history"
        var task = makeParkedTask(taskID: taskID, stepID: stepID)
        // `TaskMutationService`, not `StepMessagingService`: the latter also appends the
        // `.supervisorAnswer` display message, which would give `ConversationReplay`
        // something to rebuild from and defeat the "no history" premise.
        TaskMutationService.setSupervisorAnswer(answerText, stepID: stepID, in: &task)
        mockDelegate.taskToMutate = task
        XCTAssertNil(
            ConversationReplay.resume(from: persistedStep(stepID)!),
            "precondition: nothing replayable")

        try await runOneEntry(stepID: stepID, taskID: taskID, expectingCallIndex: 0)
        try await waitUntil { self.persistedStep(stepID)?.wireTranscript.isEmpty == false }
        XCTAssertFalse(persistedStep(stepID)?.supervisorAnswerPendingDelivery ?? true)

        try await runOneEntry(stepID: stepID, taskID: taskID, expectingCallIndex: 1)
        XCTAssertEqual(
            answerEnvelopeCount(in: stubClient.capturedCalls[1].messages), 0,
            "the answer already rode in the built prompt — appending an envelope now would "
                + "be a second delivery")
    }

    /// `persistWireTranscript` short-circuits on an empty message list. It must not
    /// consume the flag there: nothing was stored, so nothing carries the answer, and
    /// keeping it pending is the fail-safe direction (deliver again beats never deliver).
    func testEmptyTranscriptPersist_leavesTheFlagArmed() async throws {
        let taskID = 521
        let stepID = "swe_empty_persist"
        var task = makeParkedTask(taskID: taskID, stepID: stepID)
        _ = StepMessagingService.answerSupervisorQuestion(
            stepID: stepID, answer: answerText, in: &task)
        task.runs[0].steps[0].status = .running
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: task, runIndex: 0, stepIndex: 0)
        await service.persistWireTranscript(stepID: stepID, taskID: taskID, messages: [])

        XCTAssertTrue(persistedStep(stepID)?.supervisorAnswerPendingDelivery ?? false)
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)
    }

    /// The flag is per-step. Persisting one step's transcript must not spend a sibling's
    /// pending answer — parallel-ready roles run concurrently on the same run.
    func testPersistingOneStep_doesNotConsumeASiblingsFlag() async throws {
        let taskID = 522
        var task = makeParkedTask(taskID: taskID, stepID: "swe_a")
        var sibling = StepExecution(
            id: "swe_b", role: .codeReviewer, title: "CR Step", status: .running)
        sibling.supervisorAnswer = answerText
        sibling.supervisorAnswerPendingDelivery = true
        task.runs[0].steps.append(sibling)
        _ = StepMessagingService.answerSupervisorQuestion(
            stepID: "swe_a", answer: answerText, in: &task)
        task.runs[0].steps[0].status = .running
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: "swe_a", taskID: taskID, task: task, runIndex: 0, stepIndex: 0)
        await service.persistWireTranscript(
            stepID: "swe_a", taskID: taskID,
            messages: [ChatMessage(role: .user, content: "anything")])

        XCTAssertFalse(persistedStep("swe_a")?.supervisorAnswerPendingDelivery ?? true)
        XCTAssertTrue(
            persistedStep("swe_b")?.supervisorAnswerPendingDelivery ?? false,
            "the sibling never sent anything — its answer is still owed to it")
        await service.cancelStepExecution(stepID: "swe_a", taskID: taskID)
    }

    /// The Autovisor's idle park routes through `setNeedsSupervisorInput`, which nils the
    /// answer. The flag has to follow, or the park would leave a delivery armed for an
    /// answer that no longer exists.
    func testAutovisorIdlePark_disarmsDelivery() async throws {
        let taskID = 523
        let stepID = "manager_park"
        var task = makeParkedTask(taskID: taskID, stepID: stepID)
        _ = StepMessagingService.answerSupervisorQuestion(
            stepID: stepID, answer: answerText, in: &task)
        task.runs[0].steps[0].status = .running
        mockDelegate.taskToMutate = task
        XCTAssertTrue(persistedStep(stepID)?.supervisorAnswerPendingDelivery ?? false)

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: task, runIndex: 0, stepIndex: 0)
        await service.parkStepForEvents(stepID: stepID, taskID: taskID)

        XCTAssertNil(persistedStep(stepID)?.supervisorAnswer)
        XCTAssertFalse(persistedStep(stepID)?.supervisorAnswerPendingDelivery ?? true)
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)
    }

    // MARK: - Corners: the reader needs BOTH

    /// `supervisorAnswerPendingDelivery` alone is not enough — the branch also needs an
    /// answer to send. The pair is representable in isolation (a re-park that clears the
    /// answer, a hand-edited `task.json`), and an armed flag with nothing behind it must
    /// not synthesize an empty `ask_supervisor` result.
    func testArmedFlagWithNoAnswer_sendsNothing() async throws {
        let taskID = 524
        let stepID = "swe_armed_empty"
        var task = makeParkedTask(taskID: taskID, stepID: stepID)
        task.runs[0].steps[0].supervisorAnswerPendingDelivery = true
        task.runs[0].steps[0].wireTranscript = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "## Supervisor Task\n\nImplement M2."),
        ]
        mockDelegate.taskToMutate = task
        XCTAssertNil(task.runs[0].steps[0].effectiveSupervisorAnswer, "precondition")

        try await runOneEntry(stepID: stepID, taskID: taskID, expectingCallIndex: 0)
        let wire = stubClient.capturedCalls[0].messages
        XCTAssertFalse(
            wire.contains { $0.role == .tool },
            "no answer exists, so the continuation must not fabricate a tool result")
        XCTAssertEqual(wire.count, 2, "a plain replay of the transcript, nothing appended")
    }

    /// The `true`-without-an-answer state DISAGREES with the inference, so the encoder has
    /// to write it out; otherwise the decode would produce `false` and lose the arming.
    func testArmedFlagWithNoAnswer_survivesACodableRoundTrip() throws {
        var step = StepExecution(id: "swe_rt3", role: .softwareEngineer, title: "SWE Step")
        step.supervisorAnswerPendingDelivery = true

        let json = try encodeStep(step)
        XCTAssertTrue(json.contains("supervisorAnswerPendingDelivery"))
        XCTAssertTrue(try decodeStep(json).supervisorAnswerPendingDelivery)
    }

    // MARK: - Corners: the envelope itself

    /// The envelope must render byte-identically every time. It was built from a
    /// `[String: Any]` through a bare `JSONSerialization.data(withJSONObject:)`, whose key
    /// order is Swift's per-process-seeded hash order — and it was observed emitting
    /// `{"ok","response","tool"}` on one call and `{"tool","response","ok"}` on the next
    /// INSIDE ONE PROCESS. These bytes go on the wire and into `wireTranscript`, where the
    /// only speed lever is a byte-identical prefix.
    ///
    /// Caught by this suite: the delivery pin compares the wire message against a
    /// freshly rendered envelope and failed on ~2 runs in 3 for no other reason.
    ///
    /// Asserts the SORTED order rather than only "all renders agree" — the hash order is
    /// stable within a run often enough that an agreement-only check passes against the
    /// bug (measured). Sorted order is the contract; agreement is its consequence.
    func testCollaborationEnvelope_rendersDeterministically() {
        let renders = (0..<64).map { _ in
            service.buildCollaborationToolResult(
                toolName: ToolNames.askSupervisor, response: answerText)
        }
        XCTAssertEqual(Set(renders).count, 1, "key order must not vary between renders")
        XCTAssertTrue(
            renders[0].hasPrefix(#"{"ok":true,"response":"#),
            "keys must be sorted (ok < response < tool), got: \(renders[0].prefix(40))")

        let errors = (0..<64).map { _ in
            service.buildCollaborationErrorResult(
                toolName: ToolNames.askTeammate, message: "boom")
        }
        XCTAssertEqual(Set(errors).count, 1)
        XCTAssertTrue(
            errors[0].hasPrefix(#"{"error":"#),
            "keys must be sorted (error < ok < tool), got: \(errors[0].prefix(40))")
    }

    /// Every other tool result ships through `makeWireEncoder`, which sets
    /// `.withoutEscapingSlashes` precisely because small models copy the `\/` sequences in
    /// file paths into `edit_file` anchors that then never match. A collaboration answer
    /// quoting a path must not be the one envelope that escapes them.
    func testCollaborationEnvelope_doesNotEscapeSlashes() {
        let json = service.buildCollaborationToolResult(
            toolName: ToolNames.askSupervisor,
            response: "Edit Sources/MeditationApp/Meditation.swift")

        XCTAssertTrue(json.contains("Sources/MeditationApp/Meditation.swift"))
        XCTAssertFalse(json.contains(#"\/"#))
    }

    /// A step freshly minted for a role has nothing to deliver.
    func testFactoryMadeStep_isNotArmed() {
        let roleDef = TeamRoleDefinition(
            id: "role_x",
            name: "Software Engineer",
            prompt: "Implement things.",
            toolIDs: [ToolNames.createArtifact],
            usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Engineering Notes"]),
            systemRoleID: "softwareEngineer")
        XCTAssertFalse(StepExecution.make(for: roleDef).supervisorAnswerPendingDelivery)
    }

    // MARK: - Persistence

    /// A `task.json` written before the key existed must still deliver its answer once:
    /// defaulting to `false` there would silently swallow the answer of a step that was
    /// answered but not yet resumed at the moment of the upgrade.
    ///
    /// The legacy shape is produced by ENCODING rather than hand-written JSON: an armed
    /// answer agrees with the inference, so the encoder omits the key — which is byte-for-byte
    /// what an older build wrote. Hand-writing it would also have to guess `Role`'s wire form.
    func testLegacyStepWithoutTheKey_infersPendingDelivery() throws {
        var step = StepExecution(id: "swe_legacy", role: .softwareEngineer, title: "SWE Step")
        step.supervisorAnswer = "Approved."
        step.supervisorAnswerPendingDelivery = true

        let json = try encodeStep(step)
        XCTAssertFalse(
            json.contains("supervisorAnswerPendingDelivery"),
            "an armed answer agrees with the inference, so the key is omitted — that IS the "
                + "legacy on-disk shape")
        XCTAssertTrue(try decodeStep(json).supervisorAnswerPendingDelivery)
    }

    func testLegacyStepWithNoAnswer_isNotArmed() throws {
        let step = StepExecution(id: "swe_legacy_empty", role: .softwareEngineer, title: "SWE Step")
        let json = try encodeStep(step)
        XCTAssertFalse(json.contains("supervisorAnswerPendingDelivery"))
        XCTAssertFalse(try decodeStep(json).supervisorAnswerPendingDelivery)
    }

    /// The encoder omits the flag only when it agrees with the inference. A delivered
    /// answer (`false` beside a non-nil `supervisorAnswer`) DISAGREES, so it must be
    /// written out — otherwise the next decode revives it as pending and re-delivers.
    func testDeliveredAnswer_survivesACodableRoundTrip() throws {
        var step = StepExecution(id: "swe_rt", role: .softwareEngineer, title: "SWE Step")
        step.supervisorAnswer = "Approved."
        step.supervisorAnswerPendingDelivery = false

        let decoded = try decodeStep(encodeStep(step))

        XCTAssertEqual(decoded.supervisorAnswer, "Approved.")
        XCTAssertFalse(
            decoded.supervisorAnswerPendingDelivery,
            "An omitted `false` would decode back as `true` and re-deliver the answer")
    }

    func testReset_disarmsDelivery() {
        var step = StepExecution(id: "swe_reset", role: .softwareEngineer, title: "SWE Step")
        step.supervisorAnswer = "Approved."
        step.supervisorAnswerPendingDelivery = true

        step.reset()

        XCTAssertFalse(step.supervisorAnswerPendingDelivery)
    }

    // MARK: - Helpers

    /// One full entry into the step: start, wait for the request it produces, cancel so
    /// the cancellation arm persists the transcript the next entry will replay.
    private func runOneEntry(
        stepID: String, taskID: Int, expectingCallIndex index: Int
    ) async throws {
        try await startAndAwaitRequest(
            stepID: stepID, taskID: taskID, expectingCallIndex: index)
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)
    }

    /// Starts the step and blocks until the request it produces has been captured, so a
    /// caller that mutates state next can't race the request it is reasoning about.
    private func startAndAwaitRequest(
        stepID: String, taskID: Int, expectingCallIndex index: Int
    ) async throws {
        guard var task = mockDelegate.taskToMutate else {
            return XCTFail("no task installed on the delegate")
        }
        // `startStepExecution` bails unless the step is `.running` — production gets there
        // via `resumeRun`; here the test states it.
        task.runs[0].steps[0].status = .running
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: task, runIndex: 0, stepIndex: 0)
        try await waitUntil { self.stubClient.capturedCalls.count > index }
    }

    private func persistedStep(_ stepID: String) -> StepExecution? {
        mockDelegate.taskToMutate?.runs.last?.steps.first { $0.id == stepID }
    }

    private func appendToPersistedTranscript(stepID: String, _ message: ChatMessage) {
        guard var task = mockDelegate.taskToMutate,
              let stepIndex = task.runs[0].steps.firstIndex(where: { $0.id == stepID })
        else { return XCTFail("step \(stepID) not found") }
        task.runs[0].steps[stepIndex].wireTranscript.append(message)
        mockDelegate.taskToMutate = task
    }

    /// Counts the `ask_supervisor` result envelopes carrying THIS answer. Content
    /// equality, not a substring sweep: the answer text also appears in the display
    /// record and in the pending question, and only the envelope is the wire delivery.
    private func answerEnvelopeCount(in messages: [ChatMessage]) -> Int {
        let envelope = service.buildCollaborationToolResult(
            toolName: ToolNames.askSupervisor, response: answerText)
        return messages.filter { $0.role == .tool && $0.content == envelope }.count
    }

    private func encodeStep(_ step: StepExecution) throws -> String {
        String(decoding: try JSONCoderFactory.makePersistenceEncoder().encode(step), as: UTF8.self)
    }

    private func decodeStep(_ json: String) throws -> StepExecution {
        try JSONCoderFactory.makeDateDecoder().decode(StepExecution.self, from: Data(json.utf8))
    }

    /// A step shaped exactly as the runtime leaves it after `ask_supervisor` parked it and
    /// `StepMessagingService.answerSupervisorQuestion` delivered the answer.
    private func makeParkedThenAnsweredTask(taskID: Int, stepID: String) -> NTMSTask {
        var step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "SWE Step",
            expectedArtifacts: ["Engineering Notes"],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Please approve running `swift build`.",
            supervisorAnswer: answerText,
            llmConversation: [
                LLMMessage(role: .system, content: "System prompt"),
                LLMMessage(role: .user, content: "## Supervisor Task\n\nImplement M2."),
                LLMMessage(
                    role: .user,
                    content: MessageSourceContext.supervisorAnswerPrefix + answerText,
                    sourceRole: .supervisor,
                    sourceContext: .supervisorAnswer),
            ]
        )
        step.wireTranscript = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "## Supervisor Task\n\nImplement M2."),
            ChatMessage(
                role: .tool,
                content: #"{"ok":true,"data":{"question":"Please approve running `swift build`.","status":"pending"}}"#),
        ]
        return NTMSTask(
            id: taskID, title: "Test", supervisorTask: "Implement M2.",
            runs: [Run(id: 0, steps: [step])])
    }

    /// A step parked on `ask_supervisor` and NOT yet answered — the state every
    /// arming-side corner starts from.
    private func makeParkedTask(taskID: Int, stepID: String) -> NTMSTask {
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "SWE Step",
            expectedArtifacts: ["Engineering Notes"],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Please approve running `swift build`."
        )
        return NTMSTask(
            id: taskID, title: "Test", supervisorTask: "Implement M2.",
            runs: [Run(id: 0, steps: [step])])
    }

    private func makeFreshRunningTask(taskID: Int, stepID: String) -> NTMSTask {
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "SWE Step",
            expectedArtifacts: ["Engineering Notes"],
            status: .running
        )
        return NTMSTask(
            id: taskID, title: "Test", supervisorTask: "Implement M2.",
            runs: [Run(id: 0, steps: [step])])
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                throw DeliveryWaitTimeoutError(timeout: timeout)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct DeliveryWaitTimeoutError: Error, LocalizedError {
        let timeout: TimeInterval
        var errorDescription: String? {
            "waitUntil: condition not met within \(timeout)s."
        }
    }
}
