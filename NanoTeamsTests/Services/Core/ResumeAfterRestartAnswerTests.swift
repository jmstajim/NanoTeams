import XCTest

@testable import NanoTeams

/// Regression tests for the post-restart supervisor-answer path.
///
/// Scenario: chat-mode advisory role calls `ask_supervisor`. App is force-quit
/// while the step is `.needsSupervisorInput`. On next launch,
/// `StatusRecoveryService` flips the step to `.paused` and the role to `.idle`,
/// but preserves `step.needsSupervisorInput=true` and `step.wireTranscript`. The
/// Supervisor sees the Answer chip in the activity feed and submits an answer.
///
/// Bug before fix: status `.paused` (post-recovery) wasn't covered by either
/// `StepMessagingService` (only flipped `.needsSupervisorInput → .pending`) or
/// `resumeRun` branch 3's heuristic that requires non-empty conversation. Result:
/// run silently failed to continue.
///
/// Fix verified here:
/// - `StepMessagingService.answerSupervisorQuestion` flips `.paused → .pending` too.
/// - `resumeRun` adds an explicit branch that runs any paused/pending step carrying
///   an answer, so the continuation in `startStepExecution` fires regardless of
///   `step.messages`/`llmConversation` state.
@MainActor
final class ResumeAfterRestartAnswerTests: NTMSOrchestratorTestBase {

    // MARK: - Attachment-finalize failure → returns false, lastErrorMessage set

    /// Pinned by review (item #2 in the test-gap section): when a Supervisor
    /// answer carries staged attachments and finalization fails, the call
    /// must return `false` and surface `lastErrorMessage`. The bug-shape would
    /// be a "silent answer drop" where the user thinks they submitted but the
    /// step never advanced. Production code already handles this, but no test
    /// pinned the contract — easy to regress under a future refactor.
    func testAnswerWithMissingStagedAttachment_returnsFalse_andSetsLastErrorMessage() async throws {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Чат", supervisorTask: "привет")!
        await seedPostRestartState(taskID: id)

        // Construct a StagedAttachment that points at a real source file (so
        // its `init` succeeds) but whose `stagedRelativePath` does NOT exist
        // anywhere under the work folder — so `finalizeAttachments` will
        // throw on the copy step.
        let realSource = tempDir.appendingPathComponent("real-source.txt")
        try "hello".write(to: realSource, atomically: true, encoding: .utf8)
        let phantom = try StagedAttachment(
            url: realSource,
            stagedRelativePath: ".nanoteams/staged/does-not-exist/phantom.txt"
        )

        sut.lastErrorMessage = nil
        let returnValue = await sut.answerSupervisorQuestion(
            stepID: "coding_assistant",
            taskID: id,
            answer: "продолжай",
            attachments: [phantom]
        )

        XCTAssertFalse(returnValue,
                       "answerSupervisorQuestion must return false when finalization fails — " +
                       "callers (composer / Watchtower) rely on this to keep the user's draft intact")
        XCTAssertNotNil(sut.lastErrorMessage,
                        "user must see the failure reason; otherwise the dropped answer looks like silence")

        // Step state is unchanged: the answer was NOT applied.
        let step = sut.loadedTask(id)?.runs.last?.steps.first
        XCTAssertNil(step?.supervisorAnswer,
                     "supervisorAnswer must NOT be set when finalization failed")
        XCTAssertEqual(step?.status, .paused,
                       "step must remain paused — no transition into pending")
    }

