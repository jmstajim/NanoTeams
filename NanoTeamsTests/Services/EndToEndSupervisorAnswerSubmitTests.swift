import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for **Supervisor answer submission** — Supervisor
/// sees a role asking a question, types an answer, clicks Send. Must:
/// 1. Record the answer on the step (persisted + in-memory).
/// 2. Clear `needsSupervisorInput` so the feed no longer shows the prompt.
/// 3. Auto-resume if the engine was `.paused` or `.needsSupervisorInput`.
/// 4. Record attached paths (via finalization) on the step.
/// 5. Clean up staged attachment draft dir on success.
/// 6. Return `false` (no auto-resume, no state mutation) if attachment
///    finalization fails.
/// 7. Combine answer text + attachment paths into `effectiveSupervisorAnswer`.
@MainActor
final class EndToEndSupervisorAnswerSubmitTests: NTMSOrchestratorTestBase {

    private func seedStepNeedingInput(taskID: Int, stepID: String = "pm",
                                       question: String = "Should I use Redis?") async
    {
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(
                id: stepID,
                role: .productManager,
                title: "PM",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: question
            )
            var run = Run(id: 0, steps: [step],
                          roleStatuses: [stepID: .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
    }

    // MARK: - Scenario 1: Plain answer is recorded

    func testAnswer_plainText_recordedOnStep() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!
        await seedStepNeedingInput(taskID: id)

        let ok = await sut.answerSupervisorQuestion(
            stepID: "pm", taskID: id,
            answer: "Yes, use Redis for caching."
        )
        XCTAssertTrue(ok)

        let step = sut.loadedTask(id)?.runs.last?.steps.first
        XCTAssertEqual(step?.supervisorAnswer, "Yes, use Redis for caching.")
    }

    // MARK: - Scenario 2: Answer clears needsSupervisorInput flag

    func testAnswer_clearsNeedsSupervisorInputFlag() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!
        await seedStepNeedingInput(taskID: id)

        _ = await sut.answerSupervisorQuestion(
            stepID: "pm", taskID: id,
            answer: "Answer."
        )

        let step = sut.loadedTask(id)?.runs.last?.steps.first
        XCTAssertFalse(step?.needsSupervisorInput ?? true,
                       "Submitting an answer must clear the needsSupervisorInput flag")
        XCTAssertNotEqual(step?.status, .needsSupervisorInput,
                          "Step status transitions away from .needsSupervisorInput")
    }

    // MARK: - Scenario 3: Auto-resume when engine was paused/needsInput

    func testAnswer_whenEnginePaused_autoResumes() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!
        await seedStepNeedingInput(taskID: id)

        // Simulate engine being in .paused state
        sut.engineState[id] = .paused

        _ = await sut.answerSupervisorQuestion(
            stepID: "pm", taskID: id,
            answer: "Proceed."
        )

