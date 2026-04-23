import XCTest

@testable import NanoTeams

/// Tests for `NTMSOrchestrator.consumeQueuedSupervisorMessage` — the path the
/// LLM injection hook calls through. Covers behavior the service-level
/// `LLMQueuedMessageInjectionTests` can't reach because it mocks the delegate:
/// - Priority tier ordering in the real orchestrator (role-targeted → untargeted).
/// - Attachment finalization failure leaves the queue intact.
/// - Persistence failure (closure's `locateStepInLatestRun` guard) re-queues.
/// - `--- Attached Files ---` section uses FINAL paths, not staged paths.
/// - `LLMMessage` persisted with the `.supervisorMessage` source context.
/// - Partial embed failure surfaces as `lastInfoMessage` (degraded, not error).
@MainActor
final class ConsumeQueuedSupervisorMessageTests: NTMSOrchestratorTestBase {

    // MARK: - Helpers

    private var formState: QuickCaptureFormState!

    override func setUp() {
        super.setUp()
        // Resolve symlinks on tempDir (`/var/folders/...` → `/private/var/folders/...`)
        // so `NTMSPaths.relativePathFromProjectRoot` (which compares raw `.path`
        // strings, not `standardizedFileURL`) doesn't fall back to `lastPathComponent`
        // when we assert that finalized attachment paths are project-relative.
        tempDir = tempDir.resolvingSymlinksInPath()
        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState
        // `StoreConfiguration` reads `UserDefaults.standard`, so the value of
        // `embedFilesInPrompt` leaks from the dev machine into the test. Attachment
        // tests here assert the `--- Attached Files ---` path-list shape, not the
        // inline `--- Attached File: <name> ---` embed shape — pin to `false` so
        // the test is deterministic regardless of the developer's settings.
        sut.configuration.embedFilesInPrompt = false
    }

    override func tearDown() {
        if let externalSourceDir {
            try? FileManager.default.removeItem(at: externalSourceDir)
        }
        externalSourceDir = nil
        formState = nil
        super.tearDown()
    }

    /// Creates a task with a single `.running` step for the given role. The step's
    /// `id` matches `roleID` (invariant: `step.id == TeamRoleDefinition.id`).
    private func createTaskWithRunningStep(roleID: String = "pm") async -> (taskID: Int, stepID: String) {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!

        let step = StepExecution(
            id: roleID,
            role: .productManager,
            title: "PM",
            status: .running,
            llmConversation: [LLMMessage(role: .assistant, content: "Prior turn")]
        )
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [step], roleStatuses: [roleID: .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        return (taskID, roleID)
    }

    /// Creates a real file on disk and stages it through the orchestrator's
    /// repository, returning a `StagedAttachment` whose `stagedRelativePath`
    /// points at an actual file under `.nanoteams/staged/{draftID}/`.
    /// Source files for staging must live OUTSIDE the work folder. Otherwise
    /// `stageAttachment` treats them as project references (`isProjectReference: true`)
    /// and skips the copy, which means `finalizeAttachments` returns the in-project
    /// relative path as-is — not the `.nanoteams/tasks/.../attachments/` path these
    /// tests are asserting.
    private var externalSourceDir: URL!

    private func stageRealAttachment(
        content: String = "hello",
        fileName: String = "test.txt",
        draftID: UUID = UUID()
    ) -> StagedAttachment? {
        if externalSourceDir == nil {
            externalSourceDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cqsm_sources_\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: externalSourceDir, withIntermediateDirectories: true
            )
        }
        let sourceURL = externalSourceDir.appendingPathComponent(fileName)
        try? content.data(using: .utf8)?.write(to: sourceURL)
        return sut.stageAttachment(url: sourceURL, draftID: draftID)
    }

    private func queue(
        taskID: Int,
        text: String = "доложи статус",
        targetRoleID: String? = nil,
        attachments: [StagedAttachment] = [],
        clippedTexts: [String] = []
    ) -> UUID {
        let msg = QuickCaptureFormState.QueuedChatMessage(
            text: text,
            attachments: attachments,
            clippedTexts: clippedTexts,
            targetRoleID: targetRoleID
        )!
        formState.appendQueuedMessage(msg, for: taskID)
        return msg.id
    }

    // MARK: - Happy path: text only

