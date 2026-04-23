import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for **chat-mode task lifecycle**.
///
/// In a chat-mode team (Supervisor has no required artifacts — e.g. the
/// Personal Assistant template), a task runs open-ended. The UI shows
/// "Chat" instead of "Working" / "Needs review" / "Done" because the task
/// never terminates unless the user explicitly closes it.
///
/// Covered scenarios:
/// 1. Create a task on a chat-mode team → `task.isChatMode == true`.
/// 2. Chat task derivedStatus returns `.running` instead of
///    `.needsSupervisorAcceptance` when all steps are `.done`.
/// 3. Closing a chat task transitions it to `.done`.
/// 4. `finishableAdvisoryRoles` returns empty for chat mode — the
///    Supervisor cannot "finish" advisory roles manually (no Finish button).
/// 5. After close, `closedAt` is set and `derivedStatus` returns `.done`.
/// 6. Creating a task on a non-chat team → `task.isChatMode == false`.
/// 7. `adoptGeneratedTeam` with a chat-mode generated team flips the
///    task's observed `isChatMode` — even if `storedIsChatMode` was false.
/// 8. `clearGeneratedTeam` after adoption leaves `storedIsChatMode`
///    synced with the generated team (so the fallback survives save).
/// 9. Chat tasks survive reopen with isChatMode intact.
@MainActor
final class EndToEndChatModeTaskLifecycleTests: NTMSOrchestratorTestBase {

    // MARK: - Helpers

    /// Finds the Personal Assistant template team (isChatMode == true) or
    /// any team whose settings mark it as chat-mode (empty
    /// supervisor-required artifacts).
    private func chatModeTeamID() -> NTMSID? {
        sut.workFolder?.teams.first(where: { $0.isChatMode })?.id
    }

    private func nonChatModeTeamID() -> NTMSID? {
        sut.workFolder?.teams.first(where: { !$0.isChatMode })?.id
    }

    // MARK: - Scenario 1: Chat-mode team → chat-mode task

    func testCreateTask_onChatModeTeam_producesChatModeTask() async {
        await sut.openWorkFolder(tempDir)
        guard let chatTeamID = chatModeTeamID() else {
            return XCTFail("Bootstrap must include at least one chat-mode team (Personal Assistant)")
        }

        let id = await sut.createTask(
            title: "Help me plan",
            supervisorTask: "I need a dinner plan",
            preferredTeamID: chatTeamID
        )!
        await sut.switchTask(to: id)

        XCTAssertTrue(sut.activeTask?.isChatMode ?? false,
                      "Task created on chat-mode team must be chat-mode")
    }

    // MARK: - Scenario 2: Non-chat team → non-chat task

    func testCreateTask_onNonChatTeam_producesNonChatTask() async {
        await sut.openWorkFolder(tempDir)
        guard let teamID = nonChatModeTeamID() else {
            return XCTFail("Bootstrap must include at least one non-chat team")
        }

        let id = await sut.createTask(
            title: "Build",
            supervisorTask: "Ship v1",
            preferredTeamID: teamID
        )!
        await sut.switchTask(to: id)

        XCTAssertFalse(sut.activeTask?.isChatMode ?? true,
                       "Task on non-chat team must not be chat-mode")
    }

    // MARK: - Scenario 3: Derived status semantics