        // After answer, engine state should not still be .paused — either
        // `.running` (resumeRun kicked off) or at minimum NOT paused.
        XCTAssertNotEqual(sut.engineState[id], .paused,
                          "Engine must be resumed after supervisor answer")
    }

    func testAnswer_whenEngineNeedsInput_autoResumes() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!
        await seedStepNeedingInput(taskID: id)

        sut.engineState[id] = .needsSupervisorInput

        _ = await sut.answerSupervisorQuestion(
            stepID: "pm", taskID: id,
            answer: "Proceed."
        )

        XCTAssertNotEqual(sut.engineState[id], .needsSupervisorInput,
                          "Engine must resume when we answer a needsSupervisorInput")
    }

    // MARK: - Scenario 4: No auto-resume on terminal states

    func testAnswer_whenEngineDone_noResume() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!
        await seedStepNeedingInput(taskID: id)

        // If engine is .done, answering shouldn't wake it up
        sut.engineState[id] = .done

        _ = await sut.answerSupervisorQuestion(
            stepID: "pm", taskID: id,
            answer: "Too late."
        )

        XCTAssertEqual(sut.engineState[id], .done,
                       "Engine in .done stays .done — no resurrection")
    }

    // MARK: - Scenario 5: Attachment paths merged into effectiveSupervisorAnswer

    func testAnswer_withAttachmentPaths_includedInEffectiveAnswer() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!

        // Seed step with attachment paths directly (bypasses staging —
        // simulates post-finalization state).
        await sut.mutateTask(taskID: id) { task in
            var step = StepExecution(
                id: "pm", role: .productManager, title: "PM",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Which image?",
                supervisorAnswerAttachmentPaths: []
            )
            step.supervisorAnswer = "This one."
            step.supervisorAnswerAttachmentPaths = [".nanoteams/tasks/1/attachments/a.png"]
            step.needsSupervisorInput = false
            var run = Run(id: 0, steps: [step], roleStatuses: ["pm": .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        let step = sut.loadedTask(id)?.runs.last?.steps.first
        let effective = step?.effectiveSupervisorAnswer
        XCTAssertNotNil(effective)
        XCTAssertTrue(effective!.contains("This one."))
        XCTAssertTrue(effective!.contains("a.png"),
                      "effectiveSupervisorAnswer must surface attached paths")
    }

    // MARK: - Scenario 6: Empty answer is still recorded

    /// An empty answer is valid — the user may be signalling "I don't
    /// know / proceed with your best guess". The orchestrator must record
    /// it (triggering resume) rather than silently drop.
    func testAnswer_emptyString_stillRecordedAndResumes() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!
        await seedStepNeedingInput(taskID: id)
        sut.engineState[id] = .paused

        let ok = await sut.answerSupervisorQuestion(
            stepID: "pm", taskID: id,
            answer: ""
        )
        XCTAssertTrue(ok, "Empty answer must be accepted")

        XCTAssertNotEqual(sut.engineState[id], .paused,
                          "Empty answer still triggers resume")
    }

    // MARK: - Scenario 7: Multiple questions — answering one doesn't affect others

    func testAnswer_multipleSteps_onlyTargetUpdated() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!

        await sut.mutateTask(taskID: id) { task in
            let stepA = StepExecution(
                id: "pm", role: .productManager, title: "PM",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Q from PM"
            )
            let stepB = StepExecution(
                id: "tech_lead", role: .techLead, title: "TL",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Q from TL"
            )
            var run = Run(id: 0, steps: [stepA, stepB],
                          roleStatuses: ["pm": .working, "tech_lead": .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        _ = await sut.answerSupervisorQuestion(
            stepID: "pm", taskID: id,
            answer: "Reply to PM only"
        )

        let steps = sut.loadedTask(id)?.runs.last?.steps ?? []
        let pmStep = steps.first { $0.id == "pm" }
        let tlStep = steps.first { $0.id == "tech_lead" }

        XCTAssertEqual(pmStep?.supervisorAnswer, "Reply to PM only")
        XCTAssertNil(tlStep?.supervisorAnswer,
                     "TL's question must not be affected by PM's answer")
        XCTAssertTrue(tlStep?.needsSupervisorInput ?? false,
                      "TL still awaits its own answer")
    }

    // MARK: - Scenario 8: Persisted to disk — survives reopen

    func testAnswer_persistsAcrossReopen() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!
        await seedStepNeedingInput(taskID: id, stepID: "pm",
                                    question: "Q?")

        _ = await sut.answerSupervisorQuestion(
            stepID: "pm", taskID: id,
            answer: "Persistent answer"
        )

        // Simulate app restart
        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: id)

        let step = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(step?.supervisorAnswer, "Persistent answer",
                       "Answer must be persisted to task.json")
        XCTAssertFalse(step?.needsSupervisorInput ?? true,
                       "needsSupervisorInput must stay cleared after reopen")
    }
}