    func testConsume_textOnly_appendsLLMMessage_withSupervisorMessageContext() async {
        let (taskID, stepID) = await createTaskWithRunningStep()
        _ = queue(taskID: taskID, text: "доложи статус", targetRoleID: "pm")

        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: stepID
        )

        // LLM sees the "Supervisor:\n" header so it can attribute the user turn
        // in a stream mixed with tool results / memory blocks.
        XCTAssertEqual(prompt, "Supervisor:\nдоложи статус")
        let convo = sut.activeTask?.runs.last?.steps.first?.llmConversation ?? []
        XCTAssertEqual(convo.count, 2, "Prior turn + new supervisor turn")
        XCTAssertEqual(convo.last?.role, .user)
        XCTAssertEqual(convo.last?.sourceRole, .supervisor)
        XCTAssertEqual(convo.last?.sourceContext, .supervisorMessage,
                       ".supervisorAnswer would be FILTERED OUT of the timeline; must be .supervisorMessage")
        XCTAssertEqual(convo.last?.content, "Supervisor:\nдоложи статус",
                       "Persisted content includes the prefix; UI strips via displayContent")
        XCTAssertEqual(convo.last?.displayContent, "доложи статус",
                       "Activity feed must render the bubble without the attribution header")
        XCTAssertFalse(formState.hasQueuedMessage(for: taskID), "Queue drained on success")