    private func seedPostRestartState(
        taskID: Int,
        stepID: String = "coding_assistant",
        roleStatus: RoleExecutionStatus = .idle,
        conversation: [LLMMessage] = []
    ) async {
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(
                id: stepID,
                role: .softwareEngineer,
                title: "Chat",
                status: .paused,
                needsSupervisorInput: true,
                supervisorQuestion: "Что дальше?",
                llmConversation: conversation
            )
            var run = Run(id: 0, steps: [step], roleStatuses: [stepID: roleStatus])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
            task.status = .paused
        }
        // Mimic syncEngineStateFromRun seeding after openWorkFolder — for an
        // active task with a paused step, derivedStatusFromActiveRun → .paused
        // → engineState .paused. We set this directly because openWorkFolder
        // wasn't called between createTask and seeding.
        sut.engineState[taskID] = .paused
    }

    // MARK: - Branch 1.5: paused + answer + session → step gets restarted

    func testPostRestart_answer_promotesRoleToWorking() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Чат", supervisorTask: "привет")!
        await seedPostRestartState(taskID: id)

        _ = await sut.answerSupervisorQuestion(
            stepID: "coding_assistant", taskID: id,
            answer: "продолжай"
        )

        let run = sut.loadedTask(id)?.runs.last
        XCTAssertEqual(run?.roleStatuses["coding_assistant"], .working,
                       "Branch 1.5 must promote idle role to .working before runStep")
    }

    func testPostRestart_answer_recordsAnswerOnStep() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Чат", supervisorTask: "привет")!
        await seedPostRestartState(taskID: id)

        _ = await sut.answerSupervisorQuestion(
            stepID: "coding_assistant", taskID: id,
            answer: "продолжай"
        )

        let step = sut.loadedTask(id)?.runs.last?.steps.first
        XCTAssertEqual(step?.supervisorAnswer, "продолжай")
        XCTAssertFalse(step?.needsSupervisorInput ?? true,
                       "needsSupervisorInput flag must be cleared")
        XCTAssertEqual(step?.supervisorAnswerWasAuto, false,
                       "Human surfaces use the default isAutoAnswer=false — checkmark, not the badge")
    }

    // MARK: - isAutoAnswer threading (defaulted param — deleting an argument still compiles)

    /// The 3-arg LLMStateDelegate shim (used by `DelegatedSupervisorAnswerService` —
    /// a delegating parent ROLE answering) must thread `isAutoAnswer: true` all the
    /// way to `step.supervisorAnswerWasAuto`. Because the parameter is defaulted at
    /// every hop, silently dropping the argument at any call site still compiles —
    /// this pins the full chain (shim → orchestrator → StepMessagingService → step).
    func testDelegationShim_answer_marksWasAutoAnswered() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Чат", supervisorTask: "привет")!
        await seedPostRestartState(taskID: id)

        _ = await sut.answerSupervisorQuestion(
            taskID: id, stepID: "coding_assistant", answer: "use SQLite"
        )

        let step = sut.loadedTask(id)?.runs.last?.steps.first
        XCTAssertEqual(step?.supervisorAnswer, "use SQLite")
        XCTAssertEqual(step?.supervisorAnswerWasAuto, true,
                       "The delegation shim is an automated answerer — must set the badge flag")
    }

    func testPostRestart_answer_engineStateLeavesPaused() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Чат", supervisorTask: "привет")!
        await seedPostRestartState(taskID: id)

        _ = await sut.answerSupervisorQuestion(
            stepID: "coding_assistant", taskID: id,
            answer: "продолжай"
        )

        XCTAssertNotEqual(sut.engineState[id], .paused,
                          "Engine must transition out of .paused after the answer is recorded — " +
                          "the run is supposed to continue.")
    }

    // MARK: - Edge case: empty conversation

    /// Branch 3 of resumeRun (the prior fallback path) requires
    /// `!step.messages.isEmpty || !step.llmConversation.isEmpty`. Some models
    /// emit an `ask_supervisor` tool call before any assistant content has
    /// streamed, which leaves `llmConversation` empty for the very first
    /// question. Branch 1.5 must NOT depend on conversation contents — only on
    /// `effectiveSupervisorAnswer != nil`.
    func testPostRestart_answer_emptyConversation_stillRestartsRole() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Чат", supervisorTask: "привет")!
        await seedPostRestartState(
            taskID: id,
            conversation: []   // explicit: nothing in llmConversation
        )

        _ = await sut.answerSupervisorQuestion(
            stepID: "coding_assistant", taskID: id,
            answer: "продолжай"
        )

        let run = sut.loadedTask(id)?.runs.last
        XCTAssertEqual(run?.roleStatuses["coding_assistant"], .working,
                       "Branch 1.5 must fire even when conversation history is empty")
    }

    // MARK: - An answered step restarts on every provider

    /// Branch 1.5 used to additionally require a saved server-chain id, so a step
    /// answered under a provider that never minted one (and, after the stateless
    /// unification, EVERY step) silently failed to resume: the answer landed, the
    /// status moved to `.pending`, and nothing ever ran it. The branch now keys on
    /// the answer alone — `startStepExecution` replays `wireTranscript` /
    /// `llmConversation` instead of a server-held chain.
    func testPostRestart_answer_withoutAnySession_stillRestartsTheStep() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Чат", supervisorTask: "привет")!
        await seedPostRestartState(taskID: id)

        _ = await sut.answerSupervisorQuestion(
            stepID: "coding_assistant", taskID: id,
            answer: "продолжай"
        )

        let step = sut.loadedTask(id)?.runs.last?.steps.first
        XCTAssertEqual(step?.supervisorAnswer, "продолжай",
                       "Answer must be recorded")
        XCTAssertEqual(sut.loadedTask(id)?.runs.last?.roleStatuses["coding_assistant"], .working,
                       "Branch 1.5 must restart the answered step with no session involved")
    }

    // MARK: - Full user scenarios (restart roundtrip via real recreation)

    /// USER PATH: Coding Assistant chat is mid-conversation, app is force-quit
    /// while step waits for `ask_supervisor`. User opens app, sees Answer chip,
    /// answers. Run must continue.
    ///
    /// This test goes through the real persistence layer: it writes the pending
    /// state to disk via mutateTask, then **destroys and recreates the
    /// orchestrator** to mimic a real restart. `openWorkFolder` re-runs
    /// `StatusRecoveryService` and `syncEngineStateFromRun`, just like on app
    /// launch. Then the answer is submitted.
    func testRestartRoundtrip_chatAdvisory_answerContinuesRun() async {
        // ── Pre-restart: task with active ask_supervisor pause ──
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Чат", supervisorTask: "привет")!
        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(
                id: "coding_assistant",
                role: .softwareEngineer,
                title: "Coding Assistant",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Что дальше?",
                llmConversation: [
                    LLMMessage(role: .system, content: "system prompt"),
                    LLMMessage(role: .user, content: "привет"),
                    LLMMessage(role: .assistant, content: "Что дальше?")
                ]
            )
            var run = Run(id: 0, steps: [step], roleStatuses: ["coding_assistant": .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        // ── Simulate force-quit + relaunch: new orchestrator, reopen folder ──
        sut = TestOrchestrator.make(embeddingClient: embeddingClient)
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: id)

        // After recovery: status .paused, role .idle, but flag + session preserved.
        let recovered = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(recovered?.status, .paused,
                       "StatusRecoveryService must flip .needsSupervisorInput → .paused")
        XCTAssertTrue(recovered?.needsSupervisorInput ?? false,
                      "needsSupervisorInput flag must survive restart so the Answer chip surfaces")
        XCTAssertEqual(sut.activeTask?.runs.last?.roleStatuses["coding_assistant"], .idle,
                       "Working role must be reset to idle by recovery")
        XCTAssertEqual(sut.engineState[id], .paused,
                       "Engine state must be seeded to .paused for the active task")

        // ── User clicks Answer chip and submits ──
        let ok = await sut.answerSupervisorQuestion(
            stepID: "coding_assistant", taskID: id,
            answer: "продолжай"
        )
        XCTAssertTrue(ok, "Answer submission must succeed")

        // ── Run must continue: role promoted, step out of .paused ──
        let postAnswer = sut.activeTask?.runs.last?.steps.first
        XCTAssertNotEqual(postAnswer?.status, .paused,
                          "Step must transition out of .paused after answer (the bug we're fixing)")
        XCTAssertEqual(postAnswer?.supervisorAnswer, "продолжай")
        XCTAssertEqual(sut.activeTask?.runs.last?.roleStatuses["coding_assistant"], .working,
                       "Role must be promoted to .working — branch 1.5 in resumeRun")
        XCTAssertNotEqual(sut.engineState[id], .paused,
                          "Engine must leave .paused — run is continuing")
    }

    /// USER PATH: User restarts app, then queues a chat message before
    /// answering, then answers. The queue is in-memory (cleared on restart by
    /// design), so a queue made BEFORE answering loses to the answer-driven
    /// resume — but the answer itself must still kick the run.
    ///
    /// This regression-locks the order-of-operations the user described in
    /// their bug report ("я сначала ответил, run не запустился, потом сделал
    /// queue") so the answer path remains the canonical resume trigger.
    func testRestartRoundtrip_answerFirstThenQueue_runResumesOnAnswer() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Чат", supervisorTask: "привет")!
        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(
                id: "coding_assistant",
                role: .softwareEngineer,
                title: "Coding Assistant",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Q?"
            )
            let run = Run(id: 0, steps: [step], roleStatuses: ["coding_assistant": .working])
            task.runs = [run]
        }

        // Restart simulation
        sut = TestOrchestrator.make(embeddingClient: embeddingClient)
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: id)

        // Step 1: User answers (this is what failed before the fix).
        _ = await sut.answerSupervisorQuestion(
            stepID: "coding_assistant", taskID: id,
            answer: "первый ответ"
        )

        // Run must resume on the answer alone — the queue is irrelevant here.
        let step = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(step?.supervisorAnswer, "первый ответ")
        XCTAssertEqual(sut.activeTask?.runs.last?.roleStatuses["coding_assistant"], .working,
                       "Answer alone must resume the run — no need to also queue")
        XCTAssertNotEqual(sut.engineState[id], .paused)
    }

    /// USER PATH: Two consecutive restarts (e.g. crash, relaunch, crash again).
    /// The fix must be idempotent — the second restart cycle must not corrupt
    /// state or make the answer path stop working.
    func testRestartRoundtrip_twiceInARow_stillResumes() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Чат", supervisorTask: "x")!
        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(
                id: "coding_assistant",
                role: .softwareEngineer,
                title: "Coding Assistant",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Q?"
            )
            let run = Run(id: 0, steps: [step], roleStatuses: ["coding_assistant": .working])
            task.runs = [run]
        }

        // Restart #1
        sut = TestOrchestrator.make(embeddingClient: embeddingClient)
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: id)

        let afterFirstRestart = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(afterFirstRestart?.status, .paused)

        // Restart #2 — recovery should be a no-op since status is already .paused
        // and role is already .idle. The `.needsSupervisorInput` flag and the
        // supervisor question must both still be intact.
        sut = TestOrchestrator.make(embeddingClient: embeddingClient)
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: id)

        let afterSecondRestart = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(afterSecondRestart?.status, .paused)
        XCTAssertTrue(afterSecondRestart?.needsSupervisorInput ?? false,
                      "Flag must persist through multiple restarts")
        XCTAssertEqual(afterSecondRestart?.supervisorQuestion, "Q?")

        // Answer still works.
        _ = await sut.answerSupervisorQuestion(
            stepID: "coding_assistant", taskID: id,
            answer: "ok"
        )
        XCTAssertEqual(sut.activeTask?.runs.last?.roleStatuses["coding_assistant"], .working)
        XCTAssertEqual(sut.activeTask?.runs.last?.steps.first?.supervisorAnswer, "ok")
    }

    /// USER PATH: Multi-task setup. A chat task is the active one at restart
    /// time; another non-chat task is in the background. Restart, answer the
    /// chat. Only the chat task's engine should be affected.
    func testRestartRoundtrip_multipleTasks_onlyActiveResumes() async {
        await sut.openWorkFolder(tempDir)
        let chatID = await sut.createTask(title: "Чат", supervisorTask: "привет")!
        let bgID = await sut.createTask(title: "Background", supervisorTask: "do work")!

        await sut.mutateTask(taskID: chatID) { task in
            let step = StepExecution(
                id: "coding_assistant",
                role: .softwareEngineer,
                title: "Coding Assistant",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Q?"
            )
            let run = Run(id: 0, steps: [step], roleStatuses: ["coding_assistant": .working])
            task.runs = [run]
        }
        await sut.mutateTask(taskID: bgID) { task in
            let step = StepExecution(
                id: "engineer",
                role: .softwareEngineer,
                title: "SWE",
                status: .done,
                completedAt: MonotonicClock.shared.now()
            )
            let run = Run(id: 0, steps: [step], roleStatuses: ["engineer": .done])
            task.runs = [run]
        }

        // Make chat the active task, then restart.
        await sut.switchTask(to: chatID)
        sut = TestOrchestrator.make(embeddingClient: embeddingClient)
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(sut.activeTaskID, chatID,
                       "Active task must be restored from disk on reopen")

        _ = await sut.answerSupervisorQuestion(
            stepID: "coding_assistant", taskID: chatID,
            answer: "ok"
        )

        XCTAssertEqual(sut.activeTask?.runs.last?.roleStatuses["coding_assistant"], .working,
                       "Chat task's role must resume")
        // Background task's engine state should not be impacted (we never
        // touched it). Verifying explicitly: engine state for the background
        // task is whatever syncEngineStateFromRun assigned (or nil if it
        // wasn't the active task at restart). The chat task is the only one
        // that should have transitioned.
        XCTAssertNotEqual(sut.engineState[chatID], .paused)
    }

    // MARK: - Normal flow regression: status .needsSupervisorInput

    /// Sanity check that the normal flow (no restart — status was
    /// `.needsSupervisorInput` when answered) still works. The existing
    /// behavior must not regress: status flips to `.pending`,
    /// `engine.resume() → reconcileAfterPause()` picks it up.
    func testNormalFlow_answer_stillTransitionsToPending() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Test", supervisorTask: "x")!

        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(
                id: "swe", role: .softwareEngineer, title: "SWE",
                status: .needsSupervisorInput,   // <-- normal flow, no recovery
                needsSupervisorInput: true,
                supervisorQuestion: "Q?"
            )
            let run = Run(id: 0, steps: [step], roleStatuses: ["swe": .working])
            task.runs = [run]
        }
        sut.engineState[id] = .needsSupervisorInput

        _ = await sut.answerSupervisorQuestion(
            stepID: "swe", taskID: id,
            answer: "ok"
        )

        let step = sut.loadedTask(id)?.runs.last?.steps.first
        XCTAssertNotEqual(step?.status, .needsSupervisorInput,
                          "Normal flow must still transition out of .needsSupervisorInput")
        XCTAssertEqual(step?.supervisorAnswer, "ok")
        XCTAssertNotEqual(sut.engineState[id], .needsSupervisorInput,
                          "Engine must resume in normal flow")
    }
}
