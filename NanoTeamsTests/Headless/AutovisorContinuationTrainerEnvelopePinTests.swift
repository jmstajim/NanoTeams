import XCTest
@testable import NanoTeams

/// Pins the tool results `AutovisorContinuationTrainer` feeds the model in its two `message_task`
/// scenarios to the bytes production hands a built-in Autovisor manager (REC.10 measures the
/// bytes that ship, or it measures nothing).
///
/// The AFTER arm is compared with a real orchestrator answering the fixture's own `message_task`
/// call for a task in the scenario's state — decoded by `AutovisorToolDecoding` and run by
/// `AutovisorCommandExecutor` as the tool-result dispatcher runs it — so the pin covers the
/// routing that picks the reply, the reply's text and the envelope around it. Until 2026-11-07
/// both after arms injected strings written before Ш5 (`2963b3bb`) shipped its texts: other
/// wording, other advice, no `meta` object. Run 25 measured those strings.
///
/// The BEFORE arm is what the wave's base `147da1b1` shipped for both states: every
/// `message_task` was queued, the task was started when not running, and the reply was
/// `AutovisorReply.messageQueued` through the same `applyAutovisorAction` envelope builder. The
/// pre-Ш5 routing no longer exists to be asked, so its bytes are frozen here.
///
/// No engine starts and nothing reaches the network: the Review task never wakes, and the paused
/// task is pinned to the Generated placeholder with an empty brief, so its resume re-enters a
/// team generation that bails before building a request (`AutovisorActionDispatchTests`).
@MainActor
final class AutovisorContinuationTrainerEnvelopePinTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - After arm: production's answer for the scenario's state

    func testMessageTaskInReview_afterArm_isTheOrchestratorsAnswerForATaskInReview() async throws {
        let fixture = try await AutovisorContinuationTrainer.buildFixture(
            scenario: .messageTaskInReview, arm: .after)
        let taskID = try await makeReviewTask(numbered: 4)

        let production = try await productionEnvelope(for: fixture)

        XCTAssertTrue(production.contains(#""ok":false"#), "premise: a Review task refuses the message: \(production)")
        XCTAssertTrue(
            production.contains(AutovisorReply.messageDiscardedTaskFinished(taskID: taskID).text),
            "premise: the refusal is Ш5's `messageDiscardedTaskFinished`: \(production)")
        XCTAssertEqual(fixture.injectedEnvelope, production)
        XCTAssertEqual(fixture.messages.last?.content, production, "the bytes recorded are the bytes sent")
    }

    func testMessageTaskOnPaused_afterArm_isTheOrchestratorsAnswerForAPausedTask() async throws {
        let fixture = try await AutovisorContinuationTrainer.buildFixture(
            scenario: .messageTaskOnPaused, arm: .after)
        let taskID = try await makePausedTask(numbered: 5)

        let production = try await productionEnvelope(for: fixture)

        XCTAssertTrue(
            production.contains(AutovisorReply.messageQueuedAndResumed(taskID: taskID).text),
            "premise: a paused task is resumed and says so (Ш5): \(production)")
        XCTAssertEqual(fixture.injectedEnvelope, production)
        XCTAssertEqual(fixture.messages.last?.content, production, "the bytes recorded are the bytes sent")
    }

    // MARK: - Before arm: the bytes 147da1b1 shipped

    func testBothBeforeArms_carryTheMessageQueuedEnvelopeTheWaveBaseShipped() async throws {
        let review = try await AutovisorContinuationTrainer.buildFixture(
            scenario: .messageTaskInReview, arm: .before)
        let paused = try await AutovisorContinuationTrainer.buildFixture(
            scenario: .messageTaskOnPaused, arm: .before)

        XCTAssertEqual(
            review.injectedEnvelope,
            #"{"data":{"message":"Queued message for task #4.","status":"ok"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#)
        XCTAssertEqual(
            paused.injectedEnvelope,
            #"{"data":{"message":"Queued message for task #5.","status":"ok"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#)
        XCTAssertEqual(review.messages.last?.content, review.injectedEnvelope)
        XCTAssertEqual(paused.messages.last?.content, paused.injectedEnvelope)
    }

    // MARK: - History: one context, rendered by production

    /// REC.10 varies ONE text: both arms must share every turn but the injected one.
    func testBothArms_shareEveryTurnButTheInjectedToolResult() async throws {
        for scenario in [AutovisorContinuationScenario.messageTaskInReview, .messageTaskOnPaused] {
            let before = try await AutovisorContinuationTrainer.buildFixture(scenario: scenario, arm: .before)
            let after = try await AutovisorContinuationTrainer.buildFixture(scenario: scenario, arm: .after)
            XCTAssertEqual(before.messages.count, after.messages.count, scenario.rawValue)
            XCTAssertEqual(
                Array(before.messages.dropLast()), Array(after.messages.dropLast()),
                "\(scenario.rawValue): only the message_task result may differ between arms")
            XCTAssertNotEqual(before.injectedEnvelope, after.injectedEnvelope, scenario.rawValue)
        }
    }

    /// The `task_status` turn the manager read before it called `message_task` comes out of
    /// `LLMExecutionService.renderTaskStatusEnvelope`, and it reads the scenario's state: the
    /// hand-written one it replaced spelled the close hint `{"tool":…,"args":…}`, keys production
    /// never emits, and carried no `meta`.
    func testTaskStatusTurn_isProductionShapedAndReadsTheScenarioState() async throws {
        let emptyMeta = #""meta":{"truncated":false,"warnings":[]}"#

        let review = try await AutovisorContinuationTrainer.buildFixture(scenario: .messageTaskInReview, arm: .after)
        let reviewTurn = try XCTUnwrap(Self.taskStatusTurn(in: review), "review fixture has a task_status turn")
        XCTAssertTrue(reviewTurn.contains(emptyMeta), "production envelopes carry `meta`: \(reviewTurn)")
        let reviewStatus = try XCTUnwrap(Self.jsonObject(reviewTurn))
        let reviewData = try XCTUnwrap(reviewStatus["data"] as? [String: Any])
        XCTAssertEqual(reviewData["status"] as? String, TaskStatus.needsSupervisorAcceptance.rawValue)
        XCTAssertEqual(reviewData["task_id"] as? Int, 4)
        let next = try XCTUnwrap(reviewStatus["next"] as? [String: Any], "a Review task with no gate carries the close hint")
        XCTAssertEqual(next["suggested_cmd"] as? String, ToolNames.controlTask)
        XCTAssertEqual(next["suggested_args"] as? [String: String], ["action": "close", "task_id": "4"])
        XCTAssertEqual(next["reason"] as? String, LLMExecutionService.reviewReadyCloseReason)

        let paused = try await AutovisorContinuationTrainer.buildFixture(scenario: .messageTaskOnPaused, arm: .after)
        let pausedTurn = try XCTUnwrap(Self.taskStatusTurn(in: paused), "paused fixture has a task_status turn")
        XCTAssertTrue(pausedTurn.contains(emptyMeta), "production envelopes carry `meta`: \(pausedTurn)")
        let pausedStatus = try XCTUnwrap(Self.jsonObject(pausedTurn))
        XCTAssertNil(pausedStatus["next"], "a paused task carries no close hint")
        let pausedData = try XCTUnwrap(pausedStatus["data"] as? [String: Any])
        XCTAssertEqual(pausedData["status"] as? String, TaskStatus.paused.rawValue)
        XCTAssertEqual(pausedData["task_id"] as? Int, 5)
        let steps = try XCTUnwrap(pausedData["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.first?["resumable"] as? Bool, true, "the paused step is one `resume` would continue")
    }

    // MARK: - Production

    /// What the built-in manager reads for the fixture's own `message_task` call: the production
    /// decoder and executor over the orchestrator under test.
    private func productionEnvelope(for fixture: AutovisorContinuationPromptFixture) async throws -> String {
        let command = try AutovisorToolDecoding.decode(
            tool: fixture.targetToolName, rawArgs: fixture.targetArgumentsJSON
        ).get()
        let executor = AutovisorCommandExecutor(executionService: sut.llmExecutionService, delegate: sut)
        return await executor.execute(command, as: .builtInManager)
    }

    /// The envelope answering the fixture's `task_status` call, as sent.
    private static func taskStatusTurn(in fixture: AutovisorContinuationPromptFixture) -> String? {
        let statusCallIDs = Set(fixture.messages.flatMap { message in
            (message.toolCalls ?? []).filter { $0.name == ToolNames.taskStatus }.map(\.id)
        })
        return fixture.messages.first(where: { message in
            message.role == .tool && message.toolCallID.map(statusCallIDs.contains) == true
        })?.content
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Folder fixtures

    /// Opens the folder and pins a manager task, then fills task numbers until the next task
    /// created gets `id`: the trainer's history names its tasks by number, and so does the reply.
    private func openFolder(reservingNumbersBelow id: Int) async throws {
        await sut.openWorkFolder(tempDir)
        let manager = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)
        let managerID = try XCTUnwrap(manager, "createTask failed")
        await sut.mutateWorkFolder { $0.state.autovisorTaskID = managerID }
        while (sut.snapshot?.tasksIndex.nextTaskID ?? id) < id {
            let filler = await sut.createTask(title: "Filler", supervisorTask: "filler", makeActive: false)
            _ = try XCTUnwrap(filler, "createTask failed")
        }
    }

    /// A non-chat task whose only role finished and was accepted: Review, nothing at a gate.
    private func makeReviewTask(numbered id: Int) async throws -> Int {
        try await openFolder(reservingNumbersBelow: id)
        let created = await sut.createTask(title: "Add unit tests", supervisorTask: "add tests", makeActive: false)
        let taskID = try XCTUnwrap(created, "createTask failed")
        XCTAssertEqual(taskID, id, "premise: the task carries the number the fixture names")
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(false)
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .done)],
                roleStatuses: ["r": .done])]
        }
        await registerRolesOnActiveTeam(["r"])
        sut.engineState[taskID] = .needsAcceptance
        XCTAssertEqual(
            sut.loadedTask(taskID)?.derivedStatusFromActiveRun(), .needsSupervisorAcceptance,
            "premise: the task is in Review")
        return taskID
    }

    /// A task paused mid-run with a resumable step, pinned to the Generated placeholder with an
    /// empty brief so the resume `message_task` performs can never reach an engine.
    private func makePausedTask(numbered id: Int) async throws -> Int {
        try await openFolder(reservingNumbersBelow: id)
        let placeholder = TeamTemplateFactory.generatedTeam()
        await sut.mutateWorkFolder { projection in
            if !projection.teams.contains(where: { $0.templateID == DelegationConstants.generatedTeamSentinel }) {
                projection.teams.append(placeholder)
            }
        }
        let generatedTeamID = try XCTUnwrap(
            sut.snapshot?.workFolder.teams.first(where: { $0.templateID == DelegationConstants.generatedTeamSentinel })?.id,
            "the generated placeholder team must be present after seeding")
        let created = await sut.createTask(
            title: "Refactor networking", supervisorTask: "", preferredTeamID: generatedTeamID, makeActive: false)
        let taskID = try XCTUnwrap(created, "createTask failed")
        XCTAssertEqual(taskID, id, "premise: the task carries the number the fixture names")
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            task.status = .paused
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .paused)],
                roleStatuses: ["r": .working])]
        }
        sut.engineState[taskID] = .paused
        XCTAssertEqual(sut.loadedTask(taskID)?.derivedStatusFromActiveRun(), .paused, "premise: the task is paused")
        return taskID
    }
}