        // S5 regression guard: `step.messages` must NOT be touched — it has no
        // UI consumer and mid-iteration writes would duplicate in the feed.
        let stepMessages = sut.activeTask?.runs.last?.steps.first?.messages ?? []
        XCTAssertTrue(stepMessages.isEmpty,
                      "consumeQueuedSupervisorMessage must not append to step.messages — llmConversation is the single source")
    }

    // MARK: - Batching — drain everything eligible at once

    func testConsume_drainsAllEligibleMessages_targetedBeforeUntargeted() async {
        let (taskID, stepID) = await createTaskWithRunningStep(roleID: "pm")
        // Mixed queue: untargeted (oldest), pm-targeted, tl-targeted (ineligible), untargeted.
        _ = queue(taskID: taskID, text: "team A", targetRoleID: nil)
        _ = queue(taskID: taskID, text: "pm 1", targetRoleID: "pm")
        _ = queue(taskID: taskID, text: "for TL", targetRoleID: "tech_lead")
        _ = queue(taskID: taskID, text: "team B", targetRoleID: nil)
        _ = queue(taskID: taskID, text: "pm 2", targetRoleID: "pm")

        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: stepID
        )

        // Expected: targeted FIFO tier first (pm 1, pm 2), then untargeted FIFO
        // tier (team A, team B). TL-targeted stays queued.
        XCTAssertEqual(prompt, "Supervisor:\npm 1\npm 2\nteam A\nteam B")
        let remaining = formState.queuedMessages(for: taskID)
        XCTAssertEqual(remaining.count, 1, "Only TL-targeted remains")
        XCTAssertEqual(remaining.first?.text, "for TL")
    }

    func testConsume_singleMessage_stillUsesMultilineHeader() async {
        let (taskID, stepID) = await createTaskWithRunningStep(roleID: "pm")
        _ = queue(taskID: taskID, text: "single", targetRoleID: "pm")

        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: stepID
        )

        XCTAssertEqual(prompt, "Supervisor:\nsingle",
                       "Single-message batch still uses the `Supervisor:\\n<body>` shape — consistent with multi-message batches")
    }

    func testConsume_otherRoleTargeted_isIgnored() async {
        let (taskID, stepID) = await createTaskWithRunningStep(roleID: "pm")
        _ = queue(taskID: taskID, text: "for TL", targetRoleID: "tech_lead")

        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: stepID
        )

        XCTAssertNil(prompt, "PM must not consume a TL-targeted message")
        XCTAssertEqual(formState.queuedMessages(for: taskID).count, 1)
    }

    func testConsume_emptyQueue_returnsNil() async {
        let (taskID, stepID) = await createTaskWithRunningStep()
        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: stepID
        )
        XCTAssertNil(prompt)
    }

    func testConsume_nilFormState_returnsNilSilently() async {
        let (taskID, stepID) = await createTaskWithRunningStep()
        sut.quickCaptureFormState = nil

        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: stepID
        )

        XCTAssertNil(prompt, "No queue source = no delivery — defensive fallback")
    }

    // MARK: - Attachments — final paths, not staged

    func testConsume_withAttachment_rendersAttachedFilesSectionUsingFinalPath() async {
        let (taskID, stepID) = await createTaskWithRunningStep()
        guard let staged = stageRealAttachment(content: "payload", fileName: "file.txt") else {
            XCTFail("Staging must succeed")
            return
        }
        _ = queue(taskID: taskID, text: "see attached", targetRoleID: "pm", attachments: [staged])

        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: stepID
        )

        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt?.contains("see attached") ?? false)
        XCTAssertTrue(prompt?.contains("--- Attached Files ---") ?? false,
                      "Non-embedded attachments must get a '--- Attached Files ---' section")
        // Final paths live under `.nanoteams/tasks/{taskID}/attachments/` — NOT under staged/.
        let expectedTaskSegment = ".nanoteams/tasks/\(taskID)/attachments/"
        XCTAssertTrue(prompt?.contains(expectedTaskSegment) ?? false,
                      "Attached Files section must reference FINAL paths")
        XCTAssertFalse(prompt?.contains(staged.stagedRelativePath) ?? true,
                       "Staged path must NOT appear in the delivered prompt")
    }

    // MARK: - Finalization failure — data preservation

    func testConsume_finalizeFailure_preservesQueue_setsLastErrorMessage() async {
        let (taskID, stepID) = await createTaskWithRunningStep()
        let draftID = UUID()
        guard let staged = stageRealAttachment(
            content: "payload", fileName: "bad.txt", draftID: draftID
        ) else {
            XCTFail("Staging should succeed")
            return
        }
        // Sabotage finalization: delete the staged file so `copyItem` throws.
        let stagedAbsolute = tempDir
            .appendingPathComponent(staged.stagedRelativePath, isDirectory: false)
        try? FileManager.default.removeItem(at: stagedAbsolute)

        let messageID = queue(taskID: taskID, text: "see attached", targetRoleID: "pm", attachments: [staged])

        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: stepID
        )

        XCTAssertNil(prompt, "Finalization failure must abort delivery")
        let remaining = formState.queuedMessages(for: taskID)
        XCTAssertEqual(remaining.count, 1,
                       "Message must stay in the queue so the user can retry")
        XCTAssertEqual(remaining.first?.id, messageID,
                       "The same message (by id) should be re-appended, not a copy")
        XCTAssertNotNil(sut.lastErrorMessage)
        XCTAssertTrue(sut.lastErrorMessage?.contains("kept in queue") ?? false,
                      "Error text should tell the user the message is retained")

        // Activity feed must not show a Supervisor bubble — persistence was never reached.
        let convo = sut.activeTask?.runs.last?.steps.first?.llmConversation ?? []
        XCTAssertEqual(convo.count, 1, "No LLMMessage should have been persisted")
    }

    // MARK: - Persistence failure — data preservation

    func testConsume_missingStep_reQueuesAndSurfacesError() async {
        let (taskID, _) = await createTaskWithRunningStep()
        let messageID = queue(taskID: taskID, text: "text", targetRoleID: "pm")

        // Pass a stepID that doesn't exist in the latest run → the mutateTask
        // closure's locateStepInLatestRun guard fires.
        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: "nonexistent_step_id"
        )

        XCTAssertNil(prompt, "Persistence failure must abort delivery")
        let remaining = formState.queuedMessages(for: taskID)
        XCTAssertEqual(remaining.count, 1,
                       "Closure-guard failure must re-append so the message isn't silently lost")
        XCTAssertEqual(remaining.first?.id, messageID)
        XCTAssertNotNil(sut.lastErrorMessage)
        XCTAssertTrue(sut.lastErrorMessage?.contains("kept in queue") ?? false)
    }

    // MARK: - Embed success — no info banner

    func testConsume_successfulEmbed_noInfoMessage_andContentInlined() async {
        // Happy-path embed: a plain UTF-8 file succeeds inline extraction, so
        // no `failedFiles` accumulate and no info banner fires. Also verifies
        // the `--- Attached Files ---` section is suppressed (content is inline).
        let original = sut.configuration.embedFilesInPrompt
        sut.configuration.embedFilesInPrompt = true
        defer { sut.configuration.embedFilesInPrompt = original }

        let (taskID, stepID) = await createTaskWithRunningStep()
        guard let staged = stageRealAttachment(
            content: "any content", fileName: "note.txt", draftID: UUID()
        ) else {
            XCTFail("Staging should succeed")
            return
        }
        _ = queue(taskID: taskID, text: "read this", targetRoleID: "pm", attachments: [staged])

        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: stepID
        )

        XCTAssertNotNil(prompt)
        XCTAssertNil(sut.lastInfoMessage,
                     "Successful inline embed should not surface an info message")
        XCTAssertFalse(prompt?.contains("--- Attached Files ---") ?? true,
                       "Embedded files must not duplicate as attachment paths")
        XCTAssertTrue(prompt?.contains("--- Attached File: note.txt ---") ?? false)
    }

    // MARK: - Info banner for degraded delivery (real partial-embed failure)

    func testConsume_partialEmbedFailure_surfacesLastInfoMessage() async {
        // Real failure path: a file that `DocumentTextExtractor` can't parse AND
        // that isn't valid UTF-8, so it falls into `failedFiles` in
        // `AnswerTextBuilder.build`. The non-embedded file still gets its final
        // path in the `--- Attached Files ---` section — degraded, not lost.
        let original = sut.configuration.embedFilesInPrompt
        sut.configuration.embedFilesInPrompt = true
        defer { sut.configuration.embedFilesInPrompt = original }

        let (taskID, stepID) = await createTaskWithRunningStep()

        // Stage a file with non-UTF-8 bytes and an extension the document
        // extractor doesn't handle. Writes the raw bytes directly rather than
        // going through `stageRealAttachment`'s string API.
        if externalSourceDir == nil {
            externalSourceDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cqsm_sources_\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: externalSourceDir, withIntermediateDirectories: true
            )
        }
        let sourceURL = externalSourceDir.appendingPathComponent("garbage.bin")
        let nonUTF8: [UInt8] = [0xFF, 0xFE, 0x00, 0xFF, 0x80, 0x81, 0x82, 0xC0, 0xC1]
        try? Data(nonUTF8).write(to: sourceURL)
        guard let staged = sut.stageAttachment(url: sourceURL, draftID: UUID()) else {
            XCTFail("Staging should succeed even for binary")
            return
        }

        _ = queue(taskID: taskID, text: "read this", targetRoleID: "pm", attachments: [staged])

        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: stepID
        )

        XCTAssertNotNil(prompt, "Delivery must succeed — embed failure is degradation, not abort")
        XCTAssertNotNil(sut.lastInfoMessage,
                        "failedFiles must surface as lastInfoMessage after successful persistence")
        XCTAssertTrue(sut.lastInfoMessage?.contains("garbage.bin") ?? false,
                      "Info message must name the failed file")
        XCTAssertTrue(prompt?.contains("--- Attached Files ---") ?? false,
                      "Non-embeddable file falls back to path attachment, not dropped")
        XCTAssertFalse(prompt?.contains("--- Attached File: garbage.bin ---") ?? true,
                       "Failed extraction must NOT appear as inline embed")
        XCTAssertNil(sut.lastErrorMessage, "Info, not error")
    }

    // MARK: - S4 — banner precedence under failure

    func testConsume_partialEmbedPlusPersistFailure_setsErrorOnly_noInfo() async {
        // When partial-embed degradation would normally set `lastInfoMessage`
        // AND persistence fails (so nothing was actually delivered), surfacing
        // the info is misleading. Error wins; info stays nil.
        let original = sut.configuration.embedFilesInPrompt
        sut.configuration.embedFilesInPrompt = true
        defer { sut.configuration.embedFilesInPrompt = original }

        let (taskID, _) = await createTaskWithRunningStep()

        if externalSourceDir == nil {
            externalSourceDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cqsm_sources_\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: externalSourceDir, withIntermediateDirectories: true
            )
        }
        let sourceURL = externalSourceDir.appendingPathComponent("garbage.bin")
        try? Data([0xFF, 0xFE, 0x00, 0xFF]).write(to: sourceURL)
        guard let staged = sut.stageAttachment(url: sourceURL, draftID: UUID()) else {
            XCTFail("Staging should succeed")
            return
        }
        _ = queue(taskID: taskID, text: "read this", targetRoleID: "pm", attachments: [staged])

        // Force persist failure via nonexistent step ID.
        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: "nonexistent_step_id"
        )

        XCTAssertNil(prompt, "Persist failure aborts delivery")
        XCTAssertNotNil(sut.lastErrorMessage, "Persist failure must set error")
        XCTAssertNil(sut.lastInfoMessage,
                     "Info banner must stay nil — the partial-embed degradation is moot because nothing was delivered")
        XCTAssertEqual(formState.queuedMessages(for: taskID).count, 1,
                       "Message requeued for retry")
    }

    // MARK: - G1 — prepend-on-requeue preserves head-of-queue position

    func testConsume_persistenceFailure_requeuesAtHead_notTail() async {
        // Setup: queue A (targeted at pm), then queue B (targeted at tl).
        // Consume for pm pops A only (leaves B). Persistence fails (bad stepID).
        // Re-queue must restore A at HEAD, so final order is [A, B] — NOT [B, A].
        // Guards against FIFO inversion when a second message arrives before
        // (or is left in the queue during) the failing await.
        let (taskID, _) = await createTaskWithRunningStep(roleID: "pm")

        let idA = queue(taskID: taskID, text: "A for pm", targetRoleID: "pm")
        let idB = queue(taskID: taskID, text: "B for tl", targetRoleID: "tech_lead")

        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: "nonexistent_step_id"
        )

        XCTAssertNil(prompt, "Persist fails → nil")
        let remaining = formState.queuedMessages(for: taskID)
        XCTAssertEqual(remaining.count, 2, "Both A (requeued) and B (untouched) must be present")
        XCTAssertEqual(remaining[0].id, idA,
                       "A must be at HEAD after requeue — appending would push it behind B (FIFO inversion)")
        XCTAssertEqual(remaining[1].id, idB, "B stays in its original position")
    }

    // MARK: - G2 — concurrent parallel-role consumption (atomic reserve)

    func testConsume_concurrentRoles_atomicReserve_deliversToExactlyOne() async {
        // FAANG-style parallel roles: PM + TL both running on the same task,
        // single untargeted "team" message queued. Atomic reserve guarantees
        // exactly one role gets it — the other sees an empty queue by the time
        // it peeks (synchronous pop in the first call happens before any await).
        let (taskID, stepID1) = await createTaskWithRunningStep(roleID: "pm")
        await sut.mutateTask(taskID: taskID) { task in
            let tlStep = StepExecution(
                id: "tl",
                role: .techLead,
                title: "TL",
                status: .running,
                llmConversation: [LLMMessage(role: .assistant, content: "prior")]
            )
            task.runs[0].steps.append(tlStep)
            task.runs[0].roleStatuses["tl"] = .working
        }
        _ = queue(taskID: taskID, text: "team-wide", targetRoleID: nil)

        async let pmPrompt = sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "pm", stepID: stepID1
        )
        async let tlPrompt = sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: "tl", stepID: "tl"
        )
        let (pm, tl) = await (pmPrompt, tlPrompt)

        let delivered = [pm, tl].compactMap { $0 }
        XCTAssertEqual(delivered.count, 1,
                       "Atomic reserve must deliver an untargeted message to exactly ONE role, not both")
        XCTAssertEqual(delivered.first, "Supervisor:\nteam-wide")
        XCTAssertFalse(formState.hasQueuedMessage(for: taskID),
                       "Queue drained exactly once across both consumers")

        // Both steps exist but only the winner got the turn appended.
        let steps = sut.activeTask?.runs.last?.steps ?? []
        let pmConvo = steps.first(where: { $0.id == "pm" })?.llmConversation ?? []
        let tlConvo = steps.first(where: { $0.id == "tl" })?.llmConversation ?? []
        let pmGotMessage = pmConvo.contains { $0.sourceContext == .supervisorMessage }
        let tlGotMessage = tlConvo.contains { $0.sourceContext == .supervisorMessage }
        XCTAssertTrue(pmGotMessage != tlGotMessage,
                      "Exactly one step must have received the LLMMessage (XOR)")
    }

    // MARK: - Multiple tasks — queue isolation

    func testConsume_perTaskIsolation_taskBQueueUntouched() async {
        let (taskA, stepA) = await createTaskWithRunningStep(roleID: "pm")

        // Task B: only accept messages queued against taskB; taskA's queue must survive.
        _ = queue(taskID: 999, text: "for task B", targetRoleID: "pm")
        _ = queue(taskID: taskA, text: "for task A", targetRoleID: "pm")

        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskA, roleID: "pm", stepID: stepA
        )

        XCTAssertEqual(prompt, "Supervisor:\nfor task A")
        XCTAssertTrue(formState.hasQueuedMessage(for: 999),
                      "Task B's queue must be untouched by Task A consumption")
    }
}