    func testChatMode_allDoneSteps_derivedStatusStillRunning() async {
        await sut.openWorkFolder(tempDir)
        guard let chatTeamID = chatModeTeamID() else {
            return XCTFail("Need a chat-mode team")
        }

        let id = await sut.createTask(
            title: "Chat", supervisorTask: "Help",
            preferredTeamID: chatTeamID
        )!

        // Construct a run with one done step in-memory
        await sut.mutateTask(taskID: id) { task in
            var run = Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .assistant,
                              title: "A", status: .done,
                              completedAt: MonotonicClock.shared.now())
            ], roleStatuses: ["assistant": .done])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        XCTAssertEqual(
            sut.loadedTask(id)?.derivedStatusFromActiveRun(), .running,
            "All steps .done + chat mode → stays `.running` (no acceptance prompt)"
        )
    }

    func testNonChatMode_allDoneSteps_derivedStatusIsNeedsAcceptance() async {
        await sut.openWorkFolder(tempDir)
        guard let teamID = nonChatModeTeamID() else {
            return XCTFail("Need a non-chat team")
        }

        let id = await sut.createTask(
            title: "Build", supervisorTask: "Ship",
            preferredTeamID: teamID
        )!

        await sut.mutateTask(taskID: id) { task in
            var run = Run(id: 0, steps: [
                StepExecution(id: "pm", role: .productManager,
                              title: "PM", status: .done,
                              completedAt: MonotonicClock.shared.now())
            ], roleStatuses: ["pm": .done])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        XCTAssertEqual(
            sut.loadedTask(id)?.derivedStatusFromActiveRun(), .needsSupervisorAcceptance,
            "All steps .done + non-chat mode → prompts acceptance"
        )
    }

    // MARK: - Scenario 4: closeTask transitions chat task to .done

    func testCloseTask_chatMode_transitionsToDone() async {
        await sut.openWorkFolder(tempDir)
        guard let chatTeamID = chatModeTeamID() else {
            return XCTFail("Need a chat-mode team")
        }

        let id = await sut.createTask(
            title: "Chat", supervisorTask: "x",
            preferredTeamID: chatTeamID
        )!

        // Simulate a mid-running chat task
        await sut.mutateTask(taskID: id) { task in
            var run = Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .assistant,
                              title: "A", status: .running)
            ], roleStatuses: ["assistant": .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        let success = await sut.closeTask(taskID: id)
        XCTAssertTrue(success)

        let closed = sut.loadedTask(id)
        XCTAssertNotNil(closed?.closedAt, "closedAt must be set")
        XCTAssertEqual(closed?.derivedStatusFromActiveRun(), .done,
                       "After close, chat task's derivedStatus is .done")
    }

    // MARK: - Scenario 5: closeTask finalizes advisory/running steps

    /// Chat-mode advisory roles may still be `.running`/`.paused` at close
    /// time (user never pressed "Finish" — there's no Finish button in
    /// chat mode). closeTask must finalize them to `.done` on behalf of
    /// the user so no step is stranded.
    func testCloseTask_chatMode_finalizesRunningSteps() async {
        await sut.openWorkFolder(tempDir)
        guard let chatTeamID = chatModeTeamID() else {
            return XCTFail("Need a chat-mode team")
        }

        let id = await sut.createTask(
            title: "Chat", supervisorTask: "x",
            preferredTeamID: chatTeamID
        )!

        await sut.mutateTask(taskID: id) { task in
            var run = Run(id: 0, steps: [
                StepExecution(id: "a", role: .assistant, title: "A", status: .running),
                StepExecution(id: "b", role: .assistant, title: "B", status: .paused),
                StepExecution(id: "c", role: .assistant, title: "C", status: .needsSupervisorInput),
            ], roleStatuses: [
                "a": .working, "b": .working, "c": .working,
            ])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        _ = await sut.closeTask(taskID: id)

        let task = sut.loadedTask(id)
        for step in task?.runs.last?.steps ?? [] {
            XCTAssertEqual(step.status, .done,
                           "Step `\(step.id)` must be finalized to .done on close")
            XCTAssertNotNil(step.completedAt,
                            "Each finalized step gets a completedAt timestamp")
        }
        for (_, status) in task?.runs.last?.roleStatuses ?? [:] {
            XCTAssertEqual(status, .done,
                           "Role statuses must mirror step finalization")
        }
    }

    // MARK: - Scenario 6: isChatMode survives reopen

    func testChatMode_survivesReopen() async {
        await sut.openWorkFolder(tempDir)
        guard let chatTeamID = chatModeTeamID() else {
            return XCTFail("Need a chat-mode team")
        }
        let id = await sut.createTask(title: "Chat", supervisorTask: "x",
                                      preferredTeamID: chatTeamID)!

        // Reopen
        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: id)

        XCTAssertTrue(sut.activeTask?.isChatMode ?? false,
                      "Task's isChatMode survives restart via stored field")
    }

    // MARK: - Scenario 7: adoptGeneratedTeam flips chat mode

    /// A task created with a non-chat preferred team, then overridden by a
    /// generated chat-mode team, must observe isChatMode = true via the
    /// dominating-generated-team rule.
    func testAdoptGeneratedTeam_chatModeTeam_flipsObservedIsChatMode() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "x",
                            isChatMode: false)
        XCTAssertFalse(task.isChatMode)

        // Build a minimal chat-mode team: generic template, supervisor has
        // no required artifacts => isChatMode is true.
        let genTeam = Team(
            id: "gen_abc",
            name: "Generated Chat",
            templateID: "generated",
            roles: [],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )

        task.adoptGeneratedTeam(genTeam)

        XCTAssertEqual(
            task.isChatMode, genTeam.isChatMode,
            "After adopt, observed isChatMode follows the generated team"
        )
    }

    /// clearGeneratedTeam keeps storedIsChatMode synced — saving a
    /// chat-mode generated team should leave the fallback at true.
    func testClearGeneratedTeam_keepsStoredChatModeInSync() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "x",
                            isChatMode: false)

        let genTeam = Team(
            id: "gen_abc",
            name: "Generated Chat",
            templateID: "generated",
            roles: [],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )
        task.adoptGeneratedTeam(genTeam)
        let chatModeAfterAdopt = task.isChatMode

        task.clearGeneratedTeam()

        XCTAssertEqual(task.isChatMode, chatModeAfterAdopt,
                       "After clear, observed isChatMode uses storedIsChatMode — must stay in sync with adopted team's value")
    }
}
